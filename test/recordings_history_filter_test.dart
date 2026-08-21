import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/screens/recordings_history_filter.dart';

void main() {
  test('关键词筛选保持单号、日期和订单字段的既有匹配范围', () {
    final RecordingSession session = _session(
      id: 'local-1',
      code: 'JT1234567890',
      startedAt: DateTime(2026, 8, 20, 9, 5),
    );

    expect(
      filterRecordingSessionsByQuery(<RecordingSession>[session], 'JT123'),
      [session],
    );
    expect(
      filterRecordingSessionsByQuery(<RecordingSession>[session], '2026-08-20'),
      [session],
    );
    expect(
      filterRecordingSessionsByQuery(<RecordingSession>[session], '8月20日'),
      [session],
    );
    expect(
      filterRecordingSessionsByQuery(<RecordingSession>[session], 'missing'),
      isEmpty,
    );
  });

  test('日期预设生成左闭右开窗口并保留原有标签', () {
    final DateTime now = DateTime(2026, 8, 21, 15);
    expect(
      recordingHistoryDateWindow(
        preset: RecordingHistoryDatePreset.last7Days,
        now: now,
      ),
      (start: DateTime(2026, 8, 15), end: DateTime(2026, 8, 22)),
    );
    expect(
      recordingHistoryDateWindow(
        preset: RecordingHistoryDatePreset.custom,
        now: now,
        customStart: DateTime(2026, 8, 1),
        customEnd: DateTime(2026, 8, 3),
      ),
      (start: DateTime(2026, 8, 1), end: DateTime(2026, 8, 4)),
    );
    expect(
      recordingHistoryDateFilterLabel(
        preset: RecordingHistoryDatePreset.custom,
        customStart: DateTime(2026, 8, 1),
        customEnd: DateTime(2026, 8, 3),
      ),
      '8月1日-8月3日',
    );
  });

  test('本地和远端按 session 合并后再应用来源与隐藏筛选', () {
    final RecordingSession pairedLocal = _session(
      id: 'paired',
      code: 'PAIRED',
      startedAt: DateTime(2026, 8, 21, 10),
      filePath: '/recordings/paired.mp4',
    );
    final RecordingSession missingLocal = _session(
      id: 'missing-local',
      code: 'MISSING',
      startedAt: DateTime(2026, 8, 21, 8),
      filePath: '/recordings/missing.mp4',
    );
    final RemoteRecording pairedRemote = _remote(
      id: 1,
      code: 'PAIRED',
      startedAt: DateTime(2026, 8, 21, 10),
      sourceDeviceId: 'this-device',
      sourceSessionId: 'paired',
    );
    final RemoteRecording computerRemote = _remote(
      id: 2,
      code: 'COMPUTER',
      startedAt: DateTime(2026, 8, 21, 9),
      sourceDeviceId: 'computer',
    );
    final RemoteRecording hiddenRemote = _remote(
      id: 3,
      code: 'HIDDEN',
      startedAt: DateTime(2026, 8, 21, 11),
      sourceDeviceId: 'computer',
    );
    final List<RecordingHistoryItem> all = buildVisibleRecordingHistoryItems(
      localSessions: <RecordingSession>[pairedLocal, missingLocal],
      remoteRecordings: <RemoteRecording>[
        pairedRemote,
        computerRemote,
        hiddenRemote,
      ],
      hiddenRemoteIds: <int>{3},
      localRecordingPaths: <String>{pairedLocal.filePath},
      sourceFilter: RecordingSourceFilter.all,
      isRemoteFromThisDevice: (RemoteRecording remote) =>
          remote.sourceDeviceId == 'this-device',
      isLocalBackedUp: (RecordingSession local) => local.id == 'missing-local',
    );

    expect(all, hasLength(3));
    expect(all.first.local, pairedLocal);
    expect(all.first.remote, pairedRemote);
    expect(all.map((RecordingHistoryItem item) => item.remote?.id), [
      1,
      2,
      null,
    ]);

    List<RecordingHistoryItem> filtered(RecordingSourceFilter sourceFilter) =>
        buildVisibleRecordingHistoryItems(
          localSessions: <RecordingSession>[pairedLocal, missingLocal],
          remoteRecordings: <RemoteRecording>[pairedRemote, computerRemote],
          hiddenRemoteIds: const <int>{},
          localRecordingPaths: <String>{pairedLocal.filePath},
          sourceFilter: sourceFilter,
          isRemoteFromThisDevice: (RemoteRecording remote) =>
              remote.sourceDeviceId == 'this-device',
          isLocalBackedUp: (RecordingSession local) =>
              local.id == 'missing-local',
        );

    expect(filtered(RecordingSourceFilter.local).single.local, pairedLocal);
    expect(filtered(RecordingSourceFilter.backedUp), hasLength(2));
    expect(
      filtered(RecordingSourceFilter.computer).single.remote,
      computerRemote,
    );
  });
}

RecordingSession _session({
  required String id,
  required String code,
  required DateTime startedAt,
  String filePath = '/recordings/video.mp4',
}) => RecordingSession(
  id: id,
  filePath: filePath,
  startedAt: startedAt,
  endedAt: startedAt.add(const Duration(seconds: 8)),
  markers: <BarcodeMarker>[
    BarcodeMarker(code: code, occurredAt: startedAt, offset: Duration.zero),
  ],
);

RemoteRecording _remote({
  required int id,
  required String code,
  required DateTime startedAt,
  required String sourceDeviceId,
  String sourceSessionId = '',
}) => RemoteRecording(
  id: id,
  trackingNumber: code,
  startedAt: startedAt,
  duration: const Duration(seconds: 8),
  sourceType: 'external',
  sourceDeviceId: sourceDeviceId,
  sourceDeviceName: '',
  sourceSessionId: sourceSessionId,
  contentSha256: '',
  status: RemoteRecordingStatus.available,
  exists: true,
  playUri: Uri.parse('http://127.0.0.1/video/$id'),
);
