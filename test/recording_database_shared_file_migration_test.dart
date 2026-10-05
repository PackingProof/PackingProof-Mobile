import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:packing_proof_mobile/models/backup_storage_policy.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/recording_database.dart'
    as production;
import 'package:sqflite/sqflite.dart';

import 'test_repository.dart';

class RecordingDatabase extends production.RecordingDatabase {
  RecordingDatabase({
    required super.path,
    super.startSharedFileMigrationWorker,
    super.sharedFileMigrationAllowed,
    Future<int?> Function(String path)? availableStorageBytesForMigration,
    super.sharedFileMigrationDelay = Duration.zero,
    super.beforeSharedFileMigrationRowForTesting,
    super.beforeExclusiveMaterializationCreateForTesting,
    super.beforeSharedFileCopyChunkForTesting,
    super.afterDatabaseOpenForTesting,
  }) : super(
         availableStorageBytesForMigration:
             availableStorageBytesForMigration ?? (_) async => 1 << 50,
       );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late String databasePath;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'packing-proof-recording-scale-',
    );
    databasePath = '${root.path}/recordings.db';
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('close 与首次 open 竞争时关闭未发布连接且可安全重开', () async {
    final Completer<void> firstOpenReached = Completer<void>();
    final Completer<void> releaseFirstOpen = Completer<void>();
    var openCount = 0;
    final RecordingDatabase database = RecordingDatabase(
      path: databasePath,
      afterDatabaseOpenForTesting: () async {
        openCount++;
        if (openCount != 1) return;
        firstOpenReached.complete();
        await releaseFirstOpen.future;
      },
    );

    final Future<void> initialization = database.initialize();
    await firstOpenReached.future;
    final Future<void> firstClose = database.close();
    final Future<void> secondClose = database.close();
    expect(identical(firstClose, secondClose), isTrue);
    await expectLater(database.initialize(), throwsStateError);

    releaseFirstOpen.complete();
    await expectLater(initialization, throwsStateError);
    await firstClose;

    await database.initialize();
    expect(openCount, 2);
    await database.close();
  });

  test('完成迁移后的 10000 条启动不读取录像 payload', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    await _seedBackupRows(
      databasePath,
      count: 10000,
      payloadJson: '{invalid-json',
    );
    final Database completed = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    for (final String key in <String>[
      'shared_file_materialization_v1',
      'recording_file_owners_ready_v1',
    ]) {
      await completed.insert('recording_metadata', <String, Object?>{
        'key': key,
        'value': 'complete',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await completed.close();

    final RecordingDatabase reopened = RecordingDatabase(path: databasePath);
    addTearDown(reopened.close);

    // 若 initialize 仍做全表共享文件扫描，这里的非法 payload 会在首行解码失败。
    await reopened.initialize();
  });

  test('未完成迁移的 10000 条初始化只读标记且不复制或解析 payload', () async {
    final RecordingDatabase created = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
    );
    await created.initialize();
    await created.close();
    await _seedBackupRows(
      databasePath,
      count: 10000,
      payloadJson: '{invalid-json',
    );
    final Database incomplete = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await incomplete.delete(
      'recording_metadata',
      where: 'key IN (?, ?)',
      whereArgs: const <Object?>[
        'shared_file_materialization_v1',
        'recording_file_owners_ready_v1',
      ],
    );
    await incomplete.close();

    var visitedRows = 0;
    final RecordingDatabase database = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
      beforeSharedFileMigrationRowForTesting: (_) async {
        visitedRows++;
        throw StateError('initialize 不得进入录像迁移行');
      },
    );
    addTearDown(database.close);

    await database.initialize().timeout(const Duration(seconds: 1));

    expect(visitedRows, 0);
    expect(
      await database.readMetadataValue('shared_file_materialization_v1'),
      isNull,
    );
    expect(
      await database.readMetadataValue('shared_file_materialization_cursor_v1'),
      isNull,
    );
  });

  test('空间不足时保留 intent 游标源文件与记录且不留下部分副本', () async {
    final File source = File('${root.path}/low-space-source.mp4');
    await source.writeAsBytes(<int>[1, 2, 3, 4]);
    await _seedSharedSessions(databasePath, source, <String>[
      'first',
      'second',
    ]);
    // 刚好差 1 字节到「空间不足」门槛，门槛值跟着策略常量走。
    final int available =
        BackupStoragePolicy.minimumBytes + source.lengthSync() - 1;
    final RecordingDatabase database = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
      availableStorageBytesForMigration: (_) async => available,
    );
    addTearDown(database.close);
    await database.initialize();

    expect(await database.materializeSharedFileForSession('first'), isTrue);
    expect(await database.materializeSharedFileForSession('second'), isFalse);

    expect(await source.readAsBytes(), <int>[1, 2, 3, 4]);
    final List<RecordingSession> sessions = await database.loadActiveSessions();
    expect(sessions, hasLength(2));
    expect(sessions.map((value) => value.filePath).toSet(), <String>{
      source.path,
    });
    expect(
      await database.readMetadataValue(
        'shared_file_materialization_intent_v1:${base64Url.encode(utf8.encode('second'))}',
      ),
      isNotNull,
    );
    expect(
      await database.readMetadataValue('shared_file_materialization_cursor_v1'),
      isNull,
    );
    expect(
      root.listSync().whereType<File>().where(
        (File file) => file.path.contains('_独立_'),
      ),
      isEmpty,
    );
  });

  test('工作录像门控暂停后台迁移并可在空闲后显式续跑', () async {
    final File source = File('${root.path}/working-gate-source.mp4');
    await source.writeAsBytes(<int>[2, 4, 6, 8]);
    await _seedSharedSessions(databasePath, source, <String>[
      'first',
      'second',
    ]);
    var working = true;
    var visitedRows = 0;
    final RecordingDatabase database = RecordingDatabase(
      path: databasePath,
      sharedFileMigrationAllowed: () => !working,
      beforeSharedFileMigrationRowForTesting: (_) async {
        visitedRows++;
      },
    );
    addTearDown(database.close);

    await database.initialize();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(visitedRows, 0);
    expect(
      (await database.loadActiveSessions())
          .map((value) => value.filePath)
          .toSet(),
      <String>{source.path},
    );
    expect(
      await database.readMetadataValue('shared_file_materialization_v1'),
      isNull,
    );

    working = false;
    await database.resumeSharedFileMigration();
    await database.drainSharedFileMigrationForTesting();

    expect(visitedRows, 2);
    expect(
      (await database.loadActiveSessions())
          .map((value) => value.filePath)
          .toSet(),
      hasLength(2),
    );
    final production.LocalRecordingStatistics statistics = await database
        .loadLocalRecordingStatistics();
    expect(statistics.total, 2);
    expect(statistics.totalBytes, source.lengthSync());
  });

  test('复制钩子挂起时暂停有界返回且不再写入下一分块', () async {
    final File source = File('${root.path}/pause-source.mp4');
    await source.writeAsBytes(List<int>.filled(2 * 1024 * 1024, 9));
    await _seedSharedSessions(databasePath, source, <String>[
      'first',
      'second',
    ]);
    var working = false;
    var copyChunks = 0;
    final Completer<void> firstChunk = Completer<void>();
    final Completer<void> blocked = Completer<void>();
    final RecordingDatabase database = RecordingDatabase(
      path: databasePath,
      sharedFileMigrationAllowed: () => !working,
      sharedFileMigrationDelay: Duration.zero,
      beforeSharedFileCopyChunkForTesting: () async {
        copyChunks++;
        if (!firstChunk.isCompleted) firstChunk.complete();
        await blocked.future;
      },
    );
    addTearDown(database.close);

    await database.initialize();
    await firstChunk.future.timeout(const Duration(seconds: 1));
    working = true;
    final Stopwatch stopwatch = Stopwatch()..start();
    await database.pauseSharedFileMigration();
    stopwatch.stop();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(copyChunks, 1);
    expect(await source.exists(), isTrue);
    expect(
      (await database.loadActiveSessions())
          .map((RecordingSession value) => value.filePath)
          .toSet(),
      <String>{source.path},
    );
    expect(
      root.listSync().whereType<File>().where(
        (File file) => file.path.contains('_独立_'),
      ),
      isEmpty,
    );
    expect(
      await database.readMetadataValue(
        'shared_file_materialization_intent_v1:${base64Url.encode(utf8.encode('second'))}',
      ),
      isNotNull,
    );
  });

  test('分块复制中 close 有界结束且重启可从 intent 恢复', () async {
    final File source = File('${root.path}/shutdown-source.mp4');
    await source.writeAsBytes(List<int>.filled(2 * 1024 * 1024, 7));
    await _seedSharedSessions(databasePath, source, <String>[
      'first',
      'second',
    ]);
    final Completer<void> copyStarted = Completer<void>();
    final Completer<void> neverRelease = Completer<void>();
    final RecordingDatabase interrupted = RecordingDatabase(
      path: databasePath,
      sharedFileMigrationDelay: Duration.zero,
      availableStorageBytesForMigration: (_) async => 1 << 50,
      beforeSharedFileCopyChunkForTesting: () async {
        if (!copyStarted.isCompleted) copyStarted.complete();
        await neverRelease.future;
      },
    );
    await interrupted.initialize();
    await copyStarted.future.timeout(const Duration(seconds: 2));

    await interrupted.close().timeout(const Duration(seconds: 1));

    expect(await source.exists(), isTrue);
    expect(
      root.listSync().whereType<File>().where(
        (File file) => file.path.contains('_独立_'),
      ),
      isEmpty,
    );
    final Database afterClose = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    expect(
      Sqflite.firstIntValue(
        await afterClose.rawQuery(
          'SELECT COUNT(1) FROM recording_sessions WHERE is_deleted = 0',
        ),
      ),
      2,
    );
    expect(
      await _metadataValue(
        afterClose,
        'shared_file_materialization_intent_v1:${base64Url.encode(utf8.encode('second'))}',
      ),
      isNotNull,
    );
    await afterClose.close();

    final RecordingDatabase recovered = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
      availableStorageBytesForMigration: (_) async => 1 << 50,
    );
    addTearDown(recovered.close);
    await recovered.initialize();
    await recovered.drainSharedFileMigrationForTesting();

    final List<RecordingSession> recoveredSessions = await recovered
        .loadActiveSessions();
    expect(
      recoveredSessions.map((value) => value.filePath).toSet(),
      hasLength(2),
    );
    expect(await source.readAsBytes(), List<int>.filled(2 * 1024 * 1024, 7));
    expect(
      await recovered.readMetadataValue('shared_file_materialization_v1'),
      isNotNull,
    );
    expect(
      await recovered.readMetadataValue(
        'shared_file_materialization_intent_v1:${base64Url.encode(utf8.encode('second'))}',
      ),
      isNull,
    );
  });

  test('旧共享文件迁移每批最多处理一条并跨重启续接 checkpoint', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final File source = File('${root.path}/bounded-source.mp4');
    await source.writeAsBytes(<int>[1, 2, 3, 4]);
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 8);
    final Database seed = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await seed.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key IN (?, ?)',
        whereArgs: <Object?>[
          'shared_file_materialization_v1',
          'shared_file_materialization_cursor_v1',
        ],
      );
      await txn.delete('recording_file_owners');
      for (var index = 0; index < 205; index++) {
        await _insertSession(
          txn,
          RecordingSession(
            id: 'bounded-${index.toString().padLeft(3, '0')}',
            filePath: source.path,
            startedAt: startedAt.add(Duration(seconds: index)),
            endedAt: startedAt.add(Duration(seconds: index + 1)),
            markers: const <Never>[],
          ),
          updatedAt: index,
        );
      }
      // 第 3 条不属于前两个显式批次；非法 payload 可证明批次没有越界。
      await txn.update(
        'recording_sessions',
        <String, Object?>{'payload_json': '{invalid-json'},
        where: 'id = ?',
        whereArgs: <Object?>['bounded-002'],
      );
    });
    await seed.close();

    final RecordingDatabase first = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
    );
    await first.initialize();
    expect(await first.runSharedFileMigrationBatchForTesting(), isTrue);
    await first.close();
    final Database afterFirst = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    expect(
      Sqflite.firstIntValue(
        await afterFirst.rawQuery(
          'SELECT COUNT(DISTINCT file_path) FROM recording_sessions',
        ),
      ),
      1,
    );
    expect(
      await _metadataValue(afterFirst, 'shared_file_materialization_cursor_v1'),
      contains('bounded-000'),
    );
    expect(
      await _metadataValue(afterFirst, 'shared_file_materialization_v1'),
      isNull,
    );
    await afterFirst.update(
      'recording_sessions',
      <String, Object?>{
        'payload_json': jsonEncode(
          RecordingSession(
            id: 'bounded-002',
            filePath: source.path,
            startedAt: startedAt.add(const Duration(seconds: 2)),
            endedAt: startedAt.add(const Duration(seconds: 3)),
            markers: const <Never>[],
          ).toJson(),
        ),
      },
      where: 'id = ?',
      whereArgs: <Object?>['bounded-002'],
    );
    await afterFirst.close();

    final RecordingDatabase second = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
    );
    await second.initialize();
    expect(await second.runSharedFileMigrationBatchForTesting(), isTrue);
    await second.close();
    final Database afterSecond = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    expect(
      Sqflite.firstIntValue(
        await afterSecond.rawQuery(
          'SELECT COUNT(DISTINCT file_path) FROM recording_sessions',
        ),
      ),
      2,
    );
    expect(
      await _metadataValue(
        afterSecond,
        'shared_file_materialization_cursor_v1',
      ),
      contains('bounded-001'),
    );
    await afterSecond.close();

    final RecordingDatabase third = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
    );
    await third.initialize();
    await third.drainSharedFileMigrationForTesting();
    await third.close();
    final Database completed = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(completed.close);
    expect(
      Sqflite.firstIntValue(
        await completed.rawQuery(
          'SELECT COUNT(DISTINCT file_path) FROM recording_sessions',
        ),
      ),
      205,
    );
    expect(
      await _metadataValue(completed, 'shared_file_materialization_v1'),
      isNotNull,
    );
    expect(
      await _metadataValue(completed, 'shared_file_materialization_cursor_v1'),
      isNull,
    );
    expect(await source.readAsBytes(), <int>[1, 2, 3, 4]);
  });

  test('规范化后等价的旧路径别名不会漏过物化或误写完成标记', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final File source = File(p.join(root.path, 'alias', 'video.mp4'));
    await source.create(recursive: true);
    await source.writeAsBytes(<int>[8, 6, 7, 5]);
    final String aliasPath = p.join(root.path, 'alias', '.', 'video.mp4');
    expect(p.normalize(aliasPath), source.path);
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 9);
    final Database seed = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await seed.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key = ?',
        whereArgs: <Object?>['shared_file_materialization_v1'],
      );
      await txn.delete('recording_file_owners');
      await _insertSession(
        txn,
        RecordingSession(
          id: 'alias-first',
          filePath: source.path,
          startedAt: startedAt,
          endedAt: startedAt.add(const Duration(seconds: 1)),
          markers: const <Never>[],
        ),
        updatedAt: 1,
      );
      await _insertSession(
        txn,
        RecordingSession(
          id: 'alias-second',
          filePath: aliasPath,
          startedAt: startedAt.add(const Duration(seconds: 1)),
          endedAt: startedAt.add(const Duration(seconds: 2)),
          markers: const <Never>[],
        ),
        updatedAt: 2,
      );
    });
    await seed.close();

    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    await database.initialize();
    await database.drainSharedFileMigrationForTesting();
    final List<RecordingSession> sessions = await database.loadActiveSessions();

    expect(
      sessions
          .map((RecordingSession value) => p.normalize(value.filePath))
          .toSet(),
      hasLength(2),
    );
    expect(
      await database.readMetadataValue('shared_file_materialization_v1'),
      isNotNull,
    );
    expect(await source.readAsBytes(), <int>[8, 6, 7, 5]);
  });

  test('单次进程由唯一后台 worker 分批完成迁移', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 10);
    final Database seed = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await seed.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key IN (?, ?, ?)',
        whereArgs: <Object?>[
          'shared_file_materialization_v1',
          'shared_file_materialization_cursor_v1',
          'recording_file_owners_ready_v1',
        ],
      );
      await txn.delete('recording_file_owners');
      for (var index = 0; index < 250; index++) {
        await _insertSession(
          txn,
          RecordingSession(
            id: 'worker-${index.toString().padLeft(3, '0')}',
            filePath: '${root.path}/worker-$index.mp4',
            startedAt: startedAt.add(Duration(seconds: index)),
            endedAt: startedAt.add(Duration(seconds: index + 1)),
            markers: const <Never>[],
          ),
          updatedAt: index,
        );
      }
    });
    await seed.close();

    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    await database.initialize();
    await Future.wait<void>(
      List<Future<void>>.generate(10, (_) => database.initialize()),
    );
    await database.drainSharedFileMigrationForTesting();

    expect(
      await database.readMetadataValue('shared_file_materialization_v1'),
      isNotNull,
    );
    final Database raw = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(raw.close);
    expect(
      Sqflite.firstIntValue(
        await raw.rawQuery('SELECT COUNT(*) FROM recording_file_owners'),
      ),
      250,
    );
  });

  test('正常 upsert 原子拒绝规范化后与既有记录相同的路径别名', () async {
    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    await database.initialize();
    final File source = File('${root.path}/upsert/video.mp4');
    await source.create(recursive: true);
    await source.writeAsBytes(<int>[2, 7, 1, 8]);
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 11);
    await database.upsertSessions(<RecordingSession>[
      RecordingSession(
        id: 'upsert-owner',
        filePath: source.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <Never>[],
      ),
    ]);

    await expectLater(
      database.upsertSessions(<RecordingSession>[
        RecordingSession(
          id: 'upsert-alias',
          filePath: '${root.path}/upsert/./video.mp4',
          startedAt: startedAt.add(const Duration(seconds: 1)),
          endedAt: startedAt.add(const Duration(seconds: 2)),
          markers: const <Never>[],
        ),
      ]),
      throwsStateError,
    );
    expect(
      (await database.loadActiveSessions()).map((value) => value.id),
      <String>['upsert-owner'],
    );
    expect(await source.readAsBytes(), <int>[2, 7, 1, 8]);
  });

  test('迁移与 upsert 软删除交错时跳过陈旧快照并继续 checkpoint', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final File source = File(p.join(root.path, 'concurrent-source.mp4'));
    final File moved = File(p.join(root.path, 'concurrent-moved.mp4'));
    await source.writeAsBytes(<int>[3, 1, 4, 1]);
    await moved.writeAsBytes(<int>[5, 9, 2, 6]);
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 11, 30);
    final List<RecordingSession> sessions = List<RecordingSession>.generate(
      3,
      (int index) => RecordingSession(
        id: 'concurrent-$index',
        filePath: source.path,
        startedAt: startedAt.add(Duration(seconds: index)),
        endedAt: startedAt.add(Duration(seconds: index + 1)),
        markers: const <Never>[],
      ),
    );
    final Database seed = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await seed.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key IN (?, ?, ?)',
        whereArgs: <Object?>[
          'shared_file_materialization_v1',
          'shared_file_materialization_cursor_v1',
          'recording_file_owners_ready_v1',
        ],
      );
      await txn.delete('recording_file_owners');
      for (var index = 0; index < sessions.length; index++) {
        await _insertSession(txn, sessions[index], updatedAt: index);
      }
    });
    await seed.close();

    late final RecordingDatabase database;
    final Set<String> intercepted = <String>{};
    database = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
      beforeSharedFileMigrationRowForTesting: (String id) async {
        if (!intercepted.add(id)) return;
        if (id == 'concurrent-1') {
          await database.upsertSessions(<RecordingSession>[
            sessions[1].copyWith(filePath: moved.path),
          ]);
        } else if (id == 'concurrent-2') {
          await database.markDeleted(<RecordingSession>[
            sessions[2],
          ], reason: '并发迁移测试');
        }
      },
    );
    addTearDown(database.close);
    await database.initialize();
    await database.drainSharedFileMigrationForTesting();

    expect(
      await database.readMetadataValue('shared_file_materialization_v1'),
      isNotNull,
    );
    final Map<String, RecordingSession> active = <String, RecordingSession>{
      for (final RecordingSession session
          in await database.loadActiveSessions())
        session.id: session,
    };
    expect(active.keys, <String>{'concurrent-0', 'concurrent-1'});
    expect(active['concurrent-0']!.filePath, source.path);
    expect(active['concurrent-1']!.filePath, moved.path);
    final Database raw = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(raw.close);
    expect(
      await raw.query(
        'recording_file_owners',
        orderBy: 'retained_session_id ASC',
      ),
      <Map<String, Object?>>[
        <String, Object?>{
          'normalized_path': p.posix.normalize(
            source.path.replaceAll('\\', '/'),
          ),
          'retained_session_id': 'concurrent-0',
        },
        <String, Object?>{
          'normalized_path': p.posix.normalize(
            moved.path.replaceAll('\\', '/'),
          ),
          'retained_session_id': 'concurrent-1',
        },
      ],
    );
  });

  test('迁移目标竞争出现时独占创建新路径且绝不覆盖竞争文件', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final File source = File('${root.path}/exclusive-source.mp4');
    await source.writeAsBytes(<int>[2, 3, 5, 7]);
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 11, 50);
    final Database seed = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await seed.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key IN (?, ?, ?)',
        whereArgs: <Object?>[
          'shared_file_materialization_v1',
          'shared_file_materialization_cursor_v1',
          'recording_file_owners_ready_v1',
        ],
      );
      await txn.delete('recording_file_owners');
      for (var index = 0; index < 2; index++) {
        await _insertSession(
          txn,
          RecordingSession(
            id: 'exclusive-$index',
            filePath: source.path,
            startedAt: startedAt.add(Duration(seconds: index)),
            endedAt: startedAt.add(Duration(seconds: index + 1)),
            markers: const <Never>[],
          ),
          updatedAt: index,
        );
      }
    });
    await seed.close();

    File? competitor;
    final RecordingDatabase database = RecordingDatabase(
      path: databasePath,
      startSharedFileMigrationWorker: false,
      beforeExclusiveMaterializationCreateForTesting: (String path) async {
        if (competitor != null) return;
        competitor = File(path);
        await competitor!.writeAsBytes(<int>[9, 9, 9, 9]);
      },
    );
    addTearDown(database.close);
    await database.initialize();
    await database.drainSharedFileMigrationForTesting();

    expect(await competitor!.readAsBytes(), <int>[9, 9, 9, 9]);
    expect(await source.readAsBytes(), <int>[2, 3, 5, 7]);
    final List<RecordingSession> active = await database.loadActiveSessions();
    expect(
      active.map((RecordingSession value) => value.filePath).toSet(),
      hasLength(2),
    );
    final RecordingSession materialized = active.singleWhere(
      (RecordingSession value) => value.filePath != source.path,
    );
    expect(materialized.filePath, isNot(competitor!.path));
    expect(await File(materialized.filePath).readAsBytes(), <int>[2, 3, 5, 7]);
  });

  test('共享文件 intent 可在崩溃后重入且不覆盖唯一原片', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final File source = File('${root.path}/legacy.mp4');
    await source.writeAsBytes(<int>[1, 2, 3, 4]);
    final String destinationPath = '${root.path}/legacy_独立_second.mp4';
    final String intentKey =
        'shared_file_materialization_intent_v1:${base64Url.encode(utf8.encode('second'))}';
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 12);
    final RecordingSession first = RecordingSession(
      id: 'first',
      filePath: source.path,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 1)),
      markers: const <Never>[],
    );
    final RecordingSession second = RecordingSession(
      id: 'second',
      filePath: source.path,
      startedAt: startedAt.add(const Duration(seconds: 1)),
      endedAt: startedAt.add(const Duration(seconds: 2)),
      markers: const <Never>[],
    );
    final Database raw = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await raw.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key = ?',
        whereArgs: <Object?>['shared_file_materialization_v1'],
      );
      await _insertSession(txn, first, updatedAt: 1);
      await _insertSession(txn, second, updatedAt: 2);
      await txn.insert('recording_metadata', <String, Object?>{
        'key': intentKey,
        'value': jsonEncode(<String, Object?>{
          'sourcePath': source.path,
          'destinationPath': destinationPath,
        }),
      });
    });
    await raw.close();

    final RecordingDatabase recovered = RecordingDatabase(path: databasePath);
    addTearDown(recovered.close);
    await recovered.initialize();
    await recovered.drainSharedFileMigrationForTesting();
    final List<RecordingSession> sessions = await recovered
        .loadActiveSessions();

    expect(await source.readAsBytes(), <int>[1, 2, 3, 4]);
    expect(await File(destinationPath).readAsBytes(), <int>[1, 2, 3, 4]);
    expect(
      sessions.map((RecordingSession value) => value.filePath).toSet(),
      <String>{source.path, destinationPath},
    );
    expect(
      root.listSync().whereType<File>().where(
        (File file) => file.path.contains('_独立_'),
      ),
      hasLength(1),
    );

    await recovered.close();
    final RecordingDatabase reopened = RecordingDatabase(path: databasePath);
    addTearDown(reopened.close);
    await reopened.initialize();
    expect(
      root.listSync().whereType<File>().where(
        (File file) => file.path.contains('_独立_'),
      ),
      hasLength(1),
    );
  });

  test('共享源文件缺失时不写完成标记且恢复后继续迁移', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final File source = File('${root.path}/temporarily-missing.mp4');
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 13);
    final Database raw = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await raw.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key = ?',
        whereArgs: <Object?>['shared_file_materialization_v1'],
      );
      await _insertSession(
        txn,
        RecordingSession(
          id: 'missing-first',
          filePath: source.path,
          startedAt: startedAt,
          endedAt: startedAt.add(const Duration(seconds: 1)),
          markers: const <Never>[],
        ),
        updatedAt: 1,
      );
      await _insertSession(
        txn,
        RecordingSession(
          id: 'missing-second',
          filePath: source.path,
          startedAt: startedAt.add(const Duration(seconds: 1)),
          endedAt: startedAt.add(const Duration(seconds: 2)),
          markers: const <Never>[],
        ),
        updatedAt: 2,
      );
    });
    await raw.close();

    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    await database.initialize();
    await database.drainSharedFileMigrationForTesting();
    expect(
      await database.readMetadataValue('shared_file_materialization_v1'),
      isNull,
    );

    await source.writeAsBytes(<int>[1, 3, 5, 7]);
    await database.initialize();
    await database.drainSharedFileMigrationForTesting();
    final List<RecordingSession> sessions = await database.loadActiveSessions();
    expect(
      sessions.map((RecordingSession value) => value.filePath).toSet(),
      hasLength(2),
    );
    expect(
      await database.readMetadataValue('shared_file_materialization_v1'),
      isNotNull,
    );
  });

  test('恢复 intent 时拒绝复用内容不一致的既有目标', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final File source = File('${root.path}/source.mp4');
    final File occupied = File('${root.path}/occupied.mp4');
    await source.writeAsBytes(<int>[1, 2, 3, 4]);
    await occupied.writeAsBytes(<int>[9, 8, 7, 6]);
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 14);
    final String intentKey =
        'shared_file_materialization_intent_v1:${base64Url.encode(utf8.encode('second'))}';
    final Database raw = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await raw.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key = ?',
        whereArgs: <Object?>['shared_file_materialization_v1'],
      );
      for (final ({String id, int offset}) fixture
          in <({String id, int offset})>[
            (id: 'first', offset: 0),
            (id: 'second', offset: 1),
          ]) {
        await _insertSession(
          txn,
          RecordingSession(
            id: fixture.id,
            filePath: source.path,
            startedAt: startedAt.add(Duration(seconds: fixture.offset)),
            endedAt: startedAt.add(Duration(seconds: fixture.offset + 1)),
            markers: const <Never>[],
          ),
          updatedAt: fixture.offset + 1,
        );
      }
      await txn.insert('recording_metadata', <String, Object?>{
        'key': intentKey,
        'value': jsonEncode(<String, Object?>{
          'sourcePath': source.path,
          'destinationPath': occupied.path,
        }),
      });
    });
    await raw.close();

    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    await database.initialize();
    final Map<String, RecordingSession> sessions = <String, RecordingSession>{
      for (final RecordingSession session
          in await database.loadActiveSessions())
        session.id: session,
    };
    expect(sessions['second']!.filePath, isNot(occupied.path));
    expect(await File(sessions['second']!.filePath).readAsBytes(), <int>[
      1,
      2,
      3,
      4,
    ]);
    expect(await occupied.readAsBytes(), <int>[9, 8, 7, 6]);
  });

  test('恢复 intent 时拒绝把保留的共享源路径当作目标', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final File source = File('${root.path}/reserved-source.mp4');
    await source.writeAsBytes(<int>[2, 4, 6, 8]);
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 15);
    final String intentKey =
        'shared_file_materialization_intent_v1:${base64Url.encode(utf8.encode('reserved-second'))}';
    final Database raw = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await raw.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key = ?',
        whereArgs: <Object?>['shared_file_materialization_v1'],
      );
      for (final ({String id, int offset}) fixture
          in <({String id, int offset})>[
            (id: 'reserved-first', offset: 0),
            (id: 'reserved-second', offset: 1),
          ]) {
        await _insertSession(
          txn,
          RecordingSession(
            id: fixture.id,
            filePath: source.path,
            startedAt: startedAt.add(Duration(seconds: fixture.offset)),
            endedAt: startedAt.add(Duration(seconds: fixture.offset + 1)),
            markers: const <Never>[],
          ),
          updatedAt: fixture.offset + 1,
        );
      }
      await txn.insert('recording_metadata', <String, Object?>{
        'key': intentKey,
        'value': jsonEncode(<String, Object?>{
          'sourcePath': source.path,
          'destinationPath': source.path,
        }),
      });
    });
    await raw.close();

    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    await database.initialize();
    await database.drainSharedFileMigrationForTesting();
    final List<RecordingSession> sessions = await database.loadActiveSessions();
    expect(
      sessions.map((RecordingSession value) => value.filePath).toSet(),
      hasLength(2),
    );
    expect(await source.readAsBytes(), <int>[2, 4, 6, 8]);
  });

  test('条件更新未命中时保留 intent 和完成标记缺口供下次重试', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final File source = File('${root.path}/update-race.mp4');
    await source.writeAsBytes(<int>[7, 7, 7, 7]);
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 16);
    final String intentKey =
        'shared_file_materialization_intent_v1:${base64Url.encode(utf8.encode('race-second'))}';
    final Database raw = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await raw.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key = ?',
        whereArgs: <Object?>['shared_file_materialization_v1'],
      );
      for (final ({String id, int offset}) fixture
          in <({String id, int offset})>[
            (id: 'race-first', offset: 0),
            (id: 'race-second', offset: 1),
          ]) {
        await _insertSession(
          txn,
          RecordingSession(
            id: fixture.id,
            filePath: source.path,
            startedAt: startedAt.add(Duration(seconds: fixture.offset)),
            endedAt: startedAt.add(Duration(seconds: fixture.offset + 1)),
            markers: const <Never>[],
          ),
          updatedAt: fixture.offset + 1,
        );
      }
      await txn.execute('''
        CREATE TRIGGER ignore_race_materialization
        BEFORE UPDATE OF file_path ON recording_sessions
        WHEN OLD.id = 'race-second'
        BEGIN
          SELECT RAISE(IGNORE);
        END
      ''');
    });
    await raw.close();

    final RecordingDatabase interrupted = RecordingDatabase(path: databasePath);
    await interrupted.initialize();
    await interrupted.drainSharedFileMigrationForTesting();
    expect(
      await interrupted.readMetadataValue('shared_file_materialization_v1'),
      isNull,
    );
    expect(await interrupted.readMetadataValue(intentKey), isNotNull);
    await interrupted.close();

    final Database repair = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await repair.execute('DROP TRIGGER ignore_race_materialization');
    await repair.close();

    final RecordingDatabase recovered = RecordingDatabase(path: databasePath);
    addTearDown(recovered.close);
    await recovered.initialize();
    await recovered.drainSharedFileMigrationForTesting();
    expect(
      await recovered.readMetadataValue('shared_file_materialization_v1'),
      isNotNull,
    );
    expect(await recovered.readMetadataValue(intentKey), isNull);
    expect(
      (await recovered.loadActiveSessions())
          .map((RecordingSession value) => value.filePath)
          .toSet(),
      hasLength(2),
    );
  });

  test('多个 intent 指向同一正确内容目标时仍保持一记录一文件', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final File sourceA = File('${root.path}/a-source.mp4');
    final File sourceB = File('${root.path}/b-source.mp4');
    final File sharedDestination = File('${root.path}/shared-destination.mp4');
    for (final File file in <File>[sourceA, sourceB, sharedDestination]) {
      await file.writeAsBytes(<int>[4, 3, 2, 1]);
    }
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 17);
    final Database raw = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await raw.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key = ?',
        whereArgs: <Object?>['shared_file_materialization_v1'],
      );
      final List<({String id, File source, int offset})> fixtures =
          <({String id, File source, int offset})>[
            (id: 'a-first', source: sourceA, offset: 0),
            (id: 'a-second', source: sourceA, offset: 1),
            (id: 'b-first', source: sourceB, offset: 2),
            (id: 'b-second', source: sourceB, offset: 3),
          ];
      for (final ({String id, File source, int offset}) fixture in fixtures) {
        await _insertSession(
          txn,
          RecordingSession(
            id: fixture.id,
            filePath: fixture.source.path,
            startedAt: startedAt.add(Duration(seconds: fixture.offset)),
            endedAt: startedAt.add(Duration(seconds: fixture.offset + 1)),
            markers: const <Never>[],
          ),
          updatedAt: fixture.offset + 1,
        );
        if (fixture.id.endsWith('second')) {
          await txn.insert('recording_metadata', <String, Object?>{
            'key':
                'shared_file_materialization_intent_v1:${base64Url.encode(utf8.encode(fixture.id))}',
            'value': jsonEncode(<String, Object?>{
              'sourcePath': fixture.source.path,
              'destinationPath': sharedDestination.path,
            }),
          });
        }
      }
    });
    await raw.close();

    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    await database.initialize();
    await database.drainSharedFileMigrationForTesting();
    final List<RecordingSession> sessions = await database.loadActiveSessions();
    expect(
      sessions.map((RecordingSession value) => value.filePath).toSet(),
      hasLength(4),
    );
    expect(
      sessions
          .where(
            (RecordingSession value) =>
                value.filePath == sharedDestination.path,
          )
          .length,
      1,
    );
    expect(await sharedDestination.readAsBytes(), <int>[4, 3, 2, 1]);
  });

  test('遗留临时副本不被引用或覆盖且正式迁移可继续', () async {
    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    final File source = File('${root.path}/rename-source.mp4');
    final String destinationPath = '${root.path}/rename-destination.mp4';
    final File interruptedTemporary = File(
      '$destinationPath.migrating-interrupted',
    );
    await source.writeAsBytes(<int>[1, 1, 2, 3, 5]);
    await interruptedTemporary.writeAsBytes(<int>[9, 9, 9]);
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 18);
    final Database raw = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await raw.transaction((Transaction txn) async {
      await txn.delete(
        'recording_metadata',
        where: 'key = ?',
        whereArgs: <Object?>['shared_file_materialization_v1'],
      );
      for (final ({String id, int offset}) fixture
          in <({String id, int offset})>[
            (id: 'rename-first', offset: 0),
            (id: 'rename-second', offset: 1),
          ]) {
        await _insertSession(
          txn,
          RecordingSession(
            id: fixture.id,
            filePath: source.path,
            startedAt: startedAt.add(Duration(seconds: fixture.offset)),
            endedAt: startedAt.add(Duration(seconds: fixture.offset + 1)),
            markers: const <Never>[],
          ),
          updatedAt: fixture.offset + 1,
        );
      }
      await txn.insert('recording_metadata', <String, Object?>{
        'key':
            'shared_file_materialization_intent_v1:${base64Url.encode(utf8.encode('rename-second'))}',
        'value': jsonEncode(<String, Object?>{
          'sourcePath': source.path,
          'destinationPath': destinationPath,
        }),
      });
    });
    await raw.close();

    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    await database.initialize();
    await database.drainSharedFileMigrationForTesting();
    expect(await File(destinationPath).readAsBytes(), <int>[1, 1, 2, 3, 5]);
    expect(await interruptedTemporary.readAsBytes(), <int>[9, 9, 9]);
    expect(
      (await database.loadActiveSessions()).map(
        (RecordingSession value) => value.filePath,
      ),
      isNot(contains(interruptedTemporary.path)),
    );
  });
}

Future<void> _seedBackupRows(
  String path, {
  required int count,
  String? payloadJson,
}) async {
  final Database db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  final String payload =
      payloadJson ??
      jsonEncode(
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

Future<void> _seedSharedSessions(
  String path,
  File source,
  List<String> ids,
) async {
  final RecordingDatabase created = RecordingDatabase(
    path: path,
    startSharedFileMigrationWorker: false,
  );
  await created.initialize();
  await created.close();
  final Database db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await db.transaction((Transaction txn) async {
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
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 8);
    for (var index = 0; index < ids.length; index++) {
      await _insertSession(
        txn,
        RecordingSession(
          id: ids[index],
          filePath: source.path,
          startedAt: startedAt.add(Duration(seconds: index)),
          endedAt: startedAt.add(Duration(seconds: index + 1)),
          markers: const <Never>[],
        ),
        updatedAt: index,
      );
    }
  });
  await db.close();
}

Future<void> _insertSession(
  DatabaseExecutor db,
  RecordingSession session, {
  required int updatedAt,
}) => db.insert('recording_sessions', <String, Object?>{
  'id': session.id,
  'file_path': session.filePath,
  'started_at': session.startedAt.millisecondsSinceEpoch,
  'ended_at': session.endedAt.millisecondsSinceEpoch,
  'payload_json': jsonEncode(session.toJson()),
  'created_at': updatedAt,
  'updated_at': updatedAt,
});

Future<String?> _metadataValue(Database db, String key) async {
  final List<Map<String, Object?>> rows = await db.query(
    'recording_metadata',
    columns: const <String>['value'],
    where: 'key = ?',
    whereArgs: <Object?>[key],
    limit: 1,
  );
  return rows.isEmpty ? null : rows.single['value'] as String?;
}
