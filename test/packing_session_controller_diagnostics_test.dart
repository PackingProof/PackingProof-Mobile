import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:packing_proof_mobile/app/app_build_config.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/app_settings.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/models/recording_operation_mode.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/services/camera_diagnostics_service.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';
import 'package:packing_proof_mobile/services/diagnostics_log_service.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';
import 'package:packing_proof_mobile/services/speech_prompt_service.dart';
import 'package:packing_proof_mobile/services/video_watermark_service.dart';
import 'package:packing_proof_mobile/platform/platform_capabilities.dart';

import 'test_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'packing-proof-controller-diag-',
    );
  });

  tearDown(() async {
    if (!await root.exists()) {
      return;
    }
    // Windows 上日志/诊断服务可能仍有文件句柄未释放，删除临时目录会偶发
    // “目录不是空的”；重试几次避免打包脚本里的全量测试被误判失败。
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        await root.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  });

  test('初始化失败记录 init_failed 诊断事件', () async {
    final PackingSessionController controller = PackingSessionController(
      repository: testRepository(root),
      speechService: _FakeSpeechSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    await controller.initialize();

    expect(controller.phase, PackingSessionPhase.error);
    final File file = File('${root.path}/diagnostics/camera.jsonl');
    final String content = await _waitForInitFailed(file);
    expect(content, contains('"kind":"init_failed"'));
    expect(content, contains('"code":"unknown"'));
  });

  test('水印失败保留原片并记录结构化诊断', () async {
    final File source = File('${root.path}/original.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final DateTime startedAt = DateTime(2026, 8, 21, 10);
    final RecordingSession session = RecordingSession(
      id: 'session-watermark-failed',
      filePath: source.path,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 5)),
      markers: const <Never>[],
    );
    final PackingSessionController controller = PackingSessionController(
      repository: testRepository(root),
      speechService: _FakeSpeechSink(),
      videoWatermarkService: _FailingWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    await controller.watermarkAndBackupForTesting(source.path, session);

    expect(await source.exists(), isTrue);
    final File log = File('${root.path}/diagnostics/runtime.jsonl');
    final String content = await _waitForRuntimeKind(log, 'watermark_failed');
    expect(content, contains('"sessionId":"session-watermark-failed"'));
    expect(content, contains('"errorType":"StateError"'));
    expect(content, contains('watermark test failure'));
  });

  test('备份触发原因决定是否强制重启上传', () {
    expect(lanBackupForceRestartForReason('manual'), isTrue);
    expect(lanBackupForceRestartForReason('app_start'), isFalse);
    expect(lanBackupForceRestartForReason('auto_toggle_enabled'), isFalse);
    expect(lanBackupForceRestartForReason('connection_restored'), isFalse);
    expect(lanBackupForceRestartForReason('pairing_completed'), isFalse);
  });

  test('首次启动记录带版本的 app_start 且不写 app_upgrade', () async {
    final SessionRepository repository = testRepository(root);
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      packageInfoLoader: () async => PackageInfo(
        appName: '包裹留证',
        packageName: 'app.packingproof.mobile',
        version: '0.5.23',
        buildNumber: '11030',
      ),
      buildConfig: const AppBuildConfig(
        buildRevision: 'def5678',
        buildTimestamp: '2026-08-17T20:00:00Z',
      ),
      runtimeLog: DiagnosticsLogService(
        rootProvider: () async => root,
        runtimeMetadataLoader: () async => <String, Object?>{
          'appVersion': '0.5.23',
          'appBuildNumber': 11030,
          'buildRevision': 'def5678',
          'buildTimestamp': '2026-08-17T20:00:00Z',
        },
      ),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    await controller.initialize();

    final File file = File('${root.path}/diagnostics/runtime.jsonl');
    final String content = await _waitForRuntimeKind(file, 'app_start');
    expect(content, contains('"appVersion":"0.5.23"'));
    expect(content, contains('"appBuildNumber":11030'));
    expect(content, isNot(contains('"kind":"app_upgrade"')));

    final AppSettings settings = await repository.loadSettings();
    expect(settings.lastLoggedAppVersion, '0.5.23');
    expect(settings.lastLoggedAppBuildNumber, 11030);
    expect(settings.lastLoggedBuildIdentity, '0.5.23|11030|def5678');
  });

  test('构建身份变化时写 app_upgrade 且同版本不重复写', () async {
    final SessionRepository repository = testRepository(root);
    await repository.saveLastLoggedAppIdentity(
      version: '0.5.22',
      buildNumber: 11029,
      buildIdentity: '0.5.22|11029|abc1234',
    );
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      packageInfoLoader: () async => PackageInfo(
        appName: '包裹留证',
        packageName: 'app.packingproof.mobile',
        version: '0.5.23',
        buildNumber: '11030',
      ),
      buildConfig: const AppBuildConfig(
        buildRevision: 'def5678',
        buildTimestamp: '2026-08-17T20:00:00Z',
      ),
      runtimeLog: DiagnosticsLogService(
        rootProvider: () async => root,
        runtimeMetadataLoader: () async => <String, Object?>{
          'appVersion': '0.5.23',
          'appBuildNumber': 11030,
          'buildRevision': 'def5678',
          'buildTimestamp': '2026-08-17T20:00:00Z',
        },
      ),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    await controller.initialize();
    final File file = File('${root.path}/diagnostics/runtime.jsonl');
    final String content = await _waitForRuntimeKind(file, 'app_upgrade');
    expect(content, contains('"previousVersion":"0.5.22"'));
    expect(content, contains('"previousBuildNumber":11029'));
    expect(content, contains('"currentVersion":"0.5.23"'));
    expect(content, contains('"currentBuildNumber":11030'));
    expect(_countOccurrences(content, '"kind":"app_upgrade"'), 1);

    final PackingSessionController second = PackingSessionController(
      repository: testRepository(root),
      speechService: _FakeSpeechSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      packageInfoLoader: () async => PackageInfo(
        appName: '包裹留证',
        packageName: 'app.packingproof.mobile',
        version: '0.5.23',
        buildNumber: '11030',
      ),
      buildConfig: const AppBuildConfig(
        buildRevision: 'def5678',
        buildTimestamp: '2026-08-17T20:00:00Z',
      ),
      runtimeLog: DiagnosticsLogService(
        rootProvider: () async => root,
        runtimeMetadataLoader: () async => <String, Object?>{
          'appVersion': '0.5.23',
          'appBuildNumber': 11030,
          'buildRevision': 'def5678',
          'buildTimestamp': '2026-08-17T20:00:00Z',
        },
      ),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );
    await second.initialize();
    final String updated = await file.readAsString();
    expect(_countOccurrences(updated, '"kind":"app_upgrade"'), 1);
  });

  test('任意状态识别条码都会触发独立滴声且同码不重复', () async {
    final _FakeSpeechSink speech = _FakeSpeechSink();
    final PackingSessionController controller = PackingSessionController(
      repository: testRepository(root),
      speechService: speech,
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'CLEAR', area: 100),
    ]);
    expect(speech.beepCount, 1);
    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'CLEAR', area: 100),
    ]);
    expect(speech.beepCount, 1);
    controller.handleNativeBarcodeFrameForTesting(
      const <NativeBarcodeCandidate>[],
    );
    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'CLEAR', area: 100),
    ]);
    expect(speech.beepCount, 2);

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'YT123456789012', area: 200),
    ]);
    expect(speech.beepCount, 3);
  });

  test('未开始工作时识别指令码立即生效且同码不重复', () async {
    final _FakeSpeechSink speech = _FakeSpeechSink();
    final PackingSessionController controller = PackingSessionController(
      repository: testRepository(root),
      speechService: speech,
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'BACK', area: 100),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.operationMode, RecordingOperationMode.returnGoods);
    expect(speech.prompts, contains(SpeechPrompt.returnMode));
    expect(speech.beepCount, 1);

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'BACK', area: 100),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(speech.beepCount, 1);
    expect(
      speech.prompts.where(
        (SpeechPrompt prompt) => prompt == SpeechPrompt.returnMode,
      ),
      hasLength(1),
    );

    controller.handleNativeBarcodeFrameForTesting(
      const <NativeBarcodeCandidate>[],
    );
    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'SHIP', area: 100),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.operationMode, RecordingOperationMode.shipping);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(speech.beepCount, 2);

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'STOP', area: 100),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.operationMode, RecordingOperationMode.shipping);

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'START', area: 100),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(speech.beepCount, 4);
  });

  test('模式切换会保存选择并播报固定模式语音，初始化恢复选择', () async {
    final SessionRepository repository = testRepository(root);
    final _FakeSpeechSink speech = _FakeSpeechSink();
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: speech,
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    await controller.initialize();
    await controller.setOperationMode(RecordingOperationMode.returnGoods);
    expect(controller.operationMode, RecordingOperationMode.returnGoods);
    expect(speech.prompts, contains(SpeechPrompt.returnMode));
    expect(
      (await repository.loadSettings()).operationMode,
      RecordingOperationMode.returnGoods,
    );

    final PackingSessionController restored = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );
    await restored.initialize();
    expect(restored.operationMode, RecordingOperationMode.returnGoods);
  });

  test('历史记录扫码忽略二维码并从同帧选择 Code128', () async {
    final PackingSessionController controller = PackingSessionController(
      repository: testRepository(root),
      speechService: _FakeSpeechSink(),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    await controller.initialize();
    controller.beginHistoryBarcodeScan();
    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(
        value: 'QR12345678901',
        area: 300,
        format: 'qr',
      ),
    ]);
    expect(controller.historyScanActive, isTrue);
    expect(controller.historyScanResult, isNull);

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
    expect(controller.historyScanActive, isFalse);
    expect(controller.historyScanResult, 'YT123456789012');
  });

  testWidgets('录像兼容提示 5 秒独立计时且新事件重新计时', (WidgetTester tester) async {
    const String notice = '受硬件限制，录像时预览画面会暂停，扫码和录像不受影响';
    final PackingSessionController controller = PackingSessionController(
      repository: testRepository(root),
      speechService: _FakeSpeechSink(),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );
    controller.handleNativeRecordingFallbackForTesting(<String, Object?>{
      'mode': 'encoder_analysis',
    });
    expect(controller.cameraNotice, notice);

    await tester.pump(const Duration(seconds: 3));
    expect(controller.cameraNotice, notice);

    await tester.pump(const Duration(seconds: 2));
    expect(controller.cameraNotice, isNull);

    controller.handleNativeRecordingFallbackForTesting(<String, Object?>{
      'mode': 'encoder_analysis',
      'phase': 'stall_during_recording',
    });
    expect(controller.cameraNotice, notice);

    await tester.pump(const Duration(seconds: 3));
    expect(controller.cameraNotice, notice);

    await tester.pump(const Duration(seconds: 2));
    expect(controller.cameraNotice, isNull);
  });
}

Future<String> _waitForInitFailed(
  File file, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) {
      final String content = await file.readAsString();
      if (content.contains('"kind":"init_failed"')) {
        return content;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('camera.jsonl 未在 $timeout 内记录 init_failed 事件');
}

Future<String> _waitForRuntimeKind(
  File file,
  String kind, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) {
      final String content = await file.readAsString();
      if (content.contains('"kind":"$kind"')) {
        return content;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('runtime.jsonl 未在 $timeout 内记录 $kind 事件');
}

int _countOccurrences(String content, String needle) {
  int count = 0;
  int index = 0;
  while ((index = content.indexOf(needle, index)) >= 0) {
    count++;
    index += needle.length;
  }
  return count;
}

class _FakeSpeechSink implements SpeechPromptSink {
  final List<SpeechPrompt> prompts = <SpeechPrompt>[];
  int beepCount = 0;
  int clearCount = 0;

  @override
  bool enabled = true;

  @override
  void enqueue(SpeechPrompt prompt, {String? incidentKey}) {
    if (enabled) {
      prompts.add(prompt);
    }
  }

  @override
  Future<void> setEnabled(bool value) async => enabled = value;

  @override
  Future<void> preview() async {}

  @override
  void playShortBeep() {
    if (enabled) {
      beepCount++;
    }
  }

  @override
  void resetIncidents() {}

  @override
  void resolveIncident(String incidentKey) {}

  @override
  Future<void> clear() async {
    clearCount++;
  }

  @override
  Future<void> dispose() async {}
}

class _FailingWatermarkSink implements VideoWatermarkSink {
  @override
  Future<String> apply({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    RecordingVideoCodec videoCodec = RecordingVideoCodec.hevc,
  }) {
    throw StateError('watermark test failure');
  }
}
