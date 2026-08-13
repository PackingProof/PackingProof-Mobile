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
  Future<Map<Object?, Object?>?> snapshot() async => null;

  @override
  Future<Map<Object?, Object?>?> initialize(Map<Object?, Object?> request) {
    throw const CapabilityUnavailableException(
      PlatformCapability.lanBackup,
      reason: '当前平台暂不支持电脑备份',
    );
  }

  @override
  Future<String?> loadAccessKey() async => null;

  @override
  Future<bool> isWifiConnected() async => true;

  @override
  Future<void> saveConnection(Map<Object?, Object?> connection) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> enqueueJob(Map<Object?, Object?> request) async {}

  @override
  Future<void> requeueJob(String jobId) async {}

  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<void> updateRetentionSchedule(Map<Object?, Object?> request) async {}

  @override
  Future<Map<Object?, Object?>?> reclaimStorageIfNeeded() async => null;

  @override
  Future<Map<Object?, Object?>?> getNetworkDiagnostics() async => null;

  @override
  Future<void> dispose() async {}
}
