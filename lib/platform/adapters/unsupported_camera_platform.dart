import '../../services/continuous_camera_service.dart';
import '../../models/recording_orientation.dart';
import '../contracts/camera_platform.dart';
import '../platform_capabilities.dart';
import '../platform_exceptions.dart';

class UnsupportedCameraPlatform implements CameraPlatform {
  UnsupportedCameraPlatform();

  @override
  void Function(List<NativeBarcodeCandidate> candidates)? onBarcodeBatch;
  @override
  void Function(String message)? onError;
  @override
  void Function()? onStorageCritical;
  @override
  void Function(Map<Object?, Object?> results)? onProbeFinished;
  @override
  void Function(Map<Object?, Object?> info)? onRecordingFallback;

  @override
  Future<ContinuousCameraInitialization> initialize({
    String videoCodec = 'hevc',
    String recordingSpec = 'hd1080p30',
    String capabilityMode = 'unverified',
    RecordingOrientation recordingOrientation = RecordingOrientation.portrait,
  }) {
    throw const CapabilityUnavailableException(
      PlatformCapability.continuousCameraRecording,
      reason: '当前平台暂不支持连续录像',
    );
  }

  @override
  Future<bool> ensurePermissions({required bool recordAudio}) => _unsupported();

  @override
  Future<NativeRecordingStart> startWork(
    String path, {
    required bool recordAudio,
    required String trackingNumber,
  }) {
    throw const CapabilityUnavailableException(
      PlatformCapability.continuousCameraRecording,
      reason: '当前平台暂不支持连续录像',
    );
  }

  @override
  Future<NativeRecordingSplit> split(
    String nextPath, {
    required String trackingNumber,
  }) {
    throw const CapabilityUnavailableException(
      PlatformCapability.continuousCameraRecording,
      reason: '当前平台暂不支持连续录像',
    );
  }

  @override
  Future<NativeRecordingStop> stopWork() {
    throw const CapabilityUnavailableException(
      PlatformCapability.continuousCameraRecording,
      reason: '当前平台暂不支持连续录像',
    );
  }

  @override
  Future<CameraDiagnosticsSnapshot?> getDiagnostics() => _unsupported();

  @override
  Future<void> setPairingScanEnabled(bool enabled) => _unsupported();
  @override
  Future<void> setWorkScanEnabled(bool enabled) => _unsupported();
  @override
  Future<void> setPreviewActive(bool active) => _unsupported();
  @override
  Future<bool> setTorchEnabled(bool enabled) => _unsupported();
  @override
  Future<ContinuousCameraInitialization> switchCamera() => initialize();
  @override
  Future<List<NativeCameraLens>> listCameras() => _unsupported();
  @override
  Future<ContinuousCameraInitialization> switchToCamera(String cameraId) =>
      initialize();
  @override
  Future<Map<Object?, Object?>?> probeSequence(
    String sequence, {
    required int budgetMs,
  }) => _unsupported();
  @override
  Future<void> setCapabilityMode(String mode) => _unsupported();
  @override
  Future<void> dispose() async {}

  Never _unsupported() {
    throw const CapabilityUnavailableException(
      PlatformCapability.continuousCameraRecording,
      reason: '当前平台暂不支持连续录像',
    );
  }
}
