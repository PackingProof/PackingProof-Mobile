import 'dart:io';

import 'recording_session.dart';
import 'recording_operation_mode.dart';
import 'order_info.dart';
import 'backup_storage_policy.dart';

// 存储阈值与提示数值统一由 BackupStoragePolicy 提供；这里转出，便于本模型与
// 会话控制器的 part 文件直接引用，不必在各处重复导入。
export 'backup_storage_policy.dart';

enum LanBackupJobState { pending, uploading, paused, completed, failed }

enum LanBackupFailureKind {
  credentialInvalid,
  offlineOrTimeout,
  temporaryService,
  uploadExpired,
  verificationFailed,
  storageUnavailable,
  notBackupHost,
  incompatibleVersion,
  unknown;

  static LanBackupFailureKind? fromWireValue(Object? value) {
    return switch ('$value') {
      'credential_invalid' => LanBackupFailureKind.credentialInvalid,
      'offline_or_timeout' => LanBackupFailureKind.offlineOrTimeout,
      'temporary_service' => LanBackupFailureKind.temporaryService,
      'upload_expired' => LanBackupFailureKind.uploadExpired,
      'verification_failed' => LanBackupFailureKind.verificationFailed,
      'storage_unavailable' => LanBackupFailureKind.storageUnavailable,
      'not_backup_host' => LanBackupFailureKind.notBackupHost,
      'incompatible_version' => LanBackupFailureKind.incompatibleVersion,
      'unknown' => LanBackupFailureKind.unknown,
      _ => null,
    };
  }
}

enum LanBackupRecoveryAction {
  rescan,
  retryConnection,
  retryBackup,
  updateComputer,
}

/// 整文件重传类失败每个任务每个周期允许的自动重排上限：上传任务过期、整文件校验
/// 失败和未分类失败都会重新传送整个文件，与协议里「整文件最多尝试 3 次」保持一致。
const int lanBackupAutoRetryAttemptLimit = 3;

/// 播放页展示的备份状态：是否已备份（与录像列表同一判定）与当前备份任务。
///
/// 只在播放页第一次打开时取一次列表值是不够的：手动上传期间任务会在
/// 排队、上传、完成之间变化，卡片必须跟着它刷新。
class LanBackupPlaybackStatus {
  const LanBackupPlaybackStatus({required this.backedUp, this.job});

  /// 对当前连接电脑是否已备份（电脑端录像记录可用才算）。
  final bool backedUp;

  /// 当前备份任务；还没有任务时为 null。
  final LanBackupJob? job;
}

/// 播放页手动上传一条录像的结果，页面据此给出准确提示。
enum LanBackupManualUploadResult {
  /// 已重新排队，正在传到电脑。
  uploading,

  /// 主机不在线（没配对、Wi-Fi 不通或电脑没响应），稍后再试。
  hostOffline,

  /// 这条录像已经在传，不需要重复排队。
  alreadyUploading,

  /// 本机原片不可用（已被清理或被替换），无法上传。
  sourceUnavailable;

  String get message => switch (this) {
    LanBackupManualUploadResult.uploading => '已开始上传到电脑',
    LanBackupManualUploadResult.hostOffline => '主机不在线，请连接主机后重试',
    LanBackupManualUploadResult.alreadyUploading => '正在上传到电脑',
    LanBackupManualUploadResult.sourceUnavailable => '本机原片不可用，无法上传',
  };

  /// 上传中与正在上传，播放页卡片本身就会显示进度，不必再弹一次提示；
  /// 被拦住的情况（主机不在线、原片不可用）才需要告诉操作员原因。
  bool get needsToast => switch (this) {
    LanBackupManualUploadResult.uploading ||
    LanBackupManualUploadResult.alreadyUploading => false,
    LanBackupManualUploadResult.hostOffline ||
    LanBackupManualUploadResult.sourceUnavailable => true,
  };
}

extension LanBackupFailureRecovery on LanBackupFailureKind {
  LanBackupRecoveryAction get recoveryAction => switch (this) {
    LanBackupFailureKind.credentialInvalid ||
    LanBackupFailureKind.notBackupHost => LanBackupRecoveryAction.rescan,
    LanBackupFailureKind.offlineOrTimeout =>
      LanBackupRecoveryAction.retryConnection,
    LanBackupFailureKind.incompatibleVersion =>
      LanBackupRecoveryAction.retryConnection,
    _ => LanBackupRecoveryAction.retryBackup,
  };

  /// 与 Android `LanBackupFailurePolicy.shouldAutoRetry` 一致的暂时性失败集合：
  /// 电脑或网络恢复后应当自动重新排队，不需要操作员手动点重试。
  bool get autoRetryable => switch (this) {
    LanBackupFailureKind.offlineOrTimeout ||
    LanBackupFailureKind.temporaryService ||
    LanBackupFailureKind.storageUnavailable => true,
    _ => false,
  };

  /// 可以靠重新排队自愈、但每次都要整文件重新校验或重新建上传任务的失败。
  ///
  /// 这些失败原生侧不会自己恢复，只能由 Dart 侧重新排队；因为一次重排可能重传整
  /// 个文件，每个任务每个周期只自动重排 [lanBackupAutoRetryAttemptLimit] 次，超过
  /// 后保留人工「重试备份」入口，避免坏文件反复吃掉流量。
  bool get limitedAutoRetryable => switch (this) {
    LanBackupFailureKind.uploadExpired ||
    LanBackupFailureKind.verificationFailed ||
    LanBackupFailureKind.unknown => true,
    _ => false,
  };

  String get recoveryLabel => switch (this) {
    LanBackupFailureKind.credentialInvalid => '重新申请',
    LanBackupFailureKind.offlineOrTimeout => '重试连接',
    LanBackupFailureKind.temporaryService => '稍后重试',
    LanBackupFailureKind.uploadExpired => '重新备份',
    LanBackupFailureKind.verificationFailed => '重新校验并备份',
    LanBackupFailureKind.storageUnavailable => '检查电脑后重试',
    LanBackupFailureKind.notBackupHost => '重新申请',
    LanBackupFailureKind.incompatibleVersion => '重新检查兼容性',
    LanBackupFailureKind.unknown => '重试备份',
  };
}

enum LanConnectionStatus {
  disconnected,
  connecting,
  awaitingApproval,
  approvalDenied,
  approvalUnavailable,
  connected,
  offline,
  rePair,
  notBackupHost,
}

String lanBackupFileIdentity(String path) {
  final String normalized = path.replaceAll('\\', '/');
  return normalized.replaceFirst(
    RegExp(r'^/data/(?:user/0|data)/([^/]+)/'),
    r'/data/app-private/$1/',
  );
}

bool isSameLanBackupFile(String left, String right) =>
    lanBackupFileIdentity(left) == lanBackupFileIdentity(right);

enum RemoteRecordingStatus { available, deleted, missing }

class LanBackupEndpoint {
  const LanBackupEndpoint({
    required this.baseUri,
    required this.accessKey,
    required this.computerId,
    required this.computerName,
    this.lastConnectedAt,
  });

  final Uri baseUri;
  final String accessKey;
  final String computerId;
  final String computerName;
  final DateTime? lastConnectedAt;

  String get displayAddress =>
      baseUri.hasPort ? '${baseUri.host}:${baseUri.port}' : baseUri.host;
}

class LanBackupJob {
  const LanBackupJob({
    this.revision = 0,
    required this.id,
    required this.filePath,
    required this.state,
    required this.uploadedBytes,
    required this.totalBytes,
    this.lastModified,
    this.contentSha256,
    this.errorMessage,
    this.failureKind,
    this.fileCreatedAt,
    this.backupCompletedAt,
    this.scheduledCleanupAt,
    this.localDeletedAt,
    this.waitingCleanup = false,
    this.remoteRecordId,
    this.destinationComputerId = '',
    this.cleanupReason,
  });

  factory LanBackupJob.fromMap(Map<Object?, Object?> map) {
    return LanBackupJob(
      revision: (map['revision'] as num?)?.toInt() ?? 0,
      id: map['id']! as String,
      filePath: map['filePath']! as String,
      state: LanBackupJobState.values.firstWhere(
        (LanBackupJobState value) => value.name == map['state'],
        orElse: () => LanBackupJobState.failed,
      ),
      uploadedBytes: (map['uploadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      lastModified: _dateTime(map['lastModified']),
      contentSha256: map['contentSha256'] as String?,
      errorMessage: map['errorMessage'] as String?,
      failureKind: LanBackupFailureKind.fromWireValue(map['failureKind']),
      fileCreatedAt: _dateTime(map['fileCreatedAt']),
      backupCompletedAt: _dateTime(map['backupCompletedAt']),
      scheduledCleanupAt: _dateTime(map['scheduledCleanupAt']),
      localDeletedAt: _dateTime(map['localDeletedAt']),
      waitingCleanup: map['waitingCleanup'] == true,
      remoteRecordId: (map['remoteRecordId'] as num?)?.toInt(),
      destinationComputerId: '${map['destinationComputerId'] ?? ''}',
      cleanupReason: map['cleanupReason'] as String?,
    );
  }

  final int revision;
  final String id;
  final String filePath;
  final LanBackupJobState state;
  final int uploadedBytes;
  final int totalBytes;
  final DateTime? lastModified;
  final String? contentSha256;
  final String? errorMessage;
  final LanBackupFailureKind? failureKind;
  final DateTime? fileCreatedAt;
  final DateTime? backupCompletedAt;
  final DateTime? scheduledCleanupAt;
  final DateTime? localDeletedAt;
  final bool waitingCleanup;
  final int? remoteRecordId;
  final String destinationComputerId;
  final String? cleanupReason;

  double get progress => totalBytes <= 0 ? 0 : uploadedBytes / totalBytes;
}

class LanBackupJobsByPaths {
  const LanBackupJobsByPaths({
    required this.revision,
    required this.jobs,
    required this.missingPaths,
  });

  final int revision;
  final List<LanBackupJob> jobs;
  final Set<String> missingPaths;
}

class LanBackupCleanupEvent {
  const LanBackupCleanupEvent({
    required this.revision,
    required this.eventId,
    required this.jobId,
    required this.filePath,
    required this.fileSizeBytes,
    required this.deletedAt,
    required this.reason,
  });

  final int revision;
  final String eventId;
  final String jobId;
  final String filePath;
  final int fileSizeBytes;
  final DateTime deletedAt;
  final String reason;
}

class LanBackupCleanupPage {
  const LanBackupCleanupPage({
    required this.latestRevision,
    required this.nextAfterRevision,
    required this.hasMore,
    required this.events,
  });

  final int latestRevision;
  final int nextAfterRevision;
  final bool hasMore;
  final List<LanBackupCleanupEvent> events;
}

class LanBackupSummary {
  const LanBackupSummary({
    this.revision = 0,
    this.completedRevision = 0,
    this.cleanupHighWatermark = 0,
    this.totalCount = 0,
    this.pendingCount = 0,
    this.uploadingCount = 0,
    this.pausedCount = 0,
    this.completedCount = 0,
    this.failedCount = 0,
    this.waitingCleanupCount = 0,
    this.localDeletedCount = 0,
    this.unfinishedUploadedBytes = 0,
    this.unfinishedTotalBytes = 0,
    this.activeJob,
    this.problemJob,
    this.dominantFailureKind,
  });

  final int revision;
  final int completedRevision;
  final int cleanupHighWatermark;
  final int totalCount;
  final int pendingCount;
  final int uploadingCount;
  final int pausedCount;
  final int completedCount;
  final int failedCount;
  final int waitingCleanupCount;
  final int localDeletedCount;
  final int unfinishedUploadedBytes;
  final int unfinishedTotalBytes;
  final LanBackupJob? activeJob;
  final LanBackupJob? problemJob;
  final LanBackupFailureKind? dominantFailureKind;

  int get unfinishedCount =>
      pendingCount + uploadingCount + pausedCount + failedCount;

  double get aggregateProgress => unfinishedTotalBytes <= 0
      ? 0
      : (unfinishedUploadedBytes / unfinishedTotalBytes).clamp(0, 1);
}

class StorageSpaceResult {
  const StorageSpaceResult({
    required this.availableBytes,
    required this.availableBytesBefore,
    required this.freedBytes,
    required this.deletedCount,
    required this.warning,
    required this.insufficient,
  });

  factory StorageSpaceResult.fromMap(Map<Object?, Object?> map) {
    return StorageSpaceResult(
      availableBytes: (map['availableBytes'] as num?)?.toInt() ?? 0,
      availableBytesBefore: (map['availableBytesBefore'] as num?)?.toInt() ?? 0,
      freedBytes: (map['freedBytes'] as num?)?.toInt() ?? 0,
      deletedCount: (map['deletedCount'] as num?)?.toInt() ?? 0,
      warning: map['warning'] == true,
      insufficient: map['insufficient'] == true,
    );
  }

  final int availableBytes;
  final int availableBytesBefore;
  final int freedBytes;
  final int deletedCount;
  final bool warning;
  final bool insufficient;

  /// 空间不足导致无法开始录像时展示给操作员的说明。
  String get insufficientMessage =>
      BackupStoragePolicy.insufficientToStartMessage;
}

/// 播放/备份诊断用的网络状态快照（无信号时字段为 null）。
class NetworkDiagnostics {
  const NetworkDiagnostics({
    required this.wifiConnected,
    this.rssiDbm,
    this.linkSpeedMbps,
  });

  factory NetworkDiagnostics.fromMap(Map<Object?, Object?> map) {
    return NetworkDiagnostics(
      wifiConnected: map['wifiConnected'] == true,
      rssiDbm: (map['rssiDbm'] as num?)?.toInt(),
      linkSpeedMbps: (map['linkSpeedMbps'] as num?)?.toInt(),
    );
  }

  final bool wifiConnected;
  final int? rssiDbm;
  final int? linkSpeedMbps;
}

class LanBackupSnapshot {
  const LanBackupSnapshot({
    this.endpoint,
    this.summary = const LanBackupSummary(),
    this.autoEnabled = true,
    this.message,
    this.connectionStatus = LanConnectionStatus.disconnected,
    this.deviceId = '',
    this.deviceName = '',
    this.preferredHostId = '',
    this.preferredHostName = '',
    this.mobileAppUpdate,
  });

  final LanBackupEndpoint? endpoint;
  final LanBackupSummary summary;
  final bool autoEnabled;
  final String? message;
  final LanConnectionStatus connectionStatus;
  final String deviceId;
  final String deviceName;
  final String preferredHostId;
  final String preferredHostName;
  final MobileAppUpdateNotice? mobileAppUpdate;

  bool get connected => endpoint != null;
  int get pendingCount => summary.unfinishedCount;
  int get activeCount =>
      summary.pendingCount + summary.uploadingCount + summary.pausedCount;
  int get completedCount => summary.completedCount;
  double get aggregateProgress => summary.aggregateProgress;

  LanBackupSnapshot copyWith({
    LanBackupEndpoint? endpoint,
    bool clearEndpoint = false,
    LanBackupSummary? summary,
    bool? autoEnabled,
    String? message,
    bool clearMessage = false,
    LanConnectionStatus? connectionStatus,
    String? deviceId,
    String? deviceName,
    String? preferredHostId,
    String? preferredHostName,
    MobileAppUpdateNotice? mobileAppUpdate,
    bool clearMobileAppUpdate = false,
  }) {
    return LanBackupSnapshot(
      endpoint: clearEndpoint ? null : endpoint ?? this.endpoint,
      summary: summary ?? this.summary,
      autoEnabled: autoEnabled ?? this.autoEnabled,
      message: clearMessage ? null : message ?? this.message,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      preferredHostId: preferredHostId ?? this.preferredHostId,
      preferredHostName: preferredHostName ?? this.preferredHostName,
      mobileAppUpdate: clearMobileAppUpdate
          ? null
          : mobileAppUpdate ?? this.mobileAppUpdate,
    );
  }
}

class MobileAppUpdateNotice {
  const MobileAppUpdateNotice({
    required this.minimumVersion,
    required this.minimumBuildNumber,
    required this.message,
    this.latestVersion = '',
    this.latestBuildNumber = 0,
    this.updateRequired = true,
  });

  final String minimumVersion;
  final int minimumBuildNumber;
  final String message;
  final String latestVersion;
  final int latestBuildNumber;
  final bool updateRequired;

  String get signature =>
      '${latestVersion.isEmpty ? minimumVersion : latestVersion}+'
      '${latestBuildNumber <= 0 ? minimumBuildNumber : latestBuildNumber}';
}

class RemoteRecording {
  const RemoteRecording({
    required this.id,
    required this.trackingNumber,
    required this.startedAt,
    required this.duration,
    required this.sourceType,
    required this.sourceDeviceId,
    required this.sourceDeviceName,
    required this.sourceSessionId,
    required this.contentSha256,
    required this.playUri,
    this.videoCodec = '',
    this.thumbnailUri,
    this.exists = true,
    this.status = RemoteRecordingStatus.available,
    this.statusReason = '',
    this.orderInfo,
    this.operationMode = RecordingOperationMode.shipping,
  });

  factory RemoteRecording.fromJson(Map<String, Object?> json, Uri baseUri) {
    final String rawStart = '${json['startTime'] ?? ''}';
    return RemoteRecording(
      id: (json['id'] as num).toInt(),
      trackingNumber: '${json['trackingNumber'] ?? json['orderId'] ?? ''}',
      startedAt:
          DateTime.tryParse(rawStart) ?? DateTime.fromMillisecondsSinceEpoch(0),
      duration: Duration(
        milliseconds: (((json['durationSec'] as num?) ?? 0) * 1000).round(),
      ),
      sourceType: '${json['sourceType'] ?? 'pc'}',
      sourceDeviceId: '${json['sourceDeviceId'] ?? ''}',
      sourceDeviceName: '${json['sourceDeviceName'] ?? ''}',
      sourceSessionId: '${json['sourceSessionId'] ?? ''}',
      contentSha256: '${json['contentSha256'] ?? ''}',
      videoCodec: '${json['videoCodec'] ?? ''}',
      playUri: baseUri.resolve(
        '${json['playUrl'] ?? '/api/mobile-backup/videos/${json['id']}/play?compat=0'}',
      ),
      thumbnailUri: json['thumbnailUrl'] == null
          ? null
          : baseUri.resolve('${json['thumbnailUrl']}'),
      exists: json['exists'] != false,
      orderInfo: _orderInfoFromRemoteJson(json),
      operationMode: recordingOperationModeFromStorage(json['mode']),
    );
  }

  final int id;
  final String trackingNumber;
  final DateTime startedAt;
  final Duration duration;
  final String sourceType;
  final String sourceDeviceId;
  final String sourceDeviceName;
  final String sourceSessionId;
  final String contentSha256;
  final String videoCodec;
  final Uri playUri;
  final Uri? thumbnailUri;
  final bool exists;
  final RemoteRecordingStatus status;
  final String statusReason;
  final OrderInfo? orderInfo;
  final RecordingOperationMode operationMode;

  RemoteRecording withStatus({
    required RemoteRecordingStatus status,
    required bool exists,
    String reason = '',
  }) => RemoteRecording(
    id: id,
    trackingNumber: trackingNumber,
    startedAt: startedAt,
    duration: duration,
    sourceType: sourceType,
    sourceDeviceId: sourceDeviceId,
    sourceDeviceName: sourceDeviceName,
    sourceSessionId: sourceSessionId,
    contentSha256: contentSha256,
    videoCodec: videoCodec,
    playUri: playUri,
    thumbnailUri: thumbnailUri,
    exists: exists,
    status: status,
    statusReason: reason,
    orderInfo: orderInfo,
    operationMode: operationMode,
  );
}

OrderInfo? _orderInfoFromRemoteJson(Map<String, Object?> json) {
  final OrderInfo value = OrderInfo.fromMap(<Object?, Object?>{
    'trackingNumber': json['trackingNumber'] ?? json['orderId'] ?? '',
    'orderId': json['sourceOrderId'] ?? '',
    'buyerMessage': json['buyerMessage'] ?? '',
    'sellerMemo': json['sellerMemo'] ?? '',
    'productInfo': json['productInfo'] ?? '',
    if (json['orderInfo'] is Map)
      ...Map<Object?, Object?>.from(json['orderInfo']! as Map),
  });
  return value.details.length <= 1 && value.orderId.isEmpty ? null : value;
}

class RemoteRecordingPage {
  const RemoteRecordingPage({
    required this.data,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.deviceTotal,
  });

  const RemoteRecordingPage.empty()
    : data = const <RemoteRecording>[],
      page = 1,
      pageSize = 5,
      total = 0,
      deviceTotal = 0;

  final List<RemoteRecording> data;
  final int page;
  final int pageSize;
  final int total;
  final int deviceTotal;

  int get pageCount => total <= 0 ? 0 : (total + pageSize - 1) ~/ pageSize;
  bool get hasMore => page < pageCount;
}

DateTime? _dateTime(Object? value) => switch (value) {
  String text => DateTime.tryParse(text),
  num milliseconds => DateTime.fromMillisecondsSinceEpoch(
    milliseconds.toInt(),
    isUtc: true,
  ),
  _ => null,
};

Map<String, Object?> recordingSessionBackupMap(RecordingSession session) {
  return <String, Object?>{
    'id': session.id,
    'trackingNumber': session.displayCode,
    'startedAt': session.startedAt.toUtc().toIso8601String(),
    'endedAt': session.endedAt.toUtc().toIso8601String(),
    'mediaStartMs': session.mediaStart.inMilliseconds,
    'mediaEndMs': session.playbackEnd.inMilliseconds,
    'mode': session.operationMode.storageValue,
    if (session.videoCodec.isNotEmpty) 'videoCodec': session.videoCodec,
    'markers': session.markers
        .map(
          (marker) => <String, Object?>{
            'code': marker.code,
            'occurredAt': marker.occurredAt.toUtc().toIso8601String(),
            'offsetMs': marker.offset.inMilliseconds,
          },
        )
        .toList(growable: false),
  };
}

bool isPrivateLanAddress(InternetAddress address) {
  if (address.type == InternetAddressType.IPv4) {
    final List<int> bytes = address.rawAddress;
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254);
  }
  final List<int> bytes = address.rawAddress;
  return (bytes[0] & 0xFE) == 0xFC ||
      (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80);
}
