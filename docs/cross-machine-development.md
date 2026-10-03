# 双机开发与验证

本文档约定 PackingProof-Mobile 在 Mac 与 Windows 之间的日常开发、同步和跨平台验证方式。机器地址、账号、密钥及具体连接命令只记录在各自机器的本机私有笔记，禁止提交仓库或推送到远端。

## 对等编译节点

- 两台机器按工具链分工，不按“谁是主力开发机”分工：
  - Mac 提供 iOS、Xcode、CocoaPods 与 TestFlight 上传能力
  - Windows 提供 Android 原生 Gradle/JVM 测试、APK 构建、签名发布与 Android 真机验证能力
- AI 的运行环境在哪一边都成立，不假设固定在某台机器上。缺哪一半工具链，就按本机私有笔记通过局域网 SSH 到具备该工具链的那台机器补齐，并读回完整输出和退出码后再下结论：
  - 在 Windows 侧：golden、RunnerTests、iOS 构建、TestFlight 走 SSH 到 Mac
  - 在 Mac 侧：Gradle/JVM 原生单测、APK 构建、Release 创建走 SSH 到 Windows
  - 一条命令在哪台机器上执行，不改变它属于哪一半；需要的那半没跑，就不能算通过
- 当前机器缺少目标平台工具链时，不要把它误判为代码失败，也不要为单次验证临时安装 SDK、Java 或改写 `PATH`；也不要因为本机不是“记忆中的那一台”就跳过该半验证
- Flutter/Dart 平台无关的分析和测试可在任一具备项目 SDK 的机器运行

## 常用开发命令

从仓库根目录执行：

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk --debug
```

Windows 已通过系统 `PATH` 提供 Flutter 和 Dart。日常工作直接调用 `flutter` 和 `dart`，不要安装另一套 SDK 或改写 `PATH`。Android Gradle 任务必须从 `android/` 使用仓库包装器执行。

只格式化当前任务修改的文件：

```powershell
dart format <changed-files>
```

## 同步与远端验证

1. 当前功能形成可同步提交，并确认工作区没有混入无关改动
2. 通过 bundle、patch 或远端推送把提交提供给另一台机器
3. 另一台机器使用 rebase 取得完全相同的提交，不创建 merge 提交，也不 squash
4. 通过 SSH 执行目标平台测试或构建，读取完整退出状态和关键日志
5. 若发现同一功能的缺陷，在原机器修正并按提交修订规则处理，再让另一台 rebase 后复验

已推送、共享或被其他工作依赖的分支不得擅自 rebase 改写历史。确需线性化时，先确认无人基于该分支继续工作。

## Android 本地调试安装

更新已安装的 Android debug 包时不要使用 `flutter install`，因为当前 Flutter 工具会先卸载旧版本，导致应用私有目录中的录像索引、设置和本机录像一并丢失。

需要保留应用数据时，使用以下任一方式：

```powershell
flutter run -d <device-id> --debug
flutter build apk --debug
adb install -r <apk>
```

## Android 真机集成测试

禁止直接执行 `flutter test integration_test/... -d <device-id>`。Flutter 默认会在集成测试结束时卸载被测应用；Flutter issue [#166709](https://github.com/flutter/flutter/issues/166709) 和已合并的 PR [#182714](https://github.com/flutter/flutter/pull/182714) 明确确认了该行为，并在 Flutter 3.44 增加了 `--no-uninstall` 开关。

Android 构建还会识别 Flutter 的 `integration_test` target 并强制切换为隔离包，作为误用原始命令时的数据安全兜底。仓库的安全入口会同时启用隔离包名 `app.packingproof.mobile.integration_test` 和 `--no-uninstall`，不会安装、覆盖或卸载正式包 `app.packingproof.mobile`：

```powershell
dart run tool/run_android_integration_test.dart `
  --device <device-id> `
  --target integration_test/continuous_segment_camera_test.dart
```

必须明确指定单个设备和单个 `integration_test/` 测试文件；缺少参数、目录外目标或额外 Flutter 参数都会默认安全失败。不得直接设置 `PACKING_PROOF_INTEGRATION_TEST_PACKAGE` 绕过该入口，也不得把 `--no-uninstall` 单独当成允许在正式包数据上运行集成测试的依据。

正式签名的本地 Release 测试包和正式发布流程见 [android-release.md](android-release.md)。iOS 构建与依赖规则见 [ios-development.md](ios-development.md)。
