import '../contracts/backup_platform.dart';
import '../generated/platform_api.g.dart';
import '../platform_capabilities.dart';
import '../platform_exceptions.dart';

class UnsupportedBackupNativePlatform implements BackupNativePlatform {
  const UnsupportedBackupNativePlatform();

  @override
  void setSummaryListener(void Function(BackupSummaryDto summary)? listener) {}

  @override
  Future<BackupSummaryDto> summary() => _unsupported();

  @override
  Future<BackupSummaryDto> initialize(Map<Object?, Object?> request) {
    throw const CapabilityUnavailableException(
      PlatformCapability.lanBackup,
      reason: '当前平台暂不支持电脑备份',
    );
  }

  @override
  Future<void> setAutoEnabled(bool enabled) => _unsupported();

  @override
  Future<BackupJobsByPathsDto> jobsForPaths(List<String> paths) =>
      _unsupported();

  @override
  Future<BackupCleanupPageDto> cleanupEvents({
    required int afterRevision,
    required int limit,
  }) => _unsupported();

  @override
  Future<void> acknowledgeCleanupEvents(int throughRevision) => _unsupported();

  @override
  Future<bool> hasPendingJobsOutsideDestination(String computerId) =>
      _unsupported();

  @override
  Future<String?> loadAccessKey() => _unsupported();

  @override
  Future<bool> isWifiConnected() => _unsupported();

  @override
  Future<void> saveConnection(Map<Object?, Object?> connection) =>
      _unsupported();

  @override
  Future<void> disconnect() => _unsupported();

  @override
  Future<void> enqueueJob(Map<Object?, Object?> request) => _unsupported();

  @override
  Future<void> enqueueJobs(List<Map<Object?, Object?>> requests) =>
      _unsupported();

  @override
  Future<void> requeueJob(String jobId, {bool manual = false}) =>
      _unsupported();

  @override
  Future<void> cancelJob(String jobId) => _unsupported();

  @override
  Future<void> updateRetentionSchedule(Map<Object?, Object?> request) =>
      _unsupported();

  @override
  Future<int?> availableRecordingStorageBytes() => _unsupported();

  @override
  Future<Map<Object?, Object?>?> reclaimStorageIfNeeded() => _unsupported();

  @override
  Future<Map<Object?, Object?>?> getNetworkDiagnostics() => _unsupported();

  @override
  Future<void> dispose() async {}

  Never _unsupported() {
    throw const CapabilityUnavailableException(
      PlatformCapability.lanBackup,
      reason: '当前平台暂不支持电脑备份',
    );
  }
}
