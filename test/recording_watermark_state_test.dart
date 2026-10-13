import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';
import 'package:packing_proof_mobile/models/recording_orientation.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:sqflite/sqflite.dart';

import 'test_repository.dart';

void main() {
  test('原生实时水印结果映射为最终数据库状态', () {
    expect(
      nativeWatermarkStatus(NativeWatermarkDisposition.completed),
      WatermarkProcessingStatus.completed,
    );
    expect(
      nativeWatermarkStatus(NativeWatermarkDisposition.failedPartial),
      WatermarkProcessingStatus.failed,
    );
    expect(
      nativeWatermarkStatus(NativeWatermarkDisposition.postProcessRequired),
      WatermarkProcessingStatus.pending,
    );
    expect(
      nativeWatermarkNeedsPostProcess(
        NativeWatermarkDisposition.postProcessRequired,
      ),
      isTrue,
    );
    expect(
      nativeWatermarkNeedsPostProcess(NativeWatermarkDisposition.completed),
      isFalse,
    );
    expect(
      nativeWatermarkNeedsPostProcess(NativeWatermarkDisposition.failedPartial),
      isFalse,
    );
  });

  test('关闭添加水印后原生结论一律按已完成成片处理', () {
    for (final NativeWatermarkDisposition disposition
        in NativeWatermarkDisposition.values) {
      expect(
        nativeWatermarkStatus(disposition, watermarkEnabled: false),
        WatermarkProcessingStatus.completed,
      );
      expect(
        nativeWatermarkNeedsPostProcess(disposition, watermarkEnabled: false),
        isFalse,
      );
    }
    expect(
      flutterRecordingWatermarkStatus(watermarkEnabled: false),
      WatermarkProcessingStatus.completed,
    );
    expect(
      flutterRecordingWatermarkStatus(watermarkEnabled: true),
      WatermarkProcessingStatus.pending,
    );
  });

  test('旧数据库迁移后录像默认已完成竖屏水印', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-watermark-migration-',
    );
    final String databasePath = '${root.path}/recordings.db';
    final File video = File('${root.path}/legacy.mp4');
    await video.writeAsBytes(<int>[1, 2, 3]);
    final DateTime startedAt = DateTime.utc(2026, 8, 20, 10);
    final Map<String, Object?> payload = <String, Object?>{
      'id': 'legacy',
      'filePath': video.path,
      'startedAt': startedAt.toIso8601String(),
      'endedAt': startedAt.add(const Duration(seconds: 2)).toIso8601String(),
      'markers': <Object?>[],
    };
    final Database legacy = await openDatabase(
      databasePath,
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE recording_sessions (
            id TEXT PRIMARY KEY,
            file_path TEXT NOT NULL,
            started_at INTEGER NOT NULL,
            ended_at INTEGER NOT NULL,
            tracking_number TEXT NOT NULL DEFAULT '',
            order_id TEXT NOT NULL DEFAULT '',
            search_text TEXT NOT NULL DEFAULT '',
            payload_json TEXT NOT NULL,
            file_size_bytes INTEGER NOT NULL DEFAULT 0,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            deleted_at INTEGER,
            delete_reason TEXT NOT NULL DEFAULT '',
            missing_at INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
      },
    );
    await legacy.insert('recording_sessions', <String, Object?>{
      'id': 'legacy',
      'file_path': video.path,
      'started_at': startedAt.millisecondsSinceEpoch,
      'ended_at': startedAt
          .add(const Duration(seconds: 2))
          .millisecondsSinceEpoch,
      'payload_json': jsonEncode(payload),
      'created_at': startedAt.millisecondsSinceEpoch,
      'updated_at': startedAt.millisecondsSinceEpoch,
    });
    await legacy.close();

    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(() async {
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    await database.initialize();

    final List<RecordingSession> sessions = await database.loadActiveSessions();
    expect(sessions, hasLength(1));
    expect(
      sessions.single.watermarkStatus,
      WatermarkProcessingStatus.completed,
    );
    expect(sessions.single.recordingOrientation, RecordingOrientation.portrait);
    expect(sessions.single.watermarkAttemptCount, 0);
    expect(
      await database.queryBackupRows(
        afterUpdatedAt: null,
        afterId: null,
        highUpdatedAt: null,
        highId: null,
        pageSize: 10,
      ),
      hasLength(1),
    );
  });

  test('水印完成或失败录像进入备份查询且待处理状态可恢复', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-watermark-state-',
    );
    final RecordingDatabase database = RecordingDatabase(
      path: '${root.path}/recordings.db',
    );
    addTearDown(() async {
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    final DateTime startedAt = DateTime.utc(2026, 8, 21, 10);
    final List<RecordingSession> sessions = <RecordingSession>[];
    for (final ({String id, WatermarkProcessingStatus status}) fixture
        in <({String id, WatermarkProcessingStatus status})>[
          (id: 'pending', status: WatermarkProcessingStatus.pending),
          (id: 'completed', status: WatermarkProcessingStatus.completed),
          (id: 'failed', status: WatermarkProcessingStatus.failed),
        ]) {
      final File video = File('${root.path}/${fixture.id}.mp4');
      await video.writeAsBytes(<int>[1, 2, 3]);
      sessions.add(
        RecordingSession(
          id: fixture.id,
          filePath: video.path,
          startedAt: startedAt,
          endedAt: startedAt.add(const Duration(seconds: 2)),
          markers: const <Never>[],
          recordingOrientation: RecordingOrientation.landscapeLeft,
          watermarkStatus: fixture.status,
        ),
      );
    }
    await database.upsertSessions(sessions);

    final List<RecordingBackupRow> backup = await database.queryBackupRows(
      afterUpdatedAt: null,
      afterId: null,
      highUpdatedAt: null,
      highId: null,
      pageSize: 10,
    );
    expect(backup.map((RecordingBackupRow row) => row.id), <String>[
      'completed',
      'failed',
    ]);
    final List<RecordingBackupRow> backupRows = await database.queryBackupRows(
      afterUpdatedAt: null,
      afterId: null,
      highUpdatedAt: null,
      highId: null,
      pageSize: 10,
    );
    expect(backupRows.map((row) => row.id), <String>['completed', 'failed']);
    await database.setUpdatedAtForTesting(id: 'pending', updatedAt: 50);
    await database.setUpdatedAtForTesting(id: 'failed', updatedAt: 60);
    await database.setUpdatedAtForTesting(id: 'completed', updatedAt: 100);
    final ({int updatedAt, String id}) oldHighWatermark = (await database
        .loadBackupHighWatermark())!;
    expect((await database.loadBackupHighWatermark())?.id, 'completed');
    final List<RecordingSession> pending = await database
        .loadPendingWatermarkSessions();
    expect(pending.map((session) => session.id), <String>['pending']);
    expect(
      pending.single.recordingOrientation,
      RecordingOrientation.landscapeLeft,
    );

    final File finalVideo = File('${root.path}/pending-final.mp4');
    await finalVideo.writeAsBytes(<int>[4, 5, 6, 7]);
    await database.upsertSessions(<RecordingSession>[
      pending.single.copyWith(
        filePath: finalVideo.path,
        watermarkStatus: WatermarkProcessingStatus.completed,
        watermarkAttemptCount: 1,
      ),
    ]);
    final RecordingSession finalized = (await database.findActiveByIds(<String>{
      'pending',
    })).single;
    expect(finalized.filePath, finalVideo.path);
    expect(finalized.watermarkStatus, WatermarkProcessingStatus.completed);
    expect(finalized.watermarkAttemptCount, 1);
    final ({int updatedAt, String id}) newHighWatermark = (await database
        .loadBackupHighWatermark())!;
    final List<RecordingBackupRow> increment = await database.queryBackupRows(
      afterUpdatedAt: oldHighWatermark.updatedAt,
      afterId: oldHighWatermark.id,
      highUpdatedAt: newHighWatermark.updatedAt,
      highId: newHighWatermark.id,
      pageSize: 10,
    );
    expect(increment.map((row) => row.id), <String>['pending']);
    final Map<String, Object?> wire = recordingSessionBackupMap(finalized);
    expect(wire, isNot(contains('recordingOrientation')));
    expect(wire, isNot(contains('watermarkStatus')));
    expect(wire, isNot(contains('watermarkAttemptCount')));
  });

  test('重启时待处理水印已达三次则原子标记失败且不再获得导出权', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-watermark-attempt-limit-',
    );
    final RecordingDatabase database = RecordingDatabase(
      path: '${root.path}/recordings.db',
    );
    addTearDown(() async {
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    final File source = File('${root.path}/pending.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final DateTime startedAt = DateTime.utc(2026, 8, 21, 10);
    await database.upsertSessions(<RecordingSession>[
      RecordingSession(
        id: 'attempt-limit',
        filePath: source.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 2)),
        markers: const <Never>[],
        watermarkStatus: WatermarkProcessingStatus.pending,
        watermarkAttemptCount: 3,
      ),
    ]);

    final WatermarkAttemptClaim? claim = await database
        .claimPendingWatermarkAttempt(
          sessionId: 'attempt-limit',
          expectedAttempt: 3,
          maximumAttempts: 3,
        );

    expect(claim, isNotNull);
    expect(claim!.claimed, isFalse);
    expect(claim.exhausted, isTrue);
    expect(claim.session.watermarkStatus, WatermarkProcessingStatus.failed);
    expect(await database.loadPendingWatermarkSessions(), isEmpty);
    expect(await source.exists(), isTrue);
  });

  test('原子 claim 转为 processing 且重启将遗留处理恢复为失败', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-watermark-processing-recovery-',
    );
    final String path = '${root.path}/recordings.db';
    final File source = File('${root.path}/processing.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final RecordingDatabase first = RecordingDatabase(
      path: path,
      watermarkOwnerIdForTesting: 'old-process',
    );
    await first.upsertSessions(<RecordingSession>[
      RecordingSession(
        id: 'processing-recovery',
        filePath: source.path,
        startedAt: DateTime.utc(2026, 8, 21, 10),
        endedAt: DateTime.utc(2026, 8, 21, 10, 0, 1),
        markers: const <Never>[],
        watermarkStatus: WatermarkProcessingStatus.pending,
      ),
    ]);
    final WatermarkAttemptClaim claim = (await first
        .claimPendingWatermarkAttempt(
          sessionId: 'processing-recovery',
          expectedAttempt: 0,
          maximumAttempts: 1,
        ))!;
    expect(claim.claimed, isTrue);
    expect(claim.session.watermarkStatus, WatermarkProcessingStatus.processing);
    expect(
      await first.claimPendingWatermarkAttempt(
        sessionId: 'processing-recovery',
        expectedAttempt: 1,
        maximumAttempts: 1,
      ),
      isNull,
    );
    await first.close();

    final RecordingDatabase reopened = RecordingDatabase(
      path: path,
      watermarkOwnerIdForTesting: 'new-process',
    );
    addTearDown(() async {
      await reopened.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    await reopened.initialize();
    final RecordingSession recovered = (await reopened.findActiveByIds(<String>{
      'processing-recovery',
    })).single;
    expect(recovered.watermarkStatus, WatermarkProcessingStatus.failed);
    expect(await source.exists(), isTrue);
    expect(
      (await reopened.queryBackupRows(
        afterUpdatedAt: null,
        afterId: null,
        highUpdatedAt: null,
        highId: null,
        pageSize: 10,
      )).map((RecordingBackupRow row) => row.id),
      <String>['processing-recovery'],
    );
  });

  test('同进程第二个数据库实例不误恢复或重复领取活跃 processing', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-watermark-same-process-',
    );
    final String path = '${root.path}/recordings.db';
    final File source = File('${root.path}/processing.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final RecordingDatabase first = RecordingDatabase(
      path: path,
      watermarkOwnerIdForTesting: 'same-process',
    );
    final RecordingDatabase second = RecordingDatabase(
      path: path,
      watermarkOwnerIdForTesting: 'same-process',
    );
    addTearDown(() async {
      await first.close();
      await second.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    final RecordingSession pending = RecordingSession(
      id: 'same-process-claim',
      filePath: source.path,
      startedAt: DateTime.utc(2026, 8, 21, 10),
      endedAt: DateTime.utc(2026, 8, 21, 10, 0, 1),
      markers: const <Never>[],
      watermarkStatus: WatermarkProcessingStatus.pending,
    );
    await first.upsertSessions(<RecordingSession>[pending]);
    expect(
      (await first.claimPendingWatermarkAttempt(
        sessionId: pending.id,
        expectedAttempt: 0,
        maximumAttempts: 1,
      ))?.session.watermarkStatus,
      WatermarkProcessingStatus.processing,
    );

    await second.initialize();
    final RecordingSession current = (await second.findActiveByIds(<String>{
      pending.id,
    })).single;
    expect(current.watermarkStatus, WatermarkProcessingStatus.processing);
    expect(
      await second.claimPendingWatermarkAttempt(
        sessionId: pending.id,
        expectedAttempt: 1,
        maximumAttempts: 1,
      ),
      isNull,
    );
  });

  test('失败提交必须匹配 claim owner 与 operation', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-watermark-claim-cas-',
    );
    final RecordingDatabase database = RecordingDatabase(
      path: '${root.path}/recordings.db',
      watermarkOwnerIdForTesting: 'current-process',
    );
    addTearDown(() async {
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    final File source = File('${root.path}/source.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final RecordingSession pending = RecordingSession(
      id: 'claim-cas',
      filePath: source.path,
      startedAt: DateTime.utc(2026, 8, 23, 10),
      endedAt: DateTime.utc(2026, 8, 23, 10, 0, 1),
      markers: const <Never>[],
      watermarkStatus: WatermarkProcessingStatus.pending,
    );
    await database.upsertSessions(<RecordingSession>[pending]);
    final WatermarkAttemptClaim claim = (await database
        .claimPendingWatermarkAttempt(
          sessionId: pending.id,
          expectedAttempt: 0,
          maximumAttempts: 1,
        ))!;

    expect(
      await database.failProcessingWatermark(
        sessionId: pending.id,
        ownerId: 'wrong-owner',
        operationId: claim.operationId!,
      ),
      isNull,
    );
    expect(
      (await database.findActiveByIds(<String>{
        pending.id,
      })).single.watermarkStatus,
      WatermarkProcessingStatus.processing,
    );
    final RecordingSession failed = (await database.failProcessingWatermark(
      sessionId: pending.id,
      ownerId: claim.ownerId!,
      operationId: claim.operationId!,
    ))!;
    expect(failed.watermarkStatus, WatermarkProcessingStatus.failed);
  });

  test('processing 期间已删除记录拒绝迟到完成提交', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-watermark-delete-cas-',
    );
    final RecordingDatabase database = RecordingDatabase(
      path: '${root.path}/recordings.db',
      watermarkOwnerIdForTesting: 'current-process',
    );
    addTearDown(() async {
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    final File source = File('${root.path}/source.mp4');
    final File output = File('${root.path}/output.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    await output.writeAsBytes(<int>[4, 5, 6]);
    final RecordingSession pending = RecordingSession(
      id: 'delete-cas',
      filePath: source.path,
      startedAt: DateTime.utc(2026, 8, 23, 10),
      endedAt: DateTime.utc(2026, 8, 23, 10, 0, 1),
      markers: const <Never>[],
      watermarkStatus: WatermarkProcessingStatus.pending,
    );
    await database.upsertSessions(<RecordingSession>[pending]);
    final WatermarkAttemptClaim claim = (await database
        .claimPendingWatermarkAttempt(
          sessionId: pending.id,
          expectedAttempt: 0,
          maximumAttempts: 1,
        ))!;
    await database.markDeleted(<RecordingSession>[
      claim.session,
    ], reason: 'test');

    expect(
      await database.finalizeWatermarkClaim(
        session: claim.session.copyWith(
          filePath: output.path,
          watermarkStatus: WatermarkProcessingStatus.completed,
        ),
        ownerId: claim.ownerId!,
        operationId: claim.operationId!,
      ),
      isNull,
    );
    expect(await database.findActiveByIds(<String>{pending.id}), isEmpty);
  });

  test('10000 条待处理水印只读取有界批次且命中专用索引', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-watermark-scale-',
    );
    final RecordingDatabase database = RecordingDatabase(
      path: '${root.path}/recordings.db',
    );
    addTearDown(() async {
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    final DateTime startedAt = DateTime.utc(2026, 8, 21, 10);
    for (var start = 0; start < 10000; start += 200) {
      await database.upsertSessions(
        List<RecordingSession>.generate(200, (int offset) {
          final int index = start + offset;
          return RecordingSession(
            id: 'pending-${index.toString().padLeft(5, '0')}',
            filePath: '${root.path}/pending-$index.mp4',
            startedAt: startedAt.add(Duration(milliseconds: index)),
            endedAt: startedAt.add(Duration(milliseconds: index + 1)),
            markers: const <Never>[],
            watermarkStatus: WatermarkProcessingStatus.pending,
          );
        }),
      );
    }

    final List<RecordingSession> first = await database
        .loadPendingWatermarkSessions(limit: 2);
    final List<String> plan = await database
        .explainPendingWatermarkQueryForTesting();

    expect(first.map((RecordingSession session) => session.id), <String>[
      'pending-00000',
      'pending-00001',
    ]);
    final List<RecordingSession> afterFirst = await database
        .loadPendingWatermarkSessions(
          limit: 2,
          afterStartedAt: first.last.startedAt.millisecondsSinceEpoch,
          afterId: first.last.id,
        );
    expect(afterFirst.map((RecordingSession session) => session.id), <String>[
      'pending-00002',
      'pending-00003',
    ]);
    expect(plan.join('\n'), contains('idx_recording_pending_watermark'));
    expect(plan.join('\n').toUpperCase(), isNot(contains('TEMP B-TREE')));
  });
}
