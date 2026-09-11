import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/models/recording_operation_mode.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late String databasePath;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'packing-proof-recording-search-',
    );
    databasePath = '${root.path}/recordings.db';

    final RecordingDatabase created = RecordingDatabase(path: databasePath);
    await created.initialize();
    await created.close();
    await _seedSearchRows(databasePath);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('业务类型在计数和游标翻页前筛选，支持组合搜索', () async {
    final raw = await databaseFactory.openDatabase(databasePath);
    await raw.update(
      'recording_sessions',
      {'operation_mode': 'return'},
      where: 'id IN (?, ?)',
      whereArgs: ['jd-first', 'jd-second'],
    );
    await raw.close();
    final database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    final first = await database.queryActiveSessions(
      page: 1,
      pageSize: 1,
      keyword: 'JD',
      operationMode: RecordingOperationMode.returnGoods,
    );
    expect(first.total, 2);
    expect(first.data.single.id, 'jd-first');
    final second = await database.queryAdjacentActiveSessions(
      page: 2,
      pageSize: 1,
      cursor: first.lastCursor!,
      direction: LocalRecordingPageDirection.older,
      knownTotal: first.total,
      keyword: 'JD',
      operationMode: RecordingOperationMode.returnGoods,
    );
    expect(second.data.single.id, 'jd-second');
    expect(second.total, 2);
    final shipping = await database.queryActiveSessions(
      page: 1,
      pageSize: 10,
      keyword: 'JD',
      operationMode: RecordingOperationMode.shipping,
    );
    expect(shipping.total, 0);
  });

  test('版本5升级按原始记录回填业务类型且保留记录', () async {
    final raw = await databaseFactory.openDatabase(databasePath);
    final row = (await raw.query(
      'recording_sessions',
      where: 'id = ?',
      whereArgs: ['jd-first'],
    )).single;
    final payload =
        jsonDecode(row['payload_json']! as String) as Map<String, dynamic>;
    payload['operationMode'] = 'return';
    await raw.update(
      'recording_sessions',
      {'payload_json': jsonEncode(payload)},
      where: 'id = ?',
      whereArgs: ['jd-first'],
    );
    await raw.execute('DROP INDEX idx_recording_active_mode_time');
    await raw.execute(
      'ALTER TABLE recording_sessions DROP COLUMN operation_mode',
    );
    await raw.setVersion(5);
    await raw.close();
    final database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    final returned = await database.queryActiveSessions(
      page: 1,
      pageSize: 10,
      operationMode: RecordingOperationMode.returnGoods,
    );
    expect(returned.total, 1);
    expect(returned.data.single.id, 'jd-first');
    final all = await database.queryActiveSessions(page: 1, pageSize: 10);
    expect(all.total, 8);
  });

  test('搜索把 LIKE 通配符、斜杠和引号按字面字符匹配', () async {
    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);

    await _expectSearch(database, '%', <String>['literal-percent']);
    await _expectSearch(database, '_', <String>['literal-underscore']);
    await _expectSearch(database, r'\', <String>['literal-backslash']);
    await _expectSearch(database, "'quoted'", <String>['literal-quote']);
  });

  test('搜索保留中文、数字和字母的内部子串语义', () async {
    final RecordingDatabase database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);

    await _expectSearch(database, '色连衣', <String>['mixed-content']);
    await _expectSearch(database, '34567', <String>['mixed-content']);
    await _expectSearch(database, 'ABCdef', <String>['mixed-content']);
  });

  test('京东裸号查询所有包裹，完整包裹码只查询对应录像', () async {
    final database = RecordingDatabase(path: databasePath);
    addTearDown(database.close);
    await _expectSearch(database, 'JD987654321098', ['jd-first', 'jd-second']);
    await _expectSearch(database, 'JD987654321098-1-2-', ['jd-first']);
    await _expectSearch(database, 'JD987654321098-2-2-', ['jd-second']);
  });
}

Future<void> _expectSearch(
  RecordingDatabase database,
  String keyword,
  List<String> expectedIds,
) async {
  final LocalRecordingPage page = await database.queryActiveSessions(
    page: 1,
    pageSize: 100,
    keyword: keyword,
  );
  expect(page.total, expectedIds.length);
  expect(
    page.data.map((RecordingSession session) => session.id).toList(),
    expectedIds,
  );
}

Future<void> _seedSearchRows(String path) async {
  final Database db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  final DateTime base = DateTime.utc(2026, 8, 23);
  final List<({String id, String searchText})> fixtures =
      <({String id, String searchText})>[
        (id: 'literal-percent', searchText: '进度 100% 完成'),
        (id: 'literal-underscore', searchText: 'literal_under_score'),
        (id: 'literal-backslash', searchText: r'folder\recording'),
        (id: 'literal-quote', searchText: "customer 'quoted' memo"),
        (id: 'mixed-content', searchText: 'sf123456789cn abcdef 红色连衣裙'),
        (id: 'plain-decoy', searchText: '普通商品 无特殊字符'),
        (id: 'jd-first', searchText: 'JD987654321098-1-2-'),
        (id: 'jd-second', searchText: 'JD987654321098-2-2-'),
      ];
  final Batch batch = db.batch();
  for (var index = 0; index < fixtures.length; index++) {
    final fixture = fixtures[index];
    final RecordingSession session = RecordingSession(
      id: fixture.id,
      filePath: '/recordings/${fixture.id}.mp4',
      startedAt: base.subtract(Duration(seconds: index)),
      endedAt: base.subtract(Duration(seconds: index - 1)),
      markers: const <Never>[],
    );
    batch.rawInsert(
      'INSERT INTO recording_sessions('
      'id,file_path,started_at,ended_at,search_text,payload_json,created_at,updated_at'
      ') VALUES(?,?,?,?,?,?,?,?)',
      <Object?>[
        session.id,
        session.filePath,
        session.startedAt.millisecondsSinceEpoch,
        session.endedAt.millisecondsSinceEpoch,
        fixture.searchText.toLowerCase(),
        jsonEncode(session.toJson()),
        index,
        index,
      ],
    );
  }
  await batch.commit(noResult: true);
  await db.close();
}
