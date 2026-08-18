import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/order_info.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/platform/contracts/camera_platform.dart';
import 'package:packing_proof_mobile/platform/platform_capabilities.dart';
import 'package:packing_proof_mobile/services/camera_capability_policy.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';
import 'package:packing_proof_mobile/services/max_volume_service.dart';
import 'package:packing_proof_mobile/services/order_info_receiver_service.dart';
import 'package:packing_proof_mobile/services/speech_prompt_service.dart';
import 'package:packing_proof_mobile/services/video_watermark_service.dart';
import 'package:wakelock_plus_platform_interface/src/method_channel_wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'test_repository.dart';

class _FakeCameraPlatform implements CameraPlatform {
  int startWorkCalls = 0;
  String lastMode = 'unverified';
  String? lastPath;

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
  }) async {
    return const ContinuousCameraInitialization(
      textureId: 1,
      previewWidth: 1920,
      previewHeight: 1080,
      sensorOrientation: 90,
      fps: 30,
      videoMime: 'video/hevc',
      flashAvailable: false,
      lensDirection: 'back',
      canSwitchCamera: false,
      cameraId: 'back0',
    );
  }

  @override
  Future<bool> ensurePermissions({required bool recordAudio}) async => true;

  @override
  Future<NativeRecordingStart> startWork(
    String path, {
    required bool recordAudio,
  }) async {
    startWorkCalls++;
    lastPath = path;
    File(path).createSync(recursive: true);
    return NativeRecordingStart(path: path, startedAt: DateTime.now());
  }

  @override
  Future<NativeRecordingSplit> split(String nextPath) {
    throw UnimplementedError();
  }

  @override
  Future<NativeRecordingStop> stopWork() async {
    return NativeRecordingStop(
      path: lastPath ?? '',
      startedAt: DateTime.now(),
      endedAt: DateTime.now(),
    );
  }

  @override
  Future<CameraDiagnosticsSnapshot?> getDiagnostics() async {
    return CameraDiagnosticsSnapshot(
      device: const <String, Object?>{},
      camera: const <String, Object?>{
        'cameraId': 'back0',
        'videoWidth': 1920,
        'videoHeight': 1080,
        'analysisWidth': 1280,
        'analysisHeight': 720,
        'videoMime': 'video/hevc',
        'recordingSpec': 'hd1080p30',
      },
    );
  }

  Map<String, Object?> _identity() => const <String, Object?>{
    'cameraId': 'back0',
    'videoSize': '1920x1080',
    'analysisSize': '1280x720',
    'codec': 'hevc',
    'spec': 'hd1080p30',
    'probeSchemaVersion': 1,
    'cameraPipelineVersion': 1,
  };

  Map<String, Object?> _phase(String phase, String outcome) =>
      <String, Object?>{
        'phase': phase,
        'outcome': outcome,
        'previewFrames': 30,
        'analysisFrames': 30,
        'encoderBuffers': 30,
      };

  @override
  Future<Map<Object?, Object?>?> probeSequence(
    String sequence, {
    required int budgetMs,
  }) async {
    final List<Map<String, Object?>> phases;
    if (sequence == 'alternating') {
      phases = <Map<String, Object?>>[
        _phase('idle', 'configured'),
        _phase('record', 'configured'),
        _phase('idle', 'configured'),
        _phase('record', 'configured'),
        _phase('idle', 'configured'),
      ];
    } else {
      phases = <Map<String, Object?>>[
        _phase('idle', 'configured'),
        _phase('record', 'configure_failed'),
        _phase('idle', 'configured'),
        _phase('record', 'configure_failed'),
        _phase('idle', 'configured'),
      ];
    }
    return <Object?, Object?>{
      'sequence': sequence,
      'status': 'ok',
      'phases': phases,
      'identity': _identity(),
    };
  }

  @override
  Future<void> setCapabilityMode(String mode) async {
    lastMode = mode;
  }

  @override
  Future<void> setPairingScanEnabled(bool enabled) async {}
  @override
  Future<void> setWorkScanEnabled(bool enabled) async {}
  @override
  Future<void> setPreviewActive(bool active) async {}
  @override
  Future<bool> setTorchEnabled(bool enabled) async => false;
  @override
  Future<ContinuousCameraInitialization> switchCamera() => initialize();
  @override
  Future<List<NativeCameraLens>> listCameras() async => const [];
  @override
  Future<ContinuousCameraInitialization> switchToCamera(String cameraId) =>
      initialize();
  @override
  Future<void> dispose() async {}
}

class _FakeSpeechSink implements SpeechPromptSink {
  bool _enabled = true;

  @override
  bool get enabled => _enabled;
  @override
  Future<void> setEnabled(bool value) async => _enabled = value;
  @override
  void enqueue(SpeechPrompt prompt, {String? incidentKey}) {}
  @override
  Future<void> preview() async {}
  @override
  void playShortBeep() {}
  @override
  void resetIncidents() {}
  @override
  void resolveIncident(String incidentKey) {}
  @override
  Future<void> clear() async {}
  @override
  Future<void> dispose() async {}
}

class _FakeMaxVolumeSink implements MaxVolumeSink {
  @override
  Future<void> beginSession() async {}
  @override
  Future<void> endSession() async {}
  @override
  Future<void> disable() async {}
  @override
  Future<void> boost() async {}
  @override
  Future<void> dispose() async {}
}

class _FakeOrderReceiverSink implements OrderInfoReceiverSink {
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  @override
  OrderInfoReceiverSnapshot get snapshot => const OrderInfoReceiverSnapshot();
  @override
  Stream<OrderInfo> get received => const Stream<OrderInfo>.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> retry() async {}
  @override
  Future<OrderInfo?> lookup(String trackingNumber) async => null;
  @override
  Future<void> setBackgroundKeepAlive(bool enabled) async {}
  @override
  Future<void> dispose() async {}
}

class _FakeWatermarkSink implements VideoWatermarkSink {
  @override
  Future<String> apply({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    RecordingVideoCodec videoCodec = RecordingVideoCodec.hevc,
  }) async => inputPath;
}

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _FakeCameraPlatform camera;
  late PackingSessionController controller;

  setUp(() async {
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    root = await Directory.systemTemp.createTemp('packing-proof-alternating-');
    camera = _FakeCameraPlatform();
    controller = PackingSessionController(
      repository: testRepository(root),
      speechService: _FakeSpeechSink(),
      maxVolumeService: _FakeMaxVolumeSink(),
      orderInfoReceiver: _FakeOrderReceiverSink(),
      videoWatermarkService: _FakeWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.continuousCameraRecording,
      }),
      cameraService: ContinuousCameraService(platform: camera),
    );
  });

  tearDown(() async {
    WakelockPlusPlatformInterface.instance = MethodChannelWakelockPlus();
    if (await root.exists()) {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // 临时目录清理失败不阻塞测试。
      }
    }
  });

  test('首次探测锁定轮换模式并下发原生模式与一次性说明', () async {
    await controller.initialize();
    expect(controller.capabilityMode, CameraCapabilityMode.unverified);

    await controller.retryCapabilityProbe();

    expect(controller.capabilityMode, CameraCapabilityMode.alternating);
    expect(controller.phase, PackingSessionPhase.ready);
    expect(camera.lastMode, 'alternating');
    expect(controller.takeCapabilityNoticeForDisplay(), isNotNull);
    expect(controller.capabilityStatusText, contains('扫码录像轮换'));
    expect(controller.capabilityProbedAtMs, greaterThan(0));

    // 未工作时完成本单是安全的空操作。
    await controller.finishCurrentOrder();
    expect(controller.phase, PackingSessionPhase.ready);
    expect(controller.isWorking, isFalse);
  });

  test('缓存命中时不再重复探测', () async {
    await controller.initialize();
    await controller.retryCapabilityProbe();
    expect(controller.capabilityMode, CameraCapabilityMode.alternating);
    final int firstProbedAtMs = controller.capabilityProbedAtMs;

    final PackingSessionController second = PackingSessionController(
      repository: testRepository(root),
      speechService: _FakeSpeechSink(),
      maxVolumeService: _FakeMaxVolumeSink(),
      orderInfoReceiver: _FakeOrderReceiverSink(),
      videoWatermarkService: _FakeWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.continuousCameraRecording,
      }),
      cameraService: ContinuousCameraService(platform: camera),
    );
    await second.initialize();
    expect(second.capabilityMode, CameraCapabilityMode.alternating);
    expect(second.capabilityProbedAtMs, firstProbedAtMs);
  });

  test('开始工作后忽略二维码并从同帧选择 Code128', () async {
    await controller.initialize();
    await controller.startWork();

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(
        value: 'QR12345678901',
        area: 300,
        format: 'qr',
      ),
    ]);
    expect(controller.candidateCode, isEmpty);

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(
        value: 'QR12345678901',
        area: 300,
        format: 'qr',
      ),
      const NativeBarcodeCandidate(
        value: 'YT123456789012',
        area: 200,
        format: 'code128',
      ),
    ]);
    expect(controller.candidateCode, 'YT123456789012');
  });
}
