import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File source;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'packing-proof-shared-access-',
    );
    source = File('${root.path}/recordings/legacy.mp4');
    await source.create(recursive: true);
    await source.writeAsBytes(<int>[2, 3, 5, 7]);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('真实 v2 库迁移暂停时删除路径别名记录仍保留唯一原片', () async {
    await _seedV2SharedSessions(root, <String>[
      source.path,
      '${source.parent.path}/./legacy.mp4',
    ]);
    final SessionRepository repository = SessionRepository(
      rootDirectory: root,
      availableRecordingStorageBytes: () async => 1 << 50,
    );
    addTearDown(repository.dispose);

    await repository.deleteSessions(<String>{'legacy-0'});

    expect(await source.exists(), isTrue);
    expect(await source.readAsBytes(), <int>[2, 3, 5, 7]);
    expect(
      (await repository.findActiveSessionsByIds(<String>{
        'legacy-1',
      })).single.id,
      'legacy-1',
    );
  });

  test('备份增量入口先把旧共享记录物化为独立文件', () async {
    await _seedSharedSessions(root, <String>[source.path, source.path]);
    final SessionRepository repository = SessionRepository(
      rootDirectory: root,
      availableRecordingStorageBytes: () async => 1 << 50,
    );
    addTearDown(repository.dispose);
    await repository.resumeSharedFileMigration();
    final BackupRegistrationCursor highWatermark = (await repository
        .loadBackupRegistrationHighWatermark())!;

    final BackupIncrementPage page = (await repository.loadBackupIncrement(
      after: null,
      highWatermark: highWatermark,
    ))!;

    expect(page.sessions, hasLength(2));
    expect(
      page.sessions.map((RecordingSession value) => value.filePath).toSet(),
      hasLength(2),
    );
    for (final RecordingSession session in page.sessions) {
      expect(await File(session.filePath).readAsBytes(), <int>[2, 3, 5, 7]);
    }
  });

  test('工作期间暂停迁移不影响已独占文件的录像', () async {
    final File kept = File('${root.path}/recordings/kept.mp4');
    await kept.writeAsBytes(<int>[3, 1, 4, 1, 5]);
    final SessionRepository repository = SessionRepository(rootDirectory: root);
    addTearDown(repository.dispose);
    await repository.initialize();
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 10);
    await repository.addSession(
      RecordingSession(
        id: 'kept',
        filePath: kept.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <Never>[],
      ),
    );
    // 工作期间控制器会暂停旧共享录像迁移，普通录像不能因此取不到原片。
    await repository.pauseSharedFileMigration();

    final RecordingSession prepared = await repository
        .prepareSessionFileForAccess('kept');
    expect(prepared.filePath, kept.path);
    expect(await File(prepared.filePath).exists(), isTrue);
  });

  test('本地已删除的录像不进入备份增量窗口', () async {
    final File kept = File('${root.path}/recordings/kept.mp4');
    final File removed = File('${root.path}/recordings/removed.mp4');
    await kept.writeAsBytes(<int>[3, 1, 4, 1, 5]);
    await removed.writeAsBytes(<int>[2, 7, 1, 8]);
    final SessionRepository repository = SessionRepository(rootDirectory: root);
    addTearDown(repository.dispose);
    await repository.initialize();
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 10);
    await repository.addSessions(<RecordingSession>[
      RecordingSession(
        id: 'kept',
        filePath: kept.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <Never>[],
      ),
      RecordingSession(
        id: 'removed',
        filePath: removed.path,
        startedAt: startedAt.add(const Duration(seconds: 2)),
        endedAt: startedAt.add(const Duration(seconds: 3)),
        markers: const <Never>[],
      ),
    ]);
    await removed.delete();
    await repository.recordAutomaticCleanup(
      eventId: 'cleanup-removed',
      filePath: removed.path,
      fileSizeBytes: 4,
      deletedAt: DateTime.utc(2026, 8, 24, 10),
      reason: '已备份录像保留策略清理',
    );
    final BackupRegistrationCursor highWatermark = (await repository
        .loadBackupRegistrationHighWatermark())!;
    // 已删除的录像不再进入增量窗口，否则游标会永远停在取不到原片的那一页。
    final BackupIncrementPage page = (await repository.loadBackupIncrement(
      after: null,
      highWatermark: highWatermark,
    ))!;
    expect(
      page.sessions.map((RecordingSession session) => session.id),
      <String>['kept'],
    );
  });

  test('原片缺失但记录仍在时全库扫描跳过该条，增量入口仍然类型化失败', () async {
    final File kept = File('${root.path}/recordings/kept.mp4');
    final File ghost = File('${root.path}/recordings/ghost.mp4');
    await kept.writeAsBytes(<int>[3, 1, 4, 1, 5]);
    await ghost.writeAsBytes(<int>[2, 7, 1, 8]);
    final SessionRepository repository = SessionRepository(rootDirectory: root);
    addTearDown(repository.dispose);
    await repository.initialize();
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 10);
    await repository.addSessions(<RecordingSession>[
      RecordingSession(
        id: 'kept',
        filePath: kept.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <Never>[],
      ),
      RecordingSession(
        id: 'ghost',
        filePath: ghost.path,
        startedAt: startedAt.add(const Duration(seconds: 2)),
        endedAt: startedAt.add(const Duration(seconds: 3)),
        markers: const <Never>[],
      ),
    ]);
    // 文件在记录之外被删除（例如旧的清理路径没有留下清理事件）。
    await ghost.delete();
    final BackupRegistrationCursor highWatermark = (await repository
        .loadBackupRegistrationHighWatermark())!;

    await expectLater(
      repository.loadBackupIncrement(after: null, highWatermark: highWatermark),
      throwsA(isA<RecordingFilePreparationException>()),
    );
    final BackupIncrementPage scan = (await repository.loadBackupIncrement(
      after: null,
      highWatermark: highWatermark,
      materializeSessionFiles: false,
      skipUnavailableSessions: true,
    ))!;
    expect(
      scan.sessions.map((RecordingSession session) => session.id),
      <String>['kept'],
    );
  });

  test('备份物化空间不足时类型化失败且不推进为共享路径任务', () async {
    await _seedSharedSessions(root, <String>[source.path, source.path]);
    final SessionRepository repository = SessionRepository(
      rootDirectory: root,
      availableRecordingStorageBytes: () async => 2 * 1024 * 1024 * 1024,
    );
    addTearDown(repository.dispose);
    await repository.resumeSharedFileMigration();
    final BackupRegistrationCursor highWatermark = (await repository
        .loadBackupRegistrationHighWatermark())!;

    await expectLater(
      repository.loadBackupIncrement(after: null, highWatermark: highWatermark),
      throwsA(
        isA<RecordingFilePreparationException>().having(
          (RecordingFilePreparationException value) => value.failure,
          'failure',
          RecordingFilePreparationFailure.storageUnavailable,
        ),
      ),
    );
    expect(await source.readAsBytes(), <int>[2, 3, 5, 7]);
    expect(
      await source.parent
          .list()
          .where((FileSystemEntity value) => value.path.contains('_独立_'))
          .isEmpty,
      isTrue,
    );
  });
}

Future<void> _seedV2SharedSessions(Directory root, List<String> paths) async {
  final Database database = await openDatabase(
    '${root.path}/recordings.db',
    version: 2,
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
          updated_at INTEGER NOT NULL,
          recording_orientation TEXT NOT NULL DEFAULT 'portrait',
          watermark_status TEXT NOT NULL DEFAULT 'completed',
          watermark_attempt_count INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE recording_delete_logs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          file_path TEXT NOT NULL,
          session_id TEXT NOT NULL DEFAULT '',
          tracking_number TEXT NOT NULL DEFAULT '',
          file_size_bytes INTEGER NOT NULL DEFAULT 0,
          deleted_at INTEGER NOT NULL,
          reason TEXT NOT NULL DEFAULT ''
        )
      ''');
    },
  );
  final DateTime startedAt = DateTime.utc(2026, 8, 23, 8);
  for (var index = 0; index < paths.length; index++) {
    final RecordingSession session = RecordingSession(
      id: 'legacy-$index',
      filePath: paths[index],
      startedAt: startedAt.add(Duration(seconds: index)),
      endedAt: startedAt.add(Duration(seconds: index + 1)),
      markers: const <Never>[],
    );
    await database.insert('recording_sessions', <String, Object?>{
      'id': session.id,
      'file_path': session.filePath,
      'started_at': session.startedAt.millisecondsSinceEpoch,
      'ended_at': session.endedAt.millisecondsSinceEpoch,
      'payload_json': jsonEncode(session.toJson()),
      'file_size_bytes': await File(paths[index]).length(),
      'created_at': index + 1,
      'updated_at': index + 1,
    });
  }
  await database.close();
}

Future<void> _seedSharedSessions(Directory root, List<String> paths) async {
  final SessionRepository created = SessionRepository(
    rootDirectory: root,
    sharedFileMigrationAllowed: () => false,
  );
  await created.initialize();
  await created.dispose();
  final Database database = await databaseFactory.openDatabase(
    '${root.path}/recordings.db',
    options: OpenDatabaseOptions(singleInstance: false),
  );
  final DateTime startedAt = DateTime.utc(2026, 8, 23, 8);
  await database.transaction((Transaction txn) async {
    await txn.delete(
      'recording_metadata',
      where: 'key IN (?, ?, ?)',
      whereArgs: const <Object?>[
        'shared_file_materialization_v1',
        'shared_file_materialization_cursor_v1',
        'recording_file_owners_ready_v1',
      ],
    );
    await txn.delete('recording_file_owners');
    for (var index = 0; index < paths.length; index++) {
      final RecordingSession session = RecordingSession(
        id: 'legacy-$index',
        filePath: paths[index],
        startedAt: startedAt.add(Duration(seconds: index)),
        endedAt: startedAt.add(Duration(seconds: index + 1)),
        markers: const <Never>[],
      );
      await txn.insert('recording_sessions', <String, Object?>{
        'id': session.id,
        'file_path': session.filePath,
        'started_at': session.startedAt.millisecondsSinceEpoch,
        'ended_at': session.endedAt.millisecondsSinceEpoch,
        'payload_json': jsonEncode(session.toJson()),
        'created_at': index + 1,
        'updated_at': index + 1,
      });
    }
  });
  await database.close();
}
