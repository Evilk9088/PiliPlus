# PiliPlus 自动 CDN 选优 / 卡顿换线（改源码 + 自行编译）

针对「广电 SIM 卡刷视频偶发卡顿、手动切换 CDN 有好转」的场景，给 PiliPlus 增加了：

1. **APP 首帧渲染完成后**才开始自动测速，不跟启动抢资源；
2. **并行测速**（分批并发，单节点卡住不阻塞其它节点），自动切换最快线路，并 Toast 提示结果；
3. **播放中连续卡顿自动切换其它线路，并保持播放进度**；
4. **播放页 / 设置页的 CDN 选择列表**点开即自动测速一次，按速度排序展示；
5. **手动指定 CDN 后，自动逻辑不再覆盖用户选择**；
6. 单节点下载 10MB，**持续 5 秒网速低于 1MB/s 直接跳过**。

> 代码位于工作区 `PiliPlus/`，补丁文件为 `auto_cdn.patch`。Flutter SDK 已安装在 `F:\AndroidDev\flutter`（3.47.9）。

---

## 一、为什么是「改源码」而不是「做插件」

PiliPlus 是 Flutter 应用，`lib/plugin/` 目录是**内置的播放器模块源码**（`pl_player`），并不是可动态加载的插件系统；仓库里没有插件清单、动态加载入口或运行时扩展点。因此无法以「装一个插件」的方式给已编译的 APK 增加功能，只能改源码后自行编译。

---

## 二、实现原理

### 现有基础

- `lib/models/common/video/cdn_type.dart`：已内置 20+ 个 CDN 枚举（阿里 `ali/alib/alio1`、腾讯 `cos/cosb/coso1`、华为 `hw/hwb/...`、TF 线路等）。
- `lib/utils/video_utils.dart` 的 `getCdnUrl()`：把官方返回的播放 URL 的 host 替换成指定 CDN host，签名不变即可用。
- `lib/plugin/pl_player/controller.dart`：播放器暴露 `isBuffering`（RxBool）、`buffered`、`playerStatus` 等状态。

### 新增模块 `lib/utils/cdn_auto_manager.dart`

`CdnAutoManager` 是全局静态管家：

| 能力 | 说明 |
|---|---|
| 启动时机 | `WidgetsBinding.addPostFrameCallback` 首帧后，再延迟 3 秒触发测速 |
| 测速样本 | 示例视频 `BV1fK4y1t7hj` / cid `196018899`，请求一次 playurl 拿到官方链接，缓存 6 小时 |
| 并行测速 | 每批 6 个节点 `Future.wait` 并发，单节点硬超时 20s，互不阻塞 |
| 单节点测速 | 最多下载 **10MB**；启动后 5 秒若平均速度仍 **< 1MB/s** 直接淘汰；整体 20s 硬超时 |
| 完成提示 | 测速结束 Toast：`CDN 测速完成，已自动选择 xxx（x.xx MB/s）` |
| 结果缓存 | 排名持久化到 `localCache`，启动时先恢复；播放页列表按排名排序 |
| 应用策略 | 自动选出第一名写入 `CDNService`，标记 `autoCdnSelected=true` |
| 用户优先 | 手动选过 CDN 后自动结果不再覆盖；「立即测速」会强制应用一次 |
| 网络变化 | 监听 `Connectivity().onConnectivityChanged`，仅在 WiFi/蜂窝标签变化时重测 |
| host 校验 | mcdn / tf 代理等无法替换 host 的链接直接跳过，避免「切了个寂寞」 |

### 卡顿自动换线 `lib/pages/video/controller.dart`

- 订阅 `plPlayerController.isBuffering`：连续缓冲 **4 秒**判定卡顿。
- 按测速排名切换到未尝试过的下一条线路，重建视频/音频 URL（保留官方签名），调用 `setDataSource()` 重载并 `seekTo` 当前进度。
- 防护：换线冷却 20 秒、单会话最多 3 次、排除离线/直播/播放完成、URL host 校验、失败回滚、Toast 提示。

### CDN 选择列表 `lib/pages/setting/widgets/select_dialog.dart`

`CdnSelectDialog` 在 `initState` 里自动触发一次 `CdnAutoManager.testNow(notify: false)`，测速完成后 `setState` 按速度排序展示；副标题实时显示「测速中...」或该节点速度（MB/s）。播放页与设置页共用同一个对话框。

### 设置项 `lib/pages/setting/models/video_settings.dart`

| 设置项 | 默认 | 说明 |
|---|---|---|
| 启动自动测速并切换最优 CDN | 关 | 打开时立即触发一次测速；之后启动/网络切换自动执行 |
| 卡顿自动切换线路 | 关 | 对新打开的播放页生效 |
| 立即测速并切换线路 | — | 手动触发，副标题显示前 5 名测速结果 |
| CDN 测速（旧开关） | 开 | 保留兼容；选择列表现在总是自动测速 |

---

## 三、改动文件清单

| 文件 | 改动 |
|---|---|
| `lib/utils/cdn_auto_manager.dart` | **新增**：并行测速、排名缓存、网络监听、换线调度、完成提示 |
| `lib/main.dart` | 首帧后初始化 + 网络变化监听（异常保护） |
| `lib/pages/video/controller.dart` | 卡顿检测、换线重载、进度保持、生命周期清理 |
| `lib/pages/setting/widgets/select_dialog.dart` | CDN 列表自动测速 + 按速度排序 + 速度展示 |
| `lib/pages/setting/models/video_settings.dart` | 3 个新设置项 + 手动切换联动 |
| `lib/pages/video/widgets/header_control.dart` | 播放页手动切换联动 +「（自动）」标注 |
| `lib/utils/storage_key.dart` | 新增 3 个设置键 |
| `lib/utils/storage_pref.dart` | 新增 `autoCdn` / `autoCdnStallSwitch` 读取 |
| `lib/utils/video_utils.dart` | 新增 `autoCdnSelected` 状态位 |

---

## 四、编译环境（已就绪）

- 位置：`F:\AndroidDev\flutter`（Flutter 3.47.9 / Dart 3.13.7），由 `F:\AndroidDev\flutter_windows_3.47.9-stable.zip` 解压，SHA256 已校验。
- 复用已有环境：`F:\AndroidDev\sdk`（Android SDK）、`F:\AndroidDev\jdk17`（JDK 17）、`F:\AndroidDev\gradle`、`F:\AndroidDev\gradle-home`。
- 已补齐：`platforms;android-36/37/37.0`、`build-tools;36.0.0/37.0.0`、NDK r28c、CMake 3.22.1、Gradle 9.5.0、`media_kit_libs_android_video` 的 3 个 ABI jar（SHA256 校验通过）。
- **代理：7890 端口**（`http://127.0.0.1:7890`）。shell/Java/Python/git 都需要它。

### 编译前必做：给 SDK 打补丁

PiliPlus 依赖修改过的 Flutter framework 私有 API，官方 SDK 必须打补丁（CI 的 `lib/scripts/patch.ps1`）：

```powershell
$env:FLUTTER_ROOT = 'F:\AndroidDev\flutter'
$env:GITHUB_WORKSPACE = '<项目绝对路径>\PiliPlus'
$env:PUB_CACHE = '<项目同级>\.pub-cache'   # 重要：必须与项目同盘符，见下文
# 设置好 JAVA_HOME / ANDROID_HOME / 7890 代理 / PATH 后：
./lib/scripts/patch.ps1 android
```

`patch.ps1` 会给 Flutter SDK 应用 25 个补丁（暴露 `StandardBottomSheet`、`IndicatorPainter`、`WidgetSpan.rawText` 等）。脚本后半段在 Windows 上会因 `~/.pub-cache` 路径报「material_ui package not found」，需手动补做（android 分支 9 个补丁）：

```powershell
$m = Get-ChildItem "$env:PUB_CACHE\hosted\pub.dev" -Directory |
     Where-Object Name -like 'material_ui-*' | Select-Object -Last 1
foreach ($p in @('modal_barrier_material.patch','navigation_drawer.patch',
                 'popup_menu.patch','fab.patch','text_field.patch','scaffold.patch',
                 'refresh_indicator.patch','tabs.patch','bottom_sheet_android.patch')) {
    $f = "$env:GITHUB_WORKSPACE\lib\scripts\material\$p"
    (Get-Content $f -Raw) -replace "`r`n","`n" | Set-Content -NoNewline $f
    git -C $m.FullName apply --ignore-whitespace $f
}
```

> `flutter pub get` 会重新解压 `material_ui` 并**覆盖补丁**，所以每次 `pub get` 之后都要重新检查/补打 material_ui 补丁（脚本本身也是这么做的）。

### 完整编译命令

```powershell
$env:JAVA_HOME = 'F:\AndroidDev\jdk17\jdk-17.0.21.0.2+1'
$env:ANDROID_HOME = $env:ANDROID_SDK_ROOT = 'F:\AndroidDev\sdk'
$env:GRADLE_USER_HOME = 'F:\AndroidDev\gradle-home'
$env:APPDATA = '<工作区>\.appdata'          # 避开 Dart CLI 写 C 盘被拒
$env:PUB_CACHE = '<工作区>\.pub-cache'      # 与项目同在 D 盘
$env:HTTP_PROXY = $env:HTTPS_PROXY = 'http://127.0.0.1:7890'
$env:PUB_HOSTED_URL = 'https://pub.dev'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PATH = "$env:JAVA_HOME\bin;F:\AndroidDev\flutter\bin;$env:PATH"
cd PiliPlus
flutter pub get          # 重新生成 .dart_tool 与 .flutter-plugins-dependencies
# 确认 material_ui 补丁仍在（必要时补打）
flutter build apk --release --no-pub
```

产物：`PiliPlus\build\app\outputs\flutter-apk\app-release.apk`（本次实测 67.8MB，含 arm64-v8a / armeabi-v7a / x86_64 三套 `libflutter.so`）。

---

## 四之二、配置固定签名与「自覆盖升级」

### 结论

**不能覆盖安装官方版**（签名不同、包名相同 `com.example.piliplus`），但**只要自己编译的版本始终用同一把密钥签名，就能一直自覆盖升级**——这正是你需要的。

项目本身已经内置签名逻辑，`android/app/build.gradle.kts` 第 40–55 行会读 `android/key.properties`：文件存在就用 `signingConfigs.release`（V1+V2），否则回退到 debug 签名。所以只需两步：

### 1. 生成一次 keystore（只做一次，务必备份）

```powershell
$kt = 'F:\AndroidDev\jdk17\jdk-17.0.21.0.2+1\bin\keytool.exe'
$dir = '<项目绝对路径>\PiliPlus\android'
& $kt -genkeypair -v `
    -keystore "$dir\app\piliplus-release.jks" `
    -alias piliplus -keyalg RSA -keysize 2048 -validity 10950 `
    -storepass '<你的口令>' -keypass '<你的口令>' `
    -dname 'CN=PiliPlus Auto CDN, OU=Personal, O=Personal, L=Beijing, ST=Beijing, C=CN'
```

> `storeFile` 是相对 **app 模块目录**（`android/app/`）解析的，keystore 必须放在 `android/app/` 下（本次已放好）。

### 2. 写 `android/key.properties`

```properties
storeFile=piliplus-release.jks
storePassword=<你的口令>
keyAlias=piliplus
keyPassword=<你的口令>
```

`android/.gitignore` 已忽略 `key.properties` 与 `**/*.jks`，**私钥不会进 Git**；但换电脑 / 重装系统 / fork 后重新克隆时，需要手动把这两个文件拷回去，否则会退回 debug 签名，导致无法覆盖已装版本。

本次已生成并验证：证书 `CN=PiliPlus Auto CDN`，SHA-256 `5b9d319c…`，`apksigner verify` 通过（V2；`CERT.RSA`/`CERT.SF`/`MANIFEST.MF` 也都在包内）。

### 3. 自覆盖升级的硬规则

Android 允许覆盖安装的三个条件，缺一不可：

| 条件 | 说明 |
|---|---|
| 同一包名 | 固定 `com.example.piliplus`（`applicationId` 不要改） |
| 同一签名证书 | 每次都用**同一份 `.jks` 同一个 alias**；换了 keystore 就必须先卸载 |
| versionCode 递增 | 当前 `versionCode=1`（来自 `pubspec.yaml` 的 `version: 2.2.0+1`，`build.gradle.kts` 里 `versionCodeOverride = flutter.versionCode`）。**每次发新版必须把 `+N` 加 1**，例如 `2.2.0+2`、`2.2.0+3`；同 versionCode 或更低会被拒绝安装 |

推荐做法：每次编译前改 `pubspec.yaml` 的 `version`，或用命令行覆盖而不改文件：

```powershell
flutter build apk --release --no-pub --build-name=2.2.1 --build-number=2
```

> 逆向降级安装（版本号比已装的小）同样会被拒绝，只能先卸载。

### 4. 与官方版共存 / 从官方版迁移

- 若手机上装的是官方 release（不同签名）：先 `adb uninstall com.example.piliplus` 再装我们的包，之后就进入「自覆盖升级」通道。
- 若想和官方版**并存**，可在编译加 `--android-project-arg dev=1` 触发 `.dev` 后缀（`applicationId` 变 `com.example.piliplus.dev`），但那是另一套数据，且同样需要自己的签名才能在该包名下自升级。
- 卸载会清掉 APP 内的设置与登录态；覆盖升级会保留，所以只要第一次切换过去，后续升级都平滑。

### Windows 编译踩坑清单（本次实际遇到）

| 问题 | 原因 / 解决 |
|---|---|
| `dart` / `flutter.bat` 卡住、`dart analyze` 报 `.dart-tool` 拒绝访问 | Dart CLI 写 `C:\Users\...\AppData\Roaming\.dart-tool` 被沙箱拒绝 → 设 `$env:APPDATA` 到工作区 |
| `analysis_server` 子进程「拒绝访问」 | 沙箱禁止命名管道 → 用 `danger-full-access` 运行 |
| `pub get` 报 `Cannot find a Git executable` | pub 要启动 `cmd /c git` 子进程 → 同上 |
| 大量 `StandardBottomSheet` / `IndicatorPainter` / `rawText` 未定义 | 官方 SDK 未打补丁 → 执行 `patch.ps1 android` + 手动补 material_ui |
| `Gradle distribution ... does not contain any directories` | 预下载的 Gradle 9.5.0 zip 未解压 → 展开到 wrapper 的 hash 目录 |
| `Failed to find target with hash string 'android-37'` | platform 目录缺 `android.jar` → 用自动安装的 `android-37.0` 补全 `android-37` |
| media_kit 下载 jar 超时 | Gradle/Java 直连 GitHub 失败 → 用 Python 经 7890 预下载 3 个 jar 到 `build/media_kit_libs_android_video/20260906/` |
| Kotlin `Could not close incremental caches` / `different roots: C:\... and D:\...` | pub 缓存（C 盘）与项目（D 盘）跨盘符 → 把 pub 缓存整体移到 D 盘并设 `PUB_CACHE`，且必须用 **`flutter pub get`**（`dart pub get` 不更新 `.flutter-plugins-dependencies`） |
| `flutter_inappwebview_android` 一堆「找不到符号」 | Windows 260 字符路径限制导致 git checkout 漏掉多个 `.java` 文件 → `git config core.longpaths true` 后 `git -C <git缓存仓库> checkout -f HEAD` |
| 多次中断后的 Kotlin 增量缓存损坏 | 删除 `build/` 下除 `media_kit_libs_android_video` 外的子目录，并停掉残留 java 守护进程 |

> 结论：Linux/macOS CI 上没有这些坑；Windows 本地编译要把「同盘符 + 长路径 + SDK 补丁 + 预下载 jar」四件事都做对。

---

## 五、使用

1. 安装自行编译的包，进入 **设置 → 视频设置**。
2. 打开 **「启动自动测速并切换最优 CDN」**：约 3 秒后开始并行测速，完成后 Toast 提示所选线路。
3. 打开 **「卡顿自动切换线路」**：新打开视频后，连续缓冲超过 4 秒自动换线续播。
4. 播放页或设置页点 **「CDN 设置」**：列表会自动测速一次，按速度从快到慢排序，点选即切换。
5. 手动选了某条线路后，自动测速只更新排名、不再改动当前线路，直到再次手动测速或点「立即测速」。

---

## 六、可调参数

集中在 `lib/utils/cdn_auto_manager.dart` 与 `lib/pages/video/controller.dart` 顶部常量：

| 常量 | 默认 | 含义 |
|---|---|---|
| `_maxBytesPerTest` | 10MB | 单节点测速下载上限 |
| `_perTestTimeout` | 20s | 单节点硬超时 |
| `_slowGrace` | 5s | 慢节点宽限期 |
| `_slowThresholdBytesPerSecond` | 1MB/s | 慢节点阈值 |
| `_concurrency` | 6 | 并行测速并发数 |
| `_startupDelay` | 3s | 首帧后延迟多久开始测速 |
| 样本缓存有效期 | 6h | playurl 样本缓存时长 |
| `_cdnStallThreshold` | 4s | 判定卡顿的连续缓冲时长 |
| `_cdnSwitchCooldown` | 20s | 两次换线最小间隔 |
| `_cdnMaxSwitchPerSession` | 3 | 单会话最大换线次数 |

> 流量估算：18 个候选 × 10MB ≈ 180MB 上限（实际会被慢节点淘汰与命中上限提前终止大幅减少）。若嫌耗流量，调小 `_maxBytesPerTest` 或在 `_candidates` 里精简线路。

---

## 七、主仓库更新后如何同步（fork + rebase 工作流）

**结论：需要 fork 到自己的仓库，并用 `git rebase` 把自己的提交持续叠在上游最新代码上。** 不建议每次手动复制补丁，也不建议 merge（会产生大量合并提交、冲突更难处理）。

### 当前状态（已就绪）

- Fork：<https://github.com/Evilk9088/PiliPlus>
- 功能分支：`feat/auto-cdn`，提交 `2d3b7fb feat: 自动 CDN 测速选优与卡顿换线`
- 本地 `origin` → fork，`upstream` → `bggRGjQaUbCoE/PiliPlus`，两者 fetch refspec 均为标准 `+refs/heads/*:refs/remotes/*`
- 私钥 `android/app/piliplus-release.jks` 与 `android/key.properties` **不在仓库里**（被 `.gitignore` 忽略），换机器需手动拷回

若要在另一台机器上从零搭建：

```bash
git clone https://github.com/Evilk9088/PiliPlus.git PiliPlus
cd PiliPlus
git remote add upstream https://github.com/bggRGjQaUbCoE/PiliPlus.git
git checkout feat/auto-cdn
# 拷回 android/app/piliplus-release.jks 与 android/key.properties
```

### 每次上游更新后

```bash
git checkout feat/auto-cdn
git fetch upstream
git rebase upstream/main          # 把你的提交重放到上游最新提交之上
# 若有冲突：只会在你改过的 9 个文件里出现，逐个解决
#   git status -> 编辑冲突 -> git add <file> -> git rebase --continue
# 重新生成依赖 + 重新打 SDK 补丁（上游若改了 patch.ps1/补丁文件，这一步必须重跑）
flutter pub get
./lib/scripts/patch.ps1 android   # 含手动补 material_ui 部分，见第四节
flutter build apk --release --no-pub
git push --force-with-lease origin feat/auto-cdn
```

### 为什么用 rebase 而不是 merge

- 你的改动永远是「上游 + 1 个干净提交」，历史线性，冲突只集中在自己改的文件；
- 上游改了 `cdn_type.dart` 增删 CDN、`video_utils.dart` 的 `getCdnUrl()`、或播放器控制器时，冲突会立刻暴露并就地解决；
- `auto_cdn.patch` 只作为「初始导入」用，之后以 Git 提交为准，不再维护补丁。

### 降低冲突的实践

1. **尽量少碰上游文件**：目前只改了 10 个文件，其中 `cdn_auto_manager.dart` 是全新文件（永远不冲突），`storage_key.dart` / `storage_pref.dart` / `video_utils.dart` 只是追加常量；冲突面最大的是 `main.dart`、`video/controller.dart`、`select_dialog.dart`。
2. **上游发布新版本时先 rebase 再编译**，不要直接覆盖；`pubspec.yaml` 里 `flutter: 3.47.9` 若升级，需按新版本重新下载 SDK 并确认 `lib/scripts/*.patch` 仍能应用。
3. 若上游重构了 `VideoUtils.getCdnUrl()` 或 `CDNService` 枚举，重点复核 `_candidates`、`_measureAll()`、`isCdnUrlValid()` 三处。
4. 可以用 GitHub Actions 在 fork 里做「每日检查上游是否更新」，但编译仍需本机 F 盘环境。
5. **不要**把 `pubspec.lock`、`build/`、APK 提交进分支；只提交源码与文档。

### 如果不想 fork

也可以本地保留一个「上游裸仓库 + 补丁文件」：每次 `git fetch upstream && git checkout upstream/main && git apply auto_cdn.patch` 重新生成工作树。但这要求补丁始终能干净应用，上游一改相关文件就得手改补丁，长期维护成本高于 fork + rebase，因此只适合偶尔编译一次的场景。

---

## 八、已知限制

- **测速用的是示例视频链接**，不同视频、不同地域的最优 CDN 可能不同；测速结果作为「启动默认线路」和「换线排序」的参考，不能保证 100% 对应当前视频。
- **Akamai / 海外线路 / mcdn 代理类链接**无法简单替换 host，已从自动候选里排除。
- **直播流**使用独立 CDN 配置（`liveCdnUrl`），本补丁的点播自动换线不覆盖直播。
- 卡顿检测基于 mpv 的 `buffering` 流；若卡顿表现为「不缓冲但码率不足」，需改为基于 `buffered` 增量或下载速率的判定。
- 换线重载通过 `setDataSource()` 完成，会短暂重新打开媒体（有 seek 续播），并非无缝切换。
- 并行测速在移动网络下会同时占用多路连接；`_concurrency=6` 已做限制，若仍影响播放体验可继续调小。
