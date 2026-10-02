/// 摄像头工作能力模式。与 Kotlin 的 CameraCapabilityMode 保持一一对应。
enum CameraCapabilityMode {
  full,
  encoderAnalysis,
  alternating,
  unsupported,
  unverified;

  String get wireValue => switch (this) {
    CameraCapabilityMode.full => 'full',
    CameraCapabilityMode.encoderAnalysis => 'encoder_analysis',
    CameraCapabilityMode.alternating => 'alternating',
    CameraCapabilityMode.unsupported => 'unsupported',
    CameraCapabilityMode.unverified => 'unverified',
  };

  String get label => switch (this) {
    CameraCapabilityMode.full => '预览+扫码',
    CameraCapabilityMode.encoderAnalysis => '仅扫码',
    CameraCapabilityMode.alternating => '仅预览',
    CameraCapabilityMode.unsupported => '不支持',
    CameraCapabilityMode.unverified => '未检测',
  };

  String get description => switch (this) {
    CameraCapabilityMode.full => '录像时预览和扫码同时可用',
    CameraCapabilityMode.encoderAnalysis => '录像时预览画面会停住，扫码照常',
    CameraCapabilityMode.alternating => '录像时不能扫码，录完一单点「完成本单」再扫码',
    CameraCapabilityMode.unsupported => '此设备无法同时预览和扫码，暂时无法工作',
    CameraCapabilityMode.unverified => '还没检测过，先按常规方式工作，可以点「重新检测」',
  };

  static CameraCapabilityMode fromWire(Object? value) {
    final String normalized = '$value'.trim().toLowerCase();
    for (final CameraCapabilityMode mode in CameraCapabilityMode.values) {
      if (mode.wireValue == normalized) return mode;
    }
    return CameraCapabilityMode.unverified;
  }
}

/// 用户在设置里选择的摄像头工作模式。
///
/// 默认「预览+扫码」：设备到底能不能同时预览、扫码和录像，只有真跑起来才知道，
/// 所以不做探测门禁。真跑不动时由原生降级，并把这一项在设置里临时灰掉。
enum CameraCapabilityPreference {
  full,
  encoderAnalysis,
  alternating;

  String get storageValue => switch (this) {
    CameraCapabilityPreference.full => 'full',
    CameraCapabilityPreference.encoderAnalysis => 'encoder_analysis',
    CameraCapabilityPreference.alternating => 'alternating',
  };

  /// 选择直接锁定的能力模式。
  CameraCapabilityMode get lockedMode => switch (this) {
    CameraCapabilityPreference.full => CameraCapabilityMode.full,
    CameraCapabilityPreference.encoderAnalysis =>
      CameraCapabilityMode.encoderAnalysis,
    CameraCapabilityPreference.alternating => CameraCapabilityMode.alternating,
  };

  String get label => switch (this) {
    CameraCapabilityPreference.full => CameraCapabilityMode.full.label,
    CameraCapabilityPreference.encoderAnalysis =>
      CameraCapabilityMode.encoderAnalysis.label,
    CameraCapabilityPreference.alternating =>
      CameraCapabilityMode.alternating.label,
  };

  String get description => switch (this) {
    CameraCapabilityPreference.full => CameraCapabilityMode.full.description,
    CameraCapabilityPreference.encoderAnalysis =>
      CameraCapabilityMode.encoderAnalysis.description,
    CameraCapabilityPreference.alternating =>
      CameraCapabilityMode.alternating.description,
  };
}

/// 读回工作模式设置；缺失或无法识别时回到默认的「预览+扫码」。
CameraCapabilityPreference cameraCapabilityPreferenceFromStorage(Object? value) {
  final String normalized = '$value'.trim();
  for (final CameraCapabilityPreference preference
      in CameraCapabilityPreference.values) {
    if (preference.storageValue == normalized) return preference;
  }
  return CameraCapabilityPreference.full;
}
