import 'dart:async';

import 'package:flutter/services.dart';

import '../models/recording_video_codec.dart';

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
    );
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
  });

  final String value;
  final int area;

  /// 原生 ML Kit 码制名称（如 ean13、code128），内部稳定标识，非界面文案。
  final String? format;

  factory NativeBarcodeCandidate.fromMap(Map<Object?, Object?> map) {
    return NativeBarcodeCandidate(
      value: map['value']! as String,
      area: (map['area']! as num).toInt(),
      format: map['format'] as String?,
    );
  }
}

/// 原生相机与预览心跳的诊断快照。
class CameraDiagnosticsSnapshot {
  const CameraDiagnosticsSnapshot({required this.device, required this.camera});

  final Map<String, Object?> device;
  final Map<String, Object?> camera;

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

  String get deviceSummary {
    final String manufacturer = '${device['manufacturer'] ?? ''}';
    final String model = '${device['model'] ?? ''}';
    final String release = '${device['release'] ?? ''}';
    final Object? sdkInt = device['sdkInt'];
    final String name = '$manufacturer $model'.trim();
    return name.isEmpty ? '未知设备' : '$name · Android $release (SDK $sdkInt)';
  }

  factory CameraDiagnosticsSnapshot.fromMap(Map<Object?, Object?> map) {
    return CameraDiagnosticsSnapshot(
      device: Map<String, Object?>.from(map['device']! as Map),
      camera: Map<String, Object?>.from(map['camera']! as Map),
    );
  }
}

class ContinuousCameraService {
  static const MethodChannel _channel = MethodChannel(
    'app.packingproof.mobile/continuous_camera',
  );

  ContinuousCameraService() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  void Function(List<NativeBarcodeCandidate> candidates)? onBarcodeFrame;
  void Function(String message)? onError;
  void Function()? onStorageCritical;

  Future<ContinuousCameraInitialization> initialize({
    RecordingVideoCodec videoCodec = RecordingVideoCodec.hevc,
  }) async {
    final Map<Object?, Object?> values = (await _channel
        .invokeMethod<Map<Object?, Object?>>('initialize', <String, Object>{
          'videoCodec': videoCodec.storageValue,
        }))!;
    return ContinuousCameraInitialization.fromMap(values);
  }

  /// 请求运行所需权限；[recordAudio] 为 false 时只要求摄像头权限。
  Future<bool> ensurePermissions({required bool recordAudio}) async {
    return (await _channel.invokeMethod<bool>(
          'ensurePermissions',
          <String, Object>{'recordAudio': recordAudio},
        )) ??
        false;
  }

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

  Future<NativeRecordingSplit> split(String nextPath) async {
    final Map<Object?, Object?> values = (await _channel
        .invokeMethod<Map<Object?, Object?>>('split', <String, Object>{
          'path': nextPath,
        }))!;
    return NativeRecordingSplit.fromMap(values);
  }

  Future<NativeRecordingStop> stopWork() async {
    final Map<Object?, Object?> values = (await _channel
        .invokeMethod<Map<Object?, Object?>>('stopWork'))!;
    return NativeRecordingStop.fromMap(values);
  }

  Future<CameraDiagnosticsSnapshot?> getDiagnostics() async {
    final Map<Object?, Object?>? values = await _channel
        .invokeMethod<Map<Object?, Object?>>('getDiagnostics');
    if (values == null) return null;
    return CameraDiagnosticsSnapshot.fromMap(values);
  }

  Future<void> setPairingScanEnabled(bool enabled) async {
    await _channel.invokeMethod<void>('setPairingScanEnabled', <String, Object>{
      'enabled': enabled,
    });
  }

  Future<void> setWorkScanEnabled(bool enabled) async {
    await _channel.invokeMethod<void>('setWorkScanEnabled', <String, Object>{
      'enabled': enabled,
    });
  }

  Future<void> setPreviewActive(bool active) async {
    await _channel.invokeMethod<void>('setPreviewActive', <String, Object>{
      'active': active,
    });
  }

  Future<bool> setTorchEnabled(bool enabled) async {
    return (await _channel.invokeMethod<bool>(
          'setTorchEnabled',
          <String, Object>{'enabled': enabled},
        )) ??
        false;
  }

  Future<ContinuousCameraInitialization> switchCamera() async {
    final Map<Object?, Object?> values = (await _channel
        .invokeMethod<Map<Object?, Object?>>('switchCamera'))!;
    return ContinuousCameraInitialization.fromMap(values);
  }

  Future<void> dispose() async {
    onBarcodeFrame = null;
    onError = null;
    onStorageCritical = null;
    _channel.setMethodCallHandler(null);
    await _channel.invokeMethod<void>('dispose');
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'barcodeFrame':
        final List<Object?> values = List<Object?>.from(
          call.arguments! as List,
        );
        onBarcodeFrame?.call(
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
    }
  }
}
