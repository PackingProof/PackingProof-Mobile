import 'package:packing_proof_mobile/models/recording_operation_mode.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/backup_retention_policy.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/platform/platform_capabilities.dart';
import 'package:packing_proof_mobile/services/diagnostics_log_service.dart';
import 'package:packing_proof_mobile/services/lan_backup_service.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';
import 'package:packing_proof_mobile/services/speech_prompt_service.dart';
import 'package:packing_proof_mobile/services/video_watermark_service.dart';

import 'test_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('备份公共入口保持手动重启与自动续传语义', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-backup-coordinator-',
    );
    final SessionRepository repository = testRepository(root);
    await repository.initialize();
    final DateTime startedAt = DateTime.utc(2026, 8, 21, 10);
    final File firstVideo = File('${root.path}/backup-one.mp4');
    final File secondVideo = File('${root.path}/backup-two.mp4');
    await firstVideo.writeAsBytes(<int>[1]);
    await secondVideo.writeAsBytes(<int>[2]);
    await repository.addSessions(<RecordingSession>[
      RecordingSession(
        id: 'backup-one',
        filePath: firstVideo.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <Never>[],
      ),
      RecordingSession(
        id: 'backup-two',
        filePath: secondVideo.path,
        startedAt: startedAt.add(const Duration(seconds: 2)),
        endedAt: startedAt.add(const Duration(seconds: 3)),
        markers: const <Never>[],
      ),
    ]);
    final _RecordingLanBackupSink backup = _RecordingLanBackupSink();
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _NoopSpeechSink(),
      lanBackupService: backup,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    addTearDown(() async {
      await controller.shutdown();
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await controller.initialize();
    expect(backup.initializeCalls, 0);

    await controller.backupAllSessions();
    await controller.setLanBackupAutoEnabled(true);
    backup.retryConnectionResult = true;
    await controller.retryBackupConnection();
    await controller.waitForAutomaticBackupBootstrapForTesting();

    expect(backup.backupCalls.map((call) => call.forceRestart), <bool>[
      true,
      false,
      false,
    ]);
    expect(
      backup.backupCalls.map((call) => call.sessionIds.toSet()),
      everyElement(<String>{'backup-one', 'backup-two'}),
    );
  });

  test('电脑连上后自动重排可恢复的暂停上传任务', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-backup-auto-retry-',
    );
    final SessionRepository repository = testRepository(root);
    await repository.initialize();
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 12);
    final File video = File('${root.path}/retry.mp4');
    await video.writeAsBytes(<int>[1]);
    await repository.addSession(
      RecordingSession(
        id: 'retry',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <Never>[],
      ),
    );
    await repository.resumeSharedFileMigration();
    final _RecordingLanBackupSink backup = _RecordingLanBackupSink()
      ..jobsByPath[video.path] = LanBackupJob(
        id: 'job-offline',
        filePath: video.path,
        state: LanBackupJobState.paused,
        uploadedBytes: 0,
        totalBytes: 1,
        failureKind: LanBackupFailureKind.offlineOrTimeout,
      )
      // 旧版本「仅登记也写 paused」留下的任务没有失败原因，同样要恢复。
      ..jobsByPath['${video.path}.legacy'] = LanBackupJob(
        id: 'job-legacy-paused',
        filePath: '${video.path}.legacy',
        state: LanBackupJobState.paused,
        uploadedBytes: 0,
        totalBytes: 1,
      );
    await File('${video.path}.legacy').writeAsBytes(<int>[1]);
    await repository.addSession(
      RecordingSession(
        id: 'retry-legacy',
        filePath: '${video.path}.legacy',
        startedAt: startedAt.add(const Duration(seconds: 2)),
        endedAt: startedAt.add(const Duration(seconds: 3)),
        markers: const <Never>[],
      ),
    );
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _NoopSpeechSink(),
      lanBackupService: backup,
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.lanBackup,
      }),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    addTearDown(() async {
      await controller.shutdown();
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });
    await controller.initialize();

    // 没开自动备份时不重排。
    backup.emitSnapshot(
      autoEnabled: false,
      connectionStatus: LanConnectionStatus.connected,
    );
    await _waitForAutoRetrySweep();
    expect(backup.retriedJobIds, isEmpty);

    // 打开自动备份但电脑离线时也不重排。
    backup.emitSnapshot(
      autoEnabled: true,
      connectionStatus: LanConnectionStatus.offline,
    );
    await _waitForAutoRetrySweep();
    expect(backup.retriedJobIds, isEmpty);

    // 电脑连上后，暂时性失败的任务重新排队。
    backup.emitSnapshot(
      autoEnabled: true,
      connectionStatus: LanConnectionStatus.connected,
    );
    for (
      int attempt = 0;
      attempt < 100 && backup.retriedJobIds.isEmpty;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(backup.retriedJobIds.toSet(), <String>{
      'job-offline',
      'job-legacy-paused',
    });
  });

  test('凭据失效等需要人工处理的失败不会自动重排', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-backup-auto-retry-skip-',
    );
    final SessionRepository repository = testRepository(root);
    await repository.initialize();
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 12);
    final File video = File('${root.path}/manual.mp4');
    await video.writeAsBytes(<int>[1]);
    await repository.addSession(
      RecordingSession(
        id: 'manual',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <Never>[],
      ),
    );
    await repository.resumeSharedFileMigration();
    final _RecordingLanBackupSink backup = _RecordingLanBackupSink()
      ..jobsByPath[video.path] = LanBackupJob(
        id: 'job-credential',
        filePath: video.path,
        state: LanBackupJobState.paused,
        uploadedBytes: 0,
        totalBytes: 1,
        failureKind: LanBackupFailureKind.credentialInvalid,
      );
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _NoopSpeechSink(),
      lanBackupService: backup,
      capabilities: const PlatformCapabilities(<PlatformCapability>{
        PlatformCapability.lanBackup,
      }),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    addTearDown(() async {
      await controller.shutdown();
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });
    await controller.initialize();
    backup.emitSnapshot(
      autoEnabled: true,
      connectionStatus: LanConnectionStatus.connected,
    );

    await _waitForAutoRetrySweep();

    expect(backup.retriedJobIds, isEmpty);
  });

  test('自动备份触发立即返回且多个触发只由一个 runner 串行处理', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-backup-runner-',
    );
    final SessionRepository repository = testRepository(root);
    await repository.initialize();
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 12);
    final File video = File('${root.path}/runner.mp4');
    await video.writeAsBytes(<int>[1]);
    await repository.addSession(
      RecordingSession(
        id: 'runner',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <Never>[],
      ),
    );
    await repository.resumeSharedFileMigration();
    final Completer<void> firstBatchGate = Completer<void>();
    final Completer<void> firstBatchStarted = Completer<void>();
    final _RecordingLanBackupSink backup = _RecordingLanBackupSink()
      ..backupGate = firstBatchGate.future
      ..backupStarted = firstBatchStarted;
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _NoopSpeechSink(),
      lanBackupService: backup,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    addTearDown(() async {
      if (!firstBatchGate.isCompleted) firstBatchGate.complete();
      await controller.shutdown();
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await controller
        .setLanBackupAutoEnabled(true)
        .timeout(const Duration(seconds: 5));
    controller.scheduleAutomaticBackupBootstrapForTesting(
      'connection_restored',
    );
    controller.scheduleAutomaticBackupBootstrapForTesting('pairing_completed');
    await firstBatchStarted.future.timeout(const Duration(seconds: 5));

    expect(backup.backupCalls, hasLength(1));
    expect(backup.maximumConcurrentBackupCalls, 1);

    firstBatchGate.complete();
    backup.backupGate = null;
    backup.backupStarted = null;
    await controller.waitForAutomaticBackupBootstrapForTesting();

    expect(backup.backupCalls, hasLength(2));
    expect(backup.maximumConcurrentBackupCalls, 1);
    expect(
      backup.backupCalls.map((_BackupCall call) => call.forceRestart),
      everyElement(isFalse),
    );
  });

  test('关闭自动备份后在当前页完成时停止后续扫描', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-backup-runner-cancel-',
    );
    final _PagedBackupRepository repository = _PagedBackupRepository(
      rootDirectory: root,
      total: 1000,
    );
    final Completer<void> firstBatchGate = Completer<void>();
    final Completer<void> firstBatchStarted = Completer<void>();
    final _RecordingLanBackupSink backup = _RecordingLanBackupSink()
      ..backupGate = firstBatchGate.future
      ..backupStarted = firstBatchStarted;
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _NoopSpeechSink(),
      lanBackupService: backup,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    addTearDown(() async {
      if (!firstBatchGate.isCompleted) firstBatchGate.complete();
      await controller.shutdown();
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await controller.setLanBackupAutoEnabled(true);
    await firstBatchStarted.future.timeout(const Duration(seconds: 5));
    await controller.setLanBackupAutoEnabled(false);
    firstBatchGate.complete();
    await controller.waitForAutomaticBackupBootstrapForTesting();

    expect(backup.backupCalls, hasLength(1));
    expect(backup.backupCalls.single.sessionIds, hasLength(100));
    expect(backup.maximumConcurrentBackupCalls, 1);
  });

  test('启动增量备份中途关闭不跨过未处理页且下次可恢复', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-backup-cursor-interrupted-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final SessionRepository firstRepository = SessionRepository(
      rootDirectory: root,
    );
    final DateTime startedAt = DateTime.utc(2026, 8, 21, 10);
    final List<RecordingSession> sessions = <RecordingSession>[];
    for (int index = 0; index < 101; index++) {
      final File file = File('${root.path}/backup-$index.mp4');
      await file.writeAsBytes(<int>[index % 255 + 1]);
      sessions.add(
        RecordingSession(
          id: 'backup-${index.toString().padLeft(3, '0')}',
          filePath: file.path,
          startedAt: startedAt.add(Duration(seconds: index)),
          endedAt: startedAt.add(Duration(seconds: index + 1)),
          markers: const <Never>[],
        ),
      );
    }
    await firstRepository.addSessions(sessions);
    final PackingSessionController firstController = PackingSessionController(
      repository: firstRepository,
      speechService: _NoopSpeechSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    await firstRepository.resumeSharedFileMigration();
    final List<String> firstRunIds = <String>[];
    var processedPages = 0;
    await firstController.processStartupBackupIncrementForTesting((page) async {
      processedPages++;
      if (processedPages == 2) {
        throw StateError('模拟第二页处理前中断');
      }
      firstRunIds.addAll(page.map((session) => session.id));
    });
    expect(firstRunIds, hasLength(100));
    await firstController.shutdown();
    firstController.dispose();

    final SessionRepository verifier = SessionRepository(rootDirectory: root);
    expect(await verifier.loadBackupRegistrationCursor(), isNotNull);
    await verifier.dispose();

    final SessionRepository secondRepository = SessionRepository(
      rootDirectory: root,
    );
    final PackingSessionController secondController = PackingSessionController(
      repository: secondRepository,
      speechService: _NoopSpeechSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    await secondRepository.resumeSharedFileMigration();
    final List<String> secondRunIds = <String>[];
    await secondController.processStartupBackupIncrementForTesting((
      page,
    ) async {
      secondRunIds.addAll(page.map((session) => session.id));
    });
    expect(secondRunIds, hasLength(1));
    expect(await secondRepository.loadBackupRegistrationCursor(), isNotNull);
    await secondController.shutdown();
    secondController.dispose();
  });

  test('清理事件游标在原生确认失败后持久化并于下次启动补确认', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-cleanup-cursor-interrupted-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final String filePath = '${root.path}/cleaned.mp4';
    final SessionRepository firstRepository = SessionRepository(
      rootDirectory: root,
    );
    final DateTime deletedAt = DateTime.utc(2026, 8, 23, 12);
    await firstRepository.addSession(
      RecordingSession(
        id: 'cleanup-session',
        filePath: filePath,
        startedAt: deletedAt.subtract(const Duration(seconds: 2)),
        endedAt: deletedAt.subtract(const Duration(seconds: 1)),
        markers: const <Never>[],
      ),
    );
    final _RecordingLanBackupSink firstBackup = _RecordingLanBackupSink()
      ..cleanupPages.add(
        LanBackupCleanupPage(
          latestRevision: 7,
          nextAfterRevision: 7,
          hasMore: false,
          events: <LanBackupCleanupEvent>[
            LanBackupCleanupEvent(
              revision: 7,
              eventId: 'cleanup-event-7',
              jobId: 'job-7',
              filePath: filePath,
              fileSizeBytes: 1024,
              deletedAt: deletedAt,
              reason: '已备份录像保留策略清理',
            ),
          ],
        ),
      )
      ..failNextCleanupAcknowledgement = true;
    final PackingSessionController firstController = PackingSessionController(
      repository: firstRepository,
      speechService: _NoopSpeechSink(),
      lanBackupService: firstBackup,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );

    await firstController.drainCleanupEventsForTesting();
    expect(await firstRepository.loadBackupCleanupCursor(), 7);
    expect(await firstRepository.loadDeleteLogs(), hasLength(1));
    await firstController.shutdown();
    firstController.dispose();

    final SessionRepository secondRepository = SessionRepository(
      rootDirectory: root,
    );
    final _RecordingLanBackupSink secondBackup = _RecordingLanBackupSink();
    final PackingSessionController secondController = PackingSessionController(
      repository: secondRepository,
      speechService: _NoopSpeechSink(),
      lanBackupService: secondBackup,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );

    await secondController.drainCleanupEventsForTesting();
    expect(secondBackup.acknowledgedCleanupRevisions, <int>[7]);
    expect(await secondRepository.loadDeleteLogs(), hasLength(1));
    await secondController.shutdown();
    secondController.dispose();

    final SessionRepository thirdRepository = SessionRepository(
      rootDirectory: root,
    );
    final _RecordingLanBackupSink thirdBackup = _RecordingLanBackupSink();
    final PackingSessionController thirdController = PackingSessionController(
      repository: thirdRepository,
      speechService: _NoopSpeechSink(),
      lanBackupService: thirdBackup,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    await thirdController.drainCleanupEventsForTesting();
    expect(thirdBackup.acknowledgedCleanupRevisions, <int>[7]);
    expect(await thirdRepository.loadDeleteLogs(), hasLength(1));
    await thirdController.shutdown();
    thirdController.dispose();
  });

  test('清理事件整页事务失败时不推进游标并可重放', () async {
    await _verifyCleanupReplayAroundRepositoryFailure();
  });

  test('100 条清理事件仅使用一次整页数据库提交', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-cleanup-page-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final _InterruptingCleanupRepository repository =
        _InterruptingCleanupRepository(
          rootDirectory: root,
          failNextPageCommit: false,
        );
    final DateTime deletedAt = DateTime.utc(2026, 8, 23, 14);
    final _RecordingLanBackupSink backup = _RecordingLanBackupSink()
      ..cleanupPages.add(
        LanBackupCleanupPage(
          latestRevision: 100,
          nextAfterRevision: 100,
          hasMore: false,
          events: List<LanBackupCleanupEvent>.generate(
            100,
            (int index) => LanBackupCleanupEvent(
              revision: index + 1,
              eventId: 'cleanup-page-$index',
              jobId: 'cleanup-job-$index',
              filePath: '${root.path}/missing-$index.mp4',
              fileSizeBytes: index,
              deletedAt: deletedAt,
              reason: '已备份录像保留策略清理',
            ),
          ),
        ),
      );
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _NoopSpeechSink(),
      lanBackupService: backup,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );

    await controller.drainCleanupEventsForTesting();

    expect(repository.pageCommitCalls, 1);
    expect(repository.lastPageEventCount, 100);
    expect(await repository.loadBackupCleanupCursor(), 100);
    await controller.shutdown();
    controller.dispose();
  });

  for (final int total in <int>[2000, 10000, 50000]) {
    test('$total 条备份入队始终保持每批最多 100 条', () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'packing-proof-backup-scale-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final _PagedBackupRepository repository = _PagedBackupRepository(
        rootDirectory: root,
        total: total,
      );
      final _RecordingLanBackupSink backup = _RecordingLanBackupSink();
      final PackingSessionController controller = PackingSessionController(
        repository: repository,
        speechService: _NoopSpeechSink(),
        lanBackupService: backup,
        capabilities: const PlatformCapabilities(<PlatformCapability>{}),
        runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      );

      await controller.backupAllSessions();

      expect(backup.backupCalls, hasLength((total / 100).ceil()));
      expect(
        backup.backupCalls.map((call) => call.sessionIds.length),
        everyElement(lessThanOrEqualTo(100)),
      );
      expect(
        backup.backupCalls.fold<int>(
          0,
          (int sum, _BackupCall call) => sum + call.sessionIds.length,
        ),
        total,
      );
      await controller.shutdown();
      controller.dispose();
    });
  }

  test('2000 条启动入队中断后从已提交游标继续', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-backup-scale-resume-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final _PagedBackupRepository repository = _PagedBackupRepository(
      rootDirectory: root,
      total: 2000,
    );
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _NoopSpeechSink(),
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    var pages = 0;
    await controller.processStartupBackupIncrementForTesting((_) async {
      pages++;
      if (pages == 8) throw StateError('模拟第八页入队前中断');
    });

    expect(repository.savedCursor?.updatedAt, 700);

    var resumedCount = 0;
    await controller.processStartupBackupIncrementForTesting((page) async {
      resumedCount += page.length;
    });

    expect(resumedCount, 1300);
    expect(repository.savedCursor?.updatedAt, 2000);
    await controller.shutdown();
    controller.dispose();
  });

  test('水印最终失败保持失败状态并立即备份保留文件', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-failed-watermark-backup-',
    );
    final SessionRepository repository = testRepository(root);
    final File source = File('${root.path}/failed-watermark.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final DateTime startedAt = DateTime.utc(2026, 8, 21, 10);
    final RecordingSession session = RecordingSession(
      id: 'failed-watermark',
      filePath: source.path,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 2)),
      markers: const <Never>[],
      watermarkStatus: WatermarkProcessingStatus.pending,
    );
    await repository.addSession(session);
    final _RecordingLanBackupSink backup = _RecordingLanBackupSink();
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _NoopSpeechSink(),
      videoWatermarkService: _FailingWatermarkSink(),
      lanBackupService: backup,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    addTearDown(() async {
      await controller.shutdown();
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await controller.watermarkAndBackupForTesting(source.path, session);

    final RecordingSession saved = (await repository.loadSessions(
      includeMissingFiles: true,
    )).single;
    expect(saved.watermarkStatus, WatermarkProcessingStatus.failed);
    expect(await source.exists(), isTrue);
    expect(backup.enqueuedPaths, <String>[source.path]);
    expect(
      backup.enqueuedSessions.single.single.watermarkStatus,
      WatermarkProcessingStatus.failed,
    );
  });

  test('周期存储检查仅在用户可见状态变化时通知界面', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-storage-notification-',
    );
    final _RecordingLanBackupSink backup = _RecordingLanBackupSink();
    final PackingSessionController controller = PackingSessionController(
      repository: testRepository(root),
      speechService: _NoopSpeechSink(),
      lanBackupService: backup,
      capabilities: const PlatformCapabilities(<PlatformCapability>{}),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
    );
    addTearDown(() async {
      await controller.shutdown();
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });
    int notifications = 0;
    controller.addListener(() => notifications++);

    await controller.checkStorageForTesting();

    expect(notifications, 0);

    backup.storageResult = const StorageSpaceResult(
      availableBytes: 2 * 1024 * 1024 * 1024,
      availableBytesBefore: 2 * 1024 * 1024 * 1024,
      freedBytes: 0,
      deletedCount: 0,
      warning: true,
      insufficient: false,
    );
    await controller.checkStorageForTesting();

    expect(notifications, 1);
  });
}

Future<void> _verifyCleanupReplayAroundRepositoryFailure() async {
  final Directory root = await Directory.systemTemp.createTemp(
    'packing-proof-cleanup-replay-',
  );
  addTearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  final String filePath = '${root.path}/cleaned.mp4';
  final DateTime deletedAt = DateTime.utc(2026, 8, 23, 13);
  final _InterruptingCleanupRepository firstRepository =
      _InterruptingCleanupRepository(
        rootDirectory: root,
        failNextPageCommit: true,
      );
  await firstRepository.addSession(
    RecordingSession(
      id: 'cleanup-replay-session',
      filePath: filePath,
      startedAt: deletedAt.subtract(const Duration(seconds: 2)),
      endedAt: deletedAt.subtract(const Duration(seconds: 1)),
      markers: const <Never>[],
    ),
  );
  final LanBackupCleanupPage page = LanBackupCleanupPage(
    latestRevision: 9,
    nextAfterRevision: 9,
    hasMore: false,
    events: <LanBackupCleanupEvent>[
      LanBackupCleanupEvent(
        revision: 9,
        eventId: 'cleanup-replay-event',
        jobId: 'cleanup-replay-job',
        filePath: filePath,
        fileSizeBytes: 2048,
        deletedAt: deletedAt,
        reason: '已备份录像保留策略清理',
      ),
    ],
  );
  final _RecordingLanBackupSink firstBackup = _RecordingLanBackupSink()
    ..cleanupPages.add(page);
  final PackingSessionController firstController = PackingSessionController(
    repository: firstRepository,
    speechService: _NoopSpeechSink(),
    lanBackupService: firstBackup,
    capabilities: const PlatformCapabilities(<PlatformCapability>{}),
    runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
  );

  await firstController.drainCleanupEventsForTesting();
  expect(await firstRepository.loadBackupCleanupCursor(), 0);
  expect(firstBackup.acknowledgedCleanupRevisions, isEmpty);
  expect(await firstRepository.loadDeleteLogs(), isEmpty);
  await firstController.shutdown();
  firstController.dispose();

  final SessionRepository secondRepository = SessionRepository(
    rootDirectory: root,
  );
  final _RecordingLanBackupSink secondBackup = _RecordingLanBackupSink()
    ..cleanupPages.add(page);
  final PackingSessionController secondController = PackingSessionController(
    repository: secondRepository,
    speechService: _NoopSpeechSink(),
    lanBackupService: secondBackup,
    capabilities: const PlatformCapabilities(<PlatformCapability>{}),
    runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
  );

  await secondController.drainCleanupEventsForTesting();
  expect(await secondRepository.loadBackupCleanupCursor(), 9);
  expect(secondBackup.acknowledgedCleanupRevisions, <int>[9]);
  expect(await secondRepository.loadDeleteLogs(), hasLength(1));
  await secondController.shutdown();
  secondController.dispose();
}

class _BackupCall {
  const _BackupCall({required this.sessionIds, required this.forceRestart});

  final List<String> sessionIds;
  final bool forceRestart;
}

class _InterruptingCleanupRepository extends SessionRepository {
  _InterruptingCleanupRepository({
    required super.rootDirectory,
    required this.failNextPageCommit,
  });

  bool failNextPageCommit;
  int pageCommitCalls = 0;
  int lastPageEventCount = 0;

  @override
  Future<void> recordAutomaticCleanupPage({
    required List<AutomaticCleanupRecord> events,
    required int nextAfterRevision,
  }) async {
    pageCommitCalls++;
    lastPageEventCount = events.length;
    if (failNextPageCommit) {
      failNextPageCommit = false;
      throw StateError('模拟整页事务提交前中断');
    }
    await super.recordAutomaticCleanupPage(
      events: events,
      nextAfterRevision: nextAfterRevision,
    );
  }
}

class _PagedBackupRepository extends SessionRepository {
  _PagedBackupRepository({
    required Directory rootDirectory,
    required this.total,
  }) : testRoot = rootDirectory,
       super(rootDirectory: rootDirectory);

  final int total;
  final Directory testRoot;
  BackupRegistrationCursor? savedCursor;

  @override
  Future<BackupRegistrationCursor?>
  loadBackupRegistrationHighWatermark() async => total == 0
      ? null
      : BackupRegistrationCursor(updatedAt: total, id: 'session-$total');

  @override
  Future<BackupIncrementPage?> loadBackupIncrement({
    required BackupRegistrationCursor? after,
    required BackupRegistrationCursor highWatermark,
    int pageSize = 100,
  }) async {
    final int first = (after?.updatedAt ?? 0) + 1;
    if (first > highWatermark.updatedAt) return null;
    final int candidateLast = first + pageSize - 1;
    final int last = candidateLast < highWatermark.updatedAt
        ? candidateLast
        : highWatermark.updatedAt;
    final DateTime startedAt = DateTime.utc(2026, 8, 23);
    final List<RecordingSession> sessions = <RecordingSession>[
      for (int index = first; index <= last; index++)
        RecordingSession(
          id: 'session-$index',
          filePath: '${testRoot.path}/video-$index.mp4',
          startedAt: startedAt.add(Duration(seconds: index)),
          endedAt: startedAt.add(Duration(seconds: index + 1)),
          markers: const <Never>[],
        ),
    ];
    return BackupIncrementPage(
      sessions: sessions,
      nextAfter: BackupRegistrationCursor(updatedAt: last, id: 'session-$last'),
    );
  }

  @override
  Future<BackupRegistrationCursor?> loadBackupRegistrationCursor() async =>
      savedCursor;

  @override
  Future<void> saveBackupRegistrationCursor(
    BackupRegistrationCursor cursor,
  ) async {
    savedCursor = cursor;
  }
}

/// 给自动重排扫描留出调度时间；扫描本身是后台任务，无法直接 await。
Future<void> _waitForAutoRetrySweep() async {
  for (int attempt = 0; attempt < 20; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _RecordingLanBackupSink extends ChangeNotifier implements LanBackupSink {
  LanBackupSnapshot _snapshot = const LanBackupSnapshot(autoEnabled: false);
  final List<_BackupCall> backupCalls = <_BackupCall>[];
  final List<String> enqueuedPaths = <String>[];
  final List<List<RecordingSession>> enqueuedSessions =
      <List<RecordingSession>>[];
  final List<LanBackupCleanupPage> cleanupPages = <LanBackupCleanupPage>[];
  final List<int> acknowledgedCleanupRevisions = <int>[];
  final Map<String, LanBackupJob> jobsByPath = <String, LanBackupJob>{};
  final List<String> retriedJobIds = <String>[];
  bool failNextCleanupAcknowledgement = false;
  int initializeCalls = 0;
  bool retryConnectionResult = false;
  Future<void>? backupGate;
  Completer<void>? backupStarted;
  int _activeBackupCalls = 0;
  int maximumConcurrentBackupCalls = 0;
  StorageSpaceResult storageResult = const StorageSpaceResult(
    availableBytes: 4 * 1024 * 1024 * 1024,
    availableBytesBefore: 4 * 1024 * 1024 * 1024,
    freedBytes: 0,
    deletedCount: 0,
    warning: false,
    insufficient: false,
  );

  @override
  LanBackupSnapshot get snapshot => _snapshot;

  @override
  Future<void> initialize({
    required bool autoEnabled,
    required UnbackedRetentionPolicy unbackedRetention,
    required BackedRetentionPolicy backedRetention,
    UnbackedRetentionPolicy returnUnbackedRetention =
        UnbackedRetentionPolicy.days3,
    BackedRetentionPolicy returnBackedRetention =
        BackedRetentionPolicy.immediately,
    StoragePressurePolicy storagePressurePolicy =
        StoragePressurePolicy.preserveFootage,
  }) async {
    initializeCalls++;
    _snapshot = _snapshot.copyWith(autoEnabled: autoEnabled);
  }

  @override
  Future<bool> retryConnection() async => retryConnectionResult;

  @override
  Future<void> setAutoEnabled(bool enabled) async {
    _snapshot = _snapshot.copyWith(autoEnabled: enabled);
  }

  @override
  Future<void> backupAll(
    List<RecordingSession> sessions, {
    bool forceRestart = false,
  }) async {
    _activeBackupCalls++;
    maximumConcurrentBackupCalls = max(
      maximumConcurrentBackupCalls,
      _activeBackupCalls,
    );
    backupCalls.add(
      _BackupCall(
        sessionIds: sessions.map((session) => session.id).toList(),
        forceRestart: forceRestart,
      ),
    );
    final Completer<void>? started = backupStarted;
    if (started != null && !started.isCompleted) started.complete();
    try {
      final Future<void>? gate = backupGate;
      if (gate != null) await gate;
    } finally {
      _activeBackupCalls--;
    }
  }

  @override
  Future<void> setRetentionPolicies({
    required UnbackedRetentionPolicy unbacked,
    required BackedRetentionPolicy backed,
    UnbackedRetentionPolicy returnUnbacked = UnbackedRetentionPolicy.days3,
    BackedRetentionPolicy returnBacked = BackedRetentionPolicy.immediately,
    StoragePressurePolicy storagePressurePolicy =
        StoragePressurePolicy.preserveFootage,
  }) async {}

  @override
  Future<void> enqueueFinalizedFile(
    String filePath,
    List<RecordingSession> sessions,
  ) async {
    enqueuedPaths.add(filePath);
    enqueuedSessions.add(List<RecordingSession>.of(sessions));
  }

  @override
  Future<void> enqueueFinalizedFiles(
    Map<String, List<RecordingSession>> grouped, {
    bool startUpload = false,
  }) async {}

  @override
  Future<void> pair(
    String qrValue, {
    LanBackupPairingConfirmation? replacementConfirmation,
  }) async {}

  @override
  Future<void> connectToHost(
    Uri baseUri, {
    LanBackupPairingConfirmation? replacementConfirmation,
  }) async {}

  @override
  void cancelPairing() {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> retry(String jobId) async {
    retriedJobIds.add(jobId);
  }

  @override
  Future<void> cancel(String jobId) async {}

  @override
  Future<LanBackupJobsByPaths> jobsForPaths(Iterable<String> paths) async {
    final List<LanBackupJob> jobs = paths
        .map((String path) => jobsByPath[path])
        .whereType<LanBackupJob>()
        .toList(growable: false);
    return LanBackupJobsByPaths(
      revision: _snapshot.summary.revision,
      jobs: jobs,
      missingPaths: paths.toSet()
        ..removeAll(jobs.map((LanBackupJob job) => job.filePath)),
    );
  }

  /// 模拟原生快照变化（连接状态、自动备份开关）。
  void emitSnapshot({
    bool? autoEnabled,
    LanConnectionStatus? connectionStatus,
  }) {
    _snapshot = _snapshot.copyWith(
      autoEnabled: autoEnabled,
      connectionStatus: connectionStatus,
    );
    notifyListeners();
  }

  @override
  Future<LanBackupCleanupPage> cleanupEvents({
    required int afterRevision,
    int limit = 100,
  }) async => cleanupPages.isEmpty
      ? LanBackupCleanupPage(
          latestRevision: afterRevision,
          nextAfterRevision: afterRevision,
          hasMore: false,
          events: const <LanBackupCleanupEvent>[],
        )
      : cleanupPages.removeAt(0);

  @override
  Future<void> acknowledgeCleanupEvents(int throughRevision) async {
    acknowledgedCleanupRevisions.add(throughRevision);
    if (failNextCleanupAcknowledgement) {
      failNextCleanupAcknowledgement = false;
      throw StateError('模拟确认中断');
    }
  }

  @override
  Future<StorageSpaceResult> checkAndReclaimStorage() async => storageResult;

  @override
  Future<NetworkDiagnostics?> getNetworkDiagnostics() async => null;

  @override
  Future<void> refresh() async {}

  @override
  Future<RemoteRecordingPage> fetchRemoteRecordings({
    required int page,
    required int pageSize,
    String keyword = '',
    RecordingOperationMode? operationMode,
  }) async => const RemoteRecordingPage.empty();

  @override
  Future<Map<int, ({RemoteRecordingStatus status, bool exists, String reason})>>
  fetchRemoteRecordingStatuses(Iterable<int> ids) async =>
      <int, ({RemoteRecordingStatus status, bool exists, String reason})>{};

  @override
  Future<Uri?> resolveRemoteUri(Uri remoteUri) async => null;

  @override
  bool get lastRemoteResolveNeedsRepair => false;

  @override
  Map<String, String> get playbackHeaders => const <String, String>{};

  @override
  Null createRemoteVideoClipService(Uri remoteUri) => null;

  @override
  Future<void> dispose() async {
    super.dispose();
  }
}

class _NoopSpeechSink implements SpeechPromptSink {
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

class _FailingWatermarkSink implements VideoWatermarkSink {
  @override
  Future<String> apply({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    RecordingVideoCodec videoCodec = RecordingVideoCodec.hevc,
  }) {
    throw StateError('watermark failed');
  }
}
