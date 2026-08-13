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
  void Function(Map<Object?, Object?> snapshot)? _snapshotListener;

  @override
  void setSnapshotListener(
    void Function(Map<Object?, Object?> snapshot)? listener,
  ) {
    _snapshotListener = listener;
  }

  @override
  Future<Map<Object?, Object?>?> snapshot() async =>
      _map(await _hostApi.snapshot());

  @override
  Future<Map<Object?, Object?>?> initialize(
    Map<Object?, Object?> request,
  ) async => _map(await _hostApi.initialize(_wireMap(request)));

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
  Future<void> requeueJob(String jobId) => _hostApi.requeueJob(jobId);

  @override
  Future<void> cancelJob(String jobId) => _hostApi.cancelJob(jobId);

  @override
  Future<void> updateRetentionSchedule(Map<Object?, Object?> request) =>
      _hostApi.updateRetentionSchedule(_wireMap(request));

  @override
  Future<Map<Object?, Object?>?> reclaimStorageIfNeeded() async =>
      _map(await _hostApi.reclaimStorageIfNeeded());

  @override
  Future<Map<Object?, Object?>?> getNetworkDiagnostics() async =>
      _map(await _hostApi.getNetworkDiagnostics());

  @override
  Future<void> dispose() async {
    BackupNativeEventApi.setUp(null);
    _snapshotListener = null;
  }
}

class _BackupNativeEventSink extends BackupNativeEventApi {
  _BackupNativeEventSink(this._platform);

  final PigeonBackupNativePlatform _platform;

  @override
  void snapshotChanged(Map<String?, Object?> snapshot) {
    _platform._snapshotListener?.call(Map<Object?, Object?>.from(snapshot));
  }
}

Map<String?, Object?> _wireMap(Map<Object?, Object?> value) =>
    value.map((key, value) => MapEntry(key as String?, value));

Map<Object?, Object?>? _map(Map<String?, Object?>? value) {
  if (value == null) return null;
  return Map<Object?, Object?>.from(value);
}
