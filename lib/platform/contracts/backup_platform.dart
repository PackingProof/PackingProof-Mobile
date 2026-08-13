abstract interface class BackupNativePlatform {
  void setSnapshotListener(
    void Function(Map<Object?, Object?> snapshot)? listener,
  );

  Future<Map<Object?, Object?>?> snapshot();

  Future<Map<Object?, Object?>?> initialize(Map<Object?, Object?> request);

  Future<String?> loadAccessKey();

  Future<bool> isWifiConnected();

  Future<void> saveConnection(Map<Object?, Object?> connection);

  Future<void> disconnect();

  Future<void> enqueueJob(Map<Object?, Object?> request);

  Future<void> requeueJob(String jobId);

  Future<void> cancelJob(String jobId);

  Future<void> updateRetentionSchedule(Map<Object?, Object?> request);

  Future<Map<Object?, Object?>?> reclaimStorageIfNeeded();

  Future<Map<Object?, Object?>?> getNetworkDiagnostics();

  Future<void> dispose();
}
