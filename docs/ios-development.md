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

`Tools/Build-iOS.sh` 默认构建 release 并使用 `app-store` 导出方式，输出：

```text
dist/ios/PackingProof-Mobile-v<versionName>+<versionCode>.ipa
```

需要可从桌面启动且保留性能诊断能力的真机测试包时，使用 Flutter tooling 构建 profile，并采用工程现有的 bundle ID 与签名配置：

```bash
Tools/Build-iOS.sh --profile development
```

profile 产物输出为：

```text
dist/ios/PackingProof-Mobile-profile-v<versionName>+<versionCode>.ipa
```

脚本仍兼容原有的导出方式与可选缓存清理参数，例如 `Tools/Build-iOS.sh ad-hoc clean`。`clean` 只清理 Flutter 构建缓存；脚本不会安装或卸载 App，也不会删除设备容器或本地录像。

脚本会在调用 Flutter 构建前读取当前 Git revision 和 UTC 构建时间，并同时注入 App 的 `BUILD_REVISION`、`BUILD_TIMESTAMP` 与外部构建清单。设备诊断中的构建身份必须与 `build-manifest.json` 一致；两者任一为空或不一致时，不得用该包作性能或发布验收。构建清单和校验文件只用于本地发布门禁，不作为 TestFlight 或 Release 附件。

临时内部分发可传入 `ad-hoc` 或 `development`。签名证书、描述文件和其他凭据不得提交、打印或复制进构建产物。

## 正式发布

iOS 只通过 TestFlight 分发，不再向 GitHub/Gitee Release 上传 IPA。`dist/ios/` 下的 IPA、`build-manifest.json` 和 `SHA256SUMS.txt` 都只用于本地发布门禁与问题追踪，禁止作为 Release 附件；对外下载入口只有 README 中的 TestFlight 链接。

`Tools/Publish-iOS.sh` 是 App Store Connect/TestFlight 正式发布入口。它要求当前提交工作区干净且存在与 `pubspec.yaml` 一致的精确版本标签，并依次执行：

- `flutter analyze` 和完整 Flutter 测试
- 在可用 iPhone 模拟器上运行 `RunnerTests`
- 通过 `Tools/Build-iOS.sh` 构建 `app-store` Release IPA
- 校验 IPA 的 Bundle ID、版本、构建号、SHA256、Git revision、构建时间和外部构建清单

示例：

```bash
git tag v0.5.25+11040
Tools/Publish-iOS.sh
```

仅在工具链或缓存故障确实需要完整清理时使用 `Tools/Publish-iOS.sh clean`。正式 TestFlight/App Store 包不得直接调用 `Tools/Build-iOS.sh` 绕过发布门禁；普通 Profile、ad-hoc 和 development 测试包仍使用构建脚本。
