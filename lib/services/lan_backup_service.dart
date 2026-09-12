import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/lan_backup.dart';
import '../models/recording_operation_mode.dart';
import '../models/recording_session.dart';
import '../models/backup_retention_policy.dart';
import '../platform/adapters/pigeon_backup_platform.dart';
import '../platform/contracts/backup_platform.dart';
import '../platform/generated/platform_api.g.dart';
import 'lan_backup_compatibility.dart';
import 'lan_backup_discovery_service.dart';
import 'remote_video_clip_service.dart';

class LanBackupUnsupportedException implements Exception {
  const LanBackupUnsupportedException([this.message = '电脑端版本暂不支持录像备份']);

  final String message;

  @override
  String toString() => message;
}

class LanBackupCompatibilityException implements Exception {
  const LanBackupCompatibilityException(this.result);

  final LanBackupCompatibilityResult result;

  @override
  String toString() => result.message;
}

class LanBackupHostUpgradeRequiredException
    extends LanBackupCompatibilityException {
  const LanBackupHostUpgradeRequiredException()
    : super(
        const LanBackupCompatibilityResult.incompatible(
          LanBackupCompatibilityFailure.hostVersionTooOld,
        ),
      );

  @override
  String toString() => result.message;
}

class LanBackupProtocolMismatchException
    extends LanBackupCompatibilityException {
  const LanBackupProtocolMismatchException(super.result);
}

class LanBackupCompatibilityMalformedException
    extends LanBackupCompatibilityException {
  const LanBackupCompatibilityMalformedException(super.result);
}

class LanBackupClientUpgradeRequiredException implements Exception {
  const LanBackupClientUpgradeRequiredException(this.message);

  final String message;

  @override
  String toString() => message;
}

List<int> _decodeSecret(String value) {
  final String normalized = value.trim();
  if (normalized.length >= 32 && normalized.length.isEven) {
    try {
      return List<int>.generate(
        normalized.length ~/ 2,
        (int index) => int.parse(
          normalized.substring(index * 2, index * 2 + 2),
          radix: 16,
        ),
      );
    } on FormatException {
      // 非十六进制设备令牌按 UTF-8 参与签名。
    }
  }
  return utf8.encode(normalized);
}

class LanBackupNotHostException implements Exception {
  const LanBackupNotHostException();

  @override
  String toString() => '连接的电脑当前不是录像备份主机';
}

class LanBackupConnectionException implements Exception {
  const LanBackupConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LanBackupApprovalDeniedException extends LanBackupConnectionException {
  const LanBackupApprovalDeniedException() : super('电脑端已拒绝本次连接');
}

class LanBackupApprovalUnavailableException
    extends LanBackupConnectionException {
  const LanBackupApprovalUnavailableException(super.message);
}

class LanBackupApprovalTimeoutException extends LanBackupConnectionException {
  const LanBackupApprovalTimeoutException()
    : super('电脑端还未处理连接申请，请打开电脑端后再次申请；如电脑已离线请重新搜索');
}

class LanBackupPairingConfirmation {
  const LanBackupPairingConfirmation({
    required this.computerId,
    required this.baseUri,
  });

  final String computerId;
  final Uri baseUri;

  bool matches(LanBackupEndpoint endpoint) {
    final String expectedId = computerId.trim();
    final String actualId = endpoint.computerId.trim();
    if (expectedId.isNotEmpty && actualId.isNotEmpty) {
      return expectedId == actualId;
    }
    return _normalizedHostUri(baseUri) == _normalizedHostUri(endpoint.baseUri);
  }
}

class LanBackupHostMismatchException implements Exception {
  const LanBackupHostMismatchException({
    required this.currentEndpoint,
    required this.candidateEndpoint,
  });

  final LanBackupEndpoint currentEndpoint;
  final LanBackupEndpoint candidateEndpoint;

  LanBackupPairingConfirmation get confirmation => LanBackupPairingConfirmation(
    computerId: candidateEndpoint.computerId,
    baseUri: candidateEndpoint.baseUri,
  );

  @override
  String toString() => '扫描到另一台备份电脑';
}

abstract interface class LanBackupSink implements Listenable {
  LanBackupSnapshot get snapshot;

  Future<void> initialize({
    required bool autoEnabled,
    required UnbackedRetentionPolicy unbackedRetention,
    required BackedRetentionPolicy backedRetention,
    UnbackedRetentionPolicy returnUnbackedRetention =
        UnbackedRetentionPolicy.days3,
    BackedRetentionPolicy returnBackedRetention = BackedRetentionPolicy.days1,
  });
  Future<void> pair(
    String qrValue, {
    LanBackupPairingConfirmation? replacementConfirmation,
  });
  Future<void> connectToHost(
    Uri baseUri, {
    LanBackupPairingConfirmation? replacementConfirmation,
  });
  void cancelPairing();
  Future<void> disconnect();
  Future<bool> retryConnection();
  Future<void> setAutoEnabled(bool enabled);
  Future<void> setRetentionPolicies({
    required UnbackedRetentionPolicy unbacked,
    required BackedRetentionPolicy backed,
    UnbackedRetentionPolicy returnUnbacked = UnbackedRetentionPolicy.days3,
    BackedRetentionPolicy returnBacked = BackedRetentionPolicy.days1,
  });
  Future<void> enqueueFinalizedFile(
    String filePath,
    List<RecordingSession> sessions,
  );
  Future<void> enqueueFinalizedFiles(
    Map<String, List<RecordingSession>> grouped, {
    bool startUpload = false,
  });
  Future<void> backupAll(
    List<RecordingSession> sessions, {
    bool forceRestart = false,
  });
  Future<void> retry(String jobId);
  Future<void> cancel(String jobId);
  Future<LanBackupJobsByPaths> jobsForPaths(Iterable<String> paths);
  Future<LanBackupCleanupPage> cleanupEvents({
    required int afterRevision,
    int limit = 100,
  });
  Future<void> acknowledgeCleanupEvents(int throughRevision);
  Future<StorageSpaceResult> checkAndReclaimStorage();
  Future<NetworkDiagnostics?> getNetworkDiagnostics();
  Future<void> refresh();
  Future<RemoteRecordingPage> fetchRemoteRecordings({
    required int page,
    required int pageSize,
    String keyword = '',
    RecordingOperationMode? operationMode,
  });
  Future<Map<int, ({RemoteRecordingStatus status, bool exists, String reason})>>
  fetchRemoteRecordingStatuses(Iterable<int> ids);
  Future<Uri?> resolveRemoteUri(Uri remoteUri);
  Map<String, String> get playbackHeaders;
  RemoteVideoClipSink? createRemoteVideoClipService(Uri remoteUri);
  Future<void> dispose();
}

class LanBackupService extends ChangeNotifier implements LanBackupSink {
  LanBackupService({
    BackupNativePlatform? platform,
    HttpClient? httpClient,
    Future<bool> Function()? wifiConnected,
    Future<PackageInfo> Function()? packageInfoLoader,
    Future<void> Function(Duration)? retryDelay,
    Future<void> Function(String kind, Map<String, Object?> extra)? logEvent,
    LanBackupHostLocator? hostLocator,
  }) : _platform = platform ?? PigeonBackupNativePlatform(),
       _httpClient = httpClient ?? HttpClient(),
       // Keep the public injection name readable while the stored callback remains private.
       // ignore: prefer_initializing_formals
       _wifiConnected = wifiConnected,
       _packageInfoLoader = packageInfoLoader ?? PackageInfo.fromPlatform,
       _retryDelay = retryDelay ?? Future<void>.delayed,
       // Keep the public injection name readable while the stored callback remains private.
       // ignore: prefer_initializing_formals
       _logEvent = logEvent {
    _hostLocator = hostLocator ?? LanBackupHostLocatorService();
    _ownsHostLocator = hostLocator == null;
    // 跨网段连接主机时，默认 connect 可能长时间挂起并累积半开 socket，
    // 最终触发 EMFILE(too many open files)。显式收紧连接与 keep-alive 超时。
    // 仅对自行创建的客户端设置默认值，避免覆盖调用方注入的客户端配置。
    if (httpClient == null) {
      _httpClient
        ..connectionTimeout = const Duration(seconds: 5)
        ..idleTimeout = const Duration(seconds: 30);
    }
  }

  final BackupNativePlatform _platform;
  final HttpClient _httpClient;
  final Future<bool> Function()? _wifiConnected;
  final Future<PackageInfo> Function() _packageInfoLoader;
  final Future<void> Function(Duration) _retryDelay;
  final Future<void> Function(String kind, Map<String, Object?> extra)?
  _logEvent;
  late final LanBackupHostLocator _hostLocator;
  late final bool _ownsHostLocator;
  Timer? _heartbeatTimer;
  DateTime? _lastHeartbeatSentAt;
  DateTime? _lastHeartbeatStallLoggedAt;
  DateTime? _lastHeartbeatSkipLoggedAt;
  DateTime? _lastHeartbeatErrorLoggedAt;
  Future<void>? _refreshFuture;
  bool _refreshAgain = false;
  bool _nativeHandlerAttached = false;
  String _accessKey = '';
  LanBackupSnapshot _snapshot = const LanBackupSnapshot();
  int _pairingRevision = 0;
  HttpClientRequest? _activePairingRequest;
  LanBackupSnapshot? _pairingRestoreSnapshot;
  String _appVersion = currentMobileCompatibilityVersion;
  int _appBuildNumber = currentMobileCompatibilityBuildNumber;
  bool _deviceVideoClippingEnabled = false;
  bool _uploadVideoCodecEnabled = false;
  final Map<String, String> _recoveredCompatibilityByDestination =
      <String, String>{};
  String? _loggedProblemJobId;
  Future<Uri?>? _activeAddressRecovery;
  bool _disposed = false;

  @override
  LanBackupSnapshot get snapshot => _snapshot;

  @visibleForTesting
  void debugSetSnapshotForTesting(LanBackupSnapshot snapshot) {
    _snapshot = snapshot;
  }

  @visibleForTesting
  void debugSetAccessKeyForTesting(String accessKey) {
    _accessKey = accessKey;
  }

  @visibleForTesting
  void debugApplyNativeSummaryForTesting(BackupSummaryDto summary) {
    _applyNativeSummary(summary);
  }

  @visibleForTesting
  Future<void> debugApplyHeartbeatResponseForTesting(String responseBody) =>
      _applyHeartbeatResponse(responseBody);

  @visibleForTesting
  Future<void> debugSendConnectionHeartbeatForTesting() =>
      _sendConnectionHeartbeat();

  @override
  Future<void> initialize({
    required bool autoEnabled,
    required UnbackedRetentionPolicy unbackedRetention,
    required BackedRetentionPolicy backedRetention,
    UnbackedRetentionPolicy returnUnbackedRetention =
        UnbackedRetentionPolicy.days3,
    BackedRetentionPolicy returnBackedRetention = BackedRetentionPolicy.days1,
  }) async {
    _attachNativeHandler();
    _snapshot = _snapshot.copyWith(autoEnabled: autoEnabled);
    try {
      final PackageInfo packageInfo = await _packageInfoLoader();
      _appVersion = packageInfo.version;
      _appBuildNumber = int.tryParse(packageInfo.buildNumber) ?? 0;
    } on Object {
      // Version checks are optional and must never block recording or backup.
    }
    _ensureHeartbeatTimer();
    unawaited(_sendConnectionHeartbeat());
    _log('heartbeat_timer', <String, Object?>{
      'event': 'created',
      'endpoint': _snapshot.endpoint?.baseUri.toString(),
      'hasAccessKey': _accessKey.isNotEmpty,
      'deviceId': _snapshot.deviceId,
      'deviceName': _snapshot.deviceName,
    });
    // 平台初始化失败不能让心跳永久停摆：先启动心跳定时器，
    // 后续原生事件或显式刷新会重读凭据并补发心跳。
    try {
      final BackupSummaryDto summary = await _platform
          .initialize(<String, Object?>{
            'autoEnabled': autoEnabled,
            'unbackedRetentionDays': unbackedRetention.days,
            'backedRetentionDays': backedRetention.days,
            'returnUnbackedRetentionDays': returnUnbackedRetention.days,
            'returnBackedRetentionDays': returnBackedRetention.days,
          });
      _accessKey = await _platform.loadAccessKey() ?? '';
      _applyNativeSummary(summary);
    } on Object catch (error) {
      _log('heartbeat_timer', <String, Object?>{
        'event': 'platform_init_failed',
        'error': error.toString(),
      });
    }
    _ensureHeartbeatAlive();
    unawaited(_refreshHostFeatures());
  }

  static LanBackupEndpoint parsePairingQr(String value) {
    final Uri uri = Uri.parse(value.trim());
    if (uri.scheme != 'http' || uri.host.isEmpty || !uri.hasPort) {
      throw const FormatException('扫错了？注意是左边的二维码哦');
    }
    final InternetAddress address;
    try {
      address = InternetAddress(uri.host);
    } on ArgumentError {
      throw const FormatException('二维码必须使用局域网 IP 地址');
    }
    if (!isPrivateLanAddress(address)) {
      throw const FormatException('只允许连接局域网电脑');
    }
    return LanBackupEndpoint(
      baseUri: Uri(scheme: 'http', host: uri.host, port: uri.port),
      accessKey: '',
      computerId: '',
      computerName: '',
    );
  }

  @override
  Future<void> pair(
    String qrValue, {
    LanBackupPairingConfirmation? replacementConfirmation,
  }) async {
    final LanBackupEndpoint candidate = parsePairingQr(qrValue);
    await connectToHost(
      candidate.baseUri,
      replacementConfirmation: replacementConfirmation,
    );
  }

  @override
  Future<void> connectToHost(
    Uri baseUri, {
    LanBackupPairingConfirmation? replacementConfirmation,
  }) async {
    await _ensureWifiConnected();
    final LanBackupEndpoint candidateEndpoint;
    try {
      candidateEndpoint = await _readBackupHostIdentity(baseUri);
    } on LanBackupNotHostException {
      _snapshot = _snapshot.copyWith(
        connectionStatus: LanConnectionStatus.notBackupHost,
        message: '这台电脑当前不是录像备份主机，请切换电脑用途或选择另一台主机',
      );
      notifyListeners();
      rethrow;
    } on LanBackupCompatibilityException catch (error) {
      _snapshot = _snapshot.copyWith(
        connectionStatus: LanConnectionStatus.offline,
        message: error.toString(),
      );
      notifyListeners();
      rethrow;
    } on LanBackupClientUpgradeRequiredException catch (error) {
      _snapshot = _snapshot.copyWith(
        connectionStatus: LanConnectionStatus.offline,
        message: error.toString(),
      );
      notifyListeners();
      rethrow;
    }
    final LanBackupEndpoint? currentEndpoint = _snapshot.endpoint;
    final bool changesCurrentHost =
        currentEndpoint != null &&
        !_isSameBackupHost(currentEndpoint, candidateEndpoint);
    // 没有当前保存主机（例如用户已删除电脑）时视为全新配对：待备份任务随后会由
    // saveConnection/retargetJobs 自动转到新电脑，不再要求“更换备份电脑”确认。
    final bool changesPendingHost =
        currentEndpoint != null &&
        await _platform.hasPendingJobsOutsideDestination(
          candidateEndpoint.computerId,
        );
    if ((changesCurrentHost || changesPendingHost) &&
        replacementConfirmation?.matches(candidateEndpoint) != true) {
      throw LanBackupHostMismatchException(
        currentEndpoint: currentEndpoint,
        candidateEndpoint: candidateEndpoint,
      );
    }
    final int revision = ++_pairingRevision;
    final LanBackupSnapshot restoreSnapshot = _snapshot;
    _pairingRestoreSnapshot = restoreSnapshot;
    _snapshot = _snapshot.copyWith(
      connectionStatus: LanConnectionStatus.awaitingApproval,
      message: '已向“${candidateEndpoint.computerName}”发送连接申请，请在电脑上点击“允许连接”',
    );
    notifyListeners();
    try {
      final Uri enrollmentUri = baseUri.replace(
        path: '/api/mobile-backup/enroll',
      );
      final List<int> enrollmentBody = utf8.encode(
        jsonEncode(<String, Object?>{
          'deviceId': _signingDeviceId,
          'deviceName': _snapshot.deviceName,
          'deviceKind': 'mobile',
          'clientVersion': _appVersion,
          'clientBuildNumber': _appBuildNumber,
          'backupProtocol': backupProtocol,
          'enrollmentVersion': backupEnrollmentVersion,
          'authVersion': backupAuthenticationVersion,
        }),
      );
      HttpClientResponse? response;
      String body = '';
      for (int attempt = 0; attempt < 25; attempt++) {
        final HttpClientRequest request = await _httpClient
            .postUrl(enrollmentUri)
            .timeout(const Duration(seconds: 5));
        if (revision != _pairingRevision) {
          request.abort();
          return;
        }
        _activePairingRequest = request;
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.contentLength = enrollmentBody.length;
        request.add(enrollmentBody);
        response = await request.close().timeout(const Duration(seconds: 90));
        body = await utf8.decoder.bind(response).join();
        if (revision != _pairingRevision) return;
        final ({String code, String message}) attemptError =
            _decodeEnrollmentError(body);
        if (response.statusCode != HttpStatus.tooManyRequests ||
            attemptError.code != 'enrollment_approval_busy' ||
            attempt == 24) {
          break;
        }

        _snapshot = _snapshot.copyWith(
          connectionStatus: LanConnectionStatus.awaitingApproval,
          message: '保存主机正在确认另一台设备，稍后会自动继续',
        );
        notifyListeners();
        await _retryDelay(const Duration(seconds: 3));
        if (revision != _pairingRevision) return;
      }
      if (response == null) {
        throw const LanBackupApprovalUnavailableException(
          '电脑端暂时无法处理连接申请，请稍后再试',
        );
      }
      if (revision != _pairingRevision) return;
      if (response.statusCode == HttpStatus.notFound) {
        throw const LanBackupUnsupportedException();
      }
      final ({String code, String message}) enrollmentError =
          _decodeEnrollmentError(body);
      if (response.statusCode == HttpStatus.forbidden) {
        throw const LanBackupApprovalDeniedException();
      }
      if (response.statusCode == HttpStatus.conflict) {
        throw const LanBackupNotHostException();
      }
      if (response.statusCode == HttpStatus.tooManyRequests) {
        throw const LanBackupApprovalUnavailableException('申请太频繁，请稍等几秒再试');
      }
      if (response.statusCode == HttpStatus.serviceUnavailable) {
        throw LanBackupApprovalUnavailableException(
          enrollmentError.code == 'enrollment_approval_unavailable' &&
                  enrollmentError.message.isNotEmpty
              ? enrollmentError.message
              : '电脑端暂时无法显示确认窗口，请打开保存主机界面后重试',
        );
      }
      if (response.statusCode == 426) {
        throw LanBackupClientUpgradeRequiredException(
          enrollmentError.message.isEmpty
              ? '手机 App 版本过低，请更新后重新连接'
              : enrollmentError.message,
        );
      }
      if (response.statusCode != HttpStatus.ok) {
        throw const LanBackupApprovalUnavailableException(
          '电脑端暂时无法处理连接申请，请稍后再试',
        );
      }
      final Map<String, Object?> enrollment = Map<String, Object?>.from(
        jsonDecode(body) as Map<Object?, Object?>,
      );
      final String deviceToken = '${enrollment['deviceToken'] ?? ''}'.trim();
      if (enrollment['protocol'] != backupProtocol ||
          (enrollment['version'] as num?)?.toInt() != 2 ||
          (enrollment['authVersion'] as num?)?.toInt() !=
              backupAuthenticationVersion ||
          '${enrollment['deviceId'] ?? ''}'.trim().toLowerCase() !=
              _signingDeviceId.toLowerCase() ||
          deviceToken.length < 32) {
        throw const LanBackupUnsupportedException();
      }
      final LanBackupEndpoint connectedEndpoint = LanBackupEndpoint(
        baseUri: baseUri,
        accessKey: '',
        computerId: '${enrollment['computerId'] ?? ''}',
        computerName: '${enrollment['computerName'] ?? '已连接电脑'}',
        lastConnectedAt: DateTime.now(),
      );
      final String assignedDeviceName =
          '${enrollment['deviceName'] ?? _snapshot.deviceName}'.trim();
      if (revision != _pairingRevision) return;
      final LanBackupEndpoint? currentEndpoint = restoreSnapshot.endpoint;
      if (currentEndpoint != null &&
          !_isSameBackupHost(currentEndpoint, connectedEndpoint) &&
          replacementConfirmation?.matches(connectedEndpoint) != true) {
        throw LanBackupHostMismatchException(
          currentEndpoint: currentEndpoint,
          candidateEndpoint: connectedEndpoint,
        );
      }
      final _HostBackupFeatures hostFeatures = await _readHostFeatures(
        connectedEndpoint.baseUri,
        accessKey: deviceToken,
      );
      _deviceVideoClippingEnabled = hostFeatures.deviceVideoClipping;
      _uploadVideoCodecEnabled = hostFeatures.uploadVideoCodec;
      await _platform.saveConnection(<String, Object?>{
        'baseUrl': baseUri.toString(),
        'accessKey': deviceToken,
        'computerId': connectedEndpoint.computerId,
        'computerName': connectedEndpoint.computerName,
        'deviceName': assignedDeviceName,
        'supportsUploadVideoCodec': _uploadVideoCodecEnabled,
      });
      if (revision != _pairingRevision) {
        await _restorePersistedConnection(restoreSnapshot);
        return;
      }
      _accessKey = deviceToken;
      _snapshot = _snapshot.copyWith(
        deviceName: assignedDeviceName,
        endpoint: connectedEndpoint,
        connectionStatus: LanConnectionStatus.connected,
        message: '保存主机已允许连接',
      );
      notifyListeners();
      unawaited(_sendConnectionHeartbeat());
      unawaited(refresh());
    } on LanBackupHostMismatchException {
      if (revision != _pairingRevision) return;
      _snapshot = restoreSnapshot;
      notifyListeners();
      rethrow;
    } on LanBackupNotHostException {
      if (revision != _pairingRevision) return;
      _snapshot = restoreSnapshot.endpoint != null
          ? restoreSnapshot
          : _snapshot.copyWith(
              connectionStatus: LanConnectionStatus.notBackupHost,
              message: '这台电脑当前不是录像备份主机，请切换电脑用途或选择另一台主机',
            );
      notifyListeners();
      rethrow;
    } on LanBackupClientUpgradeRequiredException catch (error) {
      if (revision != _pairingRevision) return;
      _snapshot = restoreSnapshot.copyWith(
        connectionStatus: LanConnectionStatus.offline,
        message: error.message,
      );
      notifyListeners();
      rethrow;
    } on LanBackupApprovalDeniedException catch (error) {
      if (revision != _pairingRevision) return;
      _snapshot = restoreSnapshot.copyWith(
        connectionStatus: LanConnectionStatus.approvalDenied,
        message: error.message,
      );
      notifyListeners();
      rethrow;
    } on LanBackupApprovalUnavailableException catch (error) {
      if (revision != _pairingRevision) return;
      _snapshot = restoreSnapshot.copyWith(
        connectionStatus: LanConnectionStatus.approvalUnavailable,
        message: error.message,
      );
      notifyListeners();
      rethrow;
    } on FormatException {
      if (revision != _pairingRevision) return;
      const friendly = LanBackupApprovalUnavailableException(
        '电脑端返回了无法识别的连接结果，请更新电脑端后再试',
      );
      _snapshot = restoreSnapshot.copyWith(
        connectionStatus: LanConnectionStatus.approvalUnavailable,
        message: friendly.message,
      );
      notifyListeners();
      throw friendly;
    } on SocketException {
      if (revision != _pairingRevision) return;
      const friendly = LanBackupConnectionException(
        '无法通过局域网连接电脑，请确认手机和电脑连接了同一个 Wi-Fi',
      );
      _snapshot = restoreSnapshot.copyWith(
        connectionStatus: LanConnectionStatus.offline,
        message: friendly.message,
      );
      notifyListeners();
      throw friendly;
    } on TimeoutException {
      if (revision != _pairingRevision) return;
      const error = LanBackupApprovalTimeoutException();
      _snapshot = restoreSnapshot.copyWith(
        connectionStatus: LanConnectionStatus.approvalUnavailable,
        message: error.message,
      );
      notifyListeners();
      throw error;
    } on Object catch (error) {
      if (revision != _pairingRevision) return;
      const friendly = LanBackupApprovalUnavailableException(
        '电脑端暂时无法处理连接申请，请稍后再试',
      );
      _snapshot = restoreSnapshot.copyWith(
        connectionStatus: LanConnectionStatus.approvalUnavailable,
        message: friendly.message,
      );
      notifyListeners();
      if (error is LanBackupConnectionException) rethrow;
      throw friendly;
    } finally {
      if (revision == _pairingRevision) {
        _activePairingRequest = null;
        _pairingRestoreSnapshot = null;
      }
    }
  }

  ({String code, String message}) _decodeEnrollmentError(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map) {
        return (
          code: '${decoded['errorCode'] ?? ''}'.trim(),
          message: '${decoded['error'] ?? ''}'.trim(),
        );
      }
    } on FormatException {
      // 旧主机或代理可能返回纯文本，界面统一使用本地友好提示。
    }
    return (code: '', message: '');
  }

  Future<LanBackupEndpoint> _readBackupHostIdentity(Uri baseUri) async {
    final HttpClientRequest request = await _httpClient
        .getUrl(baseUri.replace(path: '/api/node-info'))
        .timeout(const Duration(seconds: 5));
    request.followRedirects = false;
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 8),
    );
    final String body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw const LanBackupConnectionException('无法读取保存主机信息');
    }
    final Map<String, Object?> node = Map<String, Object?>.from(
      jsonDecode(body) as Map<Object?, Object?>,
    );
    final Set<String> capabilities =
        ((node['capabilities'] as List<Object?>?) ?? const <Object?>[])
            .map((Object? value) => '$value'.toLowerCase())
            .toSet();
    if (!capabilities.contains('host') ||
        !capabilities.contains('mobile-backup')) {
      throw const LanBackupNotHostException();
    }
    final LanBackupCompatibilityResult compatibility =
        parseLanBackupCompatibilityResult(node['backupCompatibility']);
    if (!compatibility.isCompatible) {
      throw switch (compatibility.failure!) {
        LanBackupCompatibilityFailure.hostVersionTooOld =>
          const LanBackupHostUpgradeRequiredException(),
        LanBackupCompatibilityFailure.mobileTooOld =>
          LanBackupClientUpgradeRequiredException(compatibility.message),
        LanBackupCompatibilityFailure.protocolMismatch =>
          LanBackupProtocolMismatchException(compatibility),
        LanBackupCompatibilityFailure.malformed =>
          LanBackupCompatibilityMalformedException(compatibility),
      };
    }
    final String nodeId = '${node['nodeId'] ?? ''}'.trim();
    if (nodeId.isEmpty) throw const LanBackupUnsupportedException();
    return LanBackupEndpoint(
      baseUri: baseUri,
      accessKey: '',
      computerId: nodeId,
      computerName: '${node['nodeName'] ?? '录像文件备份主机'}'.trim(),
    );
  }

  @override
  void cancelPairing() {
    final LanBackupSnapshot? restoreSnapshot = _pairingRestoreSnapshot;
    if (restoreSnapshot == null) return;
    _pairingRevision++;
    _activePairingRequest?.abort();
    _activePairingRequest = null;
    _pairingRestoreSnapshot = null;
    _snapshot = restoreSnapshot;
    notifyListeners();
  }

  Future<void> _restorePersistedConnection(
    LanBackupSnapshot restoreSnapshot,
  ) async {
    final LanBackupEndpoint? endpoint = restoreSnapshot.endpoint;
    if (endpoint == null || _accessKey.isEmpty) {
      await _platform.disconnect();
      return;
    }
    await _platform.saveConnection(<String, Object?>{
      'baseUrl': endpoint.baseUri.toString(),
      'accessKey': _accessKey,
      'computerId': endpoint.computerId,
      'computerName': endpoint.computerName,
      'deviceName': restoreSnapshot.deviceName,
      'supportsUploadVideoCodec': _uploadVideoCodecEnabled,
    });
  }

  @override
  Future<void> disconnect() async {
    await _sendConnectionHeartbeat(connected: false);
    await _platform.disconnect();
    _snapshot = _snapshot.copyWith(
      clearEndpoint: true,
      connectionStatus: LanConnectionStatus.disconnected,
    );
    _accessKey = '';
    _deviceVideoClippingEnabled = false;
    _uploadVideoCodecEnabled = false;
    notifyListeners();
  }

  @override
  Future<bool> retryConnection() async {
    LanBackupEndpoint? endpoint = _snapshot.endpoint;
    if (endpoint == null || _accessKey.isEmpty) return false;
    _deviceVideoClippingEnabled = false;
    _uploadVideoCodecEnabled = false;
    if (_snapshot.connectionStatus == LanConnectionStatus.notBackupHost) {
      _snapshot = _snapshot.copyWith(message: '电脑用途改变后需要重新搜索，或扫码选择另一台录像备份主机');
      notifyListeners();
      return false;
    }
    if (!await _hasWifiConnection()) {
      _snapshot = _snapshot.copyWith(
        connectionStatus: LanConnectionStatus.offline,
        message: '请先连接与电脑相同的 Wi-Fi 后重试',
      );
      notifyListeners();
      return false;
    }
    await _resolveCurrentBaseUri();
    endpoint = _snapshot.endpoint;
    if (endpoint == null) return false;
    _snapshot = _snapshot.copyWith(
      connectionStatus: LanConnectionStatus.connecting,
      message: '正在重新连接电脑',
    );
    notifyListeners();
    try {
      final _BackupHostProbe hostProbe = await _probeBackupHost(
        endpoint.baseUri,
      );
      if (hostProbe.status == _BackupHostStatus.notBackupHost) {
        _snapshot = _snapshot.copyWith(
          connectionStatus: LanConnectionStatus.notBackupHost,
          message: '连接的电脑当前不是录像备份主机，请切换电脑用途或重新搜索',
        );
        notifyListeners();
        return false;
      }
      if (hostProbe.status != _BackupHostStatus.backupHost ||
          hostProbe.compatibility?.isCompatible != true) {
        _snapshot = _snapshot.copyWith(
          connectionStatus: LanConnectionStatus.offline,
          message: hostProbe.compatibility?.message ?? '暂时无法确认电脑端备份兼容性',
        );
        notifyListeners();
        return false;
      }
      final HttpClientRequest request = await _httpClient
          .getUrl(
            endpoint.baseUri.replace(path: '/api/mobile-backup/capabilities'),
          )
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      _setSignedBackupHeaders(
        request,
        _accessKey,
        const <int>[],
        method: 'GET',
        path: endpoint.baseUri
            .replace(path: '/api/mobile-backup/capabilities')
            .path,
      );
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final String responseBody = await utf8.decoder.bind(response).join();
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
        _snapshot = _snapshot.copyWith(
          connectionStatus: LanConnectionStatus.rePair,
          message: '设备连接已失效，请重新申请并在电脑上允许连接',
        );
        notifyListeners();
        return false;
      }
      if (response.statusCode == HttpStatus.notFound &&
          hostProbe.status == _BackupHostStatus.notBackupHost) {
        _snapshot = _snapshot.copyWith(
          connectionStatus: LanConnectionStatus.notBackupHost,
          message: '连接的电脑当前不是录像备份主机，请切换电脑用途或重新搜索',
        );
        notifyListeners();
        return false;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('电脑连接失败（${response.statusCode}）');
      }
      _deviceVideoClippingEnabled = parseDeviceVideoClippingFeature(
        responseBody,
      );
      _uploadVideoCodecEnabled = parseUploadVideoCodecFeature(responseBody);
      await _recoverIncompatibleJobsForCompatibleHost(
        endpoint,
        hostProbe.compatibility!,
        force: true,
      );
      _snapshot = _snapshot.copyWith(
        connectionStatus: LanConnectionStatus.connected,
        message: '电脑已重新连接',
      );
      notifyListeners();
      unawaited(_sendConnectionHeartbeat());
      return true;
    } on Object {
      _snapshot = _snapshot.copyWith(
        connectionStatus: LanConnectionStatus.offline,
        message: '仍无法连接，请确认电脑端已打开且处于同一局域网',
      );
      notifyListeners();
      return false;
    }
  }

  @override
  Future<void> setAutoEnabled(bool enabled) async {
    await _platform.setAutoEnabled(enabled);
    _snapshot = _snapshot.copyWith(autoEnabled: enabled);
    _log('backup_auto_toggle', <String, Object?>{'enabled': enabled});
    notifyListeners();
  }

  @override
  Future<void> setRetentionPolicies({
    required UnbackedRetentionPolicy unbacked,
    required BackedRetentionPolicy backed,
    UnbackedRetentionPolicy returnUnbacked = UnbackedRetentionPolicy.days3,
    BackedRetentionPolicy returnBacked = BackedRetentionPolicy.days1,
  }) async {
    await _platform.updateRetentionSchedule(<String, Object?>{
      'unbackedRetentionDays': unbacked.days,
      'backedRetentionDays': backed.days,
      'returnUnbackedRetentionDays': returnUnbacked.days,
      'returnBackedRetentionDays': returnBacked.days,
    });
    await refresh();
  }

  @override
  Future<void> enqueueFinalizedFile(
    String filePath,
    List<RecordingSession> sessions,
  ) => _enqueueBatch(<({String filePath, List<RecordingSession> sessions})>[
    (filePath: filePath, sessions: sessions),
  ], startUpload: _snapshot.autoEnabled);

  @override
  Future<void> enqueueFinalizedFiles(
    Map<String, List<RecordingSession>> grouped, {
    bool startUpload = false,
  }) => _enqueueBatch(
    grouped.entries
        .map(
          (MapEntry<String, List<RecordingSession>> entry) =>
              (filePath: entry.key, sessions: entry.value),
        )
        .toList(growable: false),
    startUpload: startUpload,
  );

  Future<void> _enqueueBatch(
    List<({String filePath, List<RecordingSession> sessions})> entries, {
    required bool startUpload,
    bool forceRestart = false,
  }) async {
    final Set<String> fileIdentities = <String>{};
    for (final ({String filePath, List<RecordingSession> sessions}) entry
        in entries) {
      if (entry.sessions.length != 1) {
        throw StateError('每个备份任务必须且只能包含一条录像记录');
      }
      final RecordingSession session = entry.sessions.single;
      if (!isSameLanBackupFile(entry.filePath, session.filePath)) {
        throw StateError('备份录像记录与文件路径不一致');
      }
      if (!fileIdentities.add(lanBackupFileIdentity(entry.filePath))) {
        throw StateError('一条录像文件只能创建一个备份任务');
      }
    }
    final List<Map<Object?, Object?>> requests = <Map<Object?, Object?>>[];
    for (final ({String filePath, List<RecordingSession> sessions}) entry
        in entries) {
      try {
        final FileStat stat = await File(entry.filePath).stat();
        if (stat.type == FileSystemEntityType.notFound || stat.size <= 0) {
          continue;
        }
      } on FileSystemException {
        continue;
      }
      requests.add(<String, Object?>{
        'filePath': entry.filePath,
        'sessions': entry.sessions
            .map(recordingSessionBackupMap)
            .toList(growable: false),
        'startUpload': startUpload,
        'forceRestart': forceRestart,
      });
    }
    for (var offset = 0; offset < requests.length; offset += 100) {
      final int end = min(offset + 100, requests.length);
      await _platform.enqueueJobs(requests.sublist(offset, end));
    }
    await refresh();
    _log('backup_enqueue_batch', <String, Object?>{
      'requestedCount': entries.length,
      'enqueuedCount': requests.length,
      'startUpload': startUpload,
      'forceRestart': forceRestart,
    });
  }

  @override
  Future<void> backupAll(
    List<RecordingSession> sessions, {
    bool forceRestart = false,
  }) async {
    _log('backup_all_batch', <String, Object?>{
      'fileCount': sessions.length,
      'sessionCount': sessions.length,
      'forceRestart': forceRestart,
    });
    await _enqueueBatch(
      sessions
          .map(
            (RecordingSession session) => (
              filePath: session.filePath,
              sessions: <RecordingSession>[session],
            ),
          )
          .toList(growable: false),
      startUpload: true,
      forceRestart: forceRestart,
    );
  }

  @override
  Future<void> retry(String jobId) async {
    await _platform.requeueJob(jobId);
    await refresh();
    _log('backup_retry', <String, Object?>{'jobId': jobId});
  }

  @override
  Future<void> cancel(String jobId) async {
    await _platform.cancelJob(jobId);
    await refresh();
    _log('backup_cancel', <String, Object?>{'jobId': jobId});
  }

  @override
  Future<LanBackupJobsByPaths> jobsForPaths(Iterable<String> paths) async {
    final LanBackupEndpoint? requestEndpoint = _snapshot.endpoint;
    final Map<String, String> valuesByIdentity = <String, String>{};
    for (final String path in paths) {
      valuesByIdentity.putIfAbsent(lanBackupFileIdentity(path), () => path);
    }
    final List<String> values = valuesByIdentity.values.toList(growable: false);
    if (values.isEmpty) {
      return LanBackupJobsByPaths(
        revision: _snapshot.summary.revision,
        jobs: const <LanBackupJob>[],
        missingPaths: const <String>{},
      );
    }
    var revision = _snapshot.summary.revision;
    final List<LanBackupJob> jobs = <LanBackupJob>[];
    final Set<String> missingPaths = <String>{};
    for (var offset = 0; offset < values.length; offset += 100) {
      final int end = min(offset + 100, values.length);
      final BackupJobsByPathsDto result = await _platform.jobsForPaths(
        values.sublist(offset, end),
      );
      if (!_sameEndpointIdentity(requestEndpoint, _snapshot.endpoint) ||
          result.revision < _snapshot.summary.revision ||
          result.revision < revision) {
        throw StateError('备份任务查询结果已过期');
      }
      revision = result.revision;
      jobs.addAll(result.jobs.map(_jobFromDto));
      missingPaths.addAll(result.missingPaths.map(lanBackupFileIdentity));
    }
    return LanBackupJobsByPaths(
      revision: revision,
      jobs: List<LanBackupJob>.unmodifiable(jobs),
      missingPaths: Set<String>.unmodifiable(missingPaths),
    );
  }

  @override
  Future<LanBackupCleanupPage> cleanupEvents({
    required int afterRevision,
    int limit = 100,
  }) async {
    final BackupCleanupPageDto result = await _platform.cleanupEvents(
      afterRevision: afterRevision,
      limit: limit.clamp(1, 100),
    );
    return LanBackupCleanupPage(
      latestRevision: result.latestRevision,
      nextAfterRevision: result.nextAfterRevision,
      hasMore: result.hasMore,
      events: result.events
          .map(
            (BackupCleanupEventDto event) => LanBackupCleanupEvent(
              revision: event.revision,
              eventId: event.eventId,
              jobId: event.jobId,
              filePath: event.filePath,
              fileSizeBytes: event.fileSizeBytes,
              deletedAt: DateTime.fromMillisecondsSinceEpoch(
                event.deletedAtMs,
                isUtc: true,
              ),
              reason: event.reason,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<void> acknowledgeCleanupEvents(int throughRevision) =>
      _platform.acknowledgeCleanupEvents(throughRevision);

  @override
  Future<StorageSpaceResult> checkAndReclaimStorage() async {
    final Map<Object?, Object?> values =
        await _platform.reclaimStorageIfNeeded() ?? <Object?, Object?>{};
    return StorageSpaceResult.fromMap(values);
  }

  @override
  Future<NetworkDiagnostics?> getNetworkDiagnostics() async {
    try {
      final Map<Object?, Object?> values =
          await _platform.getNetworkDiagnostics() ?? <Object?, Object?>{};
      return NetworkDiagnostics.fromMap(values);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> refresh() {
    final Future<void>? active = _refreshFuture;
    if (active != null) {
      _refreshAgain = true;
      return active;
    }
    final Future<void> refresh = _refreshLoop();
    _refreshFuture = refresh;
    return refresh.whenComplete(() {
      if (identical(_refreshFuture, refresh)) _refreshFuture = null;
    });
  }

  Future<void> _refreshLoop() async {
    do {
      _refreshAgain = false;
      await _refreshOnce();
    } while (_refreshAgain);
  }

  Future<void> _refreshOnce() async {
    try {
      _applyNativeSummary(await _platform.summary());
    } on PlatformException {
      // A worker can briefly hold the state file while replacing it.
    }
    _ensureHeartbeatAlive();
  }

  void _ensureHeartbeatTimer() {
    if (_disposed) return;
    _heartbeatTimer ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_sendConnectionHeartbeat()),
    );
  }

  /// 轻量看门狗：在原生快照事件或显式刷新后检查心跳并按需补发。
  void _ensureHeartbeatAlive() {
    if (_disposed) return;
    final DateTime now = DateTime.now();
    if (_snapshot.endpoint == null ||
        _snapshot.deviceId.isEmpty ||
        _snapshot.deviceName.isEmpty) {
      return; // 未配对，无需心跳。
    }
    final bool hasAccessKey = _accessKey.isNotEmpty;
    final DateTime? lastSent = _lastHeartbeatSentAt;
    final bool timerMissing = _heartbeatTimer == null;
    final bool stalled =
        timerMissing ||
        !hasAccessKey ||
        lastSent == null ||
        now.difference(lastSent) > const Duration(seconds: 60);
    if (!stalled) {
      return;
    }
    if (_lastHeartbeatStallLoggedAt != null &&
        now.difference(_lastHeartbeatStallLoggedAt!) <
            const Duration(seconds: 60)) {
      return;
    }
    _lastHeartbeatStallLoggedAt = now;
    _log('heartbeat_stalled', <String, Object?>{
      'timerAlive': !timerMissing,
      'lastSentSecondsAgo': lastSent == null
          ? -1
          : now.difference(lastSent).inSeconds,
      'hasAccessKey': hasAccessKey,
      'endpoint': _snapshot.endpoint?.baseUri.toString(),
    });
    _ensureHeartbeatTimer();
    if (hasAccessKey) {
      unawaited(_sendConnectionHeartbeat());
    } else {
      unawaited(_reloadAccessKeyAndHeartbeat());
    }
  }

  Future<void> _reloadAccessKeyAndHeartbeat() async {
    try {
      final String? key = await _platform.loadAccessKey();
      if (key == null || key.isEmpty) {
        return;
      }
      _accessKey = key;
      unawaited(_sendConnectionHeartbeat());
    } on Object {
      // 平台初始化失败后下个自愈周期再试。
    }
  }

  void _logHeartbeatSkip(Map<String, Object?> extra) {
    final DateTime now = DateTime.now();
    if (_lastHeartbeatSkipLoggedAt != null &&
        now.difference(_lastHeartbeatSkipLoggedAt!) <
            const Duration(seconds: 60)) {
      return;
    }
    _lastHeartbeatSkipLoggedAt = now;
    _log('heartbeat_skip', extra);
  }

  void _logHeartbeatError(Map<String, Object?> extra) {
    final DateTime now = DateTime.now();
    if (_lastHeartbeatErrorLoggedAt != null &&
        now.difference(_lastHeartbeatErrorLoggedAt!) <
            const Duration(seconds: 60)) {
      return;
    }
    _lastHeartbeatErrorLoggedAt = now;
    _log('heartbeat_error', extra);
  }

  void _attachNativeHandler() {
    if (_nativeHandlerAttached) return;
    _nativeHandlerAttached = true;
    _platform.setSummaryListener((BackupSummaryDto summary) {
      _applyNativeSummary(summary);
      _ensureHeartbeatAlive();
    });
  }

  Future<Uri?> _resolveCurrentBaseUri() {
    final Future<Uri?>? active = _activeAddressRecovery;
    if (active != null) return active;
    final Future<Uri?> recovery = _runAddressRecovery();
    _activeAddressRecovery = recovery;
    return recovery.whenComplete(() {
      if (identical(_activeAddressRecovery, recovery)) {
        _activeAddressRecovery = null;
      }
    });
  }

  Future<Uri?> _runAddressRecovery() async {
    LanBackupEndpoint? endpoint = _snapshot.endpoint;
    if (endpoint == null ||
        endpoint.computerId.trim().isEmpty ||
        _accessKey.isEmpty) {
      return null;
    }
    final Uri? located = await _hostLocator.locate(
      currentBaseUri: endpoint.baseUri,
      nodeId: endpoint.computerId,
    );
    if (located == null) return null;

    final LanBackupEndpoint? current = _snapshot.endpoint;
    if (current == null || current.computerId != endpoint.computerId) {
      return null;
    }
    if (_normalizedHostUri(current.baseUri) == _normalizedHostUri(located)) {
      return current.baseUri;
    }

    final LanBackupEndpoint updated = LanBackupEndpoint(
      baseUri: located,
      accessKey: '',
      computerId: current.computerId,
      computerName: current.computerName,
      lastConnectedAt: DateTime.now(),
    );
    await _platform.saveConnection(<String, Object?>{
      'baseUrl': located.toString(),
      'accessKey': _accessKey,
      'computerId': updated.computerId,
      'computerName': updated.computerName,
      'deviceName': _snapshot.deviceName,
      'supportsUploadVideoCodec': _uploadVideoCodecEnabled,
    });
    _snapshot = _snapshot.copyWith(
      endpoint: updated,
      connectionStatus: LanConnectionStatus.connected,
      message: '保存主机地址已自动更新',
    );
    _log('backup_host_address_updated', <String, Object?>{
      'computerId': updated.computerId,
      'address': located.authority,
    });
    notifyListeners();
    return located;
  }

  Future<bool> _recoverChangedEndpoint(Uri failedBaseUri) async {
    final Uri? resolved = await _resolveCurrentBaseUri();
    return resolved != null &&
        _normalizedHostUri(resolved) != _normalizedHostUri(failedBaseUri);
  }

  @override
  Future<Uri?> resolveRemoteUri(Uri remoteUri) async {
    final Uri? baseUri = await _resolveCurrentBaseUri();
    if (baseUri == null) return null;
    return remoteUri.replace(
      scheme: baseUri.scheme,
      host: baseUri.host,
      port: baseUri.port,
    );
  }

  @override
  Future<RemoteRecordingPage> fetchRemoteRecordings({
    required int page,
    required int pageSize,
    String keyword = '',
    RecordingOperationMode? operationMode,
  }) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final LanBackupEndpoint? endpoint = _snapshot.endpoint;
      if (endpoint == null || _accessKey.isEmpty) {
        return const RemoteRecordingPage.empty();
      }
      final Uri uri = buildRemoteRecordingsUri(
        endpoint.baseUri,
        page: page,
        pageSize: pageSize,
        keyword: keyword,
        operationMode: operationMode,
      );
      try {
        final HttpClientRequest request = await _httpClient
            .getUrl(uri)
            .timeout(const Duration(seconds: 5));
        _setSignedBackupHeaders(
          request,
          _accessKey,
          const <int>[],
          method: 'GET',
          path: uri.path,
        );
        final HttpClientResponse response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        final String body = await utf8.decoder.bind(response).join();
        if (response.statusCode == HttpStatus.unauthorized ||
            response.statusCode == HttpStatus.forbidden) {
          if (attempt == 0 && await _recoverChangedEndpoint(endpoint.baseUri)) {
            continue;
          }
          _snapshot = _snapshot.copyWith(
            connectionStatus: LanConnectionStatus.rePair,
          );
          notifyListeners();
          return const RemoteRecordingPage.empty();
        }
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('电脑录像读取失败（${response.statusCode}）');
        }
        final Map<String, Object?> payload = Map<String, Object?>.from(
          jsonDecode(body) as Map<Object?, Object?>,
        );
        if (operationMode != null &&
            payload['mode'] != operationMode.storageValue) {
          throw UnsupportedError('电脑版本暂不支持发货／退货筛选，请更新电脑端');
        }
        final List<RemoteRecording> recordings =
            ((payload['data'] as List<Object?>?) ?? const <Object?>[])
                .map(
                  (Object? value) => RemoteRecording.fromJson(
                    Map<String, Object?>.from(value! as Map),
                    endpoint.baseUri,
                  ),
                )
                .toList(growable: false);
        _snapshot = _snapshot.copyWith(
          connectionStatus: LanConnectionStatus.connected,
        );
        notifyListeners();
        return RemoteRecordingPage(
          data: recordings,
          page: (payload['page'] as num?)?.toInt() ?? page,
          pageSize: (payload['pageSize'] as num?)?.toInt() ?? pageSize,
          total: (payload['total'] as num?)?.toInt() ?? recordings.length,
          deviceTotal: (payload['deviceTotal'] as num?)?.toInt() ?? 0,
        );
      } on UnsupportedError {
        rethrow;
      } on Object {
        if (attempt == 0 && await _recoverChangedEndpoint(endpoint.baseUri)) {
          continue;
        }
      }
    }
    _snapshot = _snapshot.copyWith(
      connectionStatus: LanConnectionStatus.offline,
    );
    notifyListeners();
    return const RemoteRecordingPage.empty();
  }

  @override
  Future<Map<int, ({RemoteRecordingStatus status, bool exists, String reason})>>
  fetchRemoteRecordingStatuses(Iterable<int> ids) async {
    final List<int> values = ids
        .where((int id) => id > 0)
        .toSet()
        .take(100)
        .toList();
    if (_snapshot.endpoint == null || _accessKey.isEmpty || values.isEmpty) {
      return const <
        int,
        ({RemoteRecordingStatus status, bool exists, String reason})
      >{};
    }
    for (int attempt = 0; attempt < 2; attempt++) {
      final LanBackupEndpoint endpoint = _snapshot.endpoint!;
      final Uri uri = endpoint.baseUri.replace(
        path: '/api/mobile-backup/videos/status',
        queryParameters: <String, String>{'ids': values.join(',')},
      );
      try {
        final HttpClientRequest request = await _httpClient
            .getUrl(uri)
            .timeout(const Duration(seconds: 5));
        _setSignedBackupHeaders(
          request,
          _accessKey,
          const <int>[],
          method: 'GET',
          path: uri.path,
        );
        final HttpClientResponse response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        final String body = await utf8.decoder.bind(response).join();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('电脑录像状态读取失败（${response.statusCode}）');
        }
        final Map<String, Object?> payload = Map<String, Object?>.from(
          jsonDecode(body) as Map<Object?, Object?>,
        );
        return <
          int,
          ({RemoteRecordingStatus status, bool exists, String reason})
        >{
          for (final Object? value
              in (payload['data'] as List<Object?>?) ?? const <Object?>[])
            if (value is Map)
              (value['id'] as num).toInt(): (
                status: RemoteRecordingStatus.values.firstWhere(
                  (RemoteRecordingStatus status) =>
                      status.name == value['status'],
                  orElse: () => RemoteRecordingStatus.missing,
                ),
                exists: value['exists'] == true,
                reason: '${value['reason'] ?? ''}',
              ),
        };
      } on Object {
        if (attempt == 0 && await _recoverChangedEndpoint(endpoint.baseUri)) {
          continue;
        }
        rethrow;
      }
    }
    return const <
      int,
      ({RemoteRecordingStatus status, bool exists, String reason})
    >{};
  }

  @override
  Map<String, String> get playbackHeaders => const <String, String>{};

  @override
  RemoteVideoClipSink? createRemoteVideoClipService(Uri remoteUri) {
    final LanBackupEndpoint? endpoint = _snapshot.endpoint;
    if (!_deviceVideoClippingEnabled ||
        endpoint == null ||
        _accessKey.isEmpty) {
      return null;
    }
    if (remoteUri.scheme != endpoint.baseUri.scheme ||
        remoteUri.host != endpoint.baseUri.host ||
        remoteUri.port != endpoint.baseUri.port) {
      return null;
    }
    return RemoteVideoClipService(
      baseUri: endpoint.baseUri,
      accessHeaders: const <String, String>{},
      deviceScoped: true,
      requestAuthorizer: (request, body, method, path) {
        _setSignedBackupHeaders(
          request,
          _accessKey,
          body,
          method: method,
          path: path,
        );
      },
    );
  }

  Future<void> _refreshHostFeatures() async {
    final LanBackupEndpoint? endpoint = _snapshot.endpoint;
    if (endpoint == null || _accessKey.isEmpty) {
      _deviceVideoClippingEnabled = false;
      _uploadVideoCodecEnabled = false;
      return;
    }
    final _HostBackupFeatures features = await _readHostFeatures(
      endpoint.baseUri,
    );
    _deviceVideoClippingEnabled = features.deviceVideoClipping;
    _uploadVideoCodecEnabled = features.uploadVideoCodec;
    await _platform.saveConnection(<String, Object?>{
      'baseUrl': endpoint.baseUri.toString(),
      'accessKey': _accessKey,
      'computerId': endpoint.computerId,
      'computerName': endpoint.computerName,
      'deviceName': _snapshot.deviceName,
      'supportsUploadVideoCodec': _uploadVideoCodecEnabled,
    });
  }

  Future<_HostBackupFeatures> _readHostFeatures(
    Uri baseUri, {
    String? accessKey,
  }) async {
    try {
      final Uri uri = baseUri.replace(path: '/api/mobile-backup/capabilities');
      final HttpClientRequest request = await _httpClient
          .getUrl(uri)
          .timeout(const Duration(seconds: 5));
      _setSignedBackupHeaders(
        request,
        accessKey ?? _accessKey,
        const <int>[],
        method: 'GET',
        path: uri.path,
      );
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final String body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        return const _HostBackupFeatures();
      }
      return _HostBackupFeatures(
        deviceVideoClipping: parseDeviceVideoClippingFeature(body),
        uploadVideoCodec: parseUploadVideoCodecFeature(body),
      );
    } on Object {
      return const _HostBackupFeatures();
    }
  }

  Future<void> _ensureWifiConnected() async {
    if (!await _hasWifiConnection()) {
      throw const FormatException('请先连接与电脑相同的 Wi-Fi 后重试');
    }
  }

  Future<bool> _hasWifiConnection() async {
    final Future<bool> Function()? override = _wifiConnected;
    if (override != null) return override();
    try {
      return await _platform.isWifiConnected();
    } on PlatformException {
      return false;
    }
  }

  void _setSignedBackupHeaders(
    HttpClientRequest request,
    String deviceCredential,
    List<int> content, {
    required String method,
    required String path,
  }) {
    final String deviceId = _signingDeviceId;
    if (deviceId.isEmpty) {
      throw const FormatException('手机设备身份尚未准备好，请稍后重试');
    }
    final int timestamp = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final Random random = Random.secure();
    final String nonce = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((int value) => value.toRadixString(16).padLeft(2, '0')).join();
    final String contentHash = sha256.convert(content).toString();
    final String canonical = <String>[
      method.toUpperCase(),
      path,
      '$timestamp',
      nonce,
      contentHash,
      deviceId.toLowerCase(),
    ].join('\n');
    final String signature = Hmac(
      sha256,
      _decodeSecret(deviceCredential),
    ).convert(utf8.encode(canonical)).toString();
    request.headers.set('X-EPM-Auth-Version', '$backupAuthenticationVersion');
    request.headers.set('X-EPM-Timestamp', '$timestamp');
    request.headers.set('X-EPM-Nonce', nonce);
    request.headers.set('X-EPM-Content-SHA256', contentHash);
    request.headers.set('X-EPM-Signature', signature);
    request.headers.set('X-EPM-Device-Id', deviceId);
    request.headers.set('X-EPM-Device-Kind', 'mobile');
    if (_snapshot.deviceName.isNotEmpty) {
      request.headers.set(
        'X-EPM-Device-Name',
        Uri.encodeComponent(_snapshot.deviceName),
      );
    }
  }

  String get _signingDeviceId {
    final String deviceId = _snapshot.deviceId.trim();
    if (deviceId.isNotEmpty) return deviceId;
    if (!Platform.isAndroid) {
      return '00000000-0000-0000-0000-000000000001';
    }
    throw const FormatException('手机设备身份尚未准备好，请稍后重试');
  }

  Future<void> _sendConnectionHeartbeat({
    bool connected = true,
    bool allowAddressRecovery = true,
  }) async {
    final LanBackupEndpoint? endpoint = _snapshot.endpoint;
    if (endpoint == null ||
        _accessKey.isEmpty ||
        _snapshot.deviceId.isEmpty ||
        _snapshot.deviceName.isEmpty) {
      _logHeartbeatSkip(<String, Object?>{
        'endpoint': endpoint?.baseUri.toString(),
        'hasAccessKey': _accessKey.isNotEmpty,
        'deviceId': _snapshot.deviceId,
        'deviceName': _snapshot.deviceName,
      });
      return;
    }
    try {
      final HttpClientRequest request = await _httpClient
          .postUrl(endpoint.baseUri.replace(path: '/api/connections/heartbeat'))
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'clientId': _snapshot.deviceId,
          'clientType': 'mobile-app',
          'displayName': _snapshot.deviceName,
          'connected': connected,
          'nodeId': _snapshot.deviceId,
          'deviceType': 'mobile',
          'orderReceiverPort': 5280,
          'capabilities': const <String>['recording', 'order-receiver'],
          'appVersion': _appVersion,
          'appBuildNumber': _appBuildNumber,
        }),
      );
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final String responseBody = await utf8.decoder.bind(response).join();
      _lastHeartbeatSentAt = DateTime.now();
      _log('heartbeat_send', <String, Object?>{
        'status': response.statusCode,
        'connected': connected,
      });
      if (connected) {
        if (allowAddressRecovery &&
            response.statusCode != HttpStatus.ok &&
            await _recoverChangedEndpoint(endpoint.baseUri)) {
          await _sendConnectionHeartbeat(allowAddressRecovery: false);
          return;
        }
        LanConnectionStatus nextStatus = heartbeatConnectionStatus(
          response.statusCode,
        );
        final _BackupHostProbe hostProbe = await _probeBackupHost(
          endpoint.baseUri,
        );
        String? compatibilityMessage;
        if (hostProbe.status == _BackupHostStatus.notBackupHost ||
            _snapshot.connectionStatus == LanConnectionStatus.notBackupHost) {
          nextStatus = LanConnectionStatus.notBackupHost;
        } else if (hostProbe.status == _BackupHostStatus.backupHost &&
            hostProbe.compatibility?.isCompatible != true) {
          nextStatus = LanConnectionStatus.offline;
          compatibilityMessage =
              hostProbe.compatibility?.message ?? '暂时无法确认电脑端备份兼容性';
        } else if (nextStatus == LanConnectionStatus.connected &&
            hostProbe.compatibility?.isCompatible == true) {
          await _recoverIncompatibleJobsForCompatibleHost(
            endpoint,
            hostProbe.compatibility!,
          );
        }
        _applyHeartbeatConnectionStatus(
          nextStatus,
          message: compatibilityMessage,
        );
        if (nextStatus == LanConnectionStatus.connected &&
            responseBody.isNotEmpty) {
          await _applyHeartbeatResponse(responseBody);
        }
      }
    } on Object catch (error) {
      _logHeartbeatError(<String, Object?>{
        'endpoint': endpoint.baseUri.toString(),
        'connected': connected,
        'error': error.toString(),
      });
      if (connected &&
          allowAddressRecovery &&
          await _recoverChangedEndpoint(endpoint.baseUri)) {
        await _sendConnectionHeartbeat(allowAddressRecovery: false);
        return;
      }
      if (connected &&
          _snapshot.connectionStatus != LanConnectionStatus.notBackupHost) {
        _applyHeartbeatConnectionStatus(LanConnectionStatus.offline);
      }
    }
  }

  void _applyHeartbeatConnectionStatus(
    LanConnectionStatus status, {
    String? message,
  }) {
    if (_snapshot.connectionStatus == status &&
        (message == null || _snapshot.message == message)) {
      return;
    }
    _snapshot = _snapshot.copyWith(
      connectionStatus: status,
      message:
          message ??
          switch (status) {
            LanConnectionStatus.connected => '电脑已重新连接',
            LanConnectionStatus.rePair => '设备连接已失效，请重新申请并在电脑上允许连接',
            LanConnectionStatus.notBackupHost => '连接的电脑当前不是录像备份主机，请切换电脑用途或重新搜索',
            _ => '电脑已离线，正在自动重新连接',
          },
    );
    notifyListeners();
  }

  Future<_BackupHostProbe> _probeBackupHost(Uri baseUri) async {
    try {
      final HttpClientRequest request = await _httpClient
          .getUrl(baseUri.replace(path: '/api/node-info'))
          .timeout(const Duration(seconds: 3));
      request.followRedirects = false;
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final String body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        return const _BackupHostProbe(_BackupHostStatus.unknown);
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map || decoded['protocol'] != 'packingproof') {
        return const _BackupHostProbe(_BackupHostStatus.unknown);
      }
      final List<Object?> capabilities = decoded['capabilities'] is List
          ? List<Object?>.from(decoded['capabilities']! as List)
          : const <Object?>[];
      if (!capabilities.any(
        (Object? value) => '$value'.toLowerCase() == 'mobile-backup',
      )) {
        return const _BackupHostProbe(_BackupHostStatus.notBackupHost);
      }
      return _BackupHostProbe(
        _BackupHostStatus.backupHost,
        compatibility: parseLanBackupCompatibilityResult(
          decoded['backupCompatibility'],
        ),
      );
    } on Object {
      return const _BackupHostProbe(_BackupHostStatus.unknown);
    }
  }

  Future<void> _recoverIncompatibleJobsForCompatibleHost(
    LanBackupEndpoint endpoint,
    LanBackupCompatibilityResult result, {
    bool force = false,
  }) async {
    final LanBackupHostCompatibility compatibility = result.compatibility!;
    final String destination = endpoint.computerId.trim();
    if (destination.isEmpty) return;
    final String fingerprint = <Object>[
      compatibility.hostVersion,
      compatibility.protocol,
      compatibility.enrollmentVersion,
      compatibility.authVersion,
      compatibility.minimumMobileVersion,
      compatibility.minimumMobileBuildNumber,
    ].join('|');
    if (!force &&
        _recoveredCompatibilityByDestination[destination] == fingerprint) {
      return;
    }
    await _platform.saveConnection(<String, Object?>{
      'baseUrl': endpoint.baseUri.toString(),
      'accessKey': _accessKey,
      'computerId': endpoint.computerId,
      'computerName': endpoint.computerName,
      'deviceName': _snapshot.deviceName,
      'supportsUploadVideoCodec': _uploadVideoCodecEnabled,
      'recoverIncompatibleFailuresOnly': true,
    });
    _recoveredCompatibilityByDestination[destination] = fingerprint;
  }

  Future<void> _applyHeartbeatResponse(String responseBody) async {
    try {
      final Object? decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, dynamic>) return;

      final String assignedDisplayName =
          '${decoded['assignedDisplayName'] ?? ''}'.trim();
      final LanBackupEndpoint? endpoint = _snapshot.endpoint;
      if (assignedDisplayName.isNotEmpty &&
          assignedDisplayName != _snapshot.deviceName &&
          endpoint != null) {
        await _platform.saveConnection(<String, Object?>{
          'baseUrl': endpoint.baseUri.toString(),
          'accessKey': _accessKey,
          'computerId': endpoint.computerId,
          'computerName': endpoint.computerName,
          'deviceName': assignedDisplayName,
          'supportsUploadVideoCodec': _uploadVideoCodecEnabled,
        });
        _snapshot = _snapshot.copyWith(deviceName: assignedDisplayName);
        notifyListeners();
      }

      if (!decoded.containsKey('mobileAppUpdate') ||
          decoded['mobileAppUpdate'] is! Map) {
        return;
      }

      final MobileAppUpdateNotice? notice = evaluateMobileAppUpdatePolicy(
        Map<String, Object?>.from(decoded['mobileAppUpdate']! as Map),
        currentVersion: _appVersion,
        currentBuildNumber: _appBuildNumber,
      );
      final MobileAppUpdateNotice? previous = _snapshot.mobileAppUpdate;
      if (previous?.signature == notice?.signature &&
          previous?.message == notice?.message) {
        return;
      }
      _snapshot = _snapshot.copyWith(
        mobileAppUpdate: notice,
        clearMobileAppUpdate: notice == null,
      );
      notifyListeners();
    } on Object {
      // Invalid or newer policy formats are ignored for forward compatibility.
    }
  }

  void _applyNativeSummary(BackupSummaryDto value) {
    if (value.schemaVersion != 1) {
      _log('backup_summary_unsupported_schema', <String, Object?>{
        'schemaVersion': value.schemaVersion,
      });
      return;
    }
    if (value.revision < _snapshot.summary.revision) {
      _log('backup_summary_stale', <String, Object?>{
        'revision': value.revision,
        'currentRevision': _snapshot.summary.revision,
      });
      return;
    }
    final LanBackupEndpoint? endpoint = value.baseUrl == null
        ? null
        : LanBackupEndpoint(
            baseUri: Uri.parse(value.baseUrl!),
            accessKey: '',
            computerId: value.computerId ?? '',
            computerName: value.computerName ?? '',
            lastConnectedAt: value.lastConnectedAtMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    value.lastConnectedAtMs!,
                    isUtc: true,
                  ),
          );
    final LanBackupSummary summary = LanBackupSummary(
      revision: value.revision,
      completedRevision: value.completedRevision,
      cleanupHighWatermark: value.cleanupHighWatermark,
      totalCount: value.totalCount,
      pendingCount: value.pendingCount,
      uploadingCount: value.uploadingCount,
      pausedCount: value.pausedCount,
      completedCount: value.completedCount,
      failedCount: value.failedCount,
      waitingCleanupCount: value.waitingCleanupCount,
      localDeletedCount: value.localDeletedCount,
      unfinishedUploadedBytes: value.unfinishedUploadedBytes,
      unfinishedTotalBytes: value.unfinishedTotalBytes,
      activeJob: value.activeJob == null ? null : _jobFromDto(value.activeJob!),
      problemJob: value.problemJob == null
          ? null
          : _jobFromDto(value.problemJob!),
      dominantFailureKind: LanBackupFailureKind.fromWireValue(
        value.dominantFailureKind,
      ),
    );
    if (summary.dominantFailureKind ==
        LanBackupFailureKind.incompatibleVersion) {
      final String destination = endpoint?.computerId.trim() ?? '';
      if (destination.isNotEmpty) {
        _recoveredCompatibilityByDestination.remove(destination);
      }
    }
    _logBackupJobFailureEdge(summary.problemJob);
    final bool hasActiveUpload =
        summary.activeJob?.state == LanBackupJobState.uploading;
    final LanBackupSnapshot next = LanBackupSnapshot(
      deviceId: value.deviceId,
      deviceName: value.deviceName,
      preferredHostId: endpoint == null ? value.preferredHostId ?? '' : '',
      preferredHostName: endpoint == null ? value.preferredHostName ?? '' : '',
      endpoint: endpoint,
      summary: summary,
      autoEnabled: _snapshot.autoEnabled,
      connectionStatus: nativeBackupConnectionStatus(
        previous: _snapshot.connectionStatus,
        endpoint: endpoint,
        dominantFailureKind: summary.dominantFailureKind,
        hasActiveUpload: hasActiveUpload,
      ),
      message: hasActiveUpload
          ? null
          : summary.dominantFailureKind ==
                LanBackupFailureKind.credentialInvalid
          ? '设备连接已失效，请重新申请并在电脑上允许连接'
          : summary.dominantFailureKind == LanBackupFailureKind.notBackupHost
          ? '连接的电脑当前不是录像备份主机，请切换电脑用途或重新搜索'
          : _snapshot.message,
    );
    if (_sameBackupSummary(_snapshot, next)) return;
    _snapshot = next;
    notifyListeners();
  }

  void _logBackupJobFailureEdge(LanBackupJob? job) {
    if (job == null || job.state != LanBackupJobState.failed) {
      _loggedProblemJobId = null;
      return;
    }
    if (_loggedProblemJobId == job.id) return;
    _loggedProblemJobId = job.id;
    _log('backup_job_failed', <String, Object?>{
      'jobId': job.id,
      'filePath': job.filePath,
      'state': job.state.name,
      'failureKind': job.failureKind?.name,
      'errorMessage': job.errorMessage,
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _log('heartbeat_timer', <String, Object?>{
      'event': 'cancelled',
      'endpoint': _snapshot.endpoint?.baseUri.toString(),
    });
    await _sendConnectionHeartbeat(connected: false);
    if (_nativeHandlerAttached) {
      await _platform.dispose();
      _nativeHandlerAttached = false;
    }
    if (_ownsHostLocator) _hostLocator.dispose();
    _httpClient.close(force: true);
    super.dispose();
  }

  void _log(String kind, Map<String, Object?> extra) {
    final Future<void> Function(String kind, Map<String, Object?> extra)?
    logEvent = _logEvent;
    if (logEvent == null) return;
    unawaited(logEvent(kind, extra));
  }
}

bool _sameEndpointIdentity(LanBackupEndpoint? left, LanBackupEndpoint? right) {
  if (left == null || right == null) return left == null && right == null;
  return left.computerId == right.computerId && left.baseUri == right.baseUri;
}

enum _BackupHostStatus { backupHost, notBackupHost, unknown }

class _BackupHostProbe {
  const _BackupHostProbe(this.status, {this.compatibility});

  final _BackupHostStatus status;
  final LanBackupCompatibilityResult? compatibility;
}

bool _isSameBackupHost(LanBackupEndpoint current, LanBackupEndpoint candidate) {
  final String currentId = current.computerId.trim();
  final String candidateId = candidate.computerId.trim();
  if (currentId.isNotEmpty && candidateId.isNotEmpty) {
    return currentId == candidateId;
  }
  return _normalizedHostUri(current.baseUri) ==
      _normalizedHostUri(candidate.baseUri);
}

String _normalizedHostUri(Uri uri) => Uri(
  scheme: uri.scheme.toLowerCase(),
  host: uri.host.toLowerCase(),
  port: uri.hasPort ? uri.port : null,
).toString();

LanBackupJob _jobFromDto(BackupJobDto value) => LanBackupJob(
  revision: value.revision,
  id: value.id,
  filePath: value.filePath,
  state: LanBackupJobState.values.firstWhere(
    (LanBackupJobState state) => state.name == value.state,
    orElse: () => LanBackupJobState.failed,
  ),
  uploadedBytes: value.uploadedBytes,
  totalBytes: value.totalBytes,
  lastModified: _dateTimeFromMilliseconds(value.lastModifiedMs),
  contentSha256: value.contentSha256,
  errorMessage: value.errorMessage,
  failureKind: LanBackupFailureKind.fromWireValue(value.failureKind),
  fileCreatedAt: _dateTimeFromMilliseconds(value.fileCreatedAtMs),
  backupCompletedAt: _dateTimeFromMilliseconds(value.backupCompletedAtMs),
  scheduledCleanupAt: _dateTimeFromMilliseconds(value.scheduledCleanupAtMs),
  localDeletedAt: _dateTimeFromMilliseconds(value.localDeletedAtMs),
  waitingCleanup: value.waitingCleanup,
  remoteRecordId: value.remoteRecordId,
  destinationComputerId: value.destinationComputerId,
  cleanupReason: value.cleanupReason,
);

DateTime? _dateTimeFromMilliseconds(int? value) => value == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);

bool _sameBackupSummary(LanBackupSnapshot left, LanBackupSnapshot right) {
  final LanBackupJob? leftActive = left.summary.activeJob;
  final LanBackupJob? rightActive = right.summary.activeJob;
  final LanBackupJob? leftProblem = left.summary.problemJob;
  final LanBackupJob? rightProblem = right.summary.problemJob;
  return left.summary.revision == right.summary.revision &&
      left.summary.completedRevision == right.summary.completedRevision &&
      left.summary.cleanupHighWatermark == right.summary.cleanupHighWatermark &&
      left.endpoint?.baseUri == right.endpoint?.baseUri &&
      left.endpoint?.computerId == right.endpoint?.computerId &&
      left.endpoint?.computerName == right.endpoint?.computerName &&
      left.endpoint?.lastConnectedAt == right.endpoint?.lastConnectedAt &&
      left.deviceId == right.deviceId &&
      left.deviceName == right.deviceName &&
      left.preferredHostId == right.preferredHostId &&
      left.preferredHostName == right.preferredHostName &&
      left.connectionStatus == right.connectionStatus &&
      left.message == right.message &&
      left.summary.totalCount == right.summary.totalCount &&
      left.summary.pendingCount == right.summary.pendingCount &&
      left.summary.uploadingCount == right.summary.uploadingCount &&
      left.summary.pausedCount == right.summary.pausedCount &&
      left.summary.completedCount == right.summary.completedCount &&
      left.summary.failedCount == right.summary.failedCount &&
      left.summary.waitingCleanupCount == right.summary.waitingCleanupCount &&
      left.summary.localDeletedCount == right.summary.localDeletedCount &&
      left.summary.unfinishedUploadedBytes ==
          right.summary.unfinishedUploadedBytes &&
      left.summary.unfinishedTotalBytes == right.summary.unfinishedTotalBytes &&
      left.summary.dominantFailureKind == right.summary.dominantFailureKind &&
      leftActive?.id == rightActive?.id &&
      leftActive?.revision == rightActive?.revision &&
      leftActive?.state == rightActive?.state &&
      leftProblem?.id == rightProblem?.id &&
      leftProblem?.revision == rightProblem?.revision &&
      leftProblem?.state == rightProblem?.state;
}

LanConnectionStatus nativeBackupConnectionStatus({
  required LanConnectionStatus previous,
  required LanBackupEndpoint? endpoint,
  required LanBackupFailureKind? dominantFailureKind,
  bool hasActiveUpload = false,
}) {
  if (endpoint == null) return LanConnectionStatus.disconnected;
  if (hasActiveUpload) return LanConnectionStatus.connected;
  if (dominantFailureKind == LanBackupFailureKind.credentialInvalid) {
    return LanConnectionStatus.rePair;
  }
  if (dominantFailureKind == LanBackupFailureKind.notBackupHost) {
    return LanConnectionStatus.notBackupHost;
  }
  return previous == LanConnectionStatus.disconnected
      ? LanConnectionStatus.connected
      : previous;
}

@visibleForTesting
Uri buildRemoteRecordingsUri(
  Uri baseUri, {
  required int page,
  required int pageSize,
  String keyword = '',
  RecordingOperationMode? operationMode,
}) {
  return baseUri.replace(
    path: '/api/mobile-backup/videos',
    queryParameters: <String, String>{
      'page': '$page',
      'size': '$pageSize',
      if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
      if (operationMode != null) 'mode': operationMode.storageValue,
    },
  );
}

@visibleForTesting
bool parseDeviceVideoClippingFeature(String responseBody) {
  try {
    final Object? decoded = jsonDecode(responseBody);
    if (decoded is! Map || decoded['features'] is! Map) return false;
    final Map<Object?, Object?> features = Map<Object?, Object?>.from(
      decoded['features']! as Map,
    );
    return features['libraryScope'] == 'host' &&
        features['deviceVideoClipping'] == true;
  } on Object {
    // broad-catch: 无效或旧版能力响应按不支持可选编码字段降级
    return false;
  }
}

@visibleForTesting
bool parseUploadVideoCodecFeature(String responseBody) {
  try {
    final Object? decoded = jsonDecode(responseBody);
    if (decoded is! Map || decoded['features'] is! Map) return false;
    final Map<Object?, Object?> features = Map<Object?, Object?>.from(
      decoded['features']! as Map,
    );
    return features['uploadVideoCodec'] == true;
  } on Object {
    return false;
  }
}

class _HostBackupFeatures {
  const _HostBackupFeatures({
    this.deviceVideoClipping = false,
    this.uploadVideoCodec = false,
  });

  final bool deviceVideoClipping;
  final bool uploadVideoCodec;
}

@visibleForTesting
LanConnectionStatus heartbeatConnectionStatus(int statusCode) {
  if (statusCode >= 200 && statusCode < 300) {
    return LanConnectionStatus.connected;
  }
  if (statusCode == HttpStatus.unauthorized ||
      statusCode == HttpStatus.forbidden) {
    return LanConnectionStatus.rePair;
  }
  return LanConnectionStatus.offline;
}

@visibleForTesting
MobileAppUpdateNotice? evaluateMobileAppUpdatePolicy(
  Map<String, Object?> value, {
  required String currentVersion,
  required int currentBuildNumber,
}) {
  final int schemaVersion = (value['schemaVersion'] as num?)?.toInt() ?? 0;
  if (schemaVersion != 1 && schemaVersion != 2) return null;
  final String minimumVersion = '${value['minimumVersion'] ?? ''}'.trim();
  final int minimumBuildNumber =
      (value['minimumBuildNumber'] as num?)?.toInt() ?? 0;
  if (minimumVersion.isEmpty || minimumBuildNumber <= 0) return null;

  final bool updateRequired = currentBuildNumber > 0
      ? currentBuildNumber < minimumBuildNumber
      : compareAppVersions(currentVersion, minimumVersion) < 0;
  final String latestVersion = '${value['latestVersion'] ?? ''}'.trim();
  final int latestBuildNumber =
      (value['latestBuildNumber'] as num?)?.toInt() ?? 0;
  final bool updateRecommended = latestBuildNumber > 0
      ? currentBuildNumber <= 0 || currentBuildNumber < latestBuildNumber
      : latestVersion.isNotEmpty &&
            compareAppVersions(currentVersion, latestVersion) < 0;
  if (!updateRequired && !updateRecommended) return null;

  return MobileAppUpdateNotice(
    minimumVersion: minimumVersion,
    minimumBuildNumber: minimumBuildNumber,
    message: updateRequired
        ? '${value['message'] ?? ''}'.trim()
        : '发现新版手机 App，建议更新',
    latestVersion: latestVersion,
    latestBuildNumber: latestBuildNumber,
    updateRequired: updateRequired,
  );
}

@visibleForTesting
int compareAppVersions(String left, String right) {
  return compareBackupVersions(left, right);
}
