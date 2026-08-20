# Repository Guidelines

## Project Overview

PackingProof-Mobile is a Flutter app for continuous package-recording and shipping-label barcode marking. Android is the primary release target. Recordings, indexes, and settings are stored locally unless the operator explicitly configures LAN backup.

## Project Structure

- `lib/controllers/` contains recording and work-session state machines.
- `lib/services/` contains barcode recognition, persistence, speech, order receiving, and LAN backup logic.
- `lib/screens/` and `lib/widgets/` contain the Flutter UI.
- `test/` contains unit and widget regression tests; `integration_test/` contains device-level flows.
- `android/` and `ios/` contain platform projects.
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

## 必读专项文档

- 日常命令、保留数据的 Android 安装、Mac/Windows 对等 SSH 验证或跨机同步：必须阅读 `docs/cross-machine-development.md`
- 修改 iOS、Xcode、CocoaPods、Flutter iOS 插件或 IPA 构建：必须阅读 `docs/ios-development.md`
- 修改局域网发现、配对、鉴权、上传、回执、远程播放或清理：必须阅读 `docs/mobile-backup-v1.md`
- 构建本地 Release 测试 APK、准备版本、签名、打 tag 或发布：必须阅读 `docs/android-release.md` 和 `RELEASE_NOTES_TEMPLATE.md`

## Testing

- Add or update focused tests for every behavior change.
- Run the affected test file while iterating.
- Before committing, run `flutter analyze` and the relevant tests.
- Recording, camera, audio, permissions, background lifecycle, installation upgrades, and LAN backup changes still require real-device validation when affected.

## Change Discipline

- Keep changes focused and preserve the existing Flutter/Dart style.
- Before investigating or fixing a bug, first search upstream GitHub issues and PRs for the affected component (Flutter framework, plugins, native dependencies), note the relevant issue/PR numbers and conclusions, then implement.
- Keep `README.md` product-facing: describe user value, setup, privacy, and download paths; put internal implementation rules in this file or focused developer documentation.
- Do not mix unrelated fixes, features, refactors, documentation, or release maintenance in one commit.
- Avoid broad formatting, generated-file churn, dependency upgrades, or platform changes unless required.
- Inspect `git status`, the relevant diff, and the staged diff before committing.
- Do not commit build outputs, local recordings, caches, logs, credentials, or machine-specific configuration.

## 分支整合与同步

- 分支和 Mac/Windows 双机同步优先使用 rebase，保持线性历史，不 squash 原有提交；具体流程见 `docs/cross-machine-development.md`。
- 不主动创建 merge 提交；只有共享分支、发布/长期分支、明确要求保留整合入口或平台强制要求时才允许 merge。
