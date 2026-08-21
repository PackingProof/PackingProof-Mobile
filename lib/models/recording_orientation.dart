/// 用户选择的录像方向。名称直接作为持久化和跨端协议值。
enum RecordingOrientation { portrait, landscapeLeft, landscapeRight }

extension RecordingOrientationValue on RecordingOrientation {
  String get storageValue => name;

  String get label => switch (this) {
    RecordingOrientation.portrait => '竖屏',
    RecordingOrientation.landscapeLeft => '横右',
    RecordingOrientation.landscapeRight => '横左',
  };

  /// 录像变换使用的顺时针角度，仅在平台边界/几何策略内部使用。
  double get clockwiseDegrees => switch (this) {
    RecordingOrientation.portrait => 0,
    RecordingOrientation.landscapeLeft => 90,
    RecordingOrientation.landscapeRight => 270,
  };
}

RecordingOrientation recordingOrientationFromStorage(Object? value) {
  return switch (value) {
    'landscapeLeft' => RecordingOrientation.landscapeLeft,
    'landscapeRight' => RecordingOrientation.landscapeRight,
    _ => RecordingOrientation.portrait,
  };
}
