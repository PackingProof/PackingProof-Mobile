/// 平台能力标识。
///
/// 该枚举只用于描述平台具备哪些能力，业务状态机和 UI 分支应通过
/// [PlatformCapabilities] 检查并配合类型化异常处理，而不是逐项替代
/// `Platform.isAndroid` 判断。
enum PlatformCapability {
  continuousCameraRecording,
  cameraBarcodeScanning,
  lanBackup,
  orderInfoReceiver,
  videoWatermark,
  videoExport,
  recordingThumbnail,
  systemVideoPlayer,
  alertAudioSession,
  alertVolumeBoost,
}

/// 当前运行平台的能力描述。
class PlatformCapabilities {
  const PlatformCapabilities(this.supported);

  final Set<PlatformCapability> supported;

  bool supports(PlatformCapability capability) =>
      supported.contains(capability);
}
