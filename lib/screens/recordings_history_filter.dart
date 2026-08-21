import '../models/barcode_marker.dart';
import '../models/lan_backup.dart';
import '../models/recording_session.dart';

enum RecordingSourceFilter { all, local, backedUp, computer }

enum RecordingHistoryDatePreset { all, today, last7Days, last30Days, custom }

typedef RecordingHistoryDateWindow = ({DateTime start, DateTime end});

RecordingHistoryDateWindow? recordingHistoryDateWindow({
  required RecordingHistoryDatePreset preset,
  required DateTime now,
  DateTime? customStart,
  DateTime? customEnd,
}) {
  final DateTime today = DateTime(now.year, now.month, now.day);
  return switch (preset) {
    RecordingHistoryDatePreset.all => null,
    RecordingHistoryDatePreset.today => (
      start: today,
      end: today.add(const Duration(days: 1)),
    ),
    RecordingHistoryDatePreset.last7Days => (
      start: today.subtract(const Duration(days: 6)),
      end: today.add(const Duration(days: 1)),
    ),
    RecordingHistoryDatePreset.last30Days => (
      start: today.subtract(const Duration(days: 29)),
      end: today.add(const Duration(days: 1)),
    ),
    RecordingHistoryDatePreset.custom => switch ((customStart, customEnd)) {
      (final DateTime start, final DateTime end) => (
        start: start,
        end: end.add(const Duration(days: 1)),
      ),
      _ => null,
    },
  };
}

String recordingHistoryDateFilterLabel({
  required RecordingHistoryDatePreset preset,
  DateTime? customStart,
  DateTime? customEnd,
}) => switch (preset) {
  RecordingHistoryDatePreset.all => '全部日期',
  RecordingHistoryDatePreset.today => '今天',
  RecordingHistoryDatePreset.last7Days => '最近7天',
  RecordingHistoryDatePreset.last30Days => '最近30天',
  RecordingHistoryDatePreset.custom => switch ((customStart, customEnd)) {
    (final DateTime start, final DateTime end) =>
      '${start.month}月${start.day}日-${end.month}月${end.day}日',
    _ => '全部日期',
  },
};

String recordingHistoryDatePresetOptionLabel(
  RecordingHistoryDatePreset preset,
) => switch (preset) {
  RecordingHistoryDatePreset.all => '全部日期',
  RecordingHistoryDatePreset.today => '今天',
  RecordingHistoryDatePreset.last7Days => '最近7天',
  RecordingHistoryDatePreset.last30Days => '最近30天',
  RecordingHistoryDatePreset.custom => '自定义范围',
};

String recordingHistorySourceFilterLabel(RecordingSourceFilter value) =>
    switch (value) {
      RecordingSourceFilter.all => '全部来源',
      RecordingSourceFilter.local => '本地',
      RecordingSourceFilter.backedUp => '已备份',
      RecordingSourceFilter.computer => '电脑录像',
    };

List<RecordingSession> filterRecordingSessionsByQuery(
  Iterable<RecordingSession> sessions,
  String rawQuery,
) {
  final String query = rawQuery.trim().toLowerCase();
  if (query.isEmpty) return List<RecordingSession>.of(sessions);
  return sessions
      .where((RecordingSession session) {
        final DateTime value = session.startedAt;
        final String searchable =
            '${session.displayCode} '
            '${value.year}-${_two(value.month)}-${_two(value.day)} '
            '${value.month}月${value.day}日 '
            '${_two(value.hour)}:${_two(value.minute)} '
            '${session.orderInfo?.orderId ?? ''} '
            '${session.orderInfo?.buyerMessage ?? ''} '
            '${session.orderInfo?.sellerMemo ?? ''} '
            '${session.orderInfo?.productInfo ?? ''}';
        return searchable.toLowerCase().contains(query);
      })
      .toList(growable: false);
}

List<RecordingHistoryItem> buildVisibleRecordingHistoryItems({
  required Iterable<RecordingSession> localSessions,
  required Iterable<RemoteRecording> remoteRecordings,
  required Set<int> hiddenRemoteIds,
  required Set<String> localRecordingPaths,
  required RecordingSourceFilter sourceFilter,
  required bool Function(RemoteRecording remote) isRemoteFromThisDevice,
  required bool Function(RecordingSession local) isLocalBackedUp,
  RecordingHistoryDateWindow? dateWindow,
}) {
  final Map<String, RemoteRecording> remoteBySession =
      <String, RemoteRecording>{
        for (final RemoteRecording remote in remoteRecordings)
          if (remote.sourceSessionId.isNotEmpty &&
              isRemoteFromThisDevice(remote))
            remote.sourceSessionId: remote,
      };
  final List<RecordingHistoryItem> values = localSessions
      .map(
        (RecordingSession local) => RecordingHistoryItem(
          local: local,
          remote: remoteBySession.remove(local.id),
        ),
      )
      .toList();
  final Set<int> includedRemoteIds = values
      .map((RecordingHistoryItem item) => item.remote?.id)
      .whereType<int>()
      .toSet();
  for (final RemoteRecording remote in remoteRecordings) {
    if (!hiddenRemoteIds.contains(remote.id) &&
        includedRemoteIds.add(remote.id)) {
      values.add(RecordingHistoryItem(remote: remote));
    }
  }
  values.sort(
    (RecordingHistoryItem a, RecordingHistoryItem b) =>
        b.startedAt.compareTo(a.startedAt),
  );
  return values
      .where((RecordingHistoryItem item) {
        final bool inDateRange =
            dateWindow == null ||
            (!item.startedAt.isBefore(dateWindow.start) &&
                item.startedAt.isBefore(dateWindow.end));
        final bool hasLocalFile =
            item.local != null &&
            localRecordingPaths.contains(item.local!.filePath);
        final bool backedUp =
            (item.remote != null &&
                isRemoteFromThisDevice(item.remote!) &&
                item.remote!.status == RemoteRecordingStatus.available &&
                item.remote!.exists) ||
            (item.local != null && isLocalBackedUp(item.local!));
        return inDateRange &&
            switch (sourceFilter) {
              RecordingSourceFilter.all => true,
              RecordingSourceFilter.local => hasLocalFile,
              RecordingSourceFilter.backedUp => backedUp,
              RecordingSourceFilter.computer =>
                !hasLocalFile && item.remote != null,
            };
      })
      .toList(growable: false);
}

class RecordingHistoryItem {
  const RecordingHistoryItem({this.local, this.remote})
    : assert(local != null || remote != null);

  final RecordingSession? local;
  final RemoteRecording? remote;

  DateTime get startedAt => local?.startedAt ?? remote!.startedAt;

  RecordingSession get session {
    if (local != null) return local!;
    final RemoteRecording value = remote!;
    return RecordingSession(
      id: 'remote-${value.id}',
      filePath: '',
      startedAt: value.startedAt,
      endedAt: value.startedAt.add(value.duration),
      markers: value.trackingNumber.isEmpty
          ? const <BarcodeMarker>[]
          : <BarcodeMarker>[
              BarcodeMarker(
                code: value.trackingNumber,
                occurredAt: value.startedAt,
                offset: Duration.zero,
              ),
            ],
      orderInfo: value.orderInfo,
      operationMode: value.operationMode,
    );
  }
}

String _two(int number) => number.toString().padLeft(2, '0');
