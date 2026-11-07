import 'dart:async';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, debugPrint, ValueNotifier;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// 一次测速的结果。
typedef CdnSpeedResult = ({CDNService service, double bytesPerSecond});

/// 自动 CDN 管家。
///
/// 职责：
/// 1. APP 首帧渲染完成后，在后台并行对全部候选 CDN 测速并选出最快线路；
/// 2. WiFi / 蜂窝网络切换时重新测速选优；
/// 3. 缓存测速结果与测速样本，供播放卡顿时按速度排序自动换线；
/// 4. 记录用户手动指定的 CDN，避免自动逻辑覆盖用户选择。
///
/// 设计说明：B 站的 mirror CDN 链接签名与 host 无关，因此只要保留官方返回的
/// 播放 URL（含查询串），把其中的 host 替换成其它 CDN 即可直接使用，
/// 无需重新请求 playurl 接口。
abstract final class CdnAutoManager {
  /// 测速候选：排除不能替换 host 的特殊项，以及需要登录/海外环境的海外线路。
  static final List<CDNService> _candidates = [
    for (final e in CDNService.values)
      if (e != CDNService.baseUrl &&
          e != CDNService.backupUrl &&
          e != CDNService.akamai &&
          e != CDNService.aliov &&
          e != CDNService.cosov &&
          e != CDNService.hwov &&
          e != CDNService.hk_bcache)
        e,
  ];

  static const int _sampleBvidCid = 196018899;
  static const String _sampleBvid = 'BV1fK4y1t7hj';

  /// 单节点最多下载 10MB 用于测速（结果更贴近真实播放吞吐）。
  static const int _maxBytesPerTest = 10 * 1024 * 1024;

  /// 单节点整体最长测速时间。
  static const Duration _perTestTimeout = Duration(seconds: 20);

  /// 慢节点判定：持续低速超过该时长即淘汰。
  static const Duration _slowGrace = Duration(seconds: 5);

  /// 慢节点阈值：1 MB/s。
  static const double _slowThresholdBytesPerSecond = 1024 * 1024;

  /// 并行测速的并发上限，避免同时打满移动网络。
  static const int _concurrency = 6;

  /// 启动后延迟多久开始测速，确保首帧与首页加载完成。
  static const Duration _startupDelay = Duration(seconds: 3);

  static const String _kSampleUrl = 'cdnAutoSampleUrl';
  static const String _kSampleTime = 'cdnAutoSampleTime';
  static const String _kResults = 'cdnAutoRanking';
  static const String _kNetworkTag = 'cdnAutoNetworkTag';

  static final List<CdnSpeedResult> _ranking = <CdnSpeedResult>[];
  static bool _running = false;
  static Timer? _startupTimer;

  /// 测速进行中标记，供 UI 展示。
  static final ValueNotifier<bool> testing = ValueNotifier<bool>(false);

  static bool get autoCdnEnabled => Pref.autoCdn;
  static bool get autoCdnStallSwitchEnabled => Pref.autoCdnStallSwitch;

  /// 按测速速度从快到慢排序的线路列表；未测速过时回退到内置候选顺序。
  static List<CDNService> get rankedServices {
    if (_ranking.isEmpty) return _candidates;
    return _ranking.map((e) => e.service).toList();
  }

  /// 完整测速排名（含速度），供播放页 CDN 列表展示。
  static List<CdnSpeedResult> get ranking => List.unmodifiable(_ranking);

  /// 最近一次测速结果的可读描述，供设置页展示。
  static String get rankingSummary {
    if (_ranking.isEmpty) return '暂无测速结果';
    return _ranking
        .take(5)
        .map(
          (e) =>
              '${e.service.name}: ${(e.bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s',
        )
        .join('\n');
  }

  /// 手动选择 CDN 时调用：写入用户偏好，并让自动逻辑不要覆盖。
  static Future<void> setManualCdn(CDNService service) async {
    VideoUtils.cdnService = service;
    VideoUtils.autoCdnSelected = false;
    await GStorage.setting.put(SettingBoxKey.CDNService, service.name);
    await GStorage.setting.put(SettingBoxKey.autoCdnSelected, false);
  }

  /// 换线失败时恢复到原线路，同时保持「自动」状态。
  static void restoreAutoCdn(CDNService service) {
    VideoUtils.cdnService = service;
    VideoUtils.autoCdnSelected = true;
    GStorage.setting.put(SettingBoxKey.CDNService, service.name);
    GStorage.setting.put(SettingBoxKey.autoCdnSelected, true);
  }

  /// APP 启动时调用：恢复上次结果，并在首帧之后延迟触发测速。
  static void init() {
    restoreRanking();
    if (!autoCdnEnabled) return;
    final autoSelected =
        GStorage.setting.get(SettingBoxKey.autoCdnSelected) == true;
    final cdnName = GStorage.setting.get(SettingBoxKey.CDNService);
    if (autoSelected && cdnName is String) {
      try {
        VideoUtils.cdnService = CDNService.values.byName(cdnName);
        VideoUtils.autoCdnSelected = true;
      } catch (_) {}
    }
    _startupTimer?.cancel();
    _startupTimer = Timer(_startupDelay, () {
      unawaited(_runAutoTest(trigger: '启动', notify: true));
    });
  }

  /// 由首帧回调调用，确保测速不会与启动抢资源。
  static void scheduleStartupTest() {
    if (!autoCdnEnabled || _startupTimer != null) return;
    _startupTimer?.cancel();
    _startupTimer = Timer(_startupDelay, () {
      unawaited(_runAutoTest(trigger: '启动', notify: true));
    });
  }

  /// 网络状态变化时调用（移动/WiFi 切换、SIM 网络变化等）。
  static Future<void> onConnectivityChanged() async {
    if (!autoCdnEnabled) return;
    final tag = await _currentNetworkTag();
    final lastTag = GStorage.setting.get(_kNetworkTag);
    if (lastTag == tag) return;
    await GStorage.setting.put(_kNetworkTag, tag);
    await _runAutoTest(trigger: '网络变化', notify: true);
  }

  /// 手动触发一次测速（设置页「立即测速」、播放页 CDN 列表）。
  static Future<void> testNow({bool notify = true}) =>
      _runAutoTest(trigger: '手动', force: true, notify: notify);

  static Future<String> _currentNetworkTag() async {
    final isWiFi = await ConnectivityUtils.isWiFi;
    return isWiFi ? 'wifi' : 'cellular';
  }

  static Future<void> _runAutoTest({
    required String trigger,
    bool force = false,
    bool notify = false,
  }) async {
    if (!autoCdnEnabled && !force) return;
    if (_running) return;
    _running = true;
    testing.value = true;
    try {
      if (kDebugMode) debugPrint('[CDN自动] 开始并行测速，触发：$trigger');
      final playUrls = await _getSamplePlayUrls();
      if (playUrls == null || playUrls.isEmpty) {
        if (kDebugMode) debugPrint('[CDN自动] 无法获取测速样本，跳过');
        if (notify) showToast('CDN 测速失败：无法获取测速样本');
        return;
      }

      final results = await _measureAll(playUrls);

      if (results.isEmpty) {
        if (kDebugMode) debugPrint('[CDN自动] 所有线路测速均失败，保持当前线路');
        if (notify) showToast('CDN 测速完成：无可用线路，保持当前设置');
        return;
      }

      results.sort((a, b) => b.bytesPerSecond.compareTo(a.bytesPerSecond));
      _ranking
        ..clear()
        ..addAll(results);

      await _saveRanking(results);
      await _applyBest(results.first.service, trigger: trigger, force: force);

      if (notify) {
        final best = results.first;
        final speed = best.bytesPerSecond / (1024 * 1024);
        showToast(
          'CDN 测速完成，已自动选择 ${best.service.desc}（${speed.toStringAsFixed(2)} MB/s）',
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[CDN自动] 测速异常：$e');
      if (notify) showToast('CDN 测速异常，已保持当前线路');
    } finally {
      _running = false;
      testing.value = false;
    }
  }

  /// 并行测速：分批发起，单节点卡住不会阻塞其它节点。
  static Future<List<CdnSpeedResult>> _measureAll(
    Iterable<String> playUrls,
  ) async {
    final results = <CdnSpeedResult>[];
    final tasks = <_CdnTestTask>[];

    for (final service in _candidates) {
      final url = VideoUtils.getCdnUrl(
        playUrls,
        defaultCDNService: service,
      );
      // 某些特殊链接（mcdn / tf 代理）无法直接替换 host，生成的结果
      // 并非该 CDN 的地址，测速没有意义，直接跳过。
      if (!isCdnUrlValid(url, service)) {
        if (kDebugMode) {
          debugPrint('[CDN自动] ${service.name} 无法替换 host，跳过');
        }
        continue;
      }
      tasks.add(_CdnTestTask(service, url));
    }

    if (tasks.isEmpty) return results;

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 6),
        headers: {
          'user-agent': BrowserUa.pc,
          'referer': HttpString.baseUrl,
        },
      ),
    );

    try {
      // 分批并行：每批最多 [_concurrency] 个节点同时测速。
      for (var i = 0; i < tasks.length; i += _concurrency) {
        final batch = tasks.skip(i).take(_concurrency).toList();
        final batchResults = await Future.wait(
          batch.map((task) => _measureSpeed(dio, task)),
        );
        for (final result in batchResults) {
          if (result != null) results.add(result);
        }
      }
    } finally {
      dio.close(force: true);
    }
    return results;
  }

  /// 单个节点测速。返回 null 表示该节点失败或被判定过慢。
  static Future<CdnSpeedResult?> _measureSpeed(
    Dio dio,
    _CdnTestTask task,
  ) async {
    final token = CancelToken();
    Timer? hardTimer;
    Timer? slowTimer;
    int downloaded = 0;
    bool slowAborted = false;
    final start = DateTime.now().microsecondsSinceEpoch;

    void abortSlow() {
      slowAborted = true;
      token.cancel();
    }

    try {
      // 整体硬超时，防止节点完全无响应。
      hardTimer = Timer(_perTestTimeout, token.cancel);
      // 慢节点宽限期：5 秒后如果平均速度仍低于 1MB/s，直接淘汰。
      slowTimer = Timer(_slowGrace, () {
        final elapsed = DateTime.now().microsecondsSinceEpoch - start;
        final speed = elapsed > 0 ? downloaded * 1000000 / elapsed : 0.0;
        if (speed < _slowThresholdBytesPerSecond) abortSlow();
      });

      await dio.get<dynamic>(
        task.url,
        cancelToken: token,
        onReceiveProgress: (count, _) {
          downloaded = count;
          if (downloaded >= _maxBytesPerTest) token.cancel();
        },
      );
    } catch (_) {
      // 达到上限 / 超时 / 慢节点淘汰都会由 CancelToken 主动取消，属于正常结束。
    } finally {
      hardTimer?.cancel();
      slowTimer?.cancel();
    }

    if (slowAborted) {
      if (kDebugMode) debugPrint('[CDN自动] ${task.service.name} 过慢，跳过');
      return null;
    }
    if (downloaded <= 0) return null;
    final elapsed = DateTime.now().microsecondsSinceEpoch - start;
    if (elapsed <= 0) return null;
    final speed = downloaded * 1000000 / elapsed;
    final result = (service: task.service, bytesPerSecond: speed);
    if (kDebugMode) {
      debugPrint(
        '[CDN自动] ${task.service.name}: '
        '${(speed / (1024 * 1024)).toStringAsFixed(2)} MB/s '
        '(${(downloaded / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
    }
    return result;
  }

  /// 获取测速用的官方播放链接。优先复用近期缓存，避免每次启动都请求接口。
  static Future<Iterable<String>?> _getSamplePlayUrls() async {
    final cached = GStorage.localCache.get(_kSampleUrl);
    final cachedTime = GStorage.localCache.get(_kSampleTime);
    List<String>? cachedUrls;
    if (cached is List && cached.isNotEmpty) {
      cachedUrls = cached.whereType<String>().toList();
    } else if (cached is String && cached.isNotEmpty) {
      // 兼容早期版本只缓存单个 URL 的情况。
      cachedUrls = [cached];
    }
    if (cachedUrls != null &&
        cachedUrls.isNotEmpty &&
        cachedTime is int &&
        DateTime.now().millisecondsSinceEpoch - cachedTime <
            const Duration(hours: 6).inMilliseconds) {
      return cachedUrls;
    }

    try {
      final result = await VideoHttp.videoUrl(
        cid: _sampleBvidCid,
        bvid: _sampleBvid,
        qn: VideoQuality.high1080.code,
        tryLook: false,
        videoType: VideoType.ugc,
      );
      final item = result.dataOrNull?.dash?.video?.firstOrNull;
      final urls = item?.playUrls.toList();
      if (urls == null || urls.isEmpty) return null;
      await GStorage.localCache.put(_kSampleUrl, urls);
      await GStorage.localCache.put(
        _kSampleTime,
        DateTime.now().millisecondsSinceEpoch,
      );
      return urls;
    } catch (e) {
      if (kDebugMode) debugPrint('[CDN自动] 获取测速样本失败：$e');
      // 接口不可用时，退而使用旧缓存。
      if (cachedUrls != null && cachedUrls.isNotEmpty) return cachedUrls;
      return null;
    }
  }

  static Future<void> _applyBest(
    CDNService best, {
    required String trigger,
    bool force = false,
  }) async {
    // 用户手动选择的线路优先，不被自动结果覆盖；手动触发测速时强制应用。
    // autoCdnSelected 缺失表示旧版本或用户手动设置过：仅当保存的是默认值时才应用自动结果。
    final autoSelected =
        GStorage.setting.get(SettingBoxKey.autoCdnSelected) == true;
    final cdnName = GStorage.setting.get(SettingBoxKey.CDNService);
    if (!autoSelected && !force && cdnName is String) {
      try {
        final saved = CDNService.values.byName(cdnName);
        if (saved != _defaultCdn) {
          if (kDebugMode) {
            debugPrint('[CDN自动] 检测到手动线路 ${saved.name}，跳过自动应用');
          }
          return;
        }
      } catch (_) {}
    }

    VideoUtils.cdnService = best;
    VideoUtils.autoCdnSelected = true;
    await GStorage.setting.put(SettingBoxKey.CDNService, best.name);
    await GStorage.setting.put(SettingBoxKey.autoCdnSelected, true);
    if (kDebugMode) {
      debugPrint('[CDN自动] $trigger 完成，最优线路：${best.name}');
    }
  }

  /// 与 [Pref.defaultCDNService] 的默认值保持一致。
  static const CDNService _defaultCdn = CDNService.backupUrl;

  static Future<void> _saveRanking(List<CdnSpeedResult> results) async {
    await GStorage.localCache.put(
      _kResults,
      results
          .map((e) => '${e.service.name}:${e.bytesPerSecond.toStringAsFixed(0)}')
          .toList(),
    );
  }

  /// 从本地缓存恢复上次的测速排名（APP 启动时调用）。
  static void restoreRanking() {
    final saved = GStorage.localCache.get(_kResults);
    if (saved is! List) return;
    _ranking.clear();
    for (final entry in saved) {
      if (entry is! String) continue;
      final parts = entry.split(':');
      if (parts.length != 2) continue;
      try {
        final service = CDNService.values.byName(parts[0]);
        final speed = double.parse(parts[1]);
        _ranking.add((service: service, bytesPerSecond: speed));
      } catch (_) {}
    }
  }

  /// 播放卡顿时调用：换到排序中的下一条线路。
  ///
  /// 返回是否成功换线；调用方负责用新 URL 重载播放器并保持播放进度。
  static bool switchToNext({
    required CDNService current,
    required Set<CDNService> tried,
  }) {
    final services = rankedServices;
    if (services.length < 2) return false;

    var index = services.indexOf(current);
    if (index < 0) index = 0;
    for (var step = 1; step <= services.length; step++) {
      final candidate = services[(index + step) % services.length];
      if (candidate != current && !tried.contains(candidate)) {
        VideoUtils.cdnService = candidate;
        VideoUtils.autoCdnSelected = true;
        GStorage.setting.put(SettingBoxKey.CDNService, candidate.name);
        GStorage.setting.put(SettingBoxKey.autoCdnSelected, true);
        return true;
      }
    }
    return false;
  }

  /// 校验替换后的 URL 是否确实指向目标 CDN。
  static bool isCdnUrlValid(String url, CDNService service) {
    if (service.host == null) return false;
    return Uri.tryParse(url)?.host == service.host;
  }

  /// 统一的轻量提示。
  static void showToast(String message) {
    SmartDialog.showToast(
      message,
      displayTime: const Duration(seconds: 2),
    );
  }
}

class _CdnTestTask {
  const _CdnTestTask(this.service, this.url);
  final CDNService service;
  final String url;
}
