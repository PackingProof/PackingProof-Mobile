import 'dart:async';

import 'package:flutter/services.dart';

import '../models/recording_spec.dart';
import '../models/recording_video_codec.dart';
import '../models/recording_orientation.dart';
import '../platform/contracts/camera_platform.dart';
import '../platform/platform_container.dart';
import '../platform/adapters/pigeon_camera_platform.dart';

class ContinuousCameraInitialization {
  const ContinuousCameraInitialization({
    required this.textureId,
    required this.previewWidth,
    required this.previewHeight,
    required this.sensorOrientation,
    required this.fps,
    required this.videoMime,
    this.codecFallbackReason,
    required this.flashAvailable,
    required this.lensDirection,
    required this.canSwitchCamera,
    this.cameraId,
    this.zoomRatio = 1.0,
  });

  final int textureId;
  final int previewWidth;
  final int previewHeight;
  final int sensorOrientation;
  final int fps;
  final String videoMime;

  /// 编码回退原因（如 no_hevc_decoder）；正常为 null。
  final String? codecFallbackReason;
  final bool flashAvailable;
  final String lensDirection;
  final bool canSwitchCamera;
  final String? cameraId;
  final double zoomRatio;

  bool get isFrontCamera => lensDirection == 'front';

  Size get portraitPreviewSize {
    final bool swapsDimensions =
        sensorOrientation == 90 || sensorOrientation == 270;
    return swapsDimensions
        ? Size(previewHeight.toDouble(), previewWidth.toDouble())
        : Size(previewWidth.toDouble(), previewHeight.toDouble());
  }

  factory ContinuousCameraInitialization.fromMap(Map<Object?, Object?> map) {
    return ContinuousCameraInitialization(
      textureId: (map['textureId']! as num).toInt(),
      previewWidth: (map['previewWidth']! as num).toInt(),
      previewHeight: (map['previewHeight']! as num).toInt(),
      sensorOrientation: (map['sensorOrientation']! as num).toInt(),
      fps: (map['fps']! as num).toInt(),
      videoMime: map['videoMime']! as String,
      codecFallbackReason: map['codecFallbackReason'] as String?,
      flashAvailable: map['flashAvailable'] == true,
      lensDirection: '${map['lensDirection'] ?? 'back'}',
      canSwitchCamera: map['canSwitchCamera'] == true,
      cameraId: map['cameraId'] as String?,
      zoomRatio: (map['zoomRatio'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

/// 一颗可选的后置镜头（按焦距升序，[zoomRatio] 相对主摄换算）。
class NativeCameraLens {
  const NativeCameraLens({
    required this.cameraId,
    required this.focalLength,
    required this.zoomRatio,
    this.isMain = false,
  });

  final String cameraId;
  final double focalLength;
  final double zoomRatio;
  final bool isMain;

  factory NativeCameraLens.fromMap(Map<Object?, Object?> map) {
    return NativeCameraLens(
      cameraId: '${map['cameraId'] ?? ''}',
      focalLength: (map['focalLength'] as num?)?.toDouble() ?? 0,
      zoomRatio: (map['zoomRatio'] as num?)?.toDouble() ?? 1.0,
      isMain: map['isMain'] == true,
    );
  }

  /// 变焦倍数标签，如 0.5x、1x、1.3x。
  String get label {
    if (zoomRatio <= 0) return '1x';
    final double rounded = (zoomRatio * 10).roundToDouble() / 10;
    final String value = rounded == rounded.truncateToDouble()
        ? rounded.toStringAsFixed(0)
        : rounded.toStringAsFixed(1);
    return '${value}x';
  }
}

class NativeRecordingStart {
  const NativeRecordingStart({required this.path, required this.startedAt});

  final String path;
  final DateTime startedAt;

  factory NativeRecordingStart.fromMap(Map<Object?, Object?> map) {
    return NativeRecordingStart(
      path: map['path']! as String,
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['startedAtMs']! as num).toInt(),
      ),
    );
  }
}

class NativeRecordingSplit {
  const NativeRecordingSplit({
    required this.completedPath,
    required this.nextPath,
    required this.completedStartedAt,
    required this.boundaryAt,
  });

  final String completedPath;
  final String nextPath;
  final DateTime completedStartedAt;
  final DateTime boundaryAt;

  factory NativeRecordingSplit.fromMap(Map<Object?, Object?> map) {
    return NativeRecordingSplit(
      completedPath: map['completedPath']! as String,
      nextPath: map['nextPath']! as String,
      completedStartedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['completedStartedAtMs']! as num).toInt(),
      ),
      boundaryAt: DateTime.fromMillisecondsSinceEpoch(
        (map['boundaryAtMs']! as num).toInt(),
      ),
    );
  }
}

class NativeRecordingStop {
  const NativeRecordingStop({
    required this.path,
    required this.startedAt,
    required this.endedAt,
  });

  final String path;
  final DateTime startedAt;
  final DateTime endedAt;

  factory NativeRecordingStop.fromMap(Map<Object?, Object?> map) {
    return NativeRecordingStop(
      path: map['path']! as String,
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['startedAtMs']! as num).toInt(),
      ),
      endedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['endedAtMs']! as num).toInt(),
      ),
    );
  }
}

class NativeBarcodeCandidate {
  const NativeBarcodeCandidate({
    required this.value,
    required this.area,
    this.format,
    this.detectedAtMs = 0,
  });

  final String value;
  final int area;

  /// 原生 ML Kit 码制名称（如 ean13、code128），内部稳定标识，非界面文案。
  final String? format;

  /// 原生识别到该条码的 wall-clock 毫秒时间戳，仅用于诊断。
  final int detectedAtMs;

  factory NativeBarcodeCandidate.fromMap(Map<Object?, Object?> map) {
    return NativeBarcodeCandidate(
      value: map['value']! as String,
      area: (map['area']! as num).toInt(),
      format: map['format'] as String?,
      detectedAtMs: (map['detectedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 原生相机与预览心跳的诊断快照。
class CameraDiagnosticsSnapshot {
  const CameraDiagnosticsSnapshot({
    required this.device,
    required this.camera,
    this.process = const <String, Object?>{},
  });

  final Map<String, Object?> device;
  final Map<String, Object?> camera;
  final Map<String, Object?> process;

  bool get initialized => camera['initialized'] == true;
  int get previewFrameCount =>
      (camera['previewFrameCount'] as num?)?.toInt() ?? 0;
  int get previewFrameAgeMs =>
      (camera['previewFrameAgeMs'] as num?)?.toInt() ?? -1;
  int get storageAvailableBytes =>
      (camera['storageAvailableBytes'] as num?)?.toInt() ?? -1;
  int get storageTotalBytes =>
      (camera['storageTotalBytes'] as num?)?.toInt() ?? -1;
  int get muxWriteMaxMs => (camera['muxWriteMaxMs'] as num?)?.toInt() ?? 0;
  int get muxWriteStallCount =>
      (camera['muxWriteStallCount'] as num?)?.toInt() ?? 0;
  String? get codecFallbackReason => camera['codecFallbackReason'] as String?;
  String? get lastRequestTemplate => camera['lastRequestTemplate'] as String?;
  bool get stallActive => camera['stallActive'] == true;
  String? get sessionConfigStage => camera['sessionConfigStage'] as String?;
  int get sessionConfigAttempts =>
      (camera['sessionConfigAttempts'] as num?)?.toInt() ?? 0;
  String? get initFailureStage => camera['initFailureStage'] as String?;
  String? get initFailureDetail => camera['initFailureDetail'] as String?;
  String? get startFailureStage => camera['startFailureStage'] as String?;
  String? get startFailureDetail => camera['startFailureDetail'] as String?;
  String? get recordingFallbackMode =>
      camera['recordingFallbackMode'] as String?;
  bool get preferEncoderAnalysisRecording =>
      camera['preferEncoderAnalysisRecording'] == true;
  bool get recordAudio => camera['recordAudio'] == true;
  bool get probeInProgress => camera['probeInProgress'] == true;
  bool get probeCached => camera['probeCached'] == true;
  List<Map<String, Object?>> get probeResults =>
      (camera['probeResults'] as List<Object?>?)
          ?.map((Object? item) => Map<String, Object?>.from(item! as Map))
          .toList(growable: false) ??
      const <Map<String, Object?>>[];
  int? get hardwareLevel => (camera['hardwareLevel'] as num?)?.toInt();
  List<String> get capabilities => _stringList('capabilities');
  List<String> get yuvSizes => _stringList('yuvSizes');
  List<String> get videoSizes => _stringList('videoSizes');
  List<String> get previewSizes => _stringList('previewSizes');
  List<String> get physicalCameraIds => _stringList('physicalCameraIds');
  List<String> get fpsRanges => _stringList('fpsRanges');

  List<String> _stringList(String key) =>
      (camera[key] as List<Object?>?)
          ?.map((Object? item) => '$item')
          .toList(growable: false) ??
      const <String>[];

  String get deviceSummary {
    final String manufacturer = '${device['manufacturer'] ?? ''}';
    final String model = '${device['model'] ?? ''}';
    final String release = '${device['release'] ?? ''}';
    final Object? sdkInt = device['sdkInt'];
    final String name = '$manufacturer $model'.trim();
    if (name.isEmpty) {
      return '未知设备';
    }
    if (manufacturer == 'Apple') {
      return release.isEmpty ? name : '$name · iOS $release';
    }
    return release.isEmpty ? name : '$name · Android $release (SDK $sdkInt)';
  }

  factory CameraDiagnosticsSnapshot.fromMap(Map<Object?, Object?> map) {
    return CameraDiagnosticsSnapshot(
      device: Map<String, Object?>.from(map['device']! as Map),
      camera: Map<String, Object?>.from(map['camera']! as Map),
      process: map['process'] is Map
          ? Map<String, Object?>.from(map['process']! as Map)
          : const <String, Object?>{},
    );
  }
}

class ContinuousCameraService {
  ContinuousCameraService({CameraPlatform? platform, MethodChannel? channel})
    : _platform =
          platform ??
          (channel != null
              ? _LegacyCameraPlatform(channel)
              : AppContainer.forCurrentPlatform().camera) {
    _platform.onBarcodeBatch = (List<NativeBarcodeCandidate> candidates) {
      onBarcodeFrame?.call(candidates);
    };
    _platform.onError = (String message) {
      onError?.call(message);
    };
    _platform.onStorageCritical = () {
      onStorageCritical?.call();
    };
    _platform.onProbeFinished = (Map<Object?, Object?> results) {
      onProbeFinished?.call(results);
    };
    _platform.onRecordingFallback = (Map<Object?, Object?> info) {
      onRecordingFallback?.call(info);
    };
  }

  final CameraPlatform _platform;

  void Function(List<NativeBarcodeCandidate> candidates)? onBarcodeFrame;
  void Function(String message)? onError;
  void Function()? onStorageCritical;
  void Function(Map<Object?, Object?> results)? onProbeFinished;
  void Function(Map<Object?, Object?> info)? onRecordingFallback;

  Future<ContinuousCameraInitialization> initialize({
    RecordingVideoCodec videoCodec = RecordingVideoCodec.hevc,
    RecordingSpecPreset recordingSpec = RecordingSpecPreset.hd1080p30,
    RecordingOrientation recordingOrientation = RecordingOrientation.portrait,
    String capabilityMode = 'unverified',
  }) {
    if (_platform is PigeonCameraPlatform) {
      return _platform.initialize(
        videoCodec: videoCodec.storageValue,
        recordingSpec: recordingSpec.storageValue,
        recordingOrientation: recordingOrientation,
        capabilityMode: capabilityMode,
      );
    }
    return _platform.initialize(
      videoCodec: videoCodec.storageValue,
      recordingSpec: recordingSpec.storageValue,
      capabilityMode: capabilityMode,
    );
  }

  /// 请求运行所需权限；[recordAudio] 为 false 时只要求摄像头权限。
  Future<bool> ensurePermissions({required bool recordAudio}) =>
      _platform.ensurePermissions(recordAudio: recordAudio);

  Future<NativeRecordingStart> startWork(
    String path, {
    required bool recordAudio,
  }) => _platform.startWork(path, recordAudio: recordAudio);

  Future<NativeRecordingSplit> split(String nextPath) =>
      _platform.split(nextPath);

  Future<NativeRecordingStop> stopWork() => _platform.stopWork();

  Future<CameraDiagnosticsSnapshot?> getDiagnostics() =>
      _platform.getDiagnostics();

  Future<void> setPairingScanEnabled(bool enabled) =>
      _platform.setPairingScanEnabled(enabled);

  Future<void> setWorkScanEnabled(bool enabled) =>
      _platform.setWorkScanEnabled(enabled);

  Future<void> setPreviewActive(bool active) =>
      _platform.setPreviewActive(active);

  Future<bool> setTorchEnabled(bool enabled) =>
      _platform.setTorchEnabled(enabled);

  Future<ContinuousCameraInitialization> switchCamera() =>
      _platform.switchCamera();

  Future<List<NativeCameraLens>> listCameras() => _platform.listCameras();

  Future<ContinuousCameraInitialization> switchToCamera(String cameraId) =>
      _platform.switchToCamera(cameraId);

  Future<Map<Object?, Object?>?> probeSequence(
    String sequence, {
    required int budgetMs,
  }) => _platform.probeSequence(sequence, budgetMs: budgetMs);

  Future<void> setCapabilityMode(String mode) =>
      _platform.setCapabilityMode(mode);

  Future<void> dispose() async {
    onBarcodeFrame = null;
    onError = null;
    onStorageCritical = null;
    onProbeFinished = null;
    onRecordingFallback = null;
    await _platform.dispose();
  }
}

class _LegacyCameraPlatform implements CameraPlatform {
  _LegacyCameraPlatform(this._channel) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final MethodChannel _channel;

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
    RecordingOrientation recordingOrientation = RecordingOrientation.portrait,
    String capabilityMode = 'unverified',
  }) async {
    final Map<Object?, Object?> values = (await _channel
        .invokeMethod<Map<Object?, Object?>>('initialize', <String, Object>{
          'videoCodec': videoCodec,
          'recordingSpec': recordingSpec,
          'recordingOrientation': recordingOrientation.storageValue,
          'capabilityMode': capabilityMode,
        }))!;
    return ContinuousCameraInitialization.fromMap(values);
  }

  @override
  Future<bool> ensurePermissions({required bool recordAudio}) async {
    return (await _channel.invokeMethod<bool>(
          'ensurePermissions',
          <String, Object>{'recordAudio': recordAudio},
        )) ??
        false;
  }

  @override
  Future<NativeRecordingStart> startWork(
    String path, {
    required bool recordAudio,
  }) async {
    final Map<Object?, Object?> values = (await _channel
        .invokeMethod<Map<Object?, Object?>>('startWork', <String, Object>{
          'path': path,
          'recordAudio': recordAudio,
        }))!;
    return NativeRecordingStart.fromMap(values);
  }

  @override
  Future<NativeRecordingSplit> split(String nextPath) async {
    final Map<Object?, Object?> values = (await _channel
        .invokeMethod<Map<Object?, Object?>>('split', <String, Object>{
          'path': nextPath,
        }))!;
    return NativeRecordingSplit.fromMap(values);
  }

  @override
  Future<NativeRecordingStop> stopWork() async {
    final Map<Object?, Object?> values = (await _channel
        .invokeMethod<Map<Object?, Object?>>('stopWork'))!;
    return NativeRecordingStop.fromMap(values);
  }

  @override
  Future<CameraDiagnosticsSnapshot?> getDiagnostics() async {
    final Map<Object?, Object?>? values = await _channel
        .invokeMethod<Map<Object?, Object?>>('getDiagnostics');
    if (values == null) return null;
    return CameraDiagnosticsSnapshot.fromMap(values);
  }

  @override
  Future<void> setPairingScanEnabled(bool enabled) async {
    await _channel.invokeMethod<void>('setPairingScanEnabled', <String, Object>{
      'enabled': enabled,
    });
  }

  @override
  Future<void> setWorkScanEnabled(bool enabled) async {
    await _channel.invokeMethod<void>('setWorkScanEnabled', <String, Object>{
      'enabled': enabled,
    });
  }

  @override
  Future<void> setPreviewActive(bool active) async {
    await _channel.invokeMethod<void>('setPreviewActive', <String, Object>{
      'active': active,
    });
  }

  @override
  Future<bool> setTorchEnabled(bool enabled) async {
    return (await _channel.invokeMethod<bool>(
          'setTorchEnabled',
          <String, Object>{'enabled': enabled},
        )) ??
        false;
  }

  @override
  Future<ContinuousCameraInitialization> switchCamera() async {
    final Map<Object?, Object?> values = (await _channel
        .invokeMethod<Map<Object?, Object?>>('switchCamera'))!;
    return ContinuousCameraInitialization.fromMap(values);
  }

  @override
  Future<List<NativeCameraLens>> listCameras() async {
    final List<Object?>? values = await _channel.invokeMethod<List<Object?>>(
      'listCameras',
    );
    if (values == null) return const <NativeCameraLens>[];
    return values
        .map(
          (Object? value) => NativeCameraLens.fromMap(
            Map<Object?, Object?>.from(value! as Map),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<ContinuousCameraInitialization> switchToCamera(String cameraId) async {
    final Map<Object?, Object?> values = (await _channel
        .invokeMethod<Map<Object?, Object?>>('switchToCamera', <String, Object>{
          'cameraId': cameraId,
        }))!;
    return ContinuousCameraInitialization.fromMap(values);
  }

  @override
  Future<Map<Object?, Object?>?> probeSequence(
    String sequence, {
    required int budgetMs,
  }) async {
    final Map<Object?, Object?>? values = await _channel
        .invokeMethod<Map<Object?, Object?>>('probeSequence', <String, Object>{
          'sequence': sequence,
          'budgetMs': budgetMs,
        });
    return values;
  }

  @override
  Future<void> setCapabilityMode(String mode) async {
    await _channel.invokeMethod<void>('setCapabilityMode', <String, Object>{
      'mode': mode,
    });
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _channel.invokeMethod<void>('dispose');
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'barcodeFrame':
        final List<Object?> values = List<Object?>.from(
          call.arguments! as List,
        );
        onBarcodeBatch?.call(
          values
              .map((Object? value) {
                final Map<Object?, Object?> map = Map<Object?, Object?>.from(
                  value! as Map,
                );
                return NativeBarcodeCandidate.fromMap(map);
              })
              .toList(growable: false),
        );
      case 'nativeError':
        onError?.call(call.arguments?.toString() ?? '原生录像发生未知错误');
      case 'storageCritical':
        onStorageCritical?.call();
      case 'probeFinished':
        onProbeFinished?.call(
          Map<Object?, Object?>.from(call.arguments! as Map),
        );
      case 'recordingFallback':
        onRecordingFallback?.call(
          Map<Object?, Object?>.from(call.arguments! as Map),
        );
    }
  }
}
