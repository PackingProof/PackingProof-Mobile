import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late String databasePath;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'packing-proof-recording-statistics-',
    );
    databasePath = '${root.path}/recordings.db';
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('增量统计覆盖 upsert、备份清理、恢复、软删除和水印文件替换', () async {
    var now = DateTime(2026, 8, 23, 12);
    final RecordingDatabase database = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
      watermarkOwnerIdForTesting: 'statistics-owner',
      localStatisticsNowForTesting: () => now,
    );
    addTearDown(database.close);
    await database.initialize();

    final RecordingSession today = await _writeSession(
      root,
      id: 'today',
      startedAt: DateTime(2026, 8, 23, 10),
      bytes: const <int>[1, 2, 3],
      watermarkStatus: WatermarkProcessingStatus.pending,
    );
    final RecordingSession older = await _writeSession(
      root,
      id: 'older',
      startedAt: DateTime(2026, 8, 21, 10),
      bytes: const <int>[1, 2, 3, 4, 5],
    );
    await database.upsertSessions(<RecordingSession>[today, older]);
    _expectStatistics(
      await database.loadLocalRecordingStatistics(),
      total: 2,
      today: 1,
      totalBytes: 8,
    );

    final File replacement = File('${root.path}/today-watermarked.mp4');
    await replacement.writeAsBytes(const <int>[1, 2, 3, 4, 5, 6, 7]);
    final WatermarkAttemptClaim claim = (await database
        .claimPendingWatermarkAttempt(
          sessionId: today.id,
          expectedAttempt: 0,
          maximumAttempts: 3,
        ))!;
    expect(claim.claimed, isTrue);
    final RecordingSession watermarked = RecordingSession(
      id: today.id,
      filePath: replacement.path,
      startedAt: today.startedAt,
      endedAt: today.endedAt,
      markers: const <Never>[],
      watermarkStatus: WatermarkProcessingStatus.completed,
      watermarkAttemptCount: 1,
    );
    expect(
      await database.finalizeWatermarkClaim(
        session: watermarked,
        ownerId: claim.ownerId!,
        operationId: claim.operationId!,
      ),
      isNotNull,
    );
    _expectStatistics(
      await database.loadLocalRecordingStatistics(),
      total: 2,
      today: 1,
      totalBytes: 12,
    );

    await database.recordAutomaticCleanup(
      eventId: 'cleanup-today',
      filePath: replacement.path,
      fileSizeBytes: 7,
      deletedAt: now,
      reason: '测试清理',
    );
    await database.recordAutomaticCleanup(
      eventId: 'cleanup-today',
      filePath: replacement.path,
      fileSizeBytes: 7,
      deletedAt: now,
      reason: '重复测试清理',
    );
    // 本机今日统计的是今天录制的单量，电脑校验后清理本机文件不减少今日数，
    // 只有用户主动删除才扣除。
    _expectStatistics(
      await database.loadLocalRecordingStatistics(),
      total: 1,
      today: 1,
      totalBytes: 5,
    );

    final File restored = File('${root.path}/today-restored.mp4');
    await restored.writeAsBytes(await replacement.readAsBytes());
    await database.repairFilePaths(<String, String>{today.id: restored.path});
    _expectStatistics(
      await database.loadLocalRecordingStatistics(),
      total: 2,
      today: 1,
      totalBytes: 12,
    );

    await database.markDeleted(<RecordingSession>[
      watermarked.copyWith(filePath: restored.path),
    ], reason: '测试软删除');
    await database.markDeleted(<RecordingSession>[
      watermarked.copyWith(filePath: restored.path),
    ], reason: '重复测试软删除');
    _expectStatistics(
      await database.loadLocalRecordingStatistics(),
      total: 1,
      today: 0,
      totalBytes: 5,
    );

    await database.upsertSessions(<RecordingSession>[
      watermarked.copyWith(filePath: restored.path),
    ]);
    _expectStatistics(
      await database.loadLocalRecordingStatistics(),
      total: 2,
      today: 1,
      totalBytes: 12,
    );

    await expectLater(
      database.runTransactionForTesting((Transaction txn) async {
        await txn.update(
          'recording_sessions',
          <String, Object?>{'missing_at': now.millisecondsSinceEpoch},
          where: 'id = ?',
          whereArgs: <Object?>[older.id],
        );
        throw StateError('回滚统计测试');
      }),
      throwsStateError,
    );
    _expectStatistics(
      await database.loadLocalRecordingStatistics(),
      total: 2,
      today: 1,
      totalBytes: 12,
    );

    now = DateTime(2026, 8, 24, 1);
    _expectStatistics(
      await database.loadLocalRecordingStatistics(),
      total: 2,
      today: 0,
      totalBytes: 12,
    );
    now = DateTime(2026, 8, 23, 13);
    _expectStatistics(
      await database.loadLocalRecordingStatistics(),
      total: 2,
      today: 1,
      totalBytes: 12,
    );

    final String normalPlan =
        (await database.explainLocalStatisticsQueryForTesting()).join('\n');
    expect(normalPlan, isNot(contains('recording_sessions')));
    final String rolloverPlan =
        (await database.explainTodayStatisticsRebuildForTesting(
          DateTime(2026, 8, 24).millisecondsSinceEpoch,
        )).join('\n');
    expect(rolloverPlan, contains('idx_recording_statistics_today'));
  });

  test('schema v6 升级后按新口径重算今日统计，备份清理不减少', () async {
    final Database legacy = await openDatabase(
      databasePath,
      version: 6,
      onCreate: _createV6Schema,
    );
    final int startedAt = DateTime(2026, 8, 23, 9).millisecondsSinceEpoch;
    await legacy.insert('recording_sessions', <String, Object?>{
      'id': 'legacy-today-backup-cleaned',
      'file_path': '${root.path}/legacy-today.mp4',
      'started_at': startedAt,
      'ended_at': startedAt + 1000,
      'payload_json': '{}',
      'file_size_bytes': 9,
      'created_at': startedAt,
      'updated_at': startedAt,
      'missing_at': startedAt,
    });
    // v6 统计口径会把电脑校验后清理本机文件的记录从今日数里扣掉。
    await legacy.insert('recording_statistics', <String, Object?>{
      'id': 1,
      'total_count': 0,
      'today_count': 0,
      'total_bytes': 0,
      'today_start_ms': DateTime(2026, 8, 23).millisecondsSinceEpoch,
    });
    await legacy.close();

    final RecordingDatabase upgraded = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
      localStatisticsNowForTesting: () => DateTime(2026, 8, 23, 12),
    );
    addTearDown(upgraded.close);
    await upgraded.initialize();
    _expectStatistics(
      await upgraded.loadLocalRecordingStatistics(),
      total: 0,
      today: 1,
      totalBytes: 0,
    );
  });

  test('旧索引迁移只累计实际插入且不会因冲突重复计数', () async {
    final RecordingDatabase database = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
      localStatisticsNowForTesting: () => DateTime(2026, 8, 23, 12),
    );
    addTearDown(database.close);
    await database.initialize();
    final RecordingSession existing = await _writeSession(
      root,
      id: 'existing',
      startedAt: DateTime(2026, 8, 23, 9),
      bytes: const <int>[1, 2],
    );
    final RecordingSession legacy = await _writeSession(
      root,
      id: 'legacy',
      startedAt: DateTime(2026, 8, 22, 9),
      bytes: const <int>[1, 2, 3, 4],
    );
    await database.upsertSessions(<RecordingSession>[existing]);
    final File index = File('${root.path}/recordings.json');
    await index.writeAsString(
      jsonEncode(<Map<String, Object>>[existing.toJson(), legacy.toJson()]),
    );

    await database.migrateLegacyIndex(index);
    _expectStatistics(
      await database.loadLocalRecordingStatistics(),
      total: 2,
      today: 1,
      totalBytes: 6,
    );
  });

  // 五万行播种 + 升级播放在慢的 CI 机器上会超过默认 30 秒，和同类的规模测试一样放宽超时。
  test('schema v4 的五万行升级播种准确且常规统计不扫描录像表', () async {
    const int rowCount = 50000;
    final Database legacy = await openDatabase(
      databasePath,
      version: 4,
      onCreate: _createV4Schema,
    );
    for (var start = 0; start < rowCount; start += 1000) {
      final Batch batch = legacy.batch();
      for (var index = start; index < start + 1000; index++) {
        final int timestamp = DateTime(
          index.isEven ? 2026 : 2025,
          index.isEven ? 8 : 12,
          index.isEven ? 23 : 1,
        ).millisecondsSinceEpoch;
        batch.insert('recording_sessions', <String, Object?>{
          'id': 'session-$index',
          'file_path': '${root.path}/session-$index.mp4',
          'started_at': timestamp,
          'ended_at': timestamp + 1000,
          'payload_json': '{}',
          'file_size_bytes': index + 1,
          'is_deleted': index % 10 == 0 ? 1 : 0,
          'missing_at': index % 5 == 4 ? timestamp : null,
          'created_at': timestamp,
          'updated_at': timestamp,
        });
      }
      await batch.commit(noResult: true);
    }
    await legacy.close();

    final RecordingDatabase database = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
      localStatisticsNowForTesting: () => DateTime(2026, 8, 23, 12),
    );
    addTearDown(database.close);
    await database.initialize();

    var expectedTotal = 0;
    var expectedToday = 0;
    var expectedBytes = 0;
    for (var index = 0; index < rowCount; index++) {
      if (index % 10 == 0) continue;
      if (index.isEven) expectedToday++;
      if (index % 5 == 4) continue;
      expectedTotal++;
      expectedBytes += index + 1;
    }
    _expectStatistics(
      await database.loadLocalRecordingStatistics(),
      total: expectedTotal,
      today: expectedToday,
      totalBytes: expectedBytes,
    );
    final String plan = (await database.explainLocalStatisticsQueryForTesting())
        .join('\n');
    expect(plan, isNot(contains('recording_sessions')));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('升级中断会整体回滚且同版本缺失 trigger 会重新播种修复', () async {
    final Database legacy = await openDatabase(
      databasePath,
      version: 4,
      onCreate: _createV4Schema,
    );
    final int timestamp = DateTime(2026, 8, 23, 9).millisecondsSinceEpoch;
    await legacy.insert('recording_sessions', <String, Object?>{
      'id': 'legacy',
      'file_path': '${root.path}/legacy.mp4',
      'started_at': timestamp,
      'ended_at': timestamp + 1000,
      'payload_json': '{}',
      'file_size_bytes': 9,
      'created_at': timestamp,
      'updated_at': timestamp,
    });
    await legacy.close();

    await expectLater(
      openDatabase(
        databasePath,
        version: 5,
        singleInstance: false,
        onUpgrade: (Database db, int oldVersion, int newVersion) async {
          await db.execute(
            'CREATE TABLE recording_statistics (id INTEGER PRIMARY KEY)',
          );
          throw StateError('模拟升级中断');
        },
      ),
      throwsStateError,
    );
    final Database rolledBack = await openDatabase(
      databasePath,
      singleInstance: false,
    );
    expect(await rolledBack.getVersion(), 4);
    expect(
      await rolledBack.rawQuery(
        "SELECT name FROM sqlite_master WHERE name = 'recording_statistics'",
      ),
      isEmpty,
    );
    await rolledBack.close();

    final RecordingDatabase upgraded = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
      localStatisticsNowForTesting: () => DateTime(2026, 8, 23, 12),
    );
    await upgraded.initialize();
    _expectStatistics(
      await upgraded.loadLocalRecordingStatistics(),
      total: 1,
      today: 1,
      totalBytes: 9,
    );
    await upgraded.close();

    final Database damaged = await openDatabase(
      databasePath,
      singleInstance: false,
    );
    await damaged.execute('DROP TRIGGER trg_recording_statistics_update');
    await damaged.rawUpdate(
      'UPDATE recording_statistics SET total_count = 999',
    );
    await damaged.close();

    final RecordingDatabase repaired = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
      localStatisticsNowForTesting: () => DateTime(2026, 8, 23, 12),
    );
    addTearDown(repaired.close);
    await repaired.initialize();
    _expectStatistics(
      await repaired.loadLocalRecordingStatistics(),
      total: 1,
      today: 1,
      totalBytes: 9,
    );
  });
}

Future<RecordingSession> _writeSession(
  Directory root, {
  required String id,
  required DateTime startedAt,
  required List<int> bytes,
  WatermarkProcessingStatus watermarkStatus =
      WatermarkProcessingStatus.completed,
}) async {
  final File file = File('${root.path}/$id.mp4');
  await file.writeAsBytes(bytes);
  return RecordingSession(
    id: id,
    filePath: file.path,
    startedAt: startedAt,
    endedAt: startedAt.add(const Duration(seconds: 1)),
    markers: const <Never>[],
    watermarkStatus: watermarkStatus,
  );
}

void _expectStatistics(
  LocalRecordingStatistics actual, {
  required int total,
  required int today,
  required int totalBytes,
}) {
  expect(actual.total, total);
  expect(actual.today, today);
  expect(actual.totalBytes, totalBytes);
}

Future<void> _createV6Schema(Database db, int version) async {
  await db.execute('''
    CREATE TABLE recording_sessions (
      id TEXT PRIMARY KEY,
      file_path TEXT NOT NULL,
      started_at INTEGER NOT NULL,
      ended_at INTEGER NOT NULL,
      tracking_number TEXT NOT NULL DEFAULT '',
      order_id TEXT NOT NULL DEFAULT '',
      search_text TEXT NOT NULL DEFAULT '',
      operation_mode TEXT NOT NULL DEFAULT 'shipping',
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
      watermark_attempt_count INTEGER NOT NULL DEFAULT 0,
      watermark_owner_id TEXT NOT NULL DEFAULT '',
      watermark_operation_id TEXT NOT NULL DEFAULT '',
      watermark_claimed_at INTEGER
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
  await db.execute('''
    CREATE TABLE recording_metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE recording_statistics (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      total_count INTEGER NOT NULL,
      today_count INTEGER NOT NULL,
      total_bytes INTEGER NOT NULL,
      today_start_ms INTEGER NOT NULL
    )
  ''');
}

Future<void> _createV4Schema(Database db, int version) async {
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
      watermark_attempt_count INTEGER NOT NULL DEFAULT 0,
      watermark_owner_id TEXT NOT NULL DEFAULT '',
      watermark_operation_id TEXT NOT NULL DEFAULT '',
      watermark_claimed_at INTEGER
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
  await db.execute('''
    CREATE TABLE recording_metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
}
