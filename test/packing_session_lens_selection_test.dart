import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/order_info.dart';
import 'package:packing_proof_mobile/models/recording_orientation.dart';
import 'package:packing_proof_mobile/models/recording_spec.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/platform/contracts/camera_platform.dart';
import 'package:packing_proof_mobile/platform/platform_capabilities.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';
import 'package:packing_proof_mobile/services/max_volume_service.dart';
import 'package:packing_proof_mobile/services/order_info_receiver_service.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';
import 'package:packing_proof_mobile/services/speech_prompt_service.dart';
import 'package:packing_proof_mobile/services/video_watermark_service.dart';
import 'package:wakelock_plus_platform_interface/src/method_channel_wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'test_repository.dart';

class _FakeLensCameraPlatform implements CameraPlatform {
  int initializeCalls = 0;
  int stopWorkCalls = 0;
  int disposeCalls = 0;
  int switchToCameraCalls = 0;
  int switchCameraCalls = 0;
  int probeSequenceCalls = 0;
  final List<String> scanStateEvents = <String>[];
  final List<String> recordingLifecycleEvents = <String>[];
  Completer<void>? previewDeactivationBlocker;
  final Completer<void> previewDeactivationStarted = Completer<void>();
  final Set<String> uhdCameraIds = <String>{};
  bool reportPortraitUhdSize = false;
  bool flashAvailable = false;
  bool torchEnabled = false;
  final List<bool> torchRequests = <bool>[];
  String activeCameraId = 'wide';
  String requestedRecordingSpec = 'hd1080p30';

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
    initializeCalls++;
    requestedRecordingSpec = recordingSpec;
    recordingLifecycleEvents.add('initialize');
    return ContinuousCameraInitialization(
      textureId: 1,
      previewWidth: 1920,
      previewHeight: 1080,
      sensorOrientation: 90,
      fps: 30,
      videoMime: 'video/hevc',
      flashAvailable: flashAvailable,
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
    required String trackingNumber,
  }) async {
    recordingLifecycleEvents.add('start');
    return NativeRecordingStart(path: path, startedAt: DateTime.now());
  }

  @override
  Future<NativeRecordingSplit> split(
    String nextPath, {
    required String trackingNumber,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<NativeRecordingStop> stopWork() async {
    stopWorkCalls++;
    recordingLifecycleEvents.add('stop');
    return NativeRecordingStop(
      path: '',
      startedAt: DateTime.now(),
      endedAt: DateTime.now(),
      watermarkDisposition: NativeWatermarkDisposition.postProcessRequired,
    );
  }

  @override
  Future<CameraDiagnosticsSnapshot?> getDiagnostics() async {
    final bool uhdSupported = uhdCameraIds.contains(activeCameraId);
    final bool uhdActive = uhdSupported && requestedRecordingSpec == 'uhd4k30';
    return CameraDiagnosticsSnapshot(
      device: const <String, Object?>{},
      camera: <String, Object?>{
        'cameraId': activeCameraId,
        'videoWidth': uhdActive ? (reportPortraitUhdSize ? 2160 : 3840) : 1920,
        'videoHeight': uhdActive ? (reportPortraitUhdSize ? 3840 : 2160) : 1080,
        'analysisWidth': 960,
        'analysisHeight': 540,
        'videoMime': 'video/hevc',
        'recordingSpec': uhdActive ? 'uhd4k30' : 'hd1080p30',
        'supportedRecordingSpecs': <String>[
          if (uhdSupported) 'uhd4k30',
          'hd1080p30',
          'smooth720p30',
        ],
      },
    );
  }

  @override
  Future<Map<Object?, Object?>?> probeSequence(
    String sequence, {
    required int budgetMs,
  }) async {
    probeSequenceCalls++;
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
  Future<void> setWorkScanEnabled(bool enabled) async {
    scanStateEvents.add('work:$enabled');
    recordingLifecycleEvents.add('work:$enabled');
  }

  @override
  Future<void> setPreviewActive(bool active) async {
    scanStateEvents.add('preview:$active:start');
    if (!active) {
      if (!previewDeactivationStarted.isCompleted) {
        previewDeactivationStarted.complete();
      }
      await previewDeactivationBlocker?.future;
    }
    scanStateEvents.add('preview:$active:end');
  }

  @override
  Future<bool> setTorchEnabled(bool enabled) async {
    torchRequests.add(enabled);
    torchEnabled = enabled;
    return torchEnabled;
  }

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
    activeCameraId = cameraId;
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
  Future<void> dispose() async {
    disposeCalls++;
    recordingLifecycleEvents.add('dispose');
  }
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
  late SessionRepository repository;
  late _FakeLensCameraPlatform camera;
  late PackingSessionController controller;

  setUp(() async {
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    root = await Directory.systemTemp.createTemp('packing-proof-lens-');
    repository = testRepository(root);
    camera = _FakeLensCameraPlatform();
    controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      maxVolumeService: _FakeMaxVolumeSink(),
      orderInfoReceiver: _FakeOrderReceiverSink(),
      videoWatermarkService: _FakeWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.continuousCameraRecording,
      }),
      cameraService: ContinuousCameraService(platform: camera),
      cameraServiceFactory: () => ContinuousCameraService(platform: camera),
    );
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
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

  test('手电筒可以连续开关且不触发语音', () async {
    camera.flashAvailable = true;
    await controller.initialize();

    await controller.toggleTorch();
    expect(controller.torchEnabled, isTrue);
    await controller.toggleTorch();
    expect(controller.torchEnabled, isFalse);
    await controller.toggleTorch();
    expect(controller.torchEnabled, isTrue);
    expect(camera.torchRequests, <bool>[true, false, true]);
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
            PlatformCapability.orderInfoReceiver,
          }),
          cameraService: ContinuousCameraService(platform: camera),
        );
    addTearDown(() async {
      await prioritizedController.shutdown();
      prioritizedController.dispose();
    });

    final Future<void> initialization = prioritizedController.initialize();
    await orderReceiver.initializeStarted.future;

    expect(prioritizedController.phase, PackingSessionPhase.ready);
    expect(prioritizedController.isCameraReady, isTrue);

    orderInitialization.complete();
    await initialization;
  });

  test('平台未声明订单接收能力时不启动后台接收器', () async {
    final _FakeOrderReceiverSink orderReceiver = _FakeOrderReceiverSink();
    final PackingSessionController unsupportedController =
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
    addTearDown(() async {
      await unsupportedController.shutdown();
      unsupportedController.dispose();
    });

    await unsupportedController.initialize();

    expect(orderReceiver.initializeStarted.isCompleted, isFalse);
  });

  test('平台未声明相机能力协商时忽略手动探针', () async {
    await controller.initialize();

    await controller.retryCapabilityProbe();

    expect(camera.probeSequenceCalls, 0);
    expect(controller.phase, PackingSessionPhase.ready);
    expect(controller.showCameraCapabilityCard, isFalse);
  });

  test('iOS 未声明能力探针时仍同步当前镜头的 4K 规格', () async {
    camera.uhdCameraIds.add('wide');
    await controller.initialize();

    expect(controller.availableRecordingSpecs, RecordingSpecPreset.values);
    expect(camera.probeSequenceCalls, 0);
    expect(controller.showCameraCapabilityCard, isFalse);
  });

  test('支持 4K 的当前镜头仅增加选项并保持默认 1080p', () async {
    camera.uhdCameraIds.add('wide');
    final PackingSessionController capableController = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      maxVolumeService: _FakeMaxVolumeSink(),
      orderInfoReceiver: _FakeOrderReceiverSink(),
      videoWatermarkService: _FakeWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.continuousCameraRecording,
        PlatformCapability.cameraCapabilityNegotiation,
      }),
      cameraService: ContinuousCameraService(platform: camera),
      cameraServiceFactory: () => ContinuousCameraService(platform: camera),
    );
    addTearDown(() async {
      await capableController.shutdown();
      capableController.dispose();
    });

    await capableController.initialize();

    expect(
      capableController.availableRecordingSpecs,
      RecordingSpecPreset.values,
    );
    expect(capableController.recordingSpec, RecordingSpecPreset.hd1080p30);
  });

  test('旧设置保存 4K 但当前镜头不支持时初始化回退 1080p', () async {
    await repository.saveRecordingSpec(RecordingSpecPreset.uhd4k30);
    final PackingSessionController capableController = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      maxVolumeService: _FakeMaxVolumeSink(),
      orderInfoReceiver: _FakeOrderReceiverSink(),
      videoWatermarkService: _FakeWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.continuousCameraRecording,
        PlatformCapability.cameraCapabilityNegotiation,
      }),
      cameraService: ContinuousCameraService(platform: camera),
      cameraServiceFactory: () => ContinuousCameraService(platform: camera),
    );
    addTearDown(() async {
      await capableController.shutdown();
      capableController.dispose();
    });

    await capableController.initialize();

    expect(camera.requestedRecordingSpec, 'uhd4k30');
    expect(capableController.recordingSpec, RecordingSpecPreset.hd1080p30);
    expect(
      (await repository.loadSettings()).recordingSpec,
      RecordingSpecPreset.hd1080p30,
    );
  });

  test('iOS 竖屏 4K 尺寸不会被误判为不支持', () async {
    camera.uhdCameraIds.add('wide');
    camera.reportPortraitUhdSize = true;
    await repository.saveRecordingSpec(RecordingSpecPreset.uhd4k30);
    final PackingSessionController capableController = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      maxVolumeService: _FakeMaxVolumeSink(),
      orderInfoReceiver: _FakeOrderReceiverSink(),
      videoWatermarkService: _FakeWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.continuousCameraRecording,
        PlatformCapability.cameraCapabilityNegotiation,
      }),
      cameraService: ContinuousCameraService(platform: camera),
      cameraServiceFactory: () => ContinuousCameraService(platform: camera),
    );
    addTearDown(() async {
      await capableController.shutdown();
      capableController.dispose();
    });

    await capableController.initialize();

    expect(camera.requestedRecordingSpec, 'uhd4k30');
    expect(capableController.recordingSpec, RecordingSpecPreset.uhd4k30);
    expect(
      capableController.availableRecordingSpecs,
      contains(RecordingSpecPreset.uhd4k30),
    );
    expect(
      (await repository.loadSettings()).recordingSpec,
      RecordingSpecPreset.uhd4k30,
    );
  });

  test('4K 设置切到不支持镜头后回退并持久化 1080p', () async {
    camera.uhdCameraIds.add('wide');
    final PackingSessionController capableController = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      maxVolumeService: _FakeMaxVolumeSink(),
      orderInfoReceiver: _FakeOrderReceiverSink(),
      videoWatermarkService: _FakeWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.continuousCameraRecording,
        PlatformCapability.cameraCapabilityNegotiation,
      }),
      cameraService: ContinuousCameraService(platform: camera),
      cameraServiceFactory: () => ContinuousCameraService(platform: camera),
    );
    addTearDown(() async {
      await capableController.shutdown();
      capableController.dispose();
    });
    await capableController.initialize();
    await capableController.setRecordingSpec(RecordingSpecPreset.uhd4k30);

    await capableController.switchToCamera('tele');

    expect(capableController.recordingSpec, RecordingSpecPreset.hd1080p30);
    expect(
      capableController.availableRecordingSpecs,
      isNot(contains(RecordingSpecPreset.uhd4k30)),
    );
    expect(
      (await repository.loadSettings()).recordingSpec,
      RecordingSpecPreset.hd1080p30,
    );
    expect(capableController.cameraNotice, '当前镜头不支持 4K，已切换到 1080p');
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
    expect(camera.probeSequenceCalls, 0);
  });

  test('开始工作不会把用户停留的主摄切走', () async {
    await controller.initialize();

    await controller.startWork();

    expect(controller.isWorking, isTrue);
    expect(controller.activeCameraId, 'wide');
    expect(camera.switchToCameraCalls, 0);
    expect(camera.switchCameraCalls, 0);
  });

  test('工作中切换录像方向会先持久化并结束工作再重建相机', () async {
    await controller.initialize();
    await controller.startWork();
    await controller.setRecordingOrientation(
      RecordingOrientation.landscapeLeft,
    );

    expect(
      (await repository.loadSettings()).recordingOrientation,
      RecordingOrientation.landscapeLeft,
    );
    expect(controller.isWorking, isFalse);
    expect(controller.phase, PackingSessionPhase.ready);
    expect(camera.stopWorkCalls, 0);
    expect(camera.initializeCalls, 2);
    expect(camera.recordingLifecycleEvents, <String>[
      'initialize',
      'work:true',
      'work:false',
      'dispose',
      'initialize',
    ]);
  });

  test('从历史页返回后开始工作会等待预览恢复再开启扫码', () async {
    await controller.initialize();
    camera.previewDeactivationBlocker = Completer<void>();

    final Future<void> deactivation = controller.setPreviewActive(false);
    await camera.previewDeactivationStarted.future;
    bool startCompleted = false;
    final Future<void> starting = controller.startWork().whenComplete(() {
      startCompleted = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(startCompleted, isFalse);
    expect(camera.scanStateEvents, <String>['preview:false:start']);

    camera.previewDeactivationBlocker!.complete();
    await deactivation;
    await starting;

    expect(controller.isWorking, isTrue);
    expect(camera.scanStateEvents, <String>[
      'preview:false:start',
      'preview:false:end',
      'preview:true:start',
      'preview:true:end',
      'work:true',
    ]);
  });
}
