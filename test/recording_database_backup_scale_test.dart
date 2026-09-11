import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late String databasePath;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'packing-proof-recording-backup-scale-',
    );
    databasePath = '${root.path}/recordings.db';
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('keyset SQL 兼容 Android API 24 的 SQLite 3.9', () {
    final String source = File(
      'lib/services/recording_database.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('(started_at, id) >')));
    expect(source, isNot(contains('(started_at, id) <')));
    expect(source, isNot(contains('(updated_at, id) >')));
    expect(source, isNot(contains('(updated_at, id) <')));
    expect(source, contains('updated_at >= ?'));
    expect(source, contains('(updated_at > ? OR id > ?)'));
    expect(source, contains('updated_at <= ?'));
    expect(source, contains('(updated_at < ? OR id <= ?)'));
  });

  test('v2 数据库升级到 v5 时创建迁移、统计、备份与水印结构', () async {
    final File source = File('${root.path}/legacy.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    await _createV2Database(databasePath, sourcePath: source.path);

    final RecordingDatabase upgraded = RecordingDatabase(path: databasePath);
    addTearDown(upgraded.close);
    await upgraded.initialize();

    final Database raw = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(raw.close);
    expect(await raw.getVersion(), 6);
    final List<Map<String, Object?>> schema = await raw.rawQuery(
      "SELECT type, name, sql FROM sqlite_master "
      "WHERE name IN ('recording_metadata', 'recording_file_owners', "
      "'recording_statistics', 'idx_recording_backup_cursor', "
      "'idx_recording_pending_watermark', 'idx_recording_statistics_today', "
      "'trg_recording_statistics_insert', "
      "'trg_recording_statistics_delete', "
      "'trg_recording_statistics_update') "
      'ORDER BY name',
    );
    expect(schema.map((Map<String, Object?> row) => row['name']), <Object?>[
      'idx_recording_backup_cursor',
      'idx_recording_pending_watermark',
      'idx_recording_statistics_today',
      'recording_file_owners',
      'recording_metadata',
      'recording_statistics',
      'trg_recording_statistics_delete',
      'trg_recording_statistics_insert',
      'trg_recording_statistics_update',
    ]);
    expect(
      schema.first['sql'].toString(),
      contains("watermark_status IN ('completed', 'failed')"),
    );
    final List<Map<String, Object?>> columns = await raw.rawQuery(
      'PRAGMA table_info(recording_sessions)',
    );
    expect(
      columns.map((Map<String, Object?> row) => row['name']),
      containsAll(<String>[
        'watermark_owner_id',
        'watermark_operation_id',
        'watermark_claimed_at',
      ]),
    );
    final RecordingSession preserved = (await upgraded.findActiveByIds(<String>{
      'legacy-session',
    })).single;
    expect(preserved.filePath, source.path);
    expect(preserved.displayCode, 'LEGACY-TRACKING');
    expect(preserved.watermarkStatus, WatermarkProcessingStatus.completed);
    expect(await source.readAsBytes(), <int>[1, 2, 3]);
    final LocalRecordingStatistics statistics = await upgraded
        .loadLocalRecordingStatistics();
    expect(statistics.total, 1);
    expect(statistics.totalBytes, 3);
  });

  test(
    '50000 条 keyset 分页无重复遗漏且查询计划使用游标索引',
    () async {
      final RecordingDatabase created = RecordingDatabase(path: databasePath);
      await created.initialize();
      await created.close();
      await _seedBackupRows(databasePath, count: 50000);

      final RecordingDatabase database = RecordingDatabase(path: databasePath);
      addTearDown(database.close);
      await database.initialize();
      final List<String> initialPlan = await database
          .explainBackupCursorQueryForTesting();
      final List<String> cursorPlan = await database
          .explainBackupCursorQueryForTesting(
            afterUpdatedAt: 25000,
            afterId: '',
          );
      expect(
        <String>[...initialPlan, ...cursorPlan].join('\n'),
        contains('idx_recording_backup_cursor'),
      );

      final ({int updatedAt, String id}) highWatermark = (await database
          .loadBackupHighWatermark())!;
      int? afterUpdatedAt;
      String? afterId;
      var count = 0;
      String? previousId;
      while (true) {
        final List<RecordingBackupRow> page = await database.queryBackupRows(
          afterUpdatedAt: afterUpdatedAt,
          afterId: afterId,
          highUpdatedAt: highWatermark.updatedAt,
          highId: highWatermark.id,
          pageSize: 1000,
        );
        if (page.isEmpty) break;
        for (final RecordingBackupRow row in page) {
          if (previousId != null) {
            expect(row.id.compareTo(previousId), greaterThan(0));
          }
          previousId = row.id;
        }
        count += page.length;
        afterUpdatedAt = page.last.updatedAt;
        afterId = page.last.id;
      }

      expect(count, 50000);
      expect(previousId, 'session-049999');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _createV2Database(
  String path, {
  required String sourcePath,
}) async {
  final DateTime startedAt = DateTime.utc(2026, 1, 1);
  final RecordingSession session = RecordingSession(
    id: 'legacy-session',
    filePath: sourcePath,
    startedAt: startedAt,
    endedAt: startedAt.add(const Duration(seconds: 1)),
    markers: <BarcodeMarker>[
      BarcodeMarker(
        code: 'LEGACY-TRACKING',
        occurredAt: startedAt,
        offset: Duration.zero,
      ),
    ],
  );
  final Database database = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 2,
      singleInstance: false,
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
    ),
  );
  final int now = DateTime.now().millisecondsSinceEpoch;
  await database.insert('recording_sessions', <String, Object?>{
    'id': session.id,
    'file_path': session.filePath,
    'started_at': session.startedAt.millisecondsSinceEpoch,
    'ended_at': session.endedAt.millisecondsSinceEpoch,
    'tracking_number': 'LEGACY-TRACKING',
    'search_text': 'legacy-tracking',
    'payload_json': jsonEncode(session.toJson()),
    'file_size_bytes': 3,
    'created_at': now,
    'updated_at': now,
    'recording_orientation': 'portrait',
    'watermark_status': 'completed',
    'watermark_attempt_count': 0,
  });
  await database.close();
}

Future<void> _seedBackupRows(String path, {required int count}) async {
  final Database db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  final String payload = jsonEncode(
    RecordingSession(
      id: 'fixture',
      filePath: '/recordings/fixture.mp4',
      startedAt: DateTime.utc(2026, 1, 1),
      endedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
      markers: const <Never>[],
    ).toJson(),
  );
  for (var start = 0; start < count; start += 5000) {
    final Batch batch = db.batch();
    final int end = (start + 5000).clamp(0, count);
    for (var index = start; index < end; index++) {
      final String id = 'session-${index.toString().padLeft(6, '0')}';
      batch.rawInsert(
        'INSERT INTO recording_sessions('
        'id,file_path,started_at,ended_at,payload_json,created_at,updated_at'
        ') VALUES(?,?,?,?,?,?,?)',
        <Object?>[
          id,
          '/recordings/$id.mp4',
          index,
          index + 1,
          payload,
          index,
          index,
        ],
      );
    }
    await batch.commit(noResult: true);
  }
  await db.close();
}
