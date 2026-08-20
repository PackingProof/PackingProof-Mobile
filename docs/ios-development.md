# iOS 开发与构建

本文档约定 PackingProof-Mobile 的 iOS、Xcode 和 CocoaPods 开发流程。iOS 构建在 Mac 本机执行；AI 在 Windows 工作时，可按本机私有笔记通过局域网 SSH 控制 Mac 完成验证。

## 依赖与锁文件

修改 `ios/Podfile`、Flutter iOS 插件或 CocoaPods 依赖后执行：

```bash
flutter pub get
cd ios
pod install
```

必须提交与依赖输入匹配的 `ios/Podfile.lock`。其中 `PODFILE CHECKSUM` 必须等于 `ios/Podfile` 的 SHA-1：

```bash
shasum ios/Podfile
rg '^PODFILE CHECKSUM:' ios/Podfile.lock
```

本地存在 Pods 沙盒时，还应确认仓库锁文件与安装清单一致：

```bash
diff -q ios/Podfile.lock ios/Pods/Manifest.lock
```

不要把正确的 checksum 更新当成生成噪音恢复掉。若 `pod install` 只产生 CocoaPods 版本、Xcode 工程注释、空数组或其他环境差异，应先查明原因，只保留依赖或构建任务确实需要的改动。

执行 `pod install` 前应确认命中的 CocoaPods 与锁文件版本一致：

```bash
command -v pod
pod --version
rg '^COCOAPODS:' ios/Podfile.lock
```

如果同一台 Mac 同时安装了 Ruby gem 与 Homebrew 版本，应调整 `PATH`，避免旧版 `pod` 排在项目使用的版本之前。不要通过反复恢复 `Podfile.lock` 掩盖工具版本不一致。

`Podfile` 会把所有 Pods 构建目标统一到应用最低支持的 iOS 15.5，避免第三方依赖仍声明 iOS 9.0/10.0 而触发新版 Xcode 警告。`Pods.xcodeproj` 是 CocoaPods 生成文件，不要在 Xcode 中对它执行 “Update to recommended settings”；需要调整时修改 `Podfile` 并重新执行 `pod install`。

Google ML Kit 当前提供的部分静态 Mach-O 对象不包含 platform load command。Xcode 26 会提示并按 iOS 处理；在上游改用带完整平台元数据的二进制前，不要直接修改 Pods 中的预编译框架。

## 构建与测试

iOS 模拟器构建和 `RunnerTests` 应使用 `Runner.xcworkspace`，不能绕过 CocoaPods workspace。示例：

```bash
cd ios
xcodebuild build \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=<simulator>' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=<simulator>' \
  CODE_SIGNING_ALLOWED=NO
```

录制、相机、音频、权限和后台生命周期变更仍需要 iOS 真机验证。

不要同时在 Xcode 与 Flutter 命令行中构建同一个 iOS 工程。两者会共用 Runner 的 DerivedData 构建数据库，并可能触发 `build.db` locked；开始另一种构建前应先等待或停止当前构建。

## IPA 构建

`Tools/Build-iOS.sh` 默认使用 `app-store` 导出方式，输出：

```text
dist/ios/PackingProof-Mobile-v<versionName>+<versionCode>.ipa
```

临时内部分发可传入 `ad-hoc` 或 `development`。签名证书、描述文件和其他凭据不得提交、打印或复制进构建产物。
