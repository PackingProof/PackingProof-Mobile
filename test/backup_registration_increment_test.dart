import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late RecordingDatabase database;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'packing-proof-backup-cursor-',
    );
    database = RecordingDatabase(path: '${root.path}/recordings.db');
    await database.initialize();
  });

  tearDown(() async {
    await database.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<RecordingSession> addSession(String id, DateTime startedAt) async {
    final File file = File('${root.path}/$id.mp4');
    await file.writeAsBytes(<int>[1, 2, 3]);
    final RecordingSession session = RecordingSession(
      id: id,
      filePath: file.path,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 1)),
      markers: const <BarcodeMarker>[],
    );
    await database.upsertSessions(<RecordingSession>[session]);
    return session;
  }

  test('冻结高水位后新增录像留到下一轮', () async {
    final RecordingSession first = await addSession(
      'first',
      DateTime.utc(2026, 8, 20, 10),
    );
    final ({int updatedAt, String id})? highWatermark = await database
        .loadBackupHighWatermark();
    expect(highWatermark, isNotNull);

    final RecordingSession later = await addSession(
      'later',
      DateTime.utc(2026, 8, 20, 11),
    );
    final List<RecordingBackupRow> rows = await database.queryBackupRows(
      afterUpdatedAt: null,
      afterId: null,
      highUpdatedAt: highWatermark!.updatedAt,
      highId: highWatermark.id,
      pageSize: 100,
    );

    expect(rows.map((row) => row.id), contains(first.id));
    expect(rows.map((row) => row.id), isNot(contains(later.id)));
  });

  test('同时间戳多条录像按 id 稳定分页且不丢失', () async {
    final DateTime startedAt = DateTime.utc(2026, 8, 20, 10);
    await addSession('same-a', startedAt);
    await addSession('same-b', startedAt);
    await addSession('same-c', startedAt);
    const int sameUpdatedAt = 1000;
    for (final String id in <String>['same-a', 'same-b', 'same-c']) {
      await database.setUpdatedAtForTesting(id: id, updatedAt: sameUpdatedAt);
    }

    final ({int updatedAt, String id})? highWatermark = await database
        .loadBackupHighWatermark();
    expect(highWatermark, isNotNull);
    final Set<String> seen = <String>{};
    int? afterUpdatedAt;
    String? afterId;
    for (var index = 0; index < 4; index++) {
      final List<RecordingBackupRow> rows = await database.queryBackupRows(
        afterUpdatedAt: afterUpdatedAt,
        afterId: afterId,
        highUpdatedAt: highWatermark!.updatedAt,
        highId: highWatermark.id,
        pageSize: 1,
      );
      if (rows.isEmpty) break;
      final RecordingBackupRow last = rows.last;
      seen.add(last.id);
      afterUpdatedAt = last.updatedAt;
      afterId = last.id;
    }

    expect(seen, <String>{'same-a', 'same-b', 'same-c'});
  });

  test('游标编码可解析且不依赖时间回退', () {
    const int updatedAt = 1234;
    const String id = 'session-1';
    final String encoded = '${updatedAt.toString()}:$id';
    final BackupRegistrationCursor? cursor = BackupRegistrationCursor.tryParse(
      encoded,
    );

    expect(cursor, isNotNull);
    expect(cursor!.updatedAt, updatedAt);
    expect(cursor.id, id);
  });
}
