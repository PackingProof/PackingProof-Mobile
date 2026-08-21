import '../../services/continuous_camera_service.dart';

abstract interface class CameraPlatform {
  void Function(List<NativeBarcodeCandidate> candidates)? onBarcodeBatch;
  void Function(String message)? onError;
  void Function()? onStorageCritical;
  void Function(Map<Object?, Object?> results)? onProbeFinished;
  void Function(Map<Object?, Object?> info)? onRecordingFallback;

  Future<ContinuousCameraInitialization> initialize({
    String videoCodec,
    String recordingSpec,
    String capabilityMode,
  });

  Future<bool> ensurePermissions({required bool recordAudio});

  Future<NativeRecordingStart> startWork(
    String path, {
    required bool recordAudio,
    required String trackingNumber,
  });

  Future<NativeRecordingSplit> split(
    String nextPath, {
    required String trackingNumber,
  });

  Future<NativeRecordingStop> stopWork();

  Future<CameraDiagnosticsSnapshot?> getDiagnostics();

  Future<void> setPairingScanEnabled(bool enabled);

  Future<void> setWorkScanEnabled(bool enabled);

  Future<void> setPreviewActive(bool active);

  Future<bool> setTorchEnabled(bool enabled);

  Future<ContinuousCameraInitialization> switchCamera();

  Future<List<NativeCameraLens>> listCameras();

  Future<ContinuousCameraInitialization> switchToCamera(String cameraId);

  /// 仅在平台声明 cameraCapabilityNegotiation 时调用。
  Future<Map<Object?, Object?>?> probeSequence(
    String sequence, {
    required int budgetMs,
  });

  /// 仅在平台声明 cameraCapabilityNegotiation 时调用。
  Future<void> setCapabilityMode(String mode);

  Future<void> dispose();
}
