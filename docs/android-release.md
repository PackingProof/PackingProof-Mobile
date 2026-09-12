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

## 发布顺序

固化为以下顺序，任一步失败都不得继续：

1. 提交全部改动，确认工作区干净，版本号已更新
2. 两台机器各跑一次本地 CI：`./Tools/test-ci.sh`（Mac 跑 golden/RunnerTests/iOS 构建那一半，Windows 编译机跑 Android 原生测试那一半），跳过项必须在另一台补齐
3. 建本地精确标签 `v<versionName>+<versionCode>`
4. 以该标签身份执行发布构建：Android 在 Windows 编译机执行 `Tools/Publish-Android.ps1`，iOS 在 Mac 执行 `Tools/Publish-iOS.sh`
5. 构建与校验全部通过后，再推送 `main` 与标签到 GitHub 和 Gitee
6. 取回 APK 到 Mac 的 `dist/android/` 并核对 SHA256，执行 `./Tools/Publish-Releases.sh <发布笔记文件> --title "<一句话内容>"` 一次性创建 GitHub 与 Gitee Release 并上传 APK
7. iOS 执行 `./Tools/Upload-TestFlight.sh` 上传 TestFlight，不附 IPA

Android 正式发布在局域网 Windows 编译机执行 `Tools/Publish-Android.ps1`，签名目录来自仓库外配置。`.github/workflows/release.yml` 保留为手动触发（`workflow_dispatch`）的备用通道，日常发布不走它。

## 发布前验证与审计

- 本地 CI（`Tools/test-ci.sh`）是发布门禁，检查项与 `.github/workflows/ci.yml` 保持一致；两者任一变更都要同步另一处
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
pwsh -NoProfile -File Tools\Publish-Android.ps1
```

- 签名目录不需要手动传：脚本会读取仓库根目录 `.env` 的 `PACKING_PROOF_SIGNING_DIRECTORY`。`.env` 已被 `.gitignore` 忽略，只存在于编译机本地，禁止提交。需要临时覆盖时才用 `-SigningDirectory <external-signing-directory>`；两者都缺失时脚本会直接失败
- tag 优先使用 `v<versionName>+<increasing-versionCode>`，例如 `v0.5.4+11004`
- 仅当 `pubspec.yaml` 中版本名称一致且包含 version code 时，才允许纯 `v<versionName>` tag
- 正式脚本必须拒绝脏工作区、缺失或歧义 tag，以及缺少仓库外签名配置
- 使用 `-ForceClean` 仅处理确需完整 `flutter clean` 的工具链或缓存故障；日常构建不得无故全量清理
- `Tools/Build-Android.ps1` 的诊断默认值必须与 `pubspec.yaml` 保持一致
- 只发布单一 `arm64-v8a` APK；若重新出现 32 位 ARM 或 x86 包装，构建必须失败

构建输入会指纹化已跟踪的 Android 配置、依赖文件和 Flutter SDK。输入匹配时可复用 Gradle 与原生缓存，但每次构建仍必须重新生成 Flutter Release 产物，并验证 `libapp.so` 中的 Git revision 和时间戳。

## 产物与发布平台

正式构建目录输出必须包含（仅用于本地校验，不全部上传）：

```text
dist/android/PackingProof-Mobile-v<versionName>+<versionCode>.apk
SHA256SUMS.txt
build-manifest.json
```

- 不生成 Android Release ZIP
- 只有固定语音资源、元数据、Git revision、正式签名和 SHA256 全部验证通过，才算构建成功
- keystore、`签名凭据.txt`、证书和其他签名配置必须位于仓库外，禁止打印、提交、复制或打包

GitHub/Gitee Release 只上传 Android APK。iOS 不再上传 IPA，只发布到 TestFlight。`SHA256SUMS.txt` 和 `build-manifest.json` 仅用于本地发布门禁与问题追踪，不作为 Release 附件。

两个平台统一走 `Tools/Publish-Releases.sh`，它按当前精确 tag 找 `dist/android/` 下的 APK，先建 GitHub Release（连不上时自动重试），再建 Gitee Release 并上传同一个 APK；已存在的 Release 会跳过创建，可安全重跑：

```bash
./Tools/Publish-Releases.sh dist/android/RELEASE_NOTES-v<versionName>+<versionCode>.md \
  --title "<一句话内容>" [--prerelease]
```

- GitHub 登录态由 `gh auth status` 维护，Gitee 由 `gitee auth status` 维护，脚本不读也不存这两个平台的令牌
- Gitee 会把附件名里的 `+` 显示成空格，属于平台行为，不是构建问题
- 建 Gitee Release 必须带 `--target main`，否则接口会报 `target_commitish is missing`

发布笔记必须基于仓库根目录的 `RELEASE_NOTES_TEMPLATE.md`：

- 按“功能与体验 / 问题修复 / 兼容与工程”分类
- 包含下载与更新说明及未验证事项
- GitHub 与 Gitee 内容保持一致
- 标题固定为 `v<X.Y.Z+VVVV> <一句话内容>`，不加产品名或“发布”等前缀
- 预览版只写相对上一版本的增量内容
- 正式版汇总上一个正式版以来包含所有中间预览版的更新
