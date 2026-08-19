# Design QA

- Source visual truth: `C:\Users\ADMINI~1\AppData\Local\Temp\codex-clipboard-bd97f2d2-faa8-4842-9fa5-f87067920932.png`
- Device viewport: Android, 1200 × 2608 physical pixels
- Installed build: `0.3.1 (9002)`
- Captures: `artifacts/device-qa/home.png`, `history.png`, `settings.png`, `search-scan.png`, `filter.png`

## Full-view comparison evidence

- Recording tab: the camera remains the visual focus, the existing work controls stay above a persistent three-item bottom navigation, and the selected recording item has a distinct center treatment.
- History tab: order totals, computer backup, search actions, source filter, and recording list are grouped in task order. The connected computer name and IP address appear once.
- Settings tab: work mode, speech, volume, and retention controls are separated from history and remain reachable without leaving the bottom navigation.

## Focused region comparison evidence

- Bottom navigation: `历史 / 录制 / 设置` is visible and selectable on all three primary screens without covering the recording controls.
- Search actions: the barcode button opens the existing camera pipeline in history-search mode and shows a clear cancel action; the paste button remains adjacent to it.
- Source filter: the sheet exposes `全部来源 / 仅本机 / 已备份 / 电脑录像` with full-width touch targets.
- Computer backup: connected state, computer name, private-network address, upload count, percentage, progress line, backup action, and disconnect action fit in one card without duplicate address text.

## Findings

- P0: none
- P1: none
- P2: none for the requested redesign scope

## Validation history

- Release APK rebuilt after `flutter clean` to eliminate the stale Dart snapshot.
- Installed from the versioned path `dist/android/PackingProof-Mobile-v<versionName>+<versionCode>.apk`.
- Confirmed package version `0.3.1`, version code `9002` on the connected device.
- Captured and inspected the recording, history, settings, barcode-search, and source-filter states.

final result: passed
