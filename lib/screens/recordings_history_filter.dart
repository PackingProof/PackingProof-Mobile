import 'package:flutter/foundation.dart';

import '../models/barcode_marker.dart';
import '../models/lan_backup.dart';
import '../models/recording_session.dart';
import '../models/recording_operation_mode.dart';

/// 来源筛选：本地 / 已备份 / 全部，或某台具体设备。
///
/// 电脑端只用一个 `sourceType` 字段区分本机（`pc`）与外接设备（`external`），
/// 所以"电脑录像"以前会把主机和各从机的录像混在一起；这里改为按设备分开筛。
enum RecordingSourceFilterKind { all, local, backedUp, device }

@immutable
class RecordingSourceFilter {
  const RecordingSourceFilter._(this.kind, this.deviceKey);

  const RecordingSourceFilter.all()
    : this._(RecordingSourceFilterKind.all, null);

  const RecordingSourceFilter.local()
    : this._(RecordingSourceFilterKind.local, null);

  const RecordingSourceFilter.backedUp()
    : this._(RecordingSourceFilterKind.backedUp, null);

  const RecordingSourceFilter.device(String deviceKey)
    : this._(RecordingSourceFilterKind.device, deviceKey);

  final RecordingSourceFilterKind kind;

  /// 仅 [RecordingSourceFilterKind.device] 有值。
  final String? deviceKey;

  /// 判断一条录像是否命中该筛选；事实由调用方按文件系统与备份状态算好。
  bool matches(RecordingSourceFacts facts) => switch (kind) {
    RecordingSourceFilterKind.all => true,
    RecordingSourceFilterKind.local => facts.hasLocalFile,
    RecordingSourceFilterKind.backedUp => facts.backedUp,
    RecordingSourceFilterKind.device =>
      facts.sourceDeviceKey != null && facts.sourceDeviceKey == deviceKey,
  };

  @override
  bool operator ==(Object other) =>
      other is RecordingSourceFilter &&
      other.kind == kind &&
      other.deviceKey == deviceKey;

  @override
  int get hashCode => Object.hash(kind, deviceKey);

  @override
  String toString() =>
      'RecordingSourceFilter(${kind.name}${deviceKey == null ? '' : ':$deviceKey'})';
}

/// 判断一条录像命中筛选所需的事实。
typedef RecordingSourceFacts = ({
  bool hasLocalFile,
  bool backedUp,
  String? sourceDeviceKey,
});

/// 来源筛选项：并列出一个筛选项与其显示名。
typedef RecordingSourceOption = ({RecordingSourceFilter filter, String label});

/// 一台来源设备的筛选键：优先用设备 ID，退回显示名。
String recordingSourceDeviceKey({
  required String sourceDeviceId,
  required String sourceDeviceName,
}) {
  final String id = sourceDeviceId.trim();
  if (id.isNotEmpty) return id;
  return 'name:${sourceDeviceName.trim()}';
}

/// 来源设备的显示名：主机（电脑本机）与各从机分别显示自己的名字。
String recordingSourceDeviceLabel(
  RemoteRecording remote, {
  String pairedComputerName = '',
}) {
  final String name = remote.sourceDeviceName.trim();
  if (remote.sourceType.toLowerCase() != 'external') {
    if (name.isNotEmpty) return name;
    final String paired = pairedComputerName.trim();
    return paired.isEmpty ? '电脑' : paired;
  }
  return name.isEmpty ? '外接设备' : name;
}

/// 组装来源筛选项：固定项在前，随后按设备分别列出。
///
/// 设备项来自当前可见录像，所以只会出现真的存在录像的来源；主机（本机）
/// 与各从机各自一项，不再用"电脑录像"把多台机器混在一起。
List<RecordingSourceOption> recordingSourceOptions({
  required Iterable<RemoteRecording> remoteRecordings,
  String pairedComputerName = '',
}) {
  final Map<String, String> labels = <String, String>{};
  for (final RemoteRecording remote in remoteRecordings) {
    final String key = recordingSourceDeviceKey(
      sourceDeviceId: remote.sourceDeviceId,
      sourceDeviceName: remote.sourceDeviceName,
    );
    labels.putIfAbsent(
      key,
      () => recordingSourceDeviceLabel(
        remote,
        pairedComputerName: pairedComputerName,
      ),
    );
  }
  final List<String> keys = labels.keys.toList()
    ..sort((String a, String b) => labels[a]!.compareTo(labels[b]!));
  return <RecordingSourceOption>[
    (filter: const RecordingSourceFilter.all(), label: '全部来源'),
    (filter: const RecordingSourceFilter.local(), label: '本地'),
    (filter: const RecordingSourceFilter.backedUp(), label: '已备份'),
    for (final String key in keys)
      (filter: RecordingSourceFilter.device(key), label: labels[key]!),
  ];
}

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

/// 来源筛选的显示名。[deviceLabel] 用于设备项（例如"从机2"）。
String recordingHistorySourceFilterLabel(
  RecordingSourceFilter value, {
  String? deviceLabel,
}) => switch (value.kind) {
  RecordingSourceFilterKind.all => '全部来源',
  RecordingSourceFilterKind.local => '本地',
  RecordingSourceFilterKind.backedUp => '已备份',
  RecordingSourceFilterKind.device =>
    deviceLabel?.trim().isNotEmpty == true ? deviceLabel!.trim() : '其他设备',
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
  RecordingOperationMode? operationMode,
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
        return (operationMode == null ||
                item.session.operationMode == operationMode) &&
            inDateRange &&
            sourceFilter.matches((
              hasLocalFile: hasLocalFile,
              backedUp: backedUp,
              sourceDeviceKey: item.remote == null
                  ? null
                  : recordingSourceDeviceKey(
                      sourceDeviceId: item.remote!.sourceDeviceId,
                      sourceDeviceName: item.remote!.sourceDeviceName,
                    ),
            ));
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
      videoCodec: value.videoCodec,
    );
  }
}

String _two(int number) => number.toString().padLeft(2, '0');
