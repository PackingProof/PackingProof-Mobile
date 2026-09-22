import '../contracts/backup_platform.dart';
import '../generated/platform_api.g.dart';

class PigeonBackupNativePlatform implements BackupNativePlatform {
  PigeonBackupNativePlatform({BackupNativeHostApi? hostApi})
    : _hostApi = hostApi ?? BackupNativeHostApi() {
    _eventSink = _BackupNativeEventSink(this);
    BackupNativeEventApi.setUp(_eventSink);
  }

  final BackupNativeHostApi _hostApi;
  late final _BackupNativeEventSink _eventSink;
  void Function(BackupSummaryDto summary)? _summaryListener;

  @override
  void setSummaryListener(void Function(BackupSummaryDto summary)? listener) {
    _summaryListener = listener;
  }

  @override
  Future<BackupSummaryDto> summary() => _hostApi.summary();

  @override
  Future<BackupSummaryDto> initialize(Map<Object?, Object?> request) =>
      _hostApi.initialize(_wireMap(request));

  @override
  Future<void> setAutoEnabled(bool enabled) => _hostApi.setAutoEnabled(enabled);

  @override
  Future<BackupJobsByPathsDto> jobsForPaths(List<String> paths) =>
      _hostApi.jobsForPaths(paths);

  @override
  Future<BackupCleanupPageDto> cleanupEvents({
    required int afterRevision,
    required int limit,
  }) => _hostApi.cleanupEvents(afterRevision, limit);

  @override
  Future<void> acknowledgeCleanupEvents(int throughRevision) =>
      _hostApi.acknowledgeCleanupEvents(throughRevision);

  @override
  Future<bool> hasPendingJobsOutsideDestination(String computerId) =>
      _hostApi.hasPendingJobsOutsideDestination(computerId);

  @override
  Future<String?> loadAccessKey() => _hostApi.loadAccessKey();

  @override
  Future<bool> isWifiConnected() => _hostApi.isWifiConnected();

  @override
  Future<void> saveConnection(Map<Object?, Object?> connection) =>
      _hostApi.saveConnection(_wireMap(connection));

  @override
  Future<void> disconnect() => _hostApi.disconnect();

  @override
  Future<void> enqueueJob(Map<Object?, Object?> request) =>
      _hostApi.enqueueJob(_wireMap(request));

  @override
  Future<void> enqueueJobs(List<Map<Object?, Object?>> requests) =>
      _hostApi.enqueueJobs(requests.map(_wireMap).toList(growable: false));

  @override
  Future<void> requeueJob(String jobId, {bool manual = false}) =>
      _hostApi.requeueJob(jobId, manual);

  @override
  Future<void> cancelJob(String jobId) => _hostApi.cancelJob(jobId);

  @override
  Future<void> updateRetentionSchedule(Map<Object?, Object?> request) =>
      _hostApi.updateRetentionSchedule(_wireMap(request));

  @override
  Future<int?> availableRecordingStorageBytes() =>
      _hostApi.availableRecordingStorageBytes();

  @override
  Future<Map<Object?, Object?>?> reclaimStorageIfNeeded() async =>
      _map(await _hostApi.reclaimStorageIfNeeded());

  @override
  Future<Map<Object?, Object?>?> getNetworkDiagnostics() async =>
      _map(await _hostApi.getNetworkDiagnostics());

  @override
  Future<void> dispose() async {
    BackupNativeEventApi.setUp(null);
    _summaryListener = null;
  }
}

class _BackupNativeEventSink extends BackupNativeEventApi {
  _BackupNativeEventSink(this._platform);

  final PigeonBackupNativePlatform _platform;

  @override
  void summaryChanged(BackupSummaryDto summary) {
    _platform._summaryListener?.call(summary);
  }
}

Map<String?, Object?> _wireMap(Map<Object?, Object?> value) =>
    value.map((key, value) => MapEntry(key as String?, value));

Map<Object?, Object?>? _map(Map<String?, Object?>? value) {
  if (value == null) return null;
  return Map<Object?, Object?>.from(value);
}
