import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/models/recording_operation_mode.dart';
import 'package:packing_proof_mobile/models/work_mode.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';

import 'test_repository.dart';

List<int> _mp4Box(String type, {int extra = 0}) {
  final int size = 8 + extra;
  return <int>[
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...type.codeUnits,
    ...List<int>.filled(extra, 0),
  ];
}

List<int> playableMp4Bytes() => <int>[
  ..._mp4Box('ftyp', extra: 16),
  ..._mp4Box('moov'),
];

void main() {
  test('录像记录可持久化并读取', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final File source = File(
      '${root.path}${Platform.pathSeparator}capture.mp4',
    );
    await source.writeAsBytes(<int>[0, 1, 2, 3]);
    final SessionRepository repository = testRepository(root);
    final DateTime startedAt = DateTime(2026, 7, 16, 10);
    final String videoPath = await repository.finalizeVideo(
      sourcePath: source.path,
      sessionId: 'session-1',
      startedAt: startedAt,
      trackingNumber: 'JT1234567890',
    );
    final RecordingSession session = RecordingSession(
      id: 'session-1',
      filePath: videoPath,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(minutes: 2)),
      markers: <BarcodeMarker>[
        BarcodeMarker(
          code: 'JT1234567890',
          occurredAt: startedAt.add(const Duration(seconds: 12)),
          offset: const Duration(seconds: 12),
        ),
      ],
      mediaStart: const Duration(seconds: 10),
      mediaEnd: const Duration(seconds: 130),
    );

    await repository.addSession(session);
    final List<RecordingSession> loaded = await repository.loadSessions();

    expect(loaded, hasLength(1));
    expect(loaded.single.displayCode, 'JT1234567890');
    expect(loaded.single.markers.single.offset, const Duration(seconds: 12));
    expect(loaded.single.mediaStart, const Duration(seconds: 10));
    expect(loaded.single.playbackEnd, const Duration(seconds: 130));
    expect(File(videoPath).existsSync(), isTrue);
    expect(
      videoPath,
      endsWith(
        '${Platform.pathSeparator}recordings${Platform.pathSeparator}2026-07-16'
        '${Platform.pathSeparator}JT1234567890_20260716_100000_发货.mp4',
      ),
    );
  });

  test('旧录像记录缺少媒体区间时仍按完整视频播放', () {
    final DateTime startedAt = DateTime(2026, 7, 16, 10);
    final RecordingSession session = RecordingSession.fromJson(
      <String, Object?>{
        'id': 'legacy',
        'filePath': 'legacy.mp4',
        'startedAt': startedAt.toIso8601String(),
        'endedAt': startedAt.add(const Duration(seconds: 30)).toIso8601String(),
        'markers': <Object?>[],
      },
    );

    expect(session.mediaStart, Duration.zero);
    expect(session.playbackEnd, const Duration(seconds: 30));
    expect(session.operationMode, RecordingOperationMode.shipping);
  });

  test('退货录像模式可持久化并写入文件名', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_return_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final File source = File(
      '${root.path}${Platform.pathSeparator}capture.mp4',
    );
    await source.writeAsBytes(<int>[0, 1, 2, 3]);
    final SessionRepository repository = testRepository(root);
    final DateTime startedAt = DateTime(2026, 7, 31, 9, 8, 7);

    final String videoPath = await repository.finalizeVideo(
      sourcePath: source.path,
      sessionId: 'return-session',
      startedAt: startedAt,
      trackingNumber: 'RET123',
      operationMode: RecordingOperationMode.returnGoods,
    );
    final RecordingSession restored = RecordingSession.fromJson(
      RecordingSession(
        id: 'return-session',
        filePath: videoPath,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 5)),
        markers: const <BarcodeMarker>[],
        operationMode: RecordingOperationMode.returnGoods,
      ).toJson(),
    );

    expect(videoPath, endsWith('RET123_20260731_090807_退货.mp4'));
    expect(restored.operationMode, RecordingOperationMode.returnGoods);
    expect(restored.toJson()['operationMode'], 'return');
  });

  test('剪辑录像只调整逻辑播放区间并保留面单号', () {
    final DateTime startedAt = DateTime(2026, 7, 18, 10);
    final RecordingSession session = RecordingSession(
      id: 'clip-1',
      filePath: 'legacy.mp4',
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 20)),
      markers: <BarcodeMarker>[
        BarcodeMarker(
          code: 'JT1234567890',
          occurredAt: startedAt.add(const Duration(seconds: 3)),
          offset: const Duration(seconds: 3),
        ),
      ],
      mediaStart: const Duration(seconds: 10),
      mediaEnd: const Duration(seconds: 30),
    );

    final RecordingSession trimmed = session.trimmed(
      startOffset: const Duration(seconds: 2),
      endOffset: const Duration(seconds: 12),
    );

    expect(trimmed.displayCode, 'JT1234567890');
    expect(trimmed.duration, const Duration(seconds: 10));
    expect(trimmed.mediaStart, const Duration(seconds: 12));
    expect(trimmed.playbackEnd, const Duration(seconds: 22));
    expect(trimmed.markers.single.offset, const Duration(seconds: 1));
  });

  test('再次剪辑可按源视频绝对时间恢复之前裁掉的内容', () {
    final DateTime sourceStartedAt = DateTime(2026, 7, 18, 10);
    final RecordingSession clipped = RecordingSession(
      id: 'clip-restore',
      filePath: 'legacy.mp4',
      startedAt: sourceStartedAt.add(const Duration(seconds: 10)),
      endedAt: sourceStartedAt.add(const Duration(seconds: 20)),
      markers: <BarcodeMarker>[
        BarcodeMarker(
          code: 'JT1234567890',
          occurredAt: sourceStartedAt.add(const Duration(seconds: 12)),
          offset: const Duration(seconds: 2),
        ),
      ],
      mediaStart: const Duration(seconds: 10),
      mediaEnd: const Duration(seconds: 20),
    );

    final RecordingSession restored = clipped.trimmedToMediaRange(
      mediaStart: const Duration(seconds: 5),
      mediaEnd: const Duration(seconds: 25),
    );

    expect(restored.startedAt, sourceStartedAt.add(const Duration(seconds: 5)));
    expect(restored.endedAt, sourceStartedAt.add(const Duration(seconds: 25)));
    expect(restored.mediaStart, const Duration(seconds: 5));
    expect(restored.playbackEnd, const Duration(seconds: 25));
    expect(restored.markers.single.offset, const Duration(seconds: 7));
  });

  test('拒绝让两条录像记录引用同一文件', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_delete_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final File source = File(
      '${root.path}${Platform.pathSeparator}capture.mp4',
    );
    await source.writeAsBytes(<int>[0, 1, 2, 3]);
    final SessionRepository repository = testRepository(root);
    final String videoPath = await repository.finalizeVideo(
      sourcePath: source.path,
      sessionId: 'shared-recording',
      startedAt: DateTime(2026, 7, 18, 10),
      trackingNumber: '',
    );
    final DateTime startedAt = DateTime(2026, 7, 18, 10);
    final RecordingSession first = RecordingSession(
      id: 'clip-1',
      filePath: videoPath,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 10)),
      markers: const <BarcodeMarker>[],
    );
    final RecordingSession second = RecordingSession(
      id: 'clip-2',
      filePath: videoPath,
      startedAt: startedAt.add(const Duration(seconds: 10)),
      endedAt: startedAt.add(const Duration(seconds: 20)),
      markers: const <BarcodeMarker>[],
      mediaStart: const Duration(seconds: 10),
      mediaEnd: const Duration(seconds: 20),
    );
    await expectLater(
      repository.addSessions(<RecordingSession>[first, second]),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          '一条录像文件只能对应一条录像记录',
        ),
      ),
    );
    expect(File(videoPath).existsSync(), isTrue);
    expect(await repository.loadSessions(), isEmpty);
  });

  test('并发保存录像记录不会互相覆盖', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_session_race_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final SessionRepository repository = testRepository(root);
    final DateTime startedAt = DateTime(2026, 7, 22, 10);
    final File firstFile = File('${root.path}/first.mp4')
      ..writeAsBytesSync(<int>[1]);
    final File secondFile = File('${root.path}/second.mp4')
      ..writeAsBytesSync(<int>[2]);
    final String firstPath = await repository.finalizeVideo(
      sourcePath: firstFile.path,
      sessionId: 'race-first',
      startedAt: startedAt,
      trackingNumber: 'RACE1',
    );
    final String secondPath = await repository.finalizeVideo(
      sourcePath: secondFile.path,
      sessionId: 'race-second',
      startedAt: startedAt.add(const Duration(seconds: 1)),
      trackingNumber: 'RACE2',
    );

    await Future.wait(<Future<List<RecordingSession>>>[
      repository.addSession(
        RecordingSession(
          id: 'race-first',
          filePath: firstPath,
          startedAt: startedAt,
          endedAt: startedAt.add(const Duration(seconds: 1)),
          markers: const <BarcodeMarker>[],
        ),
      ),
      repository.addSession(
        RecordingSession(
          id: 'race-second',
          filePath: secondPath,
          startedAt: startedAt.add(const Duration(seconds: 1)),
          endedAt: startedAt.add(const Duration(seconds: 2)),
          markers: const <BarcodeMarker>[],
        ),
      ),
    ]);

    expect(await repository.loadSessions(), hasLength(2));
    expect(File(firstPath).existsSync(), isTrue);
    expect(File(secondPath).existsSync(), isTrue);
  });

  test('首次启动将旧 sessions.json 事务迁移到 SQLite', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_session_recovery_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final DateTime startedAt = DateTime(2026, 7, 22, 10, 30);
    final File video = File('${root.path}/recording.mp4')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final RecordingSession legacy = RecordingSession(
      id: 'migrated-session',
      filePath: video.path,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 1)),
      markers: const <BarcodeMarker>[],
    );
    final File index = File('${root.path}/sessions.json');
    await index.writeAsString(jsonEncode(<Object?>[legacy.toJson()]));

    final SessionRepository repository = testRepository(root);
    final List<RecordingSession> recovered = await repository.loadSessions();

    expect(recovered.single.id, 'migrated-session');
    expect(File('${root.path}/recordings.db').existsSync(), isTrue);
    expect(index.existsSync(), isTrue);
    expect(File('${index.path}.migrated').existsSync(), isTrue);
    expect(video.existsSync(), isTrue);
  });

  test('旧主索引损坏时从备份导入 SQLite', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_session_corrupt_recovery_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final DateTime startedAt = DateTime(2026, 7, 22, 10, 45);
    final File video = File('${root.path}/recording.mp4')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final RecordingSession legacy = RecordingSession(
      id: 'backup-session',
      filePath: video.path,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 1)),
      markers: const <BarcodeMarker>[],
    );
    final File index = File('${root.path}/sessions.json');
    final File backup = File('${index.path}.bak');
    await index.writeAsString('{broken');
    await backup.writeAsString(jsonEncode(<Object?>[legacy.toJson()]));

    final SessionRepository repository = testRepository(root);
    final List<RecordingSession> recovered = await repository.loadSessions();

    expect(recovered.single.id, 'backup-session');
    expect(index.existsSync(), isTrue);
    expect(backup.existsSync(), isTrue);
    expect(File('${index.path}.migrated').existsSync(), isTrue);
    expect(video.existsSync(), isTrue);
  });

  test('旧主索引和备份同时损坏时保留副本并正常启动', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_session_all_corrupt_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final File index = File('${root.path}/sessions.json');
    final File backup = File('${index.path}.bak');
    await index.writeAsString('{main-broken');
    await backup.writeAsString('{backup-broken');

    final SessionRepository repository = testRepository(root);
    final List<RecordingSession> recovered = await repository.loadSessions();

    expect(recovered, isEmpty);
    expect(index.existsSync(), isTrue);
    expect(backup.existsSync(), isTrue);
    expect(
      root.listSync().whereType<File>().where(
        (File file) =>
            file.path.contains('sessions-corrupt-') &&
            file.path.endsWith('.json'),
      ),
      hasLength(1),
    );
    expect(
      root.listSync().whereType<File>().where(
        (File file) =>
            file.path.contains('sessions-backup-corrupt-') &&
            file.path.endsWith('.json'),
      ),
      hasLength(1),
    );
  });

  test('启动时保全完整 pending 录像并隔离残缺与零字节录像', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_pending_recovery_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final Directory pending = Directory('${root.path}/recordings/.pending');
    await pending.create(recursive: true);
    final List<int> videoBytes = playableMp4Bytes();
    final File recoverable = File('${pending.path}/20260723_121314_123.mp4')
      ..writeAsBytesSync(videoBytes);
    final File empty = File('${pending.path}/20260723_121315_456.mp4')
      ..writeAsBytesSync(const <int>[]);

    final SessionRepository repository = testRepository(root);
    final List<RecordingSession> sessions = await repository.loadSessions();

    expect(sessions, hasLength(1));
    expect(sessions.single.id, startsWith('recovered-'));
    expect(sessions.single.startedAt, DateTime(2026, 7, 23, 12, 13, 14, 123));
    expect(sessions.single.displayCode, '未识别面单');
    expect(sessions.single.filePath, contains('异常恢复'));
    expect(File(sessions.single.filePath).readAsBytesSync(), videoBytes);
    expect(recoverable.existsSync(), isFalse);
    expect(empty.existsSync(), isFalse);
    final List<FileSystemEntity> corrupt = Directory(
      '${root.path}/recordings/损坏录像',
    ).listSync(recursive: true);
    expect(
      corrupt.whereType<File>().where(
        (File file) => file.path.endsWith('.mp4'),
      ),
      hasLength(1),
    );
  });

  test('清理水印旧源前重新核对是否仍被录像记录引用', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_watermark_cleanup_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final SessionRepository repository = testRepository(root);
    final DateTime startedAt = DateTime(2026, 7, 22, 11);
    final File source = File('${root.path}/source.mp4')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final String sourcePath = await repository.finalizeVideo(
      sourcePath: source.path,
      sessionId: 'source-session',
      startedAt: startedAt,
      trackingNumber: 'SOURCE',
    );
    await repository.addSession(
      RecordingSession(
        id: 'published-session',
        filePath: sourcePath,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <BarcodeMarker>[],
      ),
    );

    await repository.deleteFileIfUnreferenced(sourcePath);

    expect(File(sourcePath).existsSync(), isTrue);
    expect(await repository.loadSessions(), hasLength(1));
  });

  test('未识别面单和非法字符使用安全业务文件名且冲突追加会话后缀', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_name_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final SessionRepository repository = testRepository(root);
    final DateTime startedAt = DateTime(2026, 7, 19, 9, 8, 7);
    final File firstSource = File('${root.path}/first.mp4')
      ..writeAsBytesSync(<int>[1]);
    final File secondSource = File('${root.path}/second.mp4')
      ..writeAsBytesSync(<int>[2]);
    final File unknownSource = File('${root.path}/unknown.mp4')
      ..writeAsBytesSync(<int>[3]);

    final String first = await repository.finalizeVideo(
      sourcePath: firstSource.path,
      sessionId: 'session-first',
      startedAt: startedAt,
      trackingNumber: 'SF:12/34',
    );
    final String second = await repository.finalizeVideo(
      sourcePath: secondSource.path,
      sessionId: 'session-second',
      startedAt: startedAt,
      trackingNumber: 'SF:12/34',
    );
    final String unknown = await repository.finalizeVideo(
      sourcePath: unknownSource.path,
      sessionId: 'session-unknown',
      startedAt: startedAt.add(const Duration(seconds: 1)),
      trackingNumber: '',
    );

    expect(first, endsWith('SF_12_34_20260719_090807_发货.mp4'));
    expect(second, endsWith('SF_12_34_20260719_090807_发货_onsecond.mp4'));
    expect(unknown, endsWith('未识别面单_20260719_090808_发货.mp4'));
    expect(await repository.recordingPath('pending'), contains('.pending'));
  });

  test('工作模式可持久化并默认使用连续扫码', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_mode_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final SessionRepository repository = testRepository(root);

    expect(await repository.loadWorkMode(), WorkMode.continuousScan);
    await repository.saveWorkMode(WorkMode.sameCodeStop);
    expect(await repository.loadWorkMode(), WorkMode.sameCodeStop);
  });

  test('手动删除保留软删除审计且只删除最后一个文件引用', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_delete_audit_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final SessionRepository repository = testRepository(root);
    final DateTime startedAt = DateTime(2026, 7, 23, 9);
    final File source = File('${root.path}/audit.mp4')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    final String path = await repository.finalizeVideo(
      sourcePath: source.path,
      sessionId: 'audit-session',
      startedAt: startedAt,
      trackingNumber: 'AUDIT001',
    );
    await repository.addSession(
      RecordingSession(
        id: 'audit-session',
        filePath: path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 5)),
        markers: <BarcodeMarker>[
          BarcodeMarker(
            code: 'AUDIT001',
            occurredAt: startedAt,
            offset: Duration.zero,
          ),
        ],
      ),
    );

    await repository.deleteSessions(<String>{'audit-session'});

    expect(await repository.loadSessions(includeMissingFiles: true), isEmpty);
    expect(File(path).existsSync(), isFalse);
    final logs = await repository.loadDeleteLogs();
    expect(logs.single.sessionId, 'audit-session');
    expect(logs.single.trackingNumber, 'AUDIT001');
    expect(logs.single.reason, '手动删除');
    expect(logs.single.fileSizeBytes, 4);
  });

  test('文件缺失只标记状态，不丢弃录像历史', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_missing_audit_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final SessionRepository repository = testRepository(root);
    final DateTime startedAt = DateTime(2026, 7, 23, 10);
    final File video = File('${root.path}/missing.mp4')
      ..writeAsBytesSync(<int>[1]);
    await repository.addSession(
      RecordingSession(
        id: 'missing-session',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <BarcodeMarker>[],
      ),
    );
    await video.delete();

    final List<RecordingSession> sessions = await repository
        .pruneMissingSessions();

    expect(sessions.single.id, 'missing-session');
    expect(
      await repository.loadSessions(includeMissingFiles: true),
      hasLength(1),
    );
    expect(await repository.loadSessions(), isEmpty);
  });

  test('保留策略自动清理写入审计但保留远端历史记录', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_retention_audit_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final SessionRepository repository = testRepository(root);
    final DateTime startedAt = DateTime(2026, 7, 23, 12);
    final File video = File('${root.path}/retained-remote.mp4')
      ..writeAsBytesSync(List<int>.filled(16, 1));
    await repository.addSession(
      RecordingSession(
        id: 'retention-session',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: <BarcodeMarker>[
          BarcodeMarker(
            code: 'RETENTION-1',
            occurredAt: startedAt,
            offset: Duration.zero,
          ),
        ],
      ),
    );
    await video.delete();
    final DateTime deletedAt = DateTime(2026, 8, 1, 8);

    for (var index = 0; index < 2; index++) {
      await repository.recordAutomaticCleanup(
        eventId: 'cleanup-job-1',
        filePath: video.path,
        fileSizeBytes: 16,
        deletedAt: deletedAt,
        reason: '已备份录像保留策略清理',
      );
    }

    expect(
      await repository.loadSessions(includeMissingFiles: true),
      hasLength(1),
    );
    final logs = await repository.loadDeleteLogs();
    expect(logs, hasLength(1));
    expect(logs.single.sessionId, 'retention-session');
    expect(logs.single.fileSizeBytes, 16);
    expect(logs.single.deletedAt, deletedAt);
    expect(logs.single.reason, '已备份录像保留策略清理');
  });

  test('一万条录像可按数据库关键词真实分页', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_large_history_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final SessionRepository repository = testRepository(root);
    final DateTime startedAt = DateTime(2026, 1, 1);
    final List<RecordingSession> sessions = List<RecordingSession>.generate(
      10000,
      (int index) => RecordingSession(
        id: 'large-$index',
        filePath: '${root.path}/large-$index.mp4',
        startedAt: startedAt.add(Duration(seconds: index)),
        endedAt: startedAt.add(Duration(seconds: index + 1)),
        markers: <BarcodeMarker>[
          BarcodeMarker(
            code: 'TRACK${index.toString().padLeft(5, '0')}',
            occurredAt: startedAt.add(Duration(seconds: index)),
            offset: Duration.zero,
          ),
        ],
      ),
      growable: false,
    );
    await repository.addSessions(sessions);

    final first = await repository.querySessions(page: 1, pageSize: 5);
    final searched = await repository.querySessions(
      page: 1,
      pageSize: 5,
      keyword: 'TRACK09999',
    );
    final ranged = await repository.querySessions(
      page: 1,
      pageSize: 5,
      start: startedAt.add(const Duration(seconds: 9990)),
      end: startedAt.add(const Duration(seconds: 10000)),
    );

    expect(first.total, 10000);
    expect(first.data, hasLength(5));
    expect(first.data.first.id, 'large-9999');
    expect(searched.total, 1);
    expect(searched.data.single.id, 'large-9999');
    expect(ranged.total, 10);
    expect(ranged.data.first.id, 'large-9999');
  });

  test('重复单号只核验最近三十天且忽略已删除记录', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_duplicate_tracking_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final SessionRepository repository = testRepository(root);
    final DateTime now = DateTime.now();
    await repository.addSessions(<RecordingSession>[
      RecordingSession(
        id: 'recent',
        filePath: '${root.path}/recent.mp4',
        startedAt: now.subtract(const Duration(days: 29)),
        endedAt: now
            .subtract(const Duration(days: 29))
            .add(const Duration(seconds: 1)),
        markers: <BarcodeMarker>[
          BarcodeMarker(
            code: 'RECENT-TRACK',
            occurredAt: now.subtract(const Duration(days: 29)),
            offset: Duration.zero,
          ),
        ],
      ),
      RecordingSession(
        id: 'old',
        filePath: '${root.path}/old.mp4',
        startedAt: now.subtract(const Duration(days: 31)),
        endedAt: now
            .subtract(const Duration(days: 31))
            .add(const Duration(seconds: 1)),
        markers: <BarcodeMarker>[
          BarcodeMarker(
            code: 'OLD-TRACK',
            occurredAt: now.subtract(const Duration(days: 31)),
            offset: Duration.zero,
          ),
        ],
      ),
    ]);

    expect(await repository.hasRecentTrackingNumber('recent-track'), isTrue);
    expect(await repository.hasRecentTrackingNumber('OLD-TRACK'), isFalse);

    await repository.deleteSessions(<String>{'recent'});
    expect(await repository.hasRecentTrackingNumber('RECENT-TRACK'), isFalse);
  });

  test('备份分页按独立录像记录稳定分页', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_backup_page_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final SessionRepository repository = testRepository(root);
    final DateTime startedAt = DateTime(2026, 7, 23, 11);
    final String firstPath = '${root.path}/a-first.mp4';
    final String secondPath = '${root.path}/b-second.mp4';
    final String thirdPath = '${root.path}/c-third.mp4';
    await repository.addSessions(<RecordingSession>[
      RecordingSession(
        id: 'first',
        filePath: firstPath,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <BarcodeMarker>[],
      ),
      RecordingSession(
        id: 'second',
        filePath: secondPath,
        startedAt: startedAt.add(const Duration(seconds: 1)),
        endedAt: startedAt.add(const Duration(seconds: 2)),
        markers: const <BarcodeMarker>[],
      ),
      RecordingSession(
        id: 'third',
        filePath: thirdPath,
        startedAt: startedAt.add(const Duration(seconds: 2)),
        endedAt: startedAt.add(const Duration(seconds: 3)),
        markers: const <BarcodeMarker>[],
      ),
    ]);

    final first = await repository.loadBackupBatch(page: 1, pageSize: 1);
    final second = await repository.loadBackupBatch(page: 2, pageSize: 1);

    expect(first.single.id, 'first');
    expect(second.single.id, 'second');
  });

  test('旧索引中的共享录像会迁移为独立物理文件', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_mobile_shared_migration_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final File source = File('${root.path}/legacy.mp4');
    await source.writeAsBytes(<int>[1, 2, 3, 4]);
    final DateTime startedAt = DateTime(2026, 7, 23, 12);
    final List<RecordingSession> legacy = <RecordingSession>[
      RecordingSession(
        id: 'legacy-first',
        filePath: source.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <BarcodeMarker>[],
      ),
      RecordingSession(
        id: 'legacy-second',
        filePath: source.path,
        startedAt: startedAt.add(const Duration(seconds: 1)),
        endedAt: startedAt.add(const Duration(seconds: 2)),
        markers: const <BarcodeMarker>[],
        mediaStart: const Duration(seconds: 1),
        mediaEnd: const Duration(seconds: 2),
      ),
    ];
    await File('${root.path}/sessions.json').writeAsString(
      jsonEncode(legacy.map((RecordingSession item) => item.toJson()).toList()),
    );

    final SessionRepository repository = testRepository(root);
    final List<RecordingSession> migrated = await repository.loadSessions();

    expect(migrated, hasLength(2));
    expect(
      migrated.map((RecordingSession item) => item.filePath).toSet(),
      hasLength(2),
    );
    for (final RecordingSession session in migrated) {
      expect(await File(session.filePath).readAsBytes(), <int>[1, 2, 3, 4]);
    }
  });
}
