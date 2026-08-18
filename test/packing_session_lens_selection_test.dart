import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/order_info.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/platform/contracts/camera_platform.dart';
import 'package:packing_proof_mobile/platform/platform_capabilities.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';
import 'package:packing_proof_mobile/services/max_volume_service.dart';
import 'package:packing_proof_mobile/services/order_info_receiver_service.dart';
import 'package:packing_proof_mobile/services/speech_prompt_service.dart';
import 'package:packing_proof_mobile/services/video_watermark_service.dart';
import 'package:wakelock_plus_platform_interface/src/method_channel_wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'test_repository.dart';

class _FakeLensCameraPlatform implements CameraPlatform {
  int switchToCameraCalls = 0;
  int switchCameraCalls = 0;

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
      cameraId: 'wide',
    );
  }

  @override
  Future<bool> ensurePermissions({required bool recordAudio}) async => true;

  @override
  Future<NativeRecordingStart> startWork(
    String path, {
    required bool recordAudio,
  }) async {
    return NativeRecordingStart(path: path, startedAt: DateTime.now());
  }

  @override
  Future<NativeRecordingSplit> split(String nextPath) {
    throw UnimplementedError();
  }

  @override
  Future<NativeRecordingStop> stopWork() async {
    return NativeRecordingStop(
      path: '',
      startedAt: DateTime.now(),
      endedAt: DateTime.now(),
    );
  }

  @override
  Future<CameraDiagnosticsSnapshot?> getDiagnostics() async {
    return CameraDiagnosticsSnapshot(
      device: const <String, Object?>{},
      camera: const <String, Object?>{'cameraId': 'wide'},
    );
  }

  @override
  Future<Map<Object?, Object?>?> probeSequence(
    String sequence, {
    required int budgetMs,
  }) async {
    return <Object?, Object?>{
      'sequence': sequence,
      'status': 'ok',
      'phases': <Map<String, Object?>>[],
      'identity': const <String, Object?>{
        'cameraId': 'wide',
        'probeSchemaVersion': 1,
        'cameraPipelineVersion': 1,
      },
    };
  }

  @override
  Future<void> setCapabilityMode(String mode) async {}
  @override
  Future<void> setPairingScanEnabled(bool enabled) async {}
  @override
  Future<void> setWorkScanEnabled(bool enabled) async {}
  @override
  Future<void> setPreviewActive(bool active) async {}
  @override
  Future<bool> setTorchEnabled(bool enabled) async => false;
  @override
  Future<ContinuousCameraInitialization> switchCamera() async {
    switchCameraCalls++;
    return initialize();
  }

  @override
  Future<List<NativeCameraLens>> listCameras() async {
    return const <NativeCameraLens>[
      NativeCameraLens(cameraId: 'ultra', focalLength: 1.5, zoomRatio: 0.5),
      NativeCameraLens(
        cameraId: 'wide',
        focalLength: 2.8,
        zoomRatio: 1.0,
        isMain: true,
      ),
      NativeCameraLens(cameraId: 'tele', focalLength: 7.0, zoomRatio: 2.0),
    ];
  }

  @override
  Future<ContinuousCameraInitialization> switchToCamera(String cameraId) async {
    switchToCameraCalls++;
    return ContinuousCameraInitialization(
      textureId: 1,
      previewWidth: 1920,
      previewHeight: 1080,
      sensorOrientation: 90,
      fps: 30,
      videoMime: 'video/hevc',
      flashAvailable: false,
      lensDirection: 'back',
      canSwitchCamera: false,
      cameraId: cameraId,
    );
  }

  @override
  Future<void> dispose() async {}
}

class _FakeSpeechSink implements SpeechPromptSink {
  @override
  bool get enabled => true;
  @override
  Future<void> setEnabled(bool value) async {}
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
  _FakeOrderReceiverSink({this.initializeBlocker});

  final Completer<void>? initializeBlocker;
  final Completer<void> initializeStarted = Completer<void>();

  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  @override
  OrderInfoReceiverSnapshot get snapshot => const OrderInfoReceiverSnapshot();
  @override
  Stream<OrderInfo> get received => const Stream<OrderInfo>.empty();
  @override
  Future<void> initialize() async {
    if (!initializeStarted.isCompleted) initializeStarted.complete();
    await initializeBlocker?.future;
  }

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
  late _FakeLensCameraPlatform camera;
  late PackingSessionController controller;

  setUp(() async {
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    root = await Directory.systemTemp.createTemp('packing-proof-lens-');
    camera = _FakeLensCameraPlatform();
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

  test('初始化后镜头列表隐藏超广角，只保留 1x 与长焦', () async {
    await controller.initialize();
    expect(controller.phase, PackingSessionPhase.ready);
    expect(
      controller.backCameraLenses.map((NativeCameraLens lens) => lens.cameraId),
      <String>['wide', 'tele'],
    );
    expect(
      controller.backCameraLenses.any(
        (NativeCameraLens lens) => lens.zoomRatio < 1.0,
      ),
      isFalse,
    );
  });

  test('订单接收初始化较慢时摄像头先进入可用状态', () async {
    final Completer<void> orderInitialization = Completer<void>();
    final _FakeOrderReceiverSink orderReceiver = _FakeOrderReceiverSink(
      initializeBlocker: orderInitialization,
    );
    final PackingSessionController prioritizedController =
        PackingSessionController(
          repository: testRepository(root),
          speechService: _FakeSpeechSink(),
          maxVolumeService: _FakeMaxVolumeSink(),
          orderInfoReceiver: orderReceiver,
          videoWatermarkService: _FakeWatermarkSink(),
          capabilities: const PlatformCapabilities(<PlatformCapability>{
            PlatformCapability.continuousCameraRecording,
          }),
          cameraService: ContinuousCameraService(platform: camera),
        );

    final Future<void> initialization = prioritizedController.initialize();
    await orderReceiver.initializeStarted.future;

    expect(prioritizedController.phase, PackingSessionPhase.ready);
    expect(prioritizedController.isCameraReady, isTrue);

    orderInitialization.complete();
    await initialization;
  });

  test('用户切到长焦后开始工作不会切回主摄', () async {
    await controller.initialize();
    await controller.switchToCamera('tele');
    expect(controller.activeCameraId, 'tele');

    await controller.startWork();

    expect(controller.isWorking, isTrue);
    expect(controller.activeCameraId, 'tele');
    // 开始工作应保留用户所选镜头，不触发任何镜头切换。
    expect(camera.switchToCameraCalls, 1);
    expect(camera.switchCameraCalls, 0);
  });

  test('开始工作不会把用户停留的主摄切走', () async {
    await controller.initialize();

    await controller.startWork();

    expect(controller.isWorking, isTrue);
    expect(controller.activeCameraId, 'wide');
    expect(camera.switchToCameraCalls, 0);
    expect(camera.switchCameraCalls, 0);
  });
}
