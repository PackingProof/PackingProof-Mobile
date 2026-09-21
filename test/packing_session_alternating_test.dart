import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/order_info.dart';
import 'package:packing_proof_mobile/models/recording_operation_mode.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/models/work_mode.dart';
import 'package:packing_proof_mobile/platform/contracts/camera_platform.dart';
import 'package:packing_proof_mobile/platform/contracts/backup_platform.dart';
import 'package:packing_proof_mobile/platform/generated/platform_api.g.dart';
import 'package:packing_proof_mobile/platform/platform_capabilities.dart';
import 'package:packing_proof_mobile/services/camera_capability_policy.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';
import 'package:packing_proof_mobile/services/diagnostics_log_service.dart';
import 'package:packing_proof_mobile/services/lan_backup_service.dart';
import 'package:packing_proof_mobile/services/max_volume_service.dart';
import 'package:packing_proof_mobile/services/order_info_receiver_service.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';
import 'package:packing_proof_mobile/services/speech_prompt_service.dart';
import 'package:packing_proof_mobile/services/video_watermark_service.dart';
import 'package:wakelock_plus_platform_interface/src/method_channel_wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'test_repository.dart';

class _FakeCameraPlatform implements CameraPlatform {
  bool fullSupported = false;
  int startWorkCalls = 0;
  int splitCalls = 0;
  int storageLowSplitsRemaining = 0;
  int stopWorkCalls = 0;
  Completer<NativeRecordingStop>? pendingStop;
  String lastMode = 'unverified';
  String? lastPath;
  int diagnosticsCalls = 0;
  Completer<void>? diagnosticsBlocker;
  bool Function()? sharedFileMigrationPaused;
  bool? migrationPausedWhenRecordingStarted;

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
    required String trackingNumber,
  }) async {
    migrationPausedWhenRecordingStarted = sharedFileMigrationPaused?.call();
    startWorkCalls++;
    lastPath = path;
    File(path).createSync(recursive: true);
    return NativeRecordingStart(path: path, startedAt: DateTime.now());
  }

  @override
  Future<NativeRecordingSplit> split(
    String nextPath, {
    required String trackingNumber,
  }) async {
    splitCalls++;
    if (storageLowSplitsRemaining > 0) {
      storageLowSplitsRemaining--;
      throw PlatformException(
        code: 'storage_low',
        message: '存储空间不足 2GB，无法创建下一段录像',
      );
    }
    final String completedPath = lastPath ?? '';
    await File(nextPath).create(recursive: true);
    lastPath = nextPath;
    final DateTime now = DateTime.now();
    return NativeRecordingSplit(
      completedPath: completedPath,
      nextPath: nextPath,
      completedStartedAt: now.subtract(const Duration(seconds: 1)),
      boundaryAt: now,
      watermarkDisposition: NativeWatermarkDisposition.completed,
    );
  }

  @override
  Future<NativeRecordingStop> stopWork() async {
    stopWorkCalls++;
    final Completer<NativeRecordingStop>? pending = pendingStop;
    if (pending != null) return pending.future;
    return NativeRecordingStop(
      path: lastPath ?? '',
      startedAt: DateTime.now(),
      endedAt: DateTime.now(),
      watermarkDisposition: NativeWatermarkDisposition.completed,
    );
  }

  @override
  Future<CameraDiagnosticsSnapshot?> getDiagnostics() async {
    diagnosticsCalls++;
    final Completer<void>? blocker = diagnosticsBlocker;
    diagnosticsBlocker = null;
    await blocker?.future;
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
    if (sequence == 'alternating' || fullSupported) {
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

class _TrackingSessionRepository extends SessionRepository {
  _TrackingSessionRepository({required super.rootDirectory});

  bool migrationPaused = true;
  final Map<String, Completer<bool>> pendingDuplicateLookups =
      <String, Completer<bool>>{};
  final Map<String, Object> duplicateLookupErrors = <String, Object>{};
  final List<String> duplicateLookupCalls = <String>[];

  @override
  Future<bool> hasRecentTrackingNumber(String trackingNumber) async {
    duplicateLookupCalls.add(trackingNumber);
    final Object? error = duplicateLookupErrors[trackingNumber];
    if (error != null) throw error;
    final Completer<bool>? pending = pendingDuplicateLookups[trackingNumber];
    if (pending != null) return pending.future;
    return false;
  }

  @override
  Future<void> pauseSharedFileMigration() async {
    migrationPaused = true;
    await super.pauseSharedFileMigration();
  }

  @override
  Future<void> resumeSharedFileMigration() async {
    migrationPaused = false;
    await super.resumeSharedFileMigration();
  }
}

class _TrackingDiagnosticsLogService extends DiagnosticsLogService {
  _TrackingDiagnosticsLogService({required Directory root})
    : super(
        rootProvider: () async => root,
        runtimeMetadataLoader: () async => const <String, Object?>{},
      );

  final List<String> kinds = <String>[];
  final List<({String kind, Map<String, Object?> extra})> events =
      <({String kind, Map<String, Object?> extra})>[];

  @override
  Future<void> log({
    required String kind,
    Map<String, Object?> extra = const <String, Object?>{},
  }) async {
    kinds.add(kind);
    events.add((kind: kind, extra: Map<String, Object?>.from(extra)));
  }
}

class _FakeBackupPlatform implements BackupNativePlatform {
  int storageCheckCalls = 0;
  Completer<Map<Object?, Object?>?>? pendingStorageCheck;
  final List<Map<Object?, Object?>> reclaimResults = <Map<Object?, Object?>>[];

  @override
  Future<int?> availableRecordingStorageBytes() async => 1 << 50;
  final BackupSummaryDto backupSummary = BackupSummaryDto(
    schemaVersion: 1,
    revision: 0,
    completedRevision: 0,
    cleanupHighWatermark: 0,
    deviceId: 'test-device',
    deviceName: '测试设备',
    totalCount: 0,
    pendingCount: 0,
    uploadingCount: 0,
    pausedCount: 0,
    completedCount: 0,
    failedCount: 0,
    waitingCleanupCount: 0,
    localDeletedCount: 0,
    unfinishedUploadedBytes: 0,
    unfinishedTotalBytes: 0,
  );

  @override
  void setSummaryListener(void Function(BackupSummaryDto summary)? listener) {}

  @override
  Future<BackupSummaryDto> summary() async => backupSummary;

  @override
  Future<BackupSummaryDto> initialize(Map<Object?, Object?> request) async =>
      backupSummary;

  @override
  Future<void> setAutoEnabled(bool enabled) async {}

  @override
  Future<BackupJobsByPathsDto> jobsForPaths(List<String> paths) async =>
      BackupJobsByPathsDto(
        revision: backupSummary.revision,
        jobs: <BackupJobDto>[],
        missingPaths: paths,
      );

  @override
  Future<BackupCleanupPageDto> cleanupEvents({
    required int afterRevision,
    required int limit,
  }) async => BackupCleanupPageDto(
    latestRevision: afterRevision,
    nextAfterRevision: afterRevision,
    hasMore: false,
    events: <BackupCleanupEventDto>[],
  );

  @override
  Future<void> acknowledgeCleanupEvents(int throughRevision) async {}

  @override
  Future<bool> hasPendingJobsOutsideDestination(String computerId) async =>
      false;

  @override
  Future<String?> loadAccessKey() async => null;

  @override
  Future<bool> isWifiConnected() async => true;

  @override
  Future<void> saveConnection(Map<Object?, Object?> connection) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> enqueueJob(Map<Object?, Object?> request) async {}

  @override
  Future<void> enqueueJobs(List<Map<Object?, Object?>> requests) async {}

  @override
  Future<void> requeueJob(String jobId) async {}

  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<void> updateRetentionSchedule(Map<Object?, Object?> request) async {}

  @override
  Future<Map<Object?, Object?>?> reclaimStorageIfNeeded() async {
    storageCheckCalls++;
    if (reclaimResults.isNotEmpty) return reclaimResults.removeAt(0);
    final Completer<Map<Object?, Object?>?>? pending = pendingStorageCheck;
    if (pending != null) return pending.future;
    return <Object?, Object?>{
      'availableBytes': 4 * 1024 * 1024 * 1024,
      'availableBytesBefore': 4 * 1024 * 1024 * 1024,
      'freedBytes': 0,
      'deletedCount': 0,
      'warning': false,
      'insufficient': false,
    };
  }

  @override
  Future<Map<Object?, Object?>?> getNetworkDiagnostics() async => null;

  @override
  Future<void> dispose() async {}
}

class _FakeSpeechSink implements SpeechPromptSink {
  bool _enabled = true;
  final List<SpeechPrompt> prompts = <SpeechPrompt>[];

  @override
  bool get enabled => _enabled;
  @override
  Future<void> setEnabled(bool value) async => _enabled = value;
  @override
  void enqueue(SpeechPrompt prompt, {String? incidentKey}) {
    prompts.add(prompt);
  }

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
  final Map<String, Completer<OrderInfo?>> pendingLookups =
      <String, Completer<OrderInfo?>>{};
  final Map<String, OrderInfo?> lookupResults = <String, OrderInfo?>{};
  final Map<String, Object> lookupErrors = <String, Object>{};
  final List<String> lookupCalls = <String>[];

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
  Future<OrderInfo?> lookup(String trackingNumber) async {
    lookupCalls.add(trackingNumber);
    final Object? error = lookupErrors[trackingNumber];
    if (error != null) throw error;
    final Completer<OrderInfo?>? pending = pendingLookups[trackingNumber];
    if (pending != null) return pending.future;
    return lookupResults[trackingNumber];
  }

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
  late _FakeBackupPlatform backupPlatform;
  late _TrackingSessionRepository repository;
  late _FakeOrderReceiverSink orderReceiver;
  late _FakeSpeechSink speech;
  late _TrackingDiagnosticsLogService runtimeLog;
  late PackingSessionController controller;

  setUp(() async {
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    root = await Directory.systemTemp.createTemp('packing-proof-alternating-');
    camera = _FakeCameraPlatform();
    backupPlatform = _FakeBackupPlatform();
    repository = _TrackingSessionRepository(rootDirectory: root);
    camera.sharedFileMigrationPaused = () => repository.migrationPaused;
    orderReceiver = _FakeOrderReceiverSink();
    speech = _FakeSpeechSink();
    runtimeLog = _TrackingDiagnosticsLogService(root: root);
    controller = PackingSessionController(
      repository: repository,
      speechService: speech,
      maxVolumeService: _FakeMaxVolumeSink(),
      lanBackupService: LanBackupService(platform: backupPlatform),
      orderInfoReceiver: orderReceiver,
      videoWatermarkService: _FakeWatermarkSink(),
      runtimeLog: runtimeLog,
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.continuousCameraRecording,
        PlatformCapability.cameraCapabilityNegotiation,
      }),
      cameraService: ContinuousCameraService(platform: camera),
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
        PlatformCapability.cameraCapabilityNegotiation,
      }),
      cameraService: ContinuousCameraService(platform: camera),
    );
    addTearDown(() async {
      await second.shutdown();
      second.dispose();
    });
    await second.initialize();
    expect(second.capabilityMode, CameraCapabilityMode.alternating);
    expect(second.capabilityProbedAtMs, firstProbedAtMs);
  });

  test('诊断采样禁止重入且只补跑最新触发', () async {
    await controller.initialize();
    camera.diagnosticsCalls = 0;
    final Completer<void> blocker = Completer<void>();
    camera.diagnosticsBlocker = blocker;

    final Future<void> first = controller.captureCameraDiagnosticsForTesting(
      'first',
    );
    await Future<void>.delayed(Duration.zero);
    await controller.captureCameraDiagnosticsForTesting('stale');
    await controller.captureCameraDiagnosticsForTesting('latest');

    expect(camera.diagnosticsCalls, 1);
    blocker.complete();
    await first;
    expect(camera.diagnosticsCalls, 2);
  });

  test('关闭期间不补跑等待中的诊断采样', () async {
    await controller.initialize();
    camera.diagnosticsCalls = 0;
    final Completer<void> blocker = Completer<void>();
    camera.diagnosticsBlocker = blocker;

    final Future<void> first = controller.captureCameraDiagnosticsForTesting(
      'first',
    );
    await Future<void>.delayed(Duration.zero);
    await controller.captureCameraDiagnosticsForTesting('pending');
    final Future<void> shutdown = controller.shutdown();
    blocker.complete();

    await first;
    await shutdown;
    expect(camera.diagnosticsCalls, 1);
  });

  test('开始工作前空间不够会继续回收到够用再开录', () async {
    backupPlatform.reclaimResults.addAll(<Map<Object?, Object?>>[
      <Object?, Object?>{
        'availableBytes': 1 << 30,
        'availableBytesBefore': 1 << 30,
        'freedBytes': 8 << 20,
        'deletedCount': 3,
        'warning': true,
        'insufficient': true,
      },
      <Object?, Object?>{
        'availableBytes': 4 << 30,
        'availableBytesBefore': 1 << 30,
        'freedBytes': 3 << 30,
        'deletedCount': 5,
        'warning': false,
        'insufficient': false,
      },
    ]);

    await controller.initialize();
    await controller.startWork();

    expect(backupPlatform.storageCheckCalls, 2);
    expect(controller.isWorking, isTrue);
    expect(controller.errorMessage, isNull);
    expect(
      runtimeLog.events
          .lastWhere((event) => event.kind == 'start_work_stage_timing')
          .extra['outcome'],
      'success',
    );
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
    // 二维码在工作识别中完全静默：不弹提示、不出声，只留诊断日志。
    expect(
      runtimeLog.events.where((event) => event.kind == 'barcode_rejected'),
      isEmpty,
      reason: '静默码制不得产生任何用户提示',
    );
    final ({String kind, Map<String, Object?> extra}) silentEvent = runtimeLog
        .events
        .singleWhere((event) => event.kind == 'barcode_silent');
    expect(silentEvent.extra, <String, Object?>{
      'code': 'QR12345678901',
      'format': 'qr',
      'reason': 'unsupportedFormat',
      'count': 1,
      'frames': 1,
    });
    expect(controller.rejectedBarcodeMessage, isNull);

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

  test('二维码停留画面时静默日志按码节流并累计帧数', () async {
    await controller.initialize();
    await controller.startWork();

    // 面单二维码会一直停在画面里等条形码：逐帧写盘会在十几秒内挤掉整个诊断环。
    for (int i = 0; i < 30; i++) {
      controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
        const NativeBarcodeCandidate(
          value: 'QR12345678901',
          area: 300,
          format: 'qr',
        ),
      ]);
    }
    expect(
      runtimeLog.events.where((event) => event.kind == 'barcode_silent'),
      hasLength(1),
      reason: '同一个二维码 3 秒内只写一条诊断',
    );

    // 换成另一个静默码立即写盘，并把节流掉的帧数一起带出去。
    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(
        value: '6901234567890',
        area: 300,
        format: 'ean13',
      ),
    ]);
    final List<({String kind, Map<String, Object?> extra})> silentEvents =
        runtimeLog.events
            .where((event) => event.kind == 'barcode_silent')
            .toList();
    expect(silentEvents, hasLength(2));
    expect(silentEvents.last.extra['code'], '6901234567890');
    expect(silentEvents.last.extra['format'], 'ean13');
    // 首帧写了 1 条，其余 29 帧被节流，加上本帧共 30。
    expect(silentEvents.last.extra['frames'], 30);
  });

  test('配对时同帧有面单条码也优先试电脑二维码', () async {
    await controller.initialize();
    controller.beginComputerPairing();

    // 运单码排在前面时，只试第一个候选会让这一帧被运单码占住。
    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(
        value: 'YT123456789012',
        area: 5000,
        format: 'code128',
      ),
      const NativeBarcodeCandidate(
        value: 'http://192.168.1.20:5280/pair?token=abc',
        area: 100,
        format: 'qr',
      ),
    ]);

    expect(controller.pairingMessage, '已识别电脑二维码，正在连接…');
    controller.cancelComputerPairing();
    await Future<void>.delayed(Duration.zero);
  });

  test('同帧二维码排在指令码前面时指令码仍然生效', () async {
    await controller.initialize();

    // 指令码贴在面单旁边很常见：只看第一个候选会让二维码挡住指令码。
    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(
        value: 'https://example.com/label',
        area: 5000,
        format: 'qr',
      ),
      const NativeBarcodeCandidate(value: 'BACK', area: 100, format: 'code128'),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(controller.operationMode, RecordingOperationMode.returnGoods);
  });

  test('京东同帧裸号面积更大时仍选对应多包裹号', () async {
    await controller.initialize();
    await controller.startWork();
    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(
        value: 'JD123456789012',
        area: 300,
        format: 'code128',
      ),
      const NativeBarcodeCandidate(
        value: 'JD123456789012-1-2-',
        area: 200,
        format: 'code128',
      ),
    ]);
    expect(controller.candidateCode, 'JD123456789012-1-2-');
  });

  test('开始工作后接受顺丰 Code39 面单码', () async {
    await controller.initialize();
    await controller.startWork();

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(
        value: 'SF6048285539252',
        area: 200,
        format: 'code39',
      ),
    ]);

    expect(controller.candidateCode, 'SF6048285539252');
    expect(controller.rejectedBarcodeMessage, isNull);
  });

  testWidgets('同码停录在最后一帧补全包裹号且只保存一个视频', (WidgetTester tester) async {
    camera.fullSupported = true;
    try {
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.retryCapabilityProbe();
        await controller.setWorkMode(WorkMode.sameCodeStop);
        await controller.startWork();
      });
      await _confirmBarcode(tester, controller, 'JD123456789012');
      await _waitUntil(
        tester,
        () => camera.startWorkCalls == 1 && controller.isRecording,
      );
      // Both aliases remain the same visible label, so this must not stop it.
      await _confirmBarcode(tester, controller, 'JD123456789012-1-2-');
      expect(camera.stopWorkCalls, 0);
      controller.handleNativeBarcodeFrameForTesting([]);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3100)),
      );
      await _confirmBarcode(tester, controller, 'JD123456789012-1-2-');
      await _waitUntil(tester, () => controller.sessions.isNotEmpty);
      expect(controller.sessions.single.displayCode, 'JD123456789012-1-2-');
      expect(camera.splitCalls, 0);
      expect(camera.stopWorkCalls, 1);
    } finally {
      await _stopWorkIfNeeded(tester, controller);
      await tester.pump(const Duration(seconds: 4));
    }
  });

  testWidgets('原生录像开始前已暂停旧共享文件迁移', (WidgetTester tester) async {
    camera.fullSupported = true;
    try {
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.retryCapabilityProbe();
        expect(repository.migrationPaused, isFalse);
        await controller.startWork();
      });
      expect(repository.migrationPaused, isTrue);

      await _confirmBarcode(tester, controller, 'YT123456789019');
      await _waitUntil(
        tester,
        () => camera.startWorkCalls == 1,
        reason: 'native recording should start after barcode confirmation',
      );

      expect(camera.migrationPausedWhenRecordingStarted, isTrue);
    } finally {
      await _stopWorkIfNeeded(tester, controller);
      await tester.pump(const Duration(seconds: 4));
    }
  });

  testWidgets('工作期间空间不足会继续回收而不是马上停录', (WidgetTester tester) async {
    camera.fullSupported = true;
    try {
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.retryCapabilityProbe();
        await controller.startWork();
      });
      await _confirmBarcode(tester, controller, 'YT123456789011');
      await _waitUntil(
        tester,
        () => controller.currentCode == 'YT123456789011',
        reason: 'first barcode should start the native recording',
      );
      // 巡检第一轮只清掉一部分空间：应当继续清理，而不是立刻停止录像。
      backupPlatform.reclaimResults.addAll(<Map<Object?, Object?>>[
        <Object?, Object?>{
          'availableBytes': 1 << 30,
          'availableBytesBefore': 1 << 30,
          'freedBytes': 700 << 20,
          'deletedCount': 12,
          'warning': true,
          'insufficient': true,
        },
        <Object?, Object?>{
          'availableBytes': 4 << 30,
          'availableBytesBefore': 1 << 30,
          'freedBytes': 3 << 30,
          'deletedCount': 6,
          'warning': false,
          'insufficient': false,
        },
      ]);

      await tester.runAsync(controller.checkStorageWhileWorkingForTesting);

      expect(controller.isWorking, isTrue);
      expect(camera.stopWorkCalls, 0);
    } finally {
      await _stopWorkIfNeeded(tester, controller);
      await tester.pump(const Duration(seconds: 4));
    }
  });

  test('清理确实没有进展时才按策略停止录像', () async {
    await controller.initialize();
    await controller.retryCapabilityProbe();
    await controller.startWork();
    backupPlatform.reclaimResults.addAll(<Map<Object?, Object?>>[
      <Object?, Object?>{
        'availableBytes': 1 << 30,
        'availableBytesBefore': 1 << 30,
        'freedBytes': 0,
        'deletedCount': 0,
        'warning': true,
        'insufficient': true,
      },
    ]);

    await controller.checkStorageWhileWorkingForTesting();
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
    while (controller.isWorking && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(controller.isWorking, isFalse);
  });

  testWidgets('切段遇到空间不足会先回收再重试，不中断当前录像', (WidgetTester tester) async {
    camera.fullSupported = true;
    try {
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.retryCapabilityProbe();
        await controller.startWork();
      });
      await _confirmBarcode(tester, controller, 'YT123456789011');
      await _waitUntil(
        tester,
        () => controller.currentCode == 'YT123456789011',
        reason: 'first barcode should start the native recording',
      );

      // 下一次切段先被空间拦住：回收出空间后应当自动重试成功，而不是停掉录像。
      camera.storageLowSplitsRemaining = 1;
      backupPlatform.reclaimResults.add(<Object?, Object?>{
        'availableBytes': 4 << 30,
        'availableBytesBefore': 1 << 30,
        'freedBytes': 3 << 30,
        'deletedCount': 4,
        'warning': false,
        'insufficient': false,
      });

      await _confirmBarcode(tester, controller, 'YT123456789012');
      await _waitUntil(
        tester,
        () => camera.splitCalls == 2,
        reason: '回收空间后必须重试原生切段',
      );

      expect(controller.isWorking, isTrue);
      expect(controller.errorMessage, isNull);
    } finally {
      await _stopWorkIfNeeded(tester, controller);
      await tester.pump(const Duration(seconds: 4));
    }
  });

  testWidgets('切换条码不等待慢速存储回收', (WidgetTester tester) async {
    camera.fullSupported = true;
    try {
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.retryCapabilityProbe();
        await controller.startWork();
      });
      await _confirmBarcode(tester, controller, 'YT123456789011');
      await _waitUntil(
        tester,
        () => controller.currentCode == 'YT123456789011',
        reason: 'first barcode should start the native recording',
      );
      final int checksBeforeSplit = backupPlatform.storageCheckCalls;
      backupPlatform.pendingStorageCheck = Completer<Map<Object?, Object?>?>();

      await _confirmBarcode(tester, controller, 'YT123456789012');
      await _waitUntil(
        tester,
        () => camera.splitCalls == 1,
        reason: 'native split must not await storage reclaim',
      );

      expect(backupPlatform.storageCheckCalls, checksBeforeSplit);
    } finally {
      backupPlatform.pendingStorageCheck = null;
      await _stopWorkIfNeeded(tester, controller);
      await tester.pump(const Duration(seconds: 4));
    }
  });

  testWidgets('开始工作与原生切段只记录无业务标识的聚合阶段耗时', (WidgetTester tester) async {
    camera.fullSupported = true;
    try {
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.retryCapabilityProbe();
        await controller.startWork();
      });

      final Map<String, Object?> startWorkTiming = runtimeLog.events
          .lastWhere((event) => event.kind == 'start_work_stage_timing')
          .extra;
      expect(startWorkTiming['outcome'], 'success');
      expect(startWorkTiming['totalMs'], isA<int>());
      expect(
        (startWorkTiming['stagesMs']! as Map).keys,
        containsAll(<String>[
          'storageReclaim',
          'maxVolumeBegin',
          'maxVolumeBoost',
          'wakelock',
          'preview',
          'workScan',
          'orderReceiver',
        ]),
      );

      await _confirmBarcode(tester, controller, 'YT123456789071');
      await _waitUntil(
        tester,
        () => controller.currentCode == 'YT123456789071',
        reason: 'first barcode should emit native start timing',
      );
      await _confirmBarcode(tester, controller, 'YT123456789072');
      await _waitUntil(
        tester,
        () => controller.sessions.isNotEmpty,
        reason: 'second barcode should emit native split timing',
      );

      final List<Map<String, Object?>> nativeTimings = runtimeLog.events
          .where((event) => event.kind == 'native_recording_timing')
          .map((event) => event.extra)
          .toList(growable: false);
      expect(
        nativeTimings.map((timing) => timing['operation']),
        containsAll(<String>['start', 'split']),
      );
      final Map<String, Object?> splitTiming = nativeTimings.lastWhere(
        (timing) => timing['operation'] == 'split',
      );
      expect(splitTiming['outcome'], 'success');
      expect(
        (splitTiming['stagesMs']! as Map).keys,
        containsAll(<String>[
          'recordingPath',
          'nativeSplit',
          'finalizeVideo',
          'persistSession',
        ]),
      );

      for (final event in <Map<String, Object?>>[
        startWorkTiming,
        ...nativeTimings,
      ]) {
        final String encoded = event.toString().toLowerCase();
        expect(encoded, isNot(contains('trackingnumber')));
        expect(encoded, isNot(contains('filepath')));
        expect(encoded, isNot(contains('.mp4')));
        expect(encoded, isNot(contains(root.path.toLowerCase())));
        expect(encoded, isNot(contains('yt12345678907')));
      }
    } finally {
      await _stopWorkIfNeeded(tester, controller);
      await tester.pump(const Duration(seconds: 4));
    }
  });

  testWidgets('原生切段不等待重复单号和订单查询', (WidgetTester tester) async {
    camera.fullSupported = true;
    const String firstCode = 'YT123456789031';
    const String nextCode = 'YT123456789032';
    final Completer<bool> duplicateLookup = Completer<bool>();
    final Completer<OrderInfo?> orderLookup = Completer<OrderInfo?>();
    try {
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.retryCapabilityProbe();
        await controller.startWork();
      });
      await _confirmBarcode(tester, controller, firstCode);
      await _waitUntil(
        tester,
        () => controller.currentCode == firstCode,
        reason: 'first barcode should start the native recording',
      );
      final int recordingStartedBeforeSplit = speech.prompts
          .where(
            (SpeechPrompt prompt) => prompt == SpeechPrompt.recordingStarted,
          )
          .length;
      repository.pendingDuplicateLookups[nextCode] = duplicateLookup;
      orderReceiver.pendingLookups[nextCode] = orderLookup;

      await _confirmBarcode(tester, controller, nextCode);
      await _waitUntil(
        tester,
        () =>
            camera.splitCalls == 1 &&
            controller.currentCode == nextCode &&
            controller.sessions.isNotEmpty,
        reason:
            'native split, marker feedback and old segment persistence must finish while both lookups are pending',
      );

      expect(repository.duplicateLookupCalls, contains(nextCode));
      expect(orderReceiver.lookupCalls, contains(nextCode));
      expect(duplicateLookup.isCompleted, isFalse);
      expect(orderLookup.isCompleted, isFalse);
      expect(controller.currentCode, nextCode);
      expect(
        speech.prompts
            .where(
              (SpeechPrompt prompt) => prompt == SpeechPrompt.recordingStarted,
            )
            .length,
        recordingStartedBeforeSplit + 1,
      );

      duplicateLookup.complete(false);
      orderLookup.complete(null);
      await tester.pump();
    } finally {
      if (!duplicateLookup.isCompleted) duplicateLookup.complete(false);
      if (!orderLookup.isCompleted) orderLookup.complete(null);
      await _stopWorkIfNeeded(tester, controller);
      await tester.pump(const Duration(seconds: 4));
    }
  });

  testWidgets('原生切段辅助查询异常独立降级并记录', (WidgetTester tester) async {
    camera.fullSupported = true;
    const String firstCode = 'YT123456789041';
    const String nextCode = 'YT123456789042';
    try {
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.retryCapabilityProbe();
        await controller.startWork();
      });
      await _confirmBarcode(tester, controller, firstCode);
      await _waitUntil(
        tester,
        () => controller.currentCode == firstCode,
        reason: 'first barcode should start the native recording',
      );
      repository.duplicateLookupErrors[nextCode] = StateError(
        'duplicate lookup failed',
      );
      orderReceiver.lookupErrors[nextCode] = StateError('order lookup failed');

      await _confirmBarcode(tester, controller, nextCode);
      await _waitUntil(
        tester,
        () => controller.sessions.isNotEmpty,
        reason: 'successful native split must survive auxiliary lookup errors',
      );
      expect(repository.duplicateLookupCalls, contains(nextCode));
      expect(orderReceiver.lookupCalls, contains(nextCode));
      await tester.pump();
      expect(runtimeLog.kinds, contains('barcode_duplicate_lookup_failed'));
      expect(runtimeLog.kinds, contains('barcode_order_lookup_failed'));

      expect(camera.splitCalls, 1);
      expect(controller.currentCode, nextCode);
      expect(controller.errorMessage, isNull);
      expect(speech.prompts, isNot(contains(SpeechPrompt.segmentSaveFailed)));
    } finally {
      await _stopWorkIfNeeded(tester, controller);
      await tester.pump(const Duration(seconds: 4));
    }
  });

  testWidgets('原生切段用旧订单快照保存旧片段并绑定新订单', (WidgetTester tester) async {
    camera.fullSupported = true;
    const String firstCode = 'YT123456789051';
    const String nextCode = 'YT123456789052';
    const OrderInfo oldOrder = OrderInfo(
      trackingNumber: firstCode,
      orderId: 'ORDER-OLD',
    );
    const OrderInfo newOrder = OrderInfo(
      trackingNumber: nextCode,
      orderId: 'ORDER-NEW',
    );
    final Completer<OrderInfo?> orderLookup = Completer<OrderInfo?>();
    orderReceiver.lookupResults[firstCode] = oldOrder;
    try {
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.retryCapabilityProbe();
        await controller.startWork();
      });
      await _confirmBarcode(tester, controller, firstCode);
      await _waitUntil(
        tester,
        () => controller.activeOrderInfo?.orderId == oldOrder.orderId,
        reason: 'first segment should bind its order before the split',
      );
      orderReceiver.pendingLookups[nextCode] = orderLookup;

      await _confirmBarcode(tester, controller, nextCode);
      await _waitUntil(
        tester,
        () => camera.splitCalls == 1 && controller.sessions.isNotEmpty,
        reason:
            'native split and old segment persistence should finish before the next order lookup',
      );
      expect(controller.activeOrderInfo, isNull);

      orderLookup.complete(newOrder);
      await _waitUntil(
        tester,
        () =>
            controller.activeOrderInfo?.orderId == newOrder.orderId &&
            controller.sessions.isNotEmpty,
        reason: 'new order should bind after the old segment is persisted',
      );
      final RecordingSession completed = controller.sessions.singleWhere(
        (RecordingSession session) =>
            session.markers.isNotEmpty &&
            session.markers.first.code == firstCode,
      );

      expect(completed.orderInfo?.orderId, oldOrder.orderId);
      expect(controller.activeOrderInfo?.orderId, newOrder.orderId);
    } finally {
      if (!orderLookup.isCompleted) orderLookup.complete(newOrder);
      await _stopWorkIfNeeded(tester, controller);
      await tester.pump(const Duration(seconds: 4));
    }
  });

  testWidgets('结束工作后迟到订单结果不覆盖当前活动订单', (WidgetTester tester) async {
    camera.fullSupported = true;
    const String firstCode = 'YT123456789061';
    const String nextCode = 'YT123456789062';
    final Completer<OrderInfo?> orderLookup = Completer<OrderInfo?>();
    try {
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.retryCapabilityProbe();
        await controller.startWork();
      });
      await _confirmBarcode(tester, controller, firstCode);
      await _waitUntil(
        tester,
        () => controller.currentCode == firstCode,
        reason: 'first barcode should start the native recording',
      );
      orderReceiver.pendingLookups[nextCode] = orderLookup;

      await _confirmBarcode(tester, controller, nextCode);
      await _waitUntil(
        tester,
        () =>
            camera.splitCalls == 1 &&
            controller.currentCode == nextCode &&
            controller.sessions.isNotEmpty,
        reason:
            'next writer and old segment persistence should finish before the order lookup',
      );

      controller.resetRecordingTimelineForTesting();
      expect(controller.currentCode, isEmpty);
      expect(controller.activeOrderInfo, isNull);

      orderLookup.complete(
        const OrderInfo(trackingNumber: nextCode, orderId: 'LATE-ORDER'),
      );
      await tester.pump();

      expect(controller.currentCode, isEmpty);
      expect(controller.activeOrderInfo, isNull);
    } finally {
      if (!orderLookup.isCompleted) orderLookup.complete(null);
      await _stopWorkIfNeeded(tester, controller);
      await tester.pump(const Duration(seconds: 4));
    }
  });

  testWidgets('原生存储严重告警只停录一次且关闭不等待挂起任务', (WidgetTester tester) async {
    camera.fullSupported = true;
    await tester.runAsync(() async {
      await controller.initialize();
      await controller.retryCapabilityProbe();
      await controller.startWork();
    });
    await _confirmBarcode(tester, controller, 'YT123456789021');
    await _waitUntil(
      tester,
      () => controller.currentCode == 'YT123456789021',
      reason: 'recording should start before storage critical',
    );
    backupPlatform.pendingStorageCheck = Completer<Map<Object?, Object?>?>();
    camera.pendingStop = Completer<NativeRecordingStop>();
    final int checksBeforeCritical = backupPlatform.storageCheckCalls;

    camera.onStorageCritical!.call();
    camera.onStorageCritical!.call();
    await _waitUntil(
      tester,
      () => camera.stopWorkCalls == 1,
      reason: 'duplicate native callbacks must share one stop operation',
    );

    final Stopwatch shutdownTime = Stopwatch()..start();
    try {
      await tester.runAsync(
        () => controller.shutdown().timeout(const Duration(seconds: 3)),
      );
      shutdownTime.stop();

      expect(camera.stopWorkCalls, 1);
      expect(backupPlatform.storageCheckCalls - checksBeforeCritical, 1);
      expect(shutdownTime.elapsed, lessThan(const Duration(seconds: 3)));
    } finally {
      if (!camera.pendingStop!.isCompleted) {
        camera.pendingStop!.complete(
          NativeRecordingStop(
            path: camera.lastPath ?? '',
            startedAt: DateTime.now(),
            endedAt: DateTime.now(),
            watermarkDisposition: NativeWatermarkDisposition.completed,
          ),
        );
      }
      if (!backupPlatform.pendingStorageCheck!.isCompleted) {
        backupPlatform.pendingStorageCheck!.complete(<Object?, Object?>{
          'availableBytes': 4 * 1024 * 1024 * 1024,
          'availableBytesBefore': 4 * 1024 * 1024 * 1024,
          'freedBytes': 0,
          'deletedCount': 0,
          'warning': false,
          'insufficient': false,
        });
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
  });
}

Future<void> _confirmBarcode(
  WidgetTester tester,
  PackingSessionController controller,
  String value,
) async {
  final List<NativeBarcodeCandidate> candidates = <NativeBarcodeCandidate>[
    NativeBarcodeCandidate(value: value, area: 200, format: 'code128'),
  ];
  controller.handleNativeBarcodeFrameForTesting(candidates);
  controller.handleNativeBarcodeFrameForTesting(candidates);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
  String? reason,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: reason);
}

Future<void> _stopWorkIfNeeded(
  WidgetTester tester,
  PackingSessionController controller,
) async {
  if (!controller.isWorking) return;
  bool completed = false;
  final Future<Object?> stopped = controller.stopWork().whenComplete(() {
    completed = true;
  });
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!completed && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(completed, isTrue, reason: 'test cleanup should stop recording');
  await stopped;
}
