# Android 构建与发布

本文档约定 PackingProof-Mobile 的 Android 本地 Release 测试包和正式发布流程。Android 是主要发布目标；原生 Gradle/JVM 测试、APK 构建及 Android 真机验证优先在局域网 Windows 编译机执行。

## 构建入口

- `Tools/Publish-Android.ps1` 是正式发布入口，从当前精确 Git tag 解析版本，并委托 `Tools/Build-Android.ps1` 编译和验证
- `Tools/Build-Android.ps1` 是底层构建器，也可生成使用 debug 签名的本地诊断 APK
- `Tools/Build-Release-Diagnostic.ps1` 使用仓库外正式签名配置，按 `pubspec.yaml` 版本生成可覆盖安装的 Release 测试 APK
- 仓库根目录的 `双击构建Release调试版.bat` 是 `Tools/Build-Release-Diagnostic.ps1` 的便捷入口
- `dist/android/` 只保存生成产物，禁止提交

## 本地 Release 测试包

可直接双击仓库根目录的 `双击构建Release调试版.bat`。该入口读取 `pubspec.yaml` 版本，使用仓库外正式签名配置生成 ARM64 Release 测试 APK：

```text
dist/android/PackingProof-Mobile-v<versionName>+<versionCode>.apk
```

它可覆盖安装到使用相同正式签名证书的现有应用，不用于正式发布。签名目录通过仓库外配置提供，任何凭据都不得写入仓库或日志。

## 发布前验证与审计

- 执行 `flutter analyze`、完整 Flutter 测试、Android 原生测试和受影响的真机流程
- 录制、相机、音频、权限、后台生命周期、安装升级和局域网备份变更必须真机验证
- 审计自上个版本以来的完整变更，检查技术债、CPU/电池/IO/UI 性能、并发与竞态、遗漏需求、未解决缺陷或 TODO，以及资源生命周期回归
- 重点检查录制、相机生命周期、存储清理、注册与配对、备份、上传回执和本地文件删除
- 每个失败或不稳定测试都必须调查；可信的数据安全、正确性、兼容性、性能或竞态问题是发布阻断项，除非用户明确接受并记录例外
- 通过分析和测试不等于自动满足发布条件，必须记录审计结论后才能创建 tag
- 对照 `pubspec.yaml` 与 `android/app/build.gradle.kts` 的直接运行时依赖检查“关于”页开源鸣谢，并同步更新组件断言
- 构建脚本必须校验并复用匹配的固定语音资源，只生成缺失或提示内容变化的资源

## 正式发布

在干净提交上创建精确 tag，然后执行：

```powershell
git tag v0.5.4+11004
pwsh -NoProfile -File Tools\Publish-Android.ps1 `
  -SigningDirectory <external-signing-directory>
```

- tag 优先使用 `v<versionName>+<increasing-versionCode>`，例如 `v0.5.4+11004`
- 仅当 `pubspec.yaml` 中版本名称一致且包含 version code 时，才允许纯 `v<versionName>` tag
- 正式脚本必须拒绝脏工作区、缺失或歧义 tag，以及缺少仓库外签名配置
- 使用 `-ForceClean` 仅处理确需完整 `flutter clean` 的工具链或缓存故障；日常构建不得无故全量清理
- `Tools/Build-Android.ps1` 的诊断默认值必须与 `pubspec.yaml` 保持一致
- 只发布单一 `arm64-v8a` APK；若重新出现 32 位 ARM 或 x86 包装，构建必须失败

构建输入会指纹化已跟踪的 Android 配置、依赖文件和 Flutter SDK。输入匹配时可复用 Gradle 与原生缓存，但每次构建仍必须重新生成 Flutter Release 产物，并验证 `libapp.so` 中的 Git revision 和时间戳。

## 产物与发布平台

正式输出必须包含：

```text
dist/android/PackingProof-Mobile-v<versionName>+<versionCode>.apk
SHA256SUMS.txt
build-manifest.json
```

- 不生成 Android Release ZIP
- 只有固定语音资源、元数据、Git revision、正式签名和 SHA256 全部验证通过，才算构建成功
- keystore、`签名凭据.txt`、证书和其他签名配置必须位于仓库外，禁止打印、提交、复制或打包

GitHub Release 使用 GitHub 插件或 `gh` 创建并上传 tag、APK、`SHA256SUMS.txt` 和发布笔记。Gitee Release 使用：

```powershell
gitee auth status
gitee release create --tag <tag> --name "..." --notes "..."
gitee release upload <tag> dist/android/PackingProof-Mobile-v<versionName>+<versionCode>.apk SHA256SUMS.txt
```

发布笔记必须基于仓库根目录的 `RELEASE_NOTES_TEMPLATE.md`：

- 按“功能与体验 / 问题修复 / 兼容与工程”分类
- 包含下载与更新说明及未验证事项
- GitHub 与 Gitee 内容保持一致
- 标题固定为 `v<X.Y.Z+VVVV> <一句话内容>`，不加产品名或“发布”等前缀
- 预览版只写相对上一版本的增量内容
- 正式版汇总上一个正式版以来包含所有中间预览版的更新
