import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:packing_proof_mobile/app/app_build_config.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/app_settings.dart';
import 'package:packing_proof_mobile/models/recording_orientation.dart';
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

  void trackController(PackingSessionController controller) {
    addTearDown(() async {
      await controller.shutdown();
      controller.dispose();
    });
  }

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

    trackController(controller);
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

    trackController(controller);
    await controller.watermarkAndBackupForTesting(source.path, session);

    expect(await source.exists(), isTrue);
    final File log = File('${root.path}/diagnostics/runtime.jsonl');
    final String content = await _waitForRuntimeKind(log, 'watermark_failed');
    expect(content, contains('"kind":"watermark_started"'));
    expect(content, contains('"sessionId":"session-watermark-failed"'));
    expect(content, contains('"orientation":"portrait"'));
    expect(content, contains('"inputBytes":3'));
    expect(content, contains('"outputBytes":0'));
    expect(content, contains('"errorType":"StateError"'));
    expect(content, isNot(contains('watermark test failure')));
    expect(content, isNot(contains(source.path)));
  });

  test('水印失败持久化失败状态并保留原片', () async {
    final SessionRepository repository = testRepository(root);
    final File source = File('${root.path}/failed-original.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final DateTime startedAt = DateTime(2026, 8, 21, 10);
    final RecordingSession session = RecordingSession(
      id: 'session-pending-failed',
      filePath: source.path,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 5)),
      markers: const <Never>[],
      recordingOrientation: RecordingOrientation.landscapeRight,
      watermarkStatus: WatermarkProcessingStatus.pending,
    );
    await repository.addSession(session);
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      videoWatermarkService: _FailingWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    trackController(controller);
    await controller.watermarkAndBackupForTesting(
      source.path,
      session,
      session.recordingOrientation,
    );

    final List<RecordingSession> saved = await repository.loadSessions(
      includeMissingFiles: true,
    );
    expect(saved.single.watermarkStatus, WatermarkProcessingStatus.failed);
    expect(saved.single.filePath, source.path);
    expect(await source.exists(), isTrue);
  });

  test('iOS 系统中断水印最多恢复三次后标记失败', () async {
    final SessionRepository repository = testRepository(root);
    final File source = File('${root.path}/interrupted-original.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final DateTime startedAt = DateTime(2026, 8, 21, 10);
    await repository.addSession(
      RecordingSession(
        id: 'session-watermark-interrupted',
        filePath: source.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 5)),
        markers: const <Never>[],
        watermarkStatus: WatermarkProcessingStatus.pending,
      ),
    );
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      videoWatermarkService: _InterruptedWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );
    trackController(controller);

    for (int attempt = 1; attempt <= 3; attempt++) {
      final RecordingSession current = (await repository.loadSessions(
        includeMissingFiles: true,
      )).single;
      await controller.watermarkAndBackupForTesting(
        source.path,
        current,
        current.recordingOrientation,
      );
      final RecordingSession updated = (await repository.loadSessions(
        includeMissingFiles: true,
      )).single;
      expect(updated.watermarkAttemptCount, attempt);
      expect(
        updated.watermarkStatus,
        attempt < 3
            ? WatermarkProcessingStatus.pending
            : WatermarkProcessingStatus.failed,
      );
    }

    expect(await source.exists(), isTrue);
    final String log = await File(
      '${root.path}/diagnostics/runtime.jsonl',
    ).readAsString();
    expect(_countOccurrences(log, '"kind":"watermark_retry_pending"'), 2);
    expect(_countOccurrences(log, '"kind":"watermark_failed"'), 1);
  });

  test('重启恢复待处理水印时保留录像方向且只导出一次', () async {
    final SessionRepository repository = testRepository(root);
    final File source = File('${root.path}/pending-original.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final DateTime startedAt = DateTime(2026, 8, 21, 10);
    final RecordingSession session = RecordingSession(
      id: 'session-pending-resume',
      filePath: source.path,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 5)),
      markers: const <Never>[],
      recordingOrientation: RecordingOrientation.landscapeLeft,
      watermarkStatus: WatermarkProcessingStatus.pending,
    );
    await repository.addSession(session);
    final _RecordingWatermarkSink watermark = _RecordingWatermarkSink();
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      videoWatermarkService: watermark,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    trackController(controller);
    await Future.wait<void>(<Future<void>>[
      controller.resumePendingWatermarksForTesting(),
      controller.resumePendingWatermarksForTesting(),
    ]);
    await watermark.completed.future;
    await _waitForRuntimeKind(
      File('${root.path}/diagnostics/runtime.jsonl'),
      'watermark_completed',
    );

    final List<RecordingSession> saved = await repository.loadSessions(
      includeMissingFiles: true,
    );
    expect(watermark.applyCalls, 1);
    expect(watermark.orientation, RecordingOrientation.landscapeLeft);
    expect(saved.single.watermarkStatus, WatermarkProcessingStatus.completed);
    expect(saved.single.watermarkAttemptCount, 1);
    expect(
      saved.single.recordingOrientation,
      RecordingOrientation.landscapeLeft,
    );
    expect(saved.single.filePath, isNot(source.path));
    expect(await File(saved.single.filePath).exists(), isTrue);
  });

  test('最终状态落库失败时保留原片并清理孤立水印文件', () async {
    final SessionRepository repository = _FailingFinalUpdateRepository(root);
    final File source = File('${root.path}/persistence-original.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final DateTime startedAt = DateTime(2026, 8, 21, 10);
    final RecordingSession session = RecordingSession(
      id: 'session-final-update-failed',
      filePath: source.path,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 5)),
      markers: const <Never>[],
      watermarkStatus: WatermarkProcessingStatus.pending,
    );
    await repository.addSession(session);
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      videoWatermarkService: _RecordingWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );
    trackController(controller);

    await controller.watermarkAndBackupForTesting(source.path, session);

    final RecordingSession saved = (await repository.loadSessions(
      includeMissingFiles: true,
    )).single;
    expect(saved.filePath, source.path);
    expect(saved.watermarkStatus, WatermarkProcessingStatus.pending);
    expect(saved.watermarkAttemptCount, 1);
    expect(await source.exists(), isTrue);
    final List<FileSystemEntity> finalizedFiles = await Directory(
      '${root.path}/recordings',
    ).list(recursive: true).toList();
    expect(
      finalizedFiles.where(
        (FileSystemEntity entry) =>
            entry is File && entry.path.endsWith('.mp4'),
      ),
      isEmpty,
    );
  });

  test('最终状态已提交但刷新失败时重读确认成功且不回退', () async {
    final SessionRepository repository = _PostCommitFailingRepository(root);
    final File source = File('${root.path}/post-commit-original.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final RecordingSession session = _pendingWatermarkSession(
      id: 'session-post-commit-failed',
      filePath: source.path,
    );
    await repository.addSession(session);
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      videoWatermarkService: _RecordingWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    trackController(controller);

    await controller.watermarkAndBackupForTesting(source.path, session);

    final RecordingSession saved = (await repository.loadSessions(
      includeMissingFiles: true,
    )).single;
    expect(saved.watermarkStatus, WatermarkProcessingStatus.completed);
    expect(saved.filePath, isNot(source.path));
    expect(await File(saved.filePath).exists(), isTrue);
    final String log = await File(
      '${root.path}/diagnostics/runtime.jsonl',
    ).readAsString();
    expect(log, contains('"kind":"watermark_completed"'));
    expect(log, isNot(contains('"kind":"watermark_failed"')));
  });

  test('成片落库后原片清理异常不得把已完成状态回退为失败', () async {
    final SessionRepository repository = _CleanupFailingRepository(root);
    final File source = File('${root.path}/cleanup-failed-original.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final RecordingSession session = _pendingWatermarkSession(
      id: 'session-cleanup-failed',
      filePath: source.path,
    );
    await repository.addSession(session);
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      videoWatermarkService: _RecordingWatermarkSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    trackController(controller);

    await controller.watermarkAndBackupForTesting(source.path, session);

    final RecordingSession saved = (await repository.loadSessions(
      includeMissingFiles: true,
    )).single;
    expect(saved.watermarkStatus, WatermarkProcessingStatus.completed);
    expect(saved.filePath, isNot(source.path));
    final String log = await File(
      '${root.path}/diagnostics/runtime.jsonl',
    ).readAsString();
    expect(log, contains('"kind":"watermark_source_cleanup_failed"'));
    expect(log, isNot(contains('"kind":"watermark_failed"')));
  });

  test('返回前台时导出仍活跃则在中断后补跑一次且不并发', () async {
    final SessionRepository repository = testRepository(root);
    final File source = File('${root.path}/queued-resume-original.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final RecordingSession session = _pendingWatermarkSession(
      id: 'session-queued-resume',
      filePath: source.path,
    );
    await repository.addSession(session);
    final _QueuedResumeWatermarkSink watermark = _QueuedResumeWatermarkSink();
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      videoWatermarkService: watermark,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    trackController(controller);

    final Future<void> first = controller.watermarkAndBackupForTesting(
      source.path,
      session,
    );
    await watermark.firstStarted.future;
    await controller.resumePendingWatermarksForTesting();
    watermark.releaseFirst(interrupted: true);
    await first;
    await watermark.secondStarted.future;
    await _waitForRuntimeKind(
      File('${root.path}/diagnostics/runtime.jsonl'),
      'watermark_completed',
    );

    final RecordingSession saved = (await repository.loadSessions(
      includeMissingFiles: true,
    )).single;
    expect(watermark.applyCalls, 2);
    expect(watermark.maximumConcurrentCalls, 1);
    expect(saved.watermarkStatus, WatermarkProcessingStatus.completed);
    expect(saved.watermarkAttemptCount, 2);
  });

  test('返回前台时导出仍活跃但首次成功则不重复导出', () async {
    final SessionRepository repository = testRepository(root);
    final File source = File('${root.path}/queued-success-original.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final RecordingSession session = _pendingWatermarkSession(
      id: 'session-queued-success',
      filePath: source.path,
    );
    await repository.addSession(session);
    final _QueuedResumeWatermarkSink watermark = _QueuedResumeWatermarkSink();
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      videoWatermarkService: watermark,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    trackController(controller);

    final Future<void> first = controller.watermarkAndBackupForTesting(
      source.path,
      session,
    );
    await watermark.firstStarted.future;
    await controller.resumePendingWatermarksForTesting();
    watermark.releaseFirst(interrupted: false);
    await first;
    await _waitForRuntimeKind(
      File('${root.path}/diagnostics/runtime.jsonl'),
      'watermark_completed',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(watermark.applyCalls, 1);
    expect(watermark.maximumConcurrentCalls, 1);
  });

  test('两个控制器竞争同一待处理水印时只有一个获得导出权', () async {
    final SessionRepository repository = testRepository(root);
    final File source = File('${root.path}/claim-race-original.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final RecordingSession session = _pendingWatermarkSession(
      id: 'session-claim-race',
      filePath: source.path,
    );
    await repository.addSession(session);
    final _QueuedResumeWatermarkSink watermark = _QueuedResumeWatermarkSink();
    PackingSessionController buildController() => PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      videoWatermarkService: watermark,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    final PackingSessionController firstController = buildController();
    final PackingSessionController secondController = buildController();
    trackController(firstController);
    trackController(secondController);

    final Future<void> first = firstController.watermarkAndBackupForTesting(
      source.path,
      session,
    );
    await watermark.firstStarted.future;
    await secondController.watermarkAndBackupForTesting(source.path, session);
    expect(watermark.applyCalls, 1);
    watermark.releaseFirst(interrupted: false);
    await first;
  });

  test('shutdown 可重复调用并等待异步资源关闭', () async {
    final Completer<void> disposeBlocker = Completer<void>();
    final _FakeSpeechSink speech = _FakeSpeechSink(
      disposeBlocker: disposeBlocker,
    );
    final PackingSessionController controller = PackingSessionController(
      repository: testRepository(root),
      speechService: speech,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    final Future<void> first = controller.shutdown();
    final Future<void> second = controller.shutdown();
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(speech.disposeCount, 1);

    disposeBlocker.complete();
    await first;
    controller.dispose();
    expect(speech.disposeCount, 1);
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

    trackController(controller);
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

    trackController(controller);
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
    trackController(second);
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

    trackController(controller);
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

    trackController(controller);
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

    trackController(controller);
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
    trackController(restored);
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

    trackController(controller);
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
    trackController(controller);
    controller.handleNativeRecordingFallbackForTesting(<String, Object?>{
      'mode': 'encoder_analysis',
    }, persist: false);
    expect(controller.cameraNotice, notice);

    await tester.pump(const Duration(seconds: 3));
    expect(controller.cameraNotice, notice);

    await tester.pump(const Duration(seconds: 2));
    expect(controller.cameraNotice, isNull);

    controller.handleNativeRecordingFallbackForTesting(<String, Object?>{
      'mode': 'encoder_analysis',
      'phase': 'stall_during_recording',
    }, persist: false);
    expect(controller.cameraNotice, notice);

    await tester.pump(const Duration(seconds: 3));
    expect(controller.cameraNotice, notice);

    await tester.pump(const Duration(seconds: 2));
    expect(controller.cameraNotice, isNull);
    await tester.runAsync(controller.shutdown);
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
  _FakeSpeechSink({this.disposeBlocker});

  final Completer<void>? disposeBlocker;
  final List<SpeechPrompt> prompts = <SpeechPrompt>[];
  int beepCount = 0;
  int clearCount = 0;
  int disposeCount = 0;

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
  Future<void> dispose() async {
    disposeCount++;
    await disposeBlocker?.future;
  }
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

class _RecordingWatermarkSink
    implements VideoWatermarkSink, OrientedVideoWatermarkSink {
  final Completer<void> completed = Completer<void>();
  int applyCalls = 0;
  RecordingOrientation? orientation;

  @override
  Future<String> apply({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    RecordingVideoCodec videoCodec = RecordingVideoCodec.hevc,
  }) => applyWithOrientation(
    inputPath: inputPath,
    startedAt: startedAt,
    trackingNumber: trackingNumber,
    videoCodec: videoCodec,
    recordingOrientation: RecordingOrientation.portrait,
  );

  @override
  Future<String> applyWithOrientation({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    required RecordingVideoCodec videoCodec,
    required RecordingOrientation recordingOrientation,
  }) async {
    applyCalls++;
    orientation = recordingOrientation;
    final File output = File('$inputPath-watermarked.mp4');
    await File(inputPath).copy(output.path);
    if (!completed.isCompleted) completed.complete();
    return output.path;
  }
}

class _InterruptedWatermarkSink implements VideoWatermarkSink {
  @override
  Future<String> apply({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    RecordingVideoCodec videoCodec = RecordingVideoCodec.hevc,
  }) {
    throw PlatformException(code: 'watermark_interrupted');
  }
}

class _FailingFinalUpdateRepository extends SessionRepository {
  _FailingFinalUpdateRepository(Directory root) : super(rootDirectory: root);

  @override
  Future<List<RecordingSession>> updateSession(
    RecordingSession updatedSession,
  ) {
    if (updatedSession.watermarkStatus == WatermarkProcessingStatus.completed) {
      throw StateError('final watermark state persistence failed');
    }
    return super.updateSession(updatedSession);
  }
}

class _PostCommitFailingRepository extends SessionRepository {
  _PostCommitFailingRepository(Directory root) : super(rootDirectory: root);

  @override
  Future<List<RecordingSession>> updateSession(
    RecordingSession updatedSession,
  ) async {
    final List<RecordingSession> result = await super.updateSession(
      updatedSession,
    );
    if (updatedSession.watermarkStatus == WatermarkProcessingStatus.completed) {
      throw StateError('recent sessions reload failed after commit');
    }
    return result;
  }
}

class _CleanupFailingRepository extends SessionRepository {
  _CleanupFailingRepository(Directory root) : super(rootDirectory: root);

  @override
  Future<void> deleteFileIfUnreferenced(String filePath) {
    throw FileSystemException('cleanup failed');
  }
}

RecordingSession _pendingWatermarkSession({
  required String id,
  required String filePath,
}) {
  final DateTime startedAt = DateTime(2026, 8, 21, 10);
  return RecordingSession(
    id: id,
    filePath: filePath,
    startedAt: startedAt,
    endedAt: startedAt.add(const Duration(seconds: 5)),
    markers: const <Never>[],
    watermarkStatus: WatermarkProcessingStatus.pending,
  );
}

class _QueuedResumeWatermarkSink implements VideoWatermarkSink {
  final Completer<void> firstStarted = Completer<void>();
  final Completer<void> secondStarted = Completer<void>();
  final Completer<bool> _firstRelease = Completer<bool>();
  int applyCalls = 0;
  int _concurrentCalls = 0;
  int maximumConcurrentCalls = 0;

  void releaseFirst({required bool interrupted}) {
    _firstRelease.complete(interrupted);
  }

  @override
  Future<String> apply({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    RecordingVideoCodec videoCodec = RecordingVideoCodec.hevc,
  }) async {
    applyCalls++;
    final int call = applyCalls;
    _concurrentCalls++;
    if (_concurrentCalls > maximumConcurrentCalls) {
      maximumConcurrentCalls = _concurrentCalls;
    }
    try {
      if (call == 1) {
        firstStarted.complete();
        if (await _firstRelease.future) {
          throw PlatformException(code: 'watermark_interrupted');
        }
      } else if (call == 2 && !secondStarted.isCompleted) {
        secondStarted.complete();
      }
      final File output = File('$inputPath-watermarked-$call.mp4');
      await File(inputPath).copy(output.path);
      return output.path;
    } finally {
      _concurrentCalls--;
    }
  }
}
