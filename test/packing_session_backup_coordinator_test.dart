import 'dart:io';

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
    await repository.addSessions(<RecordingSession>[
      RecordingSession(
        id: 'backup-one',
        filePath: '${root.path}/backup-one.mp4',
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <Never>[],
      ),
      RecordingSession(
        id: 'backup-two',
        filePath: '${root.path}/backup-two.mp4',
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
    Future<void>? shutdown;
    final List<String> firstRunIds = <String>[];
    await firstController.processStartupBackupIncrementForTesting((page) async {
      firstRunIds.addAll(page.map((session) => session.id));
      shutdown ??= firstController.shutdown();
    });
    await shutdown!;
    expect(firstRunIds, hasLength(100));

    final SessionRepository verifier = SessionRepository(rootDirectory: root);
    expect(await verifier.loadBackupRegistrationCursor(), isNull);
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
    final List<String> secondRunIds = <String>[];
    await secondController.processStartupBackupIncrementForTesting((
      page,
    ) async {
      secondRunIds.addAll(page.map((session) => session.id));
    });
    expect(secondRunIds, hasLength(101));
    expect(await secondRepository.loadBackupRegistrationCursor(), isNotNull);
    await secondController.shutdown();
    secondController.dispose();
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
}

class _BackupCall {
  const _BackupCall({required this.sessionIds, required this.forceRestart});

  final List<String> sessionIds;
  final bool forceRestart;
}

class _RecordingLanBackupSink extends ChangeNotifier implements LanBackupSink {
  LanBackupSnapshot _snapshot = const LanBackupSnapshot(autoEnabled: false);
  final List<_BackupCall> backupCalls = <_BackupCall>[];
  final List<String> enqueuedPaths = <String>[];
  final List<List<RecordingSession>> enqueuedSessions =
      <List<RecordingSession>>[];
  int initializeCalls = 0;
  bool retryConnectionResult = false;

  @override
  LanBackupSnapshot get snapshot => _snapshot;

  @override
  Future<void> initialize({
    required bool autoEnabled,
    required UnbackedRetentionPolicy unbackedRetention,
    required BackedRetentionPolicy backedRetention,
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
    backupCalls.add(
      _BackupCall(
        sessionIds: sessions.map((session) => session.id).toList(),
        forceRestart: forceRestart,
      ),
    );
  }

  @override
  Future<void> setRetentionPolicies({
    required UnbackedRetentionPolicy unbacked,
    required BackedRetentionPolicy backed,
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
  Future<void> retry(String jobId) async {}

  @override
  Future<void> cancel(String jobId) async {}

  @override
  Future<StorageSpaceResult> checkAndReclaimStorage() async =>
      const StorageSpaceResult(
        availableBytes: 0,
        availableBytesBefore: 0,
        freedBytes: 0,
        deletedCount: 0,
        warning: false,
        insufficient: false,
      );

  @override
  Future<NetworkDiagnostics?> getNetworkDiagnostics() async => null;

  @override
  Future<void> refresh() async {}

  @override
  Future<RemoteRecordingPage> fetchRemoteRecordings({
    required int page,
    required int pageSize,
    String keyword = '',
  }) async => const RemoteRecordingPage.empty();

  @override
  Future<Map<int, ({RemoteRecordingStatus status, bool exists, String reason})>>
  fetchRemoteRecordingStatuses(Iterable<int> ids) async =>
      <int, ({RemoteRecordingStatus status, bool exists, String reason})>{};

  @override
  Future<Uri?> resolveRemoteUri(Uri remoteUri) async => null;

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
