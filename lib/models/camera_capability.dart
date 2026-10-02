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
/// 默认自动：先按完整三路工作，检测到停摆再降级；也可以手动锁定某个能力模式，
/// 用于自动降级没有触发、但设备确实扛不住三路并发的机型。
enum CameraCapabilityPreference {
  auto,
  full,
  encoderAnalysis,
  alternating;

  String get storageValue => switch (this) {
    CameraCapabilityPreference.auto => 'auto',
    CameraCapabilityPreference.full => 'full',
    CameraCapabilityPreference.encoderAnalysis => 'encoder_analysis',
    CameraCapabilityPreference.alternating => 'alternating',
  };

  /// 手动锁定的能力模式；自动时返回 null，表示仍由探测与原生降级决定。
  CameraCapabilityMode? get lockedMode => switch (this) {
    CameraCapabilityPreference.auto => null,
    CameraCapabilityPreference.full => CameraCapabilityMode.full,
    CameraCapabilityPreference.encoderAnalysis =>
      CameraCapabilityMode.encoderAnalysis,
    CameraCapabilityPreference.alternating => CameraCapabilityMode.alternating,
  };

  String get label => switch (this) {
    CameraCapabilityPreference.auto => '自动（推荐）',
    CameraCapabilityPreference.full => CameraCapabilityMode.full.label,
    CameraCapabilityPreference.encoderAnalysis =>
      CameraCapabilityMode.encoderAnalysis.label,
    CameraCapabilityPreference.alternating =>
      CameraCapabilityMode.alternating.label,
  };

  String get description => switch (this) {
    CameraCapabilityPreference.auto => '由程序自动选择：先按「预览+扫码」工作，画面卡住时自动换成能用的方式',
    CameraCapabilityPreference.full => CameraCapabilityMode.full.description,
    CameraCapabilityPreference.encoderAnalysis =>
      CameraCapabilityMode.encoderAnalysis.description,
    CameraCapabilityPreference.alternating =>
      CameraCapabilityMode.alternating.description,
  };
}
