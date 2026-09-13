import 'package:flutter/services.dart';

import '../models/recording_orientation.dart';

/// 全屏播放时视频应当铺满的屏幕方向。
enum PlaybackFullscreenLayout { portrait, landscape }

/// 全屏方向策略：竖版视频铺满竖屏，横版与正方形视频铺满横屏。
///
/// 纯计算，不触碰平台通道，便于穷举测试。
abstract final class PlaybackFullscreenPolicy {
  /// 近似正方形的判定容差：解码尺寸上报整数像素，正方形视频算出的比值未必精确等于 1。
  /// 取 0.5%，远大于像素取整误差，又不会把常见的 4:3 / 3:4 误判成正方形。
  static const double _squareAspectRatioTolerance = 0.005;

  /// 依据视频实际宽高比判定全屏方向，宽高比不可用时回退到录像元数据。
  ///
  /// [videoAspectRatio] 取 `VideoPlayerValue.aspectRatio`：未初始化或尺寸为 0
  /// 时上游返回 1.0，因此必须结合 [videoInitialized] 一起判断。
  /// 横版与正方形（含容差）都按横屏铺满，只有明显窄于正方形的视频才算竖版。
  static PlaybackFullscreenLayout layoutFor({
    required double videoAspectRatio,
    required bool videoInitialized,
    required RecordingOrientation recordedOrientation,
  }) {
    if (videoInitialized && videoAspectRatio > 0) {
      return videoAspectRatio >= 1 - _squareAspectRatioTolerance
          ? PlaybackFullscreenLayout.landscape
          : PlaybackFullscreenLayout.portrait;
    }
    return recordedOrientation == RecordingOrientation.portrait
        ? PlaybackFullscreenLayout.portrait
        : PlaybackFullscreenLayout.landscape;
  }

  /// 横屏全屏允许左右两个方向，用户怎么持机都能铺满；竖屏全屏保持应用默认竖屏。
  static List<DeviceOrientation> orientationsFor(
    PlaybackFullscreenLayout layout,
  ) {
    return switch (layout) {
      PlaybackFullscreenLayout.portrait => const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ],
      PlaybackFullscreenLayout.landscape => const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    };
  }
}
