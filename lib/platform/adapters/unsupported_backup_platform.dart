import '../contracts/backup_platform.dart';
import '../platform_capabilities.dart';
import '../platform_exceptions.dart';

class UnsupportedBackupNativePlatform implements BackupNativePlatform {
  const UnsupportedBackupNativePlatform();

  @override
  void setSnapshotListener(
    void Function(Map<Object?, Object?> snapshot)? listener,
  ) {}

  @override
  Future<Map<Object?, Object?>?> snapshot() => _unsupported();

  @override
  Future<Map<Object?, Object?>?> initialize(Map<Object?, Object?> request) {
    throw const CapabilityUnavailableException(
      PlatformCapability.lanBackup,
      reason: '当前平台暂不支持电脑备份',
    );
  }

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
  Future<void> requeueJob(String jobId) => _unsupported();

  @override
  Future<void> cancelJob(String jobId) => _unsupported();

  @override
  Future<void> updateRetentionSchedule(Map<Object?, Object?> request) =>
      _unsupported();

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
