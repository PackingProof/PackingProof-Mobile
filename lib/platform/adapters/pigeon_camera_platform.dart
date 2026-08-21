import '../../services/continuous_camera_service.dart';
import '../../models/recording_orientation.dart';
import '../contracts/camera_platform.dart';
import '../generated/platform_api.g.dart';

class PigeonCameraPlatform implements CameraPlatform {
  PigeonCameraPlatform({CameraHostApi? hostApi})
    : _hostApi = hostApi ?? CameraHostApi() {
    _eventSink = _CameraEventSink(this);
    CameraEventApi.setUp(_eventSink);
  }

  final CameraHostApi _hostApi;
  late final _CameraEventSink _eventSink;

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
  }) async {
    return _initializationFromDto(
      await _hostApi.initialize(
        CameraInitializeRequest(
          videoCodec: videoCodec,
          recordingSpec: recordingSpec,
          capabilityMode: capabilityMode,
          recordingOrientation: recordingOrientation.storageValue,
        ),
      ),
    );
  }

  @override
  Future<bool> ensurePermissions({required bool recordAudio}) =>
      _hostApi.ensurePermissions(recordAudio);

  @override
  Future<NativeRecordingStart> startWork(
    String path, {
    required bool recordAudio,
  }) async {
    final CameraRecordingStartDto value = await _hostApi.startWork(
      path,
      recordAudio,
    );
    return NativeRecordingStart.fromMap(<Object?, Object?>{
      'path': value.path,
      'startedAtMs': value.startedAtMs,
    });
  }

  @override
  Future<NativeRecordingSplit> split(String nextPath) async {
    final CameraRecordingSplitDto value = await _hostApi.split(nextPath);
    return NativeRecordingSplit.fromMap(<Object?, Object?>{
      'completedPath': value.completedPath,
      'nextPath': value.nextPath,
      'completedStartedAtMs': value.completedStartedAtMs,
      'boundaryAtMs': value.boundaryAtMs,
    });
  }

  @override
  Future<NativeRecordingStop> stopWork() async {
    final CameraRecordingStopDto value = await _hostApi.stopWork();
    return NativeRecordingStop.fromMap(<Object?, Object?>{
      'path': value.path,
      'startedAtMs': value.startedAtMs,
      'endedAtMs': value.endedAtMs,
    });
  }

  @override
  Future<CameraDiagnosticsSnapshot?> getDiagnostics() async {
    final Map<String?, Object?>? values = await _hostApi.getDiagnostics();
    if (values == null) return null;
    return CameraDiagnosticsSnapshot.fromMap(
      Map<Object?, Object?>.from(values),
    );
  }

  @override
  Future<void> setPairingScanEnabled(bool enabled) =>
      _hostApi.setPairingScanEnabled(enabled);

  @override
  Future<void> setWorkScanEnabled(bool enabled) =>
      _hostApi.setWorkScanEnabled(enabled);

  @override
  Future<void> setPreviewActive(bool active) =>
      _hostApi.setPreviewActive(active);

  @override
  Future<bool> setTorchEnabled(bool enabled) =>
      _hostApi.setTorchEnabled(enabled);

  @override
  Future<ContinuousCameraInitialization> switchCamera() async =>
      _initializationFromDto(await _hostApi.switchCamera());

  @override
  Future<List<NativeCameraLens>> listCameras() async {
    final List<CameraLensDto> values = await _hostApi.listCameras();
    return values.map(_lensFromDto).toList(growable: false);
  }

  @override
  Future<ContinuousCameraInitialization> switchToCamera(
    String cameraId,
  ) async => _initializationFromDto(await _hostApi.switchToCamera(cameraId));

  @override
  Future<Map<Object?, Object?>?> probeSequence(
    String sequence, {
    required int budgetMs,
  }) async {
    final Map<String?, Object?>? values = await _hostApi.probeSequence(
      sequence,
      budgetMs,
    );
    if (values == null) return null;
    return Map<Object?, Object?>.from(values);
  }

  @override
  Future<void> setCapabilityMode(String mode) =>
      _hostApi.setCapabilityMode(mode);

  @override
  Future<void> dispose() async {
    CameraEventApi.setUp(null);
    await _hostApi.dispose();
  }
}

class _CameraEventSink extends CameraEventApi {
  _CameraEventSink(this._platform);

  final PigeonCameraPlatform _platform;

  @override
  void sessionStarted(CameraSessionStartedDto event) {}

  @override
  void segmentStarted(CameraSegmentStartedDto event) {}

  @override
  void segmentCompleted(CameraSegmentCompletedDto event) {}

  @override
  void segmentFailed(CameraSegmentFailedDto event) {}

  @override
  void sessionFailed(CameraSessionFailedDto event) {}

  @override
  void barcodeBatch(List<BarcodeCandidateDto> candidates) {
    _platform.onBarcodeBatch?.call(
      candidates
          .map(
            (BarcodeCandidateDto value) =>
                NativeBarcodeCandidate.fromMap(<Object?, Object?>{
                  'value': value.value,
                  'area': value.area,
                  'format': value.format,
                  'detectedAtMs': value.detectedAtMs,
                }),
          )
          .toList(growable: false),
    );
  }

  @override
  void nativeError(String message) => _platform.onError?.call(message);

  @override
  void storageCritical() => _platform.onStorageCritical?.call();

  @override
  void probeFinished(Map<String?, Object?> results) =>
      _platform.onProbeFinished?.call(results);

  @override
  void recordingFallback(Map<String?, Object?> info) =>
      _platform.onRecordingFallback?.call(info);
}

ContinuousCameraInitialization _initializationFromDto(
  CameraInitializationDto value,
) => ContinuousCameraInitialization.fromMap(<Object?, Object?>{
  'textureId': value.textureId,
  'previewWidth': value.previewWidth,
  'previewHeight': value.previewHeight,
  'sensorOrientation': value.sensorOrientation,
  'fps': value.fps,
  'videoMime': value.videoMime,
  'codecFallbackReason': value.codecFallbackReason,
  'flashAvailable': value.flashAvailable,
  'lensDirection': value.lensDirection,
  'canSwitchCamera': value.canSwitchCamera,
  'cameraId': value.cameraId,
  'zoomRatio': value.zoomRatio,
});

NativeCameraLens _lensFromDto(CameraLensDto value) =>
    NativeCameraLens.fromMap(<Object?, Object?>{
      'cameraId': value.cameraId,
      'focalLength': value.focalLength,
      'zoomRatio': value.zoomRatio,
      'isMain': value.isMain,
    });
