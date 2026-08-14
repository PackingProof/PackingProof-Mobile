# Repository Guidelines

## Project Overview

PackingProof-Mobile is a Flutter app for continuous package-recording and shipping-label barcode marking. Android is the primary release target. Recordings, indexes, and settings are stored locally unless the operator explicitly configures LAN backup.

## Project Structure

- `lib/controllers/` contains recording and work-session state machines.
- `lib/services/` contains barcode recognition, persistence, speech, order receiving, and LAN backup logic.
- `lib/screens/` and `lib/widgets/` contain the Flutter UI.
- `test/` contains unit and widget regression tests; `integration_test/` contains device-level flows.
- `android/` and `ios/` contain platform projects.
- `Tools/Publish-Android.ps1` is the formal Android release entry point. It resolves the version from the exact Git tag and delegates compilation and validation to `Tools/Build-Android.ps1`.
- `Tools/Build-Android.ps1` is the underlying Android builder and may also produce a debug-signed local diagnostic APK.
- `双击构建Release调试版.bat` builds a formally signed Release test APK from the `pubspec.yaml` version and overwrites the fixed `dist/android/PackingProof-Mobile.apk` output so it can replace an installed app with the same signing certificate.
- `dist/android/` contains generated release artifacts and must not be committed.

## Product Constraints

- Maintain one unified app edition. Do not reintroduce standard/standalone flavors or multiple APK variants.
- Generate fixed speech assets with Edge TTS on the build machine and bundle them in the APK. The app runtime must never call Edge TTS or require internet access; dynamic text and missing assets fall back to Android system TTS in offline-only mode.
- Treat `assets/audio/tts/` and its manifest as tracked release assets, not disposable runtime cache. Reuse valid files and regenerate only missing or changed prompts.
- Keep `flutter_edge_tts` build-tool-only. Do not import it from `lib/` or add any runtime Edge generation path.
- Dynamic speech is not currently persisted. If a runtime speech cache is introduced, keep it separate from bundled assets and add bounded size, stale-entry cleanup, and regression tests.
- The refund warning sound is generated locally and must remain consistent with the desktop warning behavior.
- Barcode scanning and uninterrupted recording are the core workflow. Avoid changes that require touch interaction during normal scanning work.
- Preserve local recordings and settings during upgrades. Never delete recordings based only on missing, stale, or partially matched metadata.
- Recording records and video files are one-to-one: one tracking number maps to one independent video file. Do not reintroduce the legacy master-video/sub-video or shared-file model (one video file referenced by multiple records) in user-facing copy, README, developer docs, or test descriptions. Legacy databases may still contain shared-file records; keep compatibility protection only and never create new shared-file records.
- Keep LAN backup and remote-recording cleanup semantics distinct from deleting local source recordings.
- Keep the LAN backup device ID derived anonymously from Android ID so the same formally signed app can identify the physical phone again after uninstall/reinstall. Do not expose the raw Android ID.
- Keep at least 2 GB free for recording. Storage-pressure cleanup may remove only computer-verified backups, must reuse guarded file deletion, and must never remove unbacked recordings. Storage notices remain silent and modal reminders are deferred until work ends, at most twice per local day.
- 用户可见文案整段结尾不使用句号（。）；多句提示内部可保留句号分隔。

## 平台能力与实现纪律

- 平台适配器禁止“伪成功、空实现、硬编码占位”：能力要么真实实现，要么不声明并隐藏 UI 入口；不支持的调用必须抛出类型化异常，不得静默返回假数据。
- `PlatformCapabilities` 声明、平台适配器和 UI 入口必须三者一致；新增平台边界时同时核对这三处并补充测试。
- 现有 iOS 占位实现（存储回收、Wi-Fi 检测、网络诊断、解码能力探测等）按审计清单逐步替换为真实现，禁止再新增同类占位。

## Development Commands

Run commands from the repository root:

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk --debug
```

Flutter and Dart are already available through the Windows system `PATH`. Invoke
`flutter` and `dart` directly; do not install another SDK or rewrite `PATH` for
routine repository work. Run Android Gradle tasks with the repository wrapper
from `android/`.

本地 Release 调试包可直接双击仓库根目录的 `双击构建Release调试版.bat`。该入口自动读取 `pubspec.yaml` 版本，使用调试证书生成可安装的 ARM64 Release APK，并输出到 `dist/android/PackingProof-Mobile.apk`；它不用于正式发布。

Format only files changed for the current task:

```powershell
dart format <changed-files>
```

## 本地开发与测试环境

- 日常构建测试优先使用本机或局域网编译机，不依赖 GitHub CI；具体机器地址、账号和连接方式只记录在本机本地笔记，禁止提交仓库或推送到远端。
- Mac 负责 iOS/Xcode 构建；双机同步走 rebase（见“分支整合与同步”），不产生 merge 提交。

## Testing

- Add or update focused tests for every behavior change.
- Run the affected test file while iterating.
- Before committing, run `flutter analyze` and the relevant tests.
- Before a formal release, use `Tools/Publish-Android.ps1`; it runs the full analysis and test suite through `Tools/Build-Android.ps1` before packaging.
- Before every release, audit the complete change set since the previous release for newly introduced technical debt, performance problems (CPU, battery, IO, UI), and race conditions (thread visibility, interleaving, lifecycle races), as well as omitted requirements, unresolved defects or TODOs, and resource-lifetime regressions, especially around recording, camera lifecycle, storage cleanup, enrollment, backup, upload receipts, and local-file deletion. Record the audit conclusion before tagging. Investigate every failing or flaky test instead of dismissing it as unrelated, and treat credible correctness, data-safety, compatibility, performance, or race issues as release blockers until fixed or explicitly accepted by the user as documented exceptions. Passing analysis and tests alone is not sufficient to declare the release ready.
- Before every release, compare the About page credits with direct runtime dependencies in `pubspec.yaml` and `android/app/build.gradle.kts`; update the credits and their widget assertions when a credited dependency is added, replaced, or removed.
- The release script must validate and reuse matching speech assets, generating only missing or changed fixed prompts before packaging.
- Recording, camera, audio, permissions, background lifecycle, installation upgrades, and LAN backup changes still require real-device validation when affected.

## Cross-Device Backup Compatibility

- Treat every change to discovery, enrollment, device-token authentication, upload, or verified receipts as a two-sided protocol change. The phone and host must exchange explicit protocol, enrollment, authentication, application-version, and build capabilities.
- Check host compatibility before requesting a device token. A host must reject an incompatible phone before displaying its approval prompt or issuing or rotating a token, and return a structured response that tells the user which side must update.
- Compatibility failures may pause connection and backup only. Preserve local recordings, the database, pending backup tasks, the stable device ID, and the previous host hint so work can continue offline and resume after an update.
- Keep concrete minimum versions and protocol numbers in the centralized compatibility policy code, not in this document. Update phone and desktop regression tests together whenever the wire contract changes.
- Publish the compatible phone package before a desktop release raises the minimum phone version, and verify old-host, old-client, and newer-compatible combinations before release.

## Android Release

Create an exact tag on a clean commit, then generate one formally signed APK:

```powershell
git tag v0.5.4+11004
pwsh -NoProfile -File Tools\Publish-Android.ps1 `
  -SigningDirectory <external-signing-directory>
```

- Prefer release tags in the form `v<versionName>+<increasing-versionCode>`, for example `v0.5.4+11004`. A plain `v<versionName>` tag is accepted only when `pubspec.yaml` has the same version name and supplies the version code.
- The formal release script must reject a dirty worktree, a missing or ambiguous tag, and a missing external signing configuration.
- Complete and record the release-readiness audit (technical debt, performance, concurrency/race conditions) before creating the release tag.
- Create and upload the GitHub Release (tag, APK, `SHA256SUMS.txt`, release notes) with the GitHub plugin or `gh`; create and upload the Gitee Release with the `gitee` CLI (`gitee auth status`, `gitee release create --tag <tag> --name "..." --notes "..."`, `gitee release upload <tag> dist/android/PackingProof-Mobile.apk SHA256SUMS.txt`).
- 发布笔记必须使用仓库根目录的 `RELEASE_NOTES_TEMPLATE.md`：更新内容按“功能与体验 / 问题修复 / 兼容与工程”三类填写，并包含下载与更新说明、未验证事项；禁止自创格式，GitHub 与 Gitee 的 Release 笔记保持一致。Release 标题固定为“`v<X.Y.Z+VVVV> <一句话内容>`”（版本号开头，不加产品名或“发布”等前缀）。更新日志范围：预览版只写本预览版增量内容，正式版必须汇总上一个正式版以来（含中间所有预览版）的全部更新内容。
- Release builds fingerprint tracked Android configuration, dependency files, and the Flutter SDK. Matching inputs reuse Gradle/native caches, while every build still regenerates Flutter Release output and verifies the Git revision and timestamp inside `libapp.so`.
- Pass `-ForceClean` to `Tools/Publish-Android.ps1` or `Tools/Build-Release-Diagnostic.ps1` when diagnosing a toolchain or cache problem that requires a full `flutter clean`.
- Keep diagnostic defaults in `Tools/Build-Android.ps1` synchronized with `pubspec.yaml`.
- Release a single `arm64-v8a` APK; 32-bit ARM and x86 are intentionally unsupported and packaging must fail if either reappears.
- Keep keystores and `签名凭据.txt` outside the repository.
- Never print, commit, copy, or package signing credentials.
- Release output is `dist/android/PackingProof-Mobile.apk`, with `SHA256SUMS.txt` and `build-manifest.json`.
- Do not create a ZIP archive for the Android release.
- Treat the build as successful only when bundled speech assets, metadata, Git revision, formal signature, and SHA256 validation all pass.

## Change Discipline

- Keep changes focused and preserve the existing Flutter/Dart style.
- Before investigating or fixing a bug, first search upstream GitHub issues and PRs for the affected component (Flutter framework, plugins, native dependencies), note the relevant issue/PR numbers and conclusions, then implement.
- Keep `README.md` product-facing: describe user value, setup, privacy, and download paths; put internal implementation rules in this file or focused developer documentation.
- Do not mix unrelated fixes, features, refactors, documentation, or release maintenance in one commit.
- Avoid broad formatting, generated-file churn, dependency upgrades, or platform changes unless required.
- Inspect `git status`, the relevant diff, and the staged diff before committing.
- Do not commit build outputs, local recordings, caches, logs, credentials, or machine-specific configuration.

## 分支整合与同步

- 分支整合优先使用 rebase，保持主线直线历史；不把多个提交压缩成一个，原来有几个就保留几个。
- 不主动生成 merge 提交；merge 仅用于：分支已推送且多人共用、需要保留整个功能分支的整合入口、发布分支或长期分支之间互相同步，或平台/保护分支强制要求时。
- 已推送给他人使用的分支不随意 rebase 改写历史；如需线性化，先确认无人基于该分支工作。
- Mac 与 Windows 双机同步：本机提交后，通过 bundle、patch 或远端推送让另一台 rebase 同步，禁止在本地生成 merge 提交。
