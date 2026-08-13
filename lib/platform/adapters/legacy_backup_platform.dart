import 'package:flutter/services.dart';

import '../contracts/backup_platform.dart';

class LegacyBackupNativePlatform implements BackupNativePlatform {
  LegacyBackupNativePlatform(MethodChannel channel) : _channel = channel;

  static const String channelName = 'app.packingproof.mobile/lan_backup';

  final MethodChannel _channel;
  void Function(Map<Object?, Object?> snapshot)? _listener;

  @override
  void setSnapshotListener(
    void Function(Map<Object?, Object?> snapshot)? listener,
  ) {
    _listener = listener;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'snapshotChanged' || call.arguments is! Map) return;
      _listener?.call(Map<Object?, Object?>.from(call.arguments! as Map));
    });
  }

  @override
  Future<Map<Object?, Object?>?> snapshot() =>
      _channel.invokeMapMethod<Object?, Object?>('snapshot');

  @override
  Future<Map<Object?, Object?>?> initialize(Map<Object?, Object?> request) =>
      _channel.invokeMapMethod<Object?, Object?>('initialize', request);

  @override
  Future<String?> loadAccessKey() =>
      _channel.invokeMethod<String>('loadAccessKey');

  @override
  Future<bool> isWifiConnected() async =>
      await _channel.invokeMethod<bool>('isWifiConnected') ?? false;

  @override
  Future<void> saveConnection(Map<Object?, Object?> connection) =>
      _channel.invokeMethod<void>('saveConnection', connection);

  @override
  Future<void> disconnect() => _channel.invokeMethod<void>('disconnect');

  @override
  Future<void> enqueueJob(Map<Object?, Object?> request) =>
      _channel.invokeMethod<void>('enqueue', request);

  @override
  Future<void> requeueJob(String jobId) =>
      _channel.invokeMethod<void>('retry', <String, Object>{'id': jobId});

  @override
  Future<void> cancelJob(String jobId) =>
      _channel.invokeMethod<void>('cancel', <String, Object>{'id': jobId});

  @override
  Future<void> updateRetentionSchedule(Map<Object?, Object?> request) =>
      _channel.invokeMethod<void>('setRetentionPolicies', request);

  @override
  Future<Map<Object?, Object?>?> reclaimStorageIfNeeded() =>
      _channel.invokeMapMethod<Object?, Object?>('checkAndReclaimStorage');

  @override
  Future<Map<Object?, Object?>?> getNetworkDiagnostics() =>
      _channel.invokeMapMethod<Object?, Object?>('getNetworkDiagnostics');

  @override
  Future<void> dispose() async {
    _listener = null;
    _channel.setMethodCallHandler(null);
  }
}
