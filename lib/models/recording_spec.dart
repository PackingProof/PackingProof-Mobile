/// 录制清晰度规格。默认保持高清档，流畅档供低存储或卡顿场景选择。
enum RecordingSpecPreset { hd1080p30, smooth720p30 }

extension RecordingSpecPresetDetails on RecordingSpecPreset {
  String get storageValue => switch (this) {
    RecordingSpecPreset.hd1080p30 => 'hd1080p30',
    RecordingSpecPreset.smooth720p30 => 'smooth720p30',
  };

  String get label => switch (this) {
    RecordingSpecPreset.hd1080p30 => '高清 1080p',
    RecordingSpecPreset.smooth720p30 => '流畅 720p',
  };

  String get description => switch (this) {
    RecordingSpecPreset.hd1080p30 => '默认画质，1080p 30 帧，文件较大，适合常规打包录像。',
    RecordingSpecPreset.smooth720p30 => '720p 30 帧，文件更小，存储紧张或预览卡顿时更流畅。',
  };

  int get videoWidth => switch (this) {
    RecordingSpecPreset.hd1080p30 => 1920,
    RecordingSpecPreset.smooth720p30 => 1280,
  };

  int get videoHeight => switch (this) {
    RecordingSpecPreset.hd1080p30 => 1080,
    RecordingSpecPreset.smooth720p30 => 720,
  };

  int get fps => 30;

  int get avcBitRate => switch (this) {
    RecordingSpecPreset.hd1080p30 => 10_000_000,
    RecordingSpecPreset.smooth720p30 => 6_000_000,
  };

  int get hevcBitRate => switch (this) {
    RecordingSpecPreset.hd1080p30 => 7_000_000,
    RecordingSpecPreset.smooth720p30 => 4_500_000,
  };
}

RecordingSpecPreset recordingSpecFromStorage(Object? value) {
  final String normalized = '$value'.trim().toLowerCase();
  return switch (normalized) {
    'smooth720p30' || '720p30' || 'smooth' => RecordingSpecPreset.smooth720p30,
    _ => RecordingSpecPreset.hd1080p30,
  };
}
