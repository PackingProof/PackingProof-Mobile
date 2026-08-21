import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';
import 'package:packing_proof_mobile/models/recording_orientation.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:sqflite/sqflite.dart';

void main() {
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
      await database.queryBackupBatch(page: 1, pageSize: 10),
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

    final List<RecordingSession> backup = await database.queryBackupBatch(
      page: 1,
      pageSize: 10,
    );
    expect(backup.map((session) => session.id), <String>[
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
}
