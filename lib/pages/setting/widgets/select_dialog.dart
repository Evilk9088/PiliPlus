import 'dart:async';

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/cdn_auto_manager.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:material_ui/material_ui.dart';

class SelectDialog<T> extends StatelessWidget {
  final T? value;
  final String title;
  final List<(T, String)> values;
  final Widget Function(BuildContext, int)? subtitleBuilder;
  final bool toggleable;

  const SelectDialog({
    super.key,
    this.value,
    required this.values,
    required this.title,
    this.subtitleBuilder,
    this.toggleable = false,
  });

  @override
  Widget build(BuildContext context) {
    final titleMedium = TextTheme.of(context).titleMedium!;
    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: Text(title),
      constraints: subtitleBuilder != null
          ? const BoxConstraints.tightFor(width: 320)
          : null,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: Material(
        type: .transparency,
        child: SingleChildScrollView(
          child: RadioGroup<T>(
            onChanged: (v) => Navigator.of(context).pop(v ?? value),
            groupValue: value,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                values.length,
                (index) {
                  final item = values[index];
                  return RadioListTile<T>(
                    toggleable: toggleable,
                    dense: true,
                    value: item.$1,
                    title: Text(
                      item.$2,
                      style: titleMedium,
                    ),
                    subtitle: subtitleBuilder?.call(context, index),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CdnSelectDialog extends StatefulWidget {
  const CdnSelectDialog({super.key});

  @override
  State<CdnSelectDialog> createState() => _CdnSelectDialogState();
}

class _CdnSelectDialogState extends State<CdnSelectDialog> {
  /// 打开对话框时自动触发一次并行测速，结果按速度排序展示。
  @override
  void initState() {
    super.initState();
    unawaited(_startAutoTest());
  }

  Future<void> _startAutoTest() async {
    await CdnAutoManager.testNow(notify: false);
    if (mounted) setState(() {});
  }

  List<CDNService> get _services => CdnAutoManager.rankedServices;

  String _speedText(CDNService service) {
    for (final result in CdnAutoManager.ranking) {
      if (result.service == service) {
        return '${(result.bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s';
      }
    }
    return CdnAutoManager.testing.value ? '测速中...' : '未测速';
  }

  @override
  Widget build(BuildContext context) {
    final services = _services;
    return SelectDialog<CDNService>(
      title: 'CDN 设置（按测速排序）',
      values: services.map((i) => (i, i.desc)).toList(),
      value: VideoUtils.cdnService,
      subtitleBuilder: (context, index) {
        final service = services[index];
        return ValueListenableBuilder<bool>(
          valueListenable: CdnAutoManager.testing,
          builder: (context, testing, _) {
            return Text(
              testing ? '测速中...' : _speedText(service),
              style: const TextStyle(fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          },
        );
      },
    );
  }
}
