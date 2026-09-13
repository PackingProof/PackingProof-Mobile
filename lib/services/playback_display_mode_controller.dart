import 'package:flutter/services.dart';

/// 播放页当前是全屏还是窗口布局。
enum PlaybackDisplayMode { windowed, fullscreen }

extension PlaybackDisplayModeValue on PlaybackDisplayMode {
  bool get isFullscreen => this == PlaybackDisplayMode.fullscreen;
}

/// 播放页需要下发的系统显示设置。
///
/// 只暴露播放页真正使用的能力：全屏铺满靠布局实现，系统栏显隐在
/// targetSdk 36 上已被系统忽略，因此这里不下发 [SystemUiMode]。
abstract interface class PlaybackDisplayPlatform {
  Future<void> setPreferredOrientations(List<DeviceOrientation> orientations);
}

/// 直接调用 `SystemChrome` 的默认实现。
class SystemChromePlaybackDisplayPlatform implements PlaybackDisplayPlatform {
  const SystemChromePlaybackDisplayPlatform();

  @override
  Future<void> setPreferredOrientations(List<DeviceOrientation> orientations) =>
      SystemChrome.setPreferredOrientations(orientations);
}

/// 全屏方向的进入与恢复。
///
/// 恢复必须幂等：退出按钮、系统返回键和页面销毁都会调用
/// [restore] 或 [dispose]，重复下发会打断已经稳定的方向。
class PlaybackDisplayModeController {
  PlaybackDisplayModeController({PlaybackDisplayPlatform? platform})
    : _platform = platform ?? const SystemChromePlaybackDisplayPlatform();

  final PlaybackDisplayPlatform _platform;

  PlaybackDisplayMode _mode = PlaybackDisplayMode.windowed;
  bool _restored = true;

  PlaybackDisplayMode get mode => _mode;

  bool get isFullscreen => _mode.isFullscreen;

  /// 进入全屏并下发 [orientations]；平台下发失败不抛错，布局全屏仍然生效。
  Future<void> enter({required List<DeviceOrientation> orientations}) async {
    _mode = PlaybackDisplayMode.fullscreen;
    _restored = false;
    await _apply(orientations);
  }

  /// 恢复应用默认竖屏。重复调用只下发一次。
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    _mode = PlaybackDisplayMode.windowed;
    await _apply(const <DeviceOrientation>[DeviceOrientation.portraitUp]);
  }

  /// 页面销毁兜底：仍处于全屏时恢复竖屏，避免残留横屏。
  Future<void> dispose() => restore();

  Future<void> _apply(List<DeviceOrientation> orientations) async {
    try {
      await _platform.setPreferredOrientations(orientations);
    } on Object {
      // broad-catch: 方向下发失败（例如大屏设备忽略方向限制、iOS 不支持横屏）
      // 不应中断全屏播放，调用方按“全屏退化为铺满当前方向”继续。
    }
  }
}
