enum RecordingVideoCodec { h264, hevc }

extension RecordingVideoCodecDetails on RecordingVideoCodec {
  String get storageValue => switch (this) {
    RecordingVideoCodec.h264 => 'h264',
    RecordingVideoCodec.hevc => 'hevc',
  };

  String get label => switch (this) {
    RecordingVideoCodec.h264 => 'H.264 兼容优先',
    RecordingVideoCodec.hevc => 'H.265 更省空间',
  };

  String get description => switch (this) {
    RecordingVideoCodec.h264 => '几乎所有设备都能播放，文件体积略大',
    RecordingVideoCodec.hevc => '个别设备可能播放不了，文件体积更小',
  };
}

RecordingVideoCodec recordingVideoCodecFromStorage(Object? value) {
  final String normalized = '$value'.trim().toLowerCase();
  // 只有明确存过 H.265 的用户继续用 H.265；缺失或未知值走新装默认 H.264。
  return switch (normalized) {
    'hevc' || 'h265' => RecordingVideoCodec.hevc,
    _ => RecordingVideoCodec.h264,
  };
}

/// 根据相机实际输出的视频轨道 MIME 反推编码，供水印转码使用。
///
/// 相机在偏好编码不可用时会回退到另一编码，因此水印必须跟随实际落盘的
/// 编码（如 video/avc、video/hevc），不能直接使用设置偏好。
RecordingVideoCodec recordingVideoCodecFromMime(
  String? videoMime, {
  RecordingVideoCodec fallback = RecordingVideoCodec.hevc,
}) {
  final String normalized = '$videoMime'.trim().toLowerCase();
  if (normalized.contains('avc') || normalized.contains('h264')) {
    return RecordingVideoCodec.h264;
  }
  if (normalized.contains('hevc') ||
      normalized.contains('h265') ||
      normalized.contains('hvc1') ||
      normalized.contains('hev1')) {
    return RecordingVideoCodec.hevc;
  }
  return fallback;
}
