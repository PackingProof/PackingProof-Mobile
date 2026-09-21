import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/backup_retention_policy.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';
import 'package:packing_proof_mobile/models/order_info.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/models/recording_operation_mode.dart';
import 'package:packing_proof_mobile/platform/contracts/backup_platform.dart';
import 'package:packing_proof_mobile/platform/device_platform.dart';
import 'package:packing_proof_mobile/platform/generated/platform_api.g.dart';
import 'package:packing_proof_mobile/services/lan_backup_service.dart';
import 'package:packing_proof_mobile/services/lan_backup_discovery_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('主机显式声明全库剪辑能力时启用设备剪辑', () {
    expect(
      parseDeviceVideoClippingFeature(
        '{"features":{"libraryScope":"host","deviceVideoClipping":true}}',
      ),
      isTrue,
    );
    expect(
      parseDeviceVideoClippingFeature('{"features":{"videoLibrary":true}}'),
      isFalse,
    );
    expect(parseDeviceVideoClippingFeature('not-json'), isFalse);
  });

  test('主机显式声明录像编码上传能力时才启用协议字段', () {
    expect(
      parseUploadVideoCodecFeature('{"features":{"uploadVideoCodec":true}}'),
      isTrue,
    );
    expect(parseUploadVideoCodecFeature('{"features":{}}'), isFalse);
    expect(parseUploadVideoCodecFeature('not-json'), isFalse);
  });

  test('电脑身份与配对记录不符时切到重新配对状态并写日志', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_identity_mismatch_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final List<({String kind, Map<String, Object?> extra})> logs =
        <({String kind, Map<String, Object?> extra})>[];
    final _IdentityMismatchHostLocator locator = _IdentityMismatchHostLocator();
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
      hostLocator: locator,
      logEvent: (String kind, Map<String, Object?> extra) async {
        logs.add((kind: kind, extra: extra));
      },
    );
    addTearDown(service.dispose);
    service.debugSetAccessKeyForTesting('a' * 64);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        deviceName: '录像手机',
        connectionStatus: LanConnectionStatus.connected,
        endpoint: LanBackupEndpoint(
          baseUri: Uri.parse('http://192.168.31.250:5280'),
          accessKey: '',
          computerId: '095c41f0-a7cb-467a-8926-29ddc2446eb6',
          computerName: '保存主机',
        ),
      ),
    );

    final Uri? resolved = await service.resolveRemoteUri(
      Uri.parse(
        'http://192.168.31.250:5280/api/mobile-backup/videos/7/play?compat=1',
      ),
    );

    expect(resolved, isNull);
    // 不能再让界面以为只是"离线"：要明确引导重新连接。
    expect(service.lastRemoteResolveNeedsRepair, isTrue);
    expect(service.snapshot.connectionStatus, LanConnectionStatus.rePair);
    final ({String kind, Map<String, Object?> extra}) mismatch = logs
        .firstWhere(
          (({String kind, Map<String, Object?> extra}) item) =>
              item.kind == 'remote_playback_identity_mismatch',
        );
    expect(
      mismatch.extra['expectedNodeId'],
      '095c41f0-a7cb-467a-8926-29ddc2446eb6',
    );
    expect(
      mismatch.extra['reportedNodeId'],
      '202f543f-7b88-407d-b636-61fc0958abe8',
    );
  });

  test('播放前按 NodeId 更新主机地址并保留令牌与路径参数', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_address_recovery_test',
    );
    Map<Object?, Object?>? saved;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'saveConnection') {
            saved = Map<Object?, Object?>.from(call.arguments! as Map);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final _FakeHostLocator locator = _FakeHostLocator(
      Uri.parse('http://192.168.1.30:5280'),
    );
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
      hostLocator: locator,
    );
    addTearDown(service.dispose);
    service.debugSetAccessKeyForTesting('a' * 64);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        deviceName: '录像手机',
        endpoint: LanBackupEndpoint(
          baseUri: Uri.parse('http://192.168.1.20:5280'),
          accessKey: '',
          computerId: 'host-1',
          computerName: '保存主机',
        ),
      ),
    );

    final Uri? resolved = await service.resolveRemoteUri(
      Uri.parse(
        'http://192.168.1.20:5280/api/mobile-backup/videos/7/play?compat=1',
      ),
    );

    expect(
      resolved,
      Uri.parse(
        'http://192.168.1.30:5280/api/mobile-backup/videos/7/play?compat=1',
      ),
    );
    expect(saved?['baseUrl'], 'http://192.168.1.30:5280');
    expect(saved?['accessKey'], 'a' * 64);
    expect(saved?['computerId'], 'host-1');
    expect(locator.requests, 1);
  });

  test('远程播放解析失败时写明原因并落诊断日志', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_resolve_failure_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final List<({String kind, Map<String, Object?> extra})> logs =
        <({String kind, Map<String, Object?> extra})>[];
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
      hostLocator: _FakeHostLocator(null),
      logEvent: (String kind, Map<String, Object?> extra) async {
        logs.add((kind: kind, extra: extra));
      },
    );
    addTearDown(service.dispose);
    service.debugSetAccessKeyForTesting('a' * 64);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        deviceId: '00000000-0000-0000-0000-000000000001',
        deviceName: '录像手机',
        endpoint: LanBackupEndpoint(
          baseUri: Uri.parse('http://192.168.1.20:5280'),
          accessKey: '',
          computerId: 'host-1',
          computerName: '保存主机',
        ),
      ),
    );

    final Uri? resolved = await service.resolveRemoteUri(
      Uri.parse('http://192.168.1.20:5280/api/mobile-backup/videos/7/play'),
    );

    expect(resolved, isNull);
    // 这条以前完全静默，导致导出日志里查不到远程播放失败的痕迹。
    final ({String kind, Map<String, Object?> extra}) failure = logs.firstWhere(
      (({String kind, Map<String, Object?> extra}) item) =>
          item.kind == 'remote_playback_resolve_failed',
    );
    expect(failure.extra['reason'], 'unreachable');
    expect(failure.extra['endpoint'], 'http://192.168.1.20:5280');
    expect(failure.extra['nodeId'], 'host-1');
    expect(failure.extra['hasAccessKey'], isTrue);
  });

  test('缺少访问密钥时远程播放解析失败原因可辨认', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_resolve_no_key_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final List<({String kind, Map<String, Object?> extra})> logs =
        <({String kind, Map<String, Object?> extra})>[];
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
      hostLocator: _FakeHostLocator(Uri.parse('http://192.168.1.20:5280')),
      logEvent: (String kind, Map<String, Object?> extra) async {
        logs.add((kind: kind, extra: extra));
      },
    );
    addTearDown(service.dispose);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        deviceName: '录像手机',
        endpoint: LanBackupEndpoint(
          baseUri: Uri.parse('http://192.168.1.20:5280'),
          accessKey: '',
          computerId: 'host-1',
          computerName: '保存主机',
        ),
      ),
    );

    final Uri? resolved = await service.resolveRemoteUri(
      Uri.parse('http://192.168.1.20:5280/api/mobile-backup/videos/7/play'),
    );

    expect(resolved, isNull);
    expect(
      logs
          .where(
            (({String kind, Map<String, Object?> extra}) item) =>
                item.kind == 'remote_playback_resolve_failed',
          )
          .single
          .extra['reason'],
      'no_access_key',
    );
  });

  test('录像列表请求失败后只在地址变化时改用新地址重试', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_request_recovery_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final _FailThenSucceedHttpClient client = _FailThenSucceedHttpClient();
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
      httpClient: client,
      hostLocator: _FakeHostLocator(Uri.parse('http://192.168.1.30:5280')),
    );
    addTearDown(service.dispose);
    service.debugSetAccessKeyForTesting('a' * 64);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        deviceId: '00000000-0000-0000-0000-000000000001',
        deviceName: '录像手机',
        endpoint: LanBackupEndpoint(
          baseUri: Uri.parse('http://192.168.1.20:5280'),
          accessKey: '',
          computerId: 'host-1',
          computerName: '保存主机',
        ),
      ),
    );

    final RemoteRecordingPage result = await service.fetchRemoteRecordings(
      page: 1,
      pageSize: 5,
    );

    expect(result.data, isEmpty);
    expect(client.requestedHosts, <String>['192.168.1.20', '192.168.1.30']);
    await expectLater(
      service.fetchRemoteRecordings(
        page: 1,
        pageSize: 5,
        operationMode: RecordingOperationMode.returnGoods,
      ),
      throwsUnsupportedError,
    );
    expect(client.requestedUris.last.queryParameters['mode'], 'return');
    client.echoMode = true;
    final filtered = await service.fetchRemoteRecordings(
      page: 1,
      pageSize: 5,
      operationMode: RecordingOperationMode.returnGoods,
    );
    expect(filtered.total, 0);
    expect(service.snapshot.connectionStatus, LanConnectionStatus.connected);
  });

  test('心跳看门狗在定时器丢失时自动补发心跳并记录状态', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_heartbeat_watchdog_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final List<String> logKinds = <String>[];
    final _HeartbeatHttpClient client = _HeartbeatHttpClient();
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(
        channel,
        summary: _backupSnapshot(deviceName: '手机1')
          ..deviceId = 'android-watchdog-test'
          ..baseUrl = 'http://192.168.31.250:5280'
          ..computerId = 'host-1'
          ..computerName = '电脑1',
      ),
      httpClient: client,
      hostLocator: _FakeHostLocator(null),
      logEvent: (String kind, Map<String, Object?> extra) async {
        logKinds.add(kind);
      },
    );
    addTearDown(service.dispose);
    service.debugSetAccessKeyForTesting('a' * 64);

    await service.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(client.heartbeatPosts, 1);
    expect(logKinds, contains('heartbeat_stalled'));
    expect(logKinds, contains('heartbeat_send'));
  });

  test('Android 私有目录别名会识别为同一个备份文件', () {
    expect(
      isSameLanBackupFile(
        '/data/user/0/app.packingproof.mobile/app_flutter/recordings/a.mp4',
        '/data/data/app.packingproof.mobile/app_flutter/recordings/a.mp4',
      ),
      isTrue,
    );
    expect(
      isSameLanBackupFile(
        '/data/user/0/app.packingproof.mobile/app_flutter/recordings/a.mp4',
        '/data/data/app.packingproof.mobile/app_flutter/recordings/b.mp4',
      ),
      isFalse,
    );
  });

  test('二维码只解析局域网主机地址并忽略旧查看密钥', () {
    final LanBackupEndpoint endpoint = LanBackupService.parsePairingQr(
      'http://192.168.1.20:5280/?key=0123456789abcdef',
    );
    expect(endpoint.baseUri.toString(), 'http://192.168.1.20:5280');
    expect(endpoint.accessKey, isEmpty);
  });

  test('拒绝公网和域名并接受不含密钥的局域网二维码', () {
    expect(
      () => LanBackupService.parsePairingQr(
        'http://8.8.8.8:5280/?key=0123456789abcdef',
      ),
      throwsFormatException,
    );
    expect(
      () => LanBackupService.parsePairingQr(
        'http://computer.local:5280/?key=0123456789abcdef',
      ),
      throwsFormatException,
    );
    expect(
      LanBackupService.parsePairingQr('http://192.168.1.20:5280/').baseUri,
      Uri.parse('http://192.168.1.20:5280'),
    );
  });

  test('电脑心跳恢复后自动切回已连接状态', () {
    expect(
      heartbeatConnectionStatus(HttpStatus.ok),
      LanConnectionStatus.connected,
    );
    expect(
      heartbeatConnectionStatus(HttpStatus.serviceUnavailable),
      LanConnectionStatus.offline,
    );
    expect(
      heartbeatConnectionStatus(HttpStatus.unauthorized),
      LanConnectionStatus.rePair,
    );
  });

  test('备份失败类型兼容旧任务并可触发重新扫码状态', () {
    final LanBackupJob legacy = LanBackupJob.fromMap(<Object?, Object?>{
      'id': 'legacy',
      'filePath': 'legacy.mp4',
      'state': 'failed',
    });
    final LanBackupJob invalidKey = LanBackupJob.fromMap(<Object?, Object?>{
      'id': 'invalid-key',
      'filePath': 'pending.mp4',
      'state': 'failed',
      'failureKind': 'credential_invalid',
    });
    final LanBackupEndpoint endpoint = LanBackupEndpoint(
      baseUri: Uri.parse('http://192.168.1.20:5280'),
      accessKey: '',
      computerId: 'computer-1',
      computerName: '仓库电脑',
    );

    expect(legacy.failureKind, isNull);
    expect(invalidKey.failureKind, LanBackupFailureKind.credentialInvalid);
    expect(
      nativeBackupConnectionStatus(
        previous: LanConnectionStatus.connected,
        endpoint: endpoint,
        dominantFailureKind: invalidKey.failureKind,
      ),
      LanConnectionStatus.rePair,
    );

    final LanBackupJob wrongRole = LanBackupJob.fromMap(<Object?, Object?>{
      'id': 'wrong-role',
      'filePath': 'pending.mp4',
      'state': 'failed',
      'failureKind': 'not_backup_host',
    });
    expect(wrongRole.failureKind, LanBackupFailureKind.notBackupHost);
    expect(
      nativeBackupConnectionStatus(
        previous: LanConnectionStatus.connected,
        endpoint: endpoint,
        dominantFailureKind: wrongRole.failureKind,
      ),
      LanConnectionStatus.notBackupHost,
    );
    expect(
      nativeBackupConnectionStatus(
        previous: LanConnectionStatus.rePair,
        endpoint: endpoint,
        dominantFailureKind: invalidKey.failureKind,
        hasActiveUpload: true,
      ),
      LanConnectionStatus.connected,
    );
  });

  test('每种结构化备份失败只映射一个恢复操作', () {
    final Map<String, LanBackupRecoveryAction> cases =
        <String, LanBackupRecoveryAction>{
          'credential_invalid': LanBackupRecoveryAction.rescan,
          'offline_or_timeout': LanBackupRecoveryAction.retryConnection,
          'temporary_service': LanBackupRecoveryAction.retryBackup,
          'upload_expired': LanBackupRecoveryAction.retryBackup,
          'verification_failed': LanBackupRecoveryAction.retryBackup,
          'storage_unavailable': LanBackupRecoveryAction.retryBackup,
          'not_backup_host': LanBackupRecoveryAction.rescan,
          'incompatible_version': LanBackupRecoveryAction.retryConnection,
          'unknown': LanBackupRecoveryAction.retryBackup,
        };

    for (final MapEntry<String, LanBackupRecoveryAction> entry
        in cases.entries) {
      final LanBackupFailureKind? kind = LanBackupFailureKind.fromWireValue(
        entry.key,
      );
      expect(kind, isNotNull);
      expect(kind!.recoveryAction, entry.value);
      expect(kind.recoveryLabel, isNotEmpty);
    }
  });

  test('手机历史仅请求当前设备可访问的录像', () {
    final Uri uri = buildRemoteRecordingsUri(
      Uri.parse('http://192.168.1.20:5280'),
      page: 2,
      pageSize: 10,
      keyword: 'TRACK-1',
      operationMode: RecordingOperationMode.returnGoods,
    );

    expect(uri.path, '/api/mobile-backup/videos');
    expect(uri.queryParameters['page'], '2');
    expect(uri.queryParameters['size'], '10');
    expect(uri.queryParameters['keyword'], 'TRACK-1');
    expect(uri.queryParameters['mode'], 'return');
    expect(uri.queryParameters.containsKey('deviceId'), isFalse);
  });

  test('电脑传来的最低版本仅在当前 App 过旧时生成更新提示', () {
    final Map<String, Object?> policy = <String, Object?>{
      'schemaVersion': 1,
      'minimumVersion': '0.5.6',
      'minimumBuildNumber': 11006,
      'message': '当前 APP 版本过低，需要更新',
    };

    expect(
      evaluateMobileAppUpdatePolicy(
        policy,
        currentVersion: '0.5.6',
        currentBuildNumber: 11006,
      ),
      isNull,
    );

    final MobileAppUpdateNotice? notice = evaluateMobileAppUpdatePolicy(
      policy,
      currentVersion: '0.5.5',
      currentBuildNumber: 11005,
    );
    expect(notice?.minimumVersion, '0.5.6');
    expect(notice?.message, '当前 APP 版本过低，需要更新');
  });

  test('版本比较兼容不同长度的语义版本号', () {
    expect(compareAppVersions('0.5.5', '0.5.6'), lessThan(0));
    expect(compareAppVersions('0.5.6', '0.5.6'), 0);
    expect(compareAppVersions('0.5.10', '0.5.6'), greaterThan(0));
  });

  test('电脑传来的推荐版本高于当前版本时生成普通更新提示', () {
    final MobileAppUpdateNotice? notice = evaluateMobileAppUpdatePolicy(
      <String, Object?>{
        'schemaVersion': 2,
        'minimumVersion': '0.5.6',
        'minimumBuildNumber': 11006,
        'message': '当前 APP 版本过低，需要更新',
        'latestVersion': '0.5.7',
        'latestBuildNumber': 11007,
      },
      currentVersion: '0.5.6',
      currentBuildNumber: 11006,
    );

    expect(notice?.updateRequired, isFalse);
    expect(notice?.latestVersion, '0.5.7');
    expect(notice?.message, '发现新版手机 App，建议更新');
  });

  test('未连接 Wi-Fi 时扫码给出友好提示且不发起网络请求', () async {
    final _UnexpectedHttpClient httpClient = _UnexpectedHttpClient();
    final LanBackupService service = LanBackupService(
      httpClient: httpClient,
      wifiConnected: () async => false,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.pair('http://192.168.1.20:5280/?key=0123456789abcdef'),
      throwsA(
        isA<FormatException>().having(
          (FormatException error) => error.message,
          'message',
          '请先连接与电脑相同的 Wi-Fi 后重试',
        ),
      ),
    );
    expect(httpClient.requested, isFalse);
  });

  test('连接到非备份用途电脑时要求重新扫码而不是更新电脑端', () async {
    final LanBackupService service = LanBackupService(
      httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
        _StreamHttpResponse(
          HttpStatus.ok,
          '{"protocol":"packingproof","protocolVersion":1,'
          '"nodeId":"computer-1","capabilities":["recording","order-receiver"]}',
        ),
      ]),
      wifiConnected: () async => true,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.pair('http://192.168.1.20:5280/?key=0123456789abcdef'),
      throwsA(isA<LanBackupNotHostException>()),
    );

    expect(
      service.snapshot.connectionStatus,
      LanConnectionStatus.notBackupHost,
    );
    expect(service.snapshot.message, contains('不是录像备份主机'));
  });

  test('录像备份元数据包含记录区间和面单标记', () {
    final DateTime startedAt = DateTime.utc(2026, 7, 19, 10);
    final RecordingSession session = RecordingSession(
      id: 'session-1',
      filePath: '${Directory.systemTemp.path}/legacy.mp4',
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 8)),
      markers: <BarcodeMarker>[
        BarcodeMarker(
          code: 'SF1234567890',
          occurredAt: startedAt,
          offset: Duration.zero,
        ),
      ],
      mediaStart: const Duration(seconds: 2),
      mediaEnd: const Duration(seconds: 10),
      operationMode: RecordingOperationMode.returnGoods,
      orderInfo: const OrderInfo(
        orderId: 'private-order',
        trackingNumber: 'SF1234567890',
        buyerMessage: 'private-message',
      ),
      videoCodec: 'h265',
    );

    final Map<String, Object?> value = recordingSessionBackupMap(session);
    expect(value['trackingNumber'], 'SF1234567890');
    expect(value['mediaStartMs'], 2000);
    expect(value['mediaEndMs'], 10000);
    expect(value['markers'], hasLength(1));
    expect(value['mode'], 'return');
    expect(value['videoCodec'], 'h265');
    expect(value, isNot(contains('orderInfo')));
  });

  test('备份元数据与四端共享契约夹具一致', () async {
    final Map<String, Object?> fixture = Map<String, Object?>.from(
      jsonDecode(
            await File(
              'protocol-fixtures/mobile-backup-v2-complete.json',
            ).readAsString(),
          )
          as Map,
    );
    final Map<String, Object?> request = Map<String, Object?>.from(
      fixture['request']! as Map,
    );
    final Map<String, Object?> expectedSession = Map<String, Object?>.from(
      (request['sessions']! as List<Object?>).single! as Map,
    );
    final Map<String, Object?> response = Map<String, Object?>.from(
      fixture['response']! as Map,
    );
    final DateTime startedAt = DateTime.parse(
      expectedSession['startedAt']! as String,
    );
    final Map<String, Object?> marker = Map<String, Object?>.from(
      (expectedSession['markers']! as List<Object?>).single! as Map,
    );
    final RecordingSession session = RecordingSession(
      id: expectedSession['id']! as String,
      filePath: '${Directory.systemTemp.path}/contract.mp4',
      startedAt: startedAt,
      endedAt: DateTime.parse(expectedSession['endedAt']! as String),
      markers: <BarcodeMarker>[
        BarcodeMarker(
          code: marker['code']! as String,
          occurredAt: DateTime.parse(marker['occurredAt']! as String),
          offset: Duration(milliseconds: (marker['offsetMs']! as num).toInt()),
        ),
      ],
      mediaStart: Duration(
        milliseconds: (expectedSession['mediaStartMs']! as num).toInt(),
      ),
      mediaEnd: Duration(
        milliseconds: (expectedSession['mediaEndMs']! as num).toInt(),
      ),
    );

    expect(recordingSessionBackupMap(session), expectedSession);
    expect(request['sessions'], hasLength(1));
    expect(response['recordId'], 42);
    expect(response, isNot(contains('recordIds')));
  });

  test('立即备份会要求原生任务强制重启', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-backup-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File video = File('${root.path}/video.mp4');
    await video.writeAsBytes(<int>[1, 2, 3]);
    final MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/lan_backup_test_${root.path.hashCode}',
    );
    MethodCall? enqueueCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'enqueue') enqueueCall = call;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);
    final DateTime startedAt = DateTime.utc(2026, 7, 19, 10);

    await service.backupAll(<RecordingSession>[
      RecordingSession(
        id: 'session-1',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <BarcodeMarker>[],
      ),
    ], forceRestart: true);

    expect(enqueueCall?.method, 'enqueue');
    final Map<Object?, Object?> arguments =
        enqueueCall!.arguments! as Map<Object?, Object?>;
    expect(arguments['startUpload'], isTrue);
    expect(arguments['forceRestart'], isTrue);
  });

  test('启动备份把已完成任务交给原生幂等裁决', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-skip-completed-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File video = File('${root.path}/video.mp4');
    await video.writeAsBytes(<int>[1, 2, 3]);
    final MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/lan_backup_skip_completed_${root.path.hashCode}',
    );
    int enqueueCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'enqueue') enqueueCalls++;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);
    final DateTime startedAt = DateTime.utc(2026, 7, 19, 10);

    await service.backupAll(<RecordingSession>[
      RecordingSession(
        id: 'session-completed',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <BarcodeMarker>[],
      ),
    ]);

    expect(enqueueCalls, 1);
  });

  test('启动备份把待上传任务交给原生幂等裁决且不强制重启', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-skip-pending-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File video = File('${root.path}/video.mp4');
    await video.writeAsBytes(<int>[1, 2, 3]);
    final MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/lan_backup_skip_pending_${root.path.hashCode}',
    );
    int enqueueCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'enqueue') enqueueCalls++;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);
    final DateTime startedAt = DateTime.utc(2026, 7, 19, 10);

    await service.backupAll(<RecordingSession>[
      RecordingSession(
        id: 'session-pending',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <BarcodeMarker>[],
      ),
    ]);

    expect(enqueueCalls, 1);
  });

  test('启动备份对暂停任务重新入队但不强制重启', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-resume-paused-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File video = File('${root.path}/video.mp4');
    await video.writeAsBytes(<int>[1, 2, 3]);
    final MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/lan_backup_resume_paused_${root.path.hashCode}',
    );
    MethodCall? enqueueCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'enqueue') enqueueCall = call;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);
    final DateTime startedAt = DateTime.utc(2026, 7, 19, 10);

    await service.backupAll(<RecordingSession>[
      RecordingSession(
        id: 'session-paused',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <BarcodeMarker>[],
      ),
    ]);

    expect(enqueueCall?.method, 'enqueue');
    final Map<Object?, Object?> arguments =
        enqueueCall!.arguments! as Map<Object?, Object?>;
    expect(arguments['startUpload'], isTrue);
    expect(arguments['forceRestart'], isFalse);
  });

  test('启动备份条件不满足时必须走原生入队', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-skip-mismatch-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File video = File('${root.path}/video.mp4');
    await video.writeAsBytes(<int>[1, 2, 3]);
    final MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/lan_backup_skip_mismatch_${root.path.hashCode}',
    );
    int enqueueCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'enqueue') enqueueCalls++;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);
    final DateTime startedAt = DateTime.utc(2026, 7, 19, 10);

    await service.backupAll(<RecordingSession>[
      RecordingSession(
        id: 'session-mismatch',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <BarcodeMarker>[],
      ),
    ]);

    expect(enqueueCalls, 1);
  });

  test('摘要内容未变时不重复通知监听者', () {
    final LanBackupService service = LanBackupService();
    addTearDown(service.dispose);
    int notifications = 0;
    service.addListener(() => notifications++);
    final BackupSummaryDto values = _backupSnapshot(deviceName: '手机1')
      ..deviceId = 'android-signature';

    service.debugApplyNativeSummaryForTesting(values);
    expect(notifications, 1);
    service.debugApplyNativeSummaryForTesting(values);
    expect(notifications, 1);
  });

  test('原生摘要拒绝低 revision 与不支持的 schemaVersion', () {
    final LanBackupService service = LanBackupService();
    addTearDown(service.dispose);

    service.debugApplyNativeSummaryForTesting(
      _backupSnapshot(deviceName: '新摘要', revision: 10),
    );
    service.debugApplyNativeSummaryForTesting(
      _backupSnapshot(deviceName: '旧摘要', revision: 9),
    );
    service.debugApplyNativeSummaryForTesting(
      _backupSnapshot(deviceName: '未知协议', schemaVersion: 2, revision: 11),
    );

    expect(service.snapshot.deviceName, '新摘要');
    expect(service.snapshot.summary.revision, 10);
  });

  test('按路径查询拒绝 endpoint 切换后的旧响应', () async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final LanBackupService service = _testBackupService(platform);
    addTearDown(service.dispose);
    service.debugApplyNativeSummaryForTesting(
      _backupSnapshot(
        deviceName: '手机',
        revision: 5,
        baseUrl: 'http://192.168.1.10:5280',
        computerId: 'computer-a',
      ),
    );
    final Completer<BackupJobsByPathsDto> response =
        Completer<BackupJobsByPathsDto>();
    platform.jobResults.add(response);

    final Future<LanBackupJobsByPaths> request = service.jobsForPaths(<String>[
      '/recordings/a.mp4',
    ]);
    service.debugApplyNativeSummaryForTesting(
      _backupSnapshot(
        deviceName: '手机',
        revision: 6,
        baseUrl: 'http://192.168.1.11:5280',
        computerId: 'computer-b',
      ),
    );
    response.complete(
      BackupJobsByPathsDto(
        revision: 5,
        jobs: <BackupJobDto>[],
        missingPaths: <String>['/recordings/a.mp4'],
      ),
    );

    await expectLater(request, throwsStateError);
  });

  test('按路径查询去重 Android 私有目录别名但向原生保留真实路径', () async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final LanBackupService service = _testBackupService(platform);
    addTearDown(service.dispose);

    await service.jobsForPaths(<String>[
      '/data/user/0/app.packingproof.mobile/files/a.mp4',
      '/data/data/app.packingproof.mobile/files/a.mp4',
    ]);

    expect(platform.requestedJobPaths, <List<String>>[
      <String>['/data/user/0/app.packingproof.mobile/files/a.mp4'],
    ]);
  });

  test('按路径查询拒绝摘要推进及分页 revision 倒退', () async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final LanBackupService service = _testBackupService(platform);
    addTearDown(service.dispose);
    service.debugApplyNativeSummaryForTesting(
      _backupSnapshot(deviceName: '手机', revision: 4),
    );
    final Completer<BackupJobsByPathsDto> staleResponse =
        Completer<BackupJobsByPathsDto>();
    platform.jobResults.add(staleResponse);
    final Future<LanBackupJobsByPaths> staleRequest = service.jobsForPaths(
      <String>['/recordings/a.mp4'],
    );
    service.debugApplyNativeSummaryForTesting(
      _backupSnapshot(deviceName: '手机', revision: 5),
    );
    staleResponse.complete(
      BackupJobsByPathsDto(
        revision: 4,
        jobs: <BackupJobDto>[],
        missingPaths: <String>['/recordings/a.mp4'],
      ),
    );
    await expectLater(staleRequest, throwsStateError);

    platform.jobResults.addAll(<Completer<BackupJobsByPathsDto>>[
      Completer<BackupJobsByPathsDto>()..complete(
        BackupJobsByPathsDto(
          revision: 6,
          jobs: <BackupJobDto>[],
          missingPaths: List<String>.generate(
            100,
            (int index) => '/recordings/$index.mp4',
          ),
        ),
      ),
      Completer<BackupJobsByPathsDto>()..complete(
        BackupJobsByPathsDto(
          revision: 5,
          jobs: <BackupJobDto>[],
          missingPaths: <String>['/recordings/100.mp4'],
        ),
      ),
    ]);
    await expectLater(
      service.jobsForPaths(
        List<String>.generate(101, (int index) => '/recordings/$index.mp4'),
      ),
      throwsStateError,
    );
  });

  test('固定大小摘要缺省字段可正常解析', () {
    final LanBackupService service = LanBackupService();
    addTearDown(service.dispose);
    service.debugApplyNativeSummaryForTesting(
      _backupSnapshot(deviceName: '手机2')
        ..deviceId = 'android-slim'
        ..totalCount = 1
        ..pendingCount = 1
        ..unfinishedTotalBytes = 100
        ..activeJob = BackupJobDto(
          revision: 0,
          id: 'job-slim',
          filePath: '/data/user/0/app.packingproof.mobile/recordings/a.mp4',
          state: 'pending',
          uploadedBytes: 0,
          totalBytes: 100,
          lastModifiedMs: 1000,
          contentSha256: 'sha-slim',
          waitingCleanup: false,
          destinationComputerId: '',
        ),
    );

    final LanBackupJob job = service.snapshot.summary.activeJob!;
    expect(job.id, 'job-slim');
    expect(job.lastModified?.millisecondsSinceEpoch, 1000);
    expect(job.contentSha256, 'sha-slim');
    expect(job.remoteRecordId, isNull);
    expect(job.destinationComputerId, '');
  });

  testWidgets('任意推进周期时钟都不会自动读取全量任务', (WidgetTester tester) async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final LanBackupService service = _testBackupService(platform);
    await service.initialize(
      autoEnabled: true,
      unbackedRetention: UnbackedRetentionPolicy.days30,
      backedRetention: BackedRetentionPolicy.days7,
    );
    await tester.pump(const Duration(hours: 6));

    expect(platform.snapshotCalls, 0);
    await service.dispose();
  });

  test('启动时把存储策略下发给原生平台', () async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final LanBackupService service = _testBackupService(platform);
    addTearDown(service.dispose);

    await service.initialize(
      autoEnabled: true,
      unbackedRetention: UnbackedRetentionPolicy.days30,
      backedRetention: BackedRetentionPolicy.days7,
    );

    expect(
      platform.lastInitializeRequest,
      containsPair('storageMinimumBytes', BackupStoragePolicy.minimumBytes),
    );
    expect(
      platform.lastInitializeRequest,
      containsPair('storageWarningBytes', BackupStoragePolicy.warningBytes),
    );
    expect(
      platform.lastInitializeRequest,
      containsPair('storageTargetBytes', BackupStoragePolicy.targetBytes),
    );
    expect(
      platform.lastInitializeRequest,
      containsPair(
        'storageAttestationFreshnessMs',
        BackupStoragePolicy.attestationFreshness.inMilliseconds,
      ),
    );
    expect(
      platform.lastInitializeRequest,
      containsPair(
        'storageConfirmationLimit',
        BackupStoragePolicy.confirmationLimit,
      ),
    );
    expect(
      platform.lastInitializeRequest,
      containsPair(
        'storageConfirmationGraceMs',
        BackupStoragePolicy.confirmationGrace.inMilliseconds,
      ),
    );
    expect(
      platform.lastInitializeRequest,
      containsPair(
        'storageDeleteUnbackedOnPressure',
        BackupStoragePolicy.toNativeRequest()['storageDeleteUnbackedOnPressure'],
      ),
    );
  });

  test('修改空间不足策略会下发给原生平台', () async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final LanBackupService service = _testBackupService(platform);
    addTearDown(service.dispose);

    await service.setRetentionPolicies(
      unbacked: UnbackedRetentionPolicy.days30,
      backed: BackedRetentionPolicy.days7,
      storagePressurePolicy: StoragePressurePolicy.preserveRecording,
    );

    expect(
      platform.lastRetentionScheduleRequest,
      containsPair('storageDeleteUnbackedOnPressure', true),
    );
  });

  test('存储检查依赖原生变更事件而不主动读取全量任务', () async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final LanBackupService service = _testBackupService(platform);
    addTearDown(service.dispose);
    await service.initialize(
      autoEnabled: true,
      unbackedRetention: UnbackedRetentionPolicy.days30,
      backedRetention: BackedRetentionPolicy.days7,
    );

    final StorageSpaceResult result = await service.checkAndReclaimStorage();

    expect(result.availableBytes, 4 * 1024 * 1024 * 1024);
    expect(platform.reclaimCalls, 1);
    expect(platform.snapshotCalls, 0);
  });

  test('原生事件更新与并发显式刷新仍可合并', () async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final LanBackupService service = _testBackupService(platform);
    addTearDown(service.dispose);
    await service.initialize(
      autoEnabled: true,
      unbackedRetention: UnbackedRetentionPolicy.days30,
      backedRetention: BackedRetentionPolicy.days7,
    );
    final Completer<BackupSummaryDto> firstSnapshot =
        Completer<BackupSummaryDto>();
    final Completer<BackupSummaryDto> mergedSnapshot =
        Completer<BackupSummaryDto>();
    platform.snapshotResults.addAll(<Completer<BackupSummaryDto>>[
      firstSnapshot,
      mergedSnapshot,
    ]);

    final Future<void> firstRefresh = service.refresh();
    final Future<void> secondRefresh = service.refresh();
    platform.emitSnapshot(_backupSnapshot(deviceName: '原生事件'));
    expect(service.snapshot.deviceName, '原生事件');
    expect(platform.snapshotCalls, 1);

    firstSnapshot.complete(_backupSnapshot(deviceName: '第一次刷新'));
    await Future<void>.delayed(Duration.zero);
    expect(platform.snapshotCalls, 2);
    mergedSnapshot.complete(_backupSnapshot(deviceName: '合并刷新'));
    await Future.wait(<Future<void>>[firstRefresh, secondRefresh]);

    expect(platform.snapshotCalls, 2);
    expect(service.snapshot.deviceName, '合并刷新');
  });

  testWidgets('dispose 后不会留下周期摘要轮询', (WidgetTester tester) async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final LanBackupService service = _testBackupService(platform);
    await service.initialize(
      autoEnabled: true,
      unbackedRetention: UnbackedRetentionPolicy.days30,
      backedRetention: BackedRetentionPolicy.days7,
    );

    await service.dispose();
    await tester.pump(const Duration(days: 1));

    expect(platform.snapshotCalls, 0);
    expect(platform.disposeCalls, 1);
  });

  test('自动备份关闭时入队仍留下决策日志', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-log-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File video = File('${root.path}/video.mp4');
    await video.writeAsBytes(<int>[1, 2, 3]);
    final MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/lan_backup_log_test_${root.path.hashCode}',
    );
    var nativeAutoEnabled = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'setAutoEnabled') {
            nativeAutoEnabled = call.arguments! as bool;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final List<({String kind, Map<String, Object?> extra})> events =
        <({String kind, Map<String, Object?> extra})>[];
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
      logEvent: (String kind, Map<String, Object?> extra) async {
        events.add((kind: kind, extra: extra));
      },
    );
    addTearDown(service.dispose);
    await service.setAutoEnabled(false);
    expect(nativeAutoEnabled, isFalse);
    final DateTime startedAt = DateTime.utc(2026, 7, 25, 10);
    await service.enqueueFinalizedFile(video.path, <RecordingSession>[
      RecordingSession(
        id: 'session-log',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <BarcodeMarker>[],
      ),
    ]);

    final List<Map<String, Object?>> enqueueLogs = events
        .where((event) => event.kind == 'backup_enqueue_batch')
        .map((event) => event.extra)
        .toList();
    expect(enqueueLogs, isNotEmpty);
    expect(enqueueLogs.last['startUpload'], isFalse);
    expect(enqueueLogs.last['forceRestart'], isFalse);
    expect(enqueueLogs.last['requestedCount'], 1);
    expect(enqueueLogs.last['enqueuedCount'], 1);
    final List<Map<String, Object?>> toggleLogs = events
        .where((event) => event.kind == 'backup_auto_toggle')
        .map((event) => event.extra)
        .toList();
    expect(toggleLogs, isNotEmpty);
    expect(toggleLogs.last['enabled'], isFalse);
  });

  test('批量注册录像只刷新一次摘要并记录批次数量', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-batch-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File first = File('${root.path}/first.mp4');
    final File second = File('${root.path}/second.mp4');
    await first.writeAsBytes(<int>[1, 2, 3]);
    await second.writeAsBytes(<int>[4, 5, 6]);
    final MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/lan_backup_batch_test_${root.path.hashCode}',
    );
    int enqueueCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'enqueue') {
            enqueueCalls++;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final List<({String kind, Map<String, Object?> extra})> events =
        <({String kind, Map<String, Object?> extra})>[];
    final _TestChannelBackupPlatform platform = _TestChannelBackupPlatform(
      channel,
    );
    final LanBackupService service = LanBackupService(
      platform: platform,
      logEvent: (String kind, Map<String, Object?> extra) async {
        events.add((kind: kind, extra: extra));
      },
    );
    addTearDown(service.dispose);
    await service.setAutoEnabled(false);
    final DateTime startedAt = DateTime.utc(2026, 7, 25, 10);

    await service.enqueueFinalizedFiles(<String, List<RecordingSession>>{
      first.path: <RecordingSession>[
        RecordingSession(
          id: 'session-batch-1',
          filePath: first.path,
          startedAt: startedAt,
          endedAt: startedAt.add(const Duration(seconds: 1)),
          markers: const <BarcodeMarker>[],
        ),
      ],
      second.path: <RecordingSession>[
        RecordingSession(
          id: 'session-batch-2',
          filePath: second.path,
          startedAt: startedAt,
          endedAt: startedAt.add(const Duration(seconds: 1)),
          markers: const <BarcodeMarker>[],
        ),
      ],
    });

    expect(enqueueCalls, 2);
    expect(platform.summaryCalls, 1);
    expect(
      events.where((event) => event.kind == 'backup_enqueue_batch'),
      hasLength(1),
    );
    final Map<String, Object?> batchLog = events
        .lastWhere((event) => event.kind == 'backup_enqueue_batch')
        .extra;
    expect(batchLog['requestedCount'], 2);
    expect(batchLog['enqueuedCount'], 2);
  });

  test('原生入队每次最多提交 100 条', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-native-batch-',
    );
    addTearDown(() => root.delete(recursive: true));
    final DateTime startedAt = DateTime.utc(2026, 8, 23, 10);
    final List<RecordingSession> sessions = <RecordingSession>[];
    for (var index = 0; index < 205; index++) {
      final File video = File('${root.path}/$index.mp4');
      await video.writeAsBytes(<int>[index & 0xff]);
      sessions.add(
        RecordingSession(
          id: 'batch-$index',
          filePath: video.path,
          startedAt: startedAt,
          endedAt: startedAt.add(const Duration(seconds: 1)),
          markers: const <BarcodeMarker>[],
        ),
      );
    }
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final LanBackupService service = LanBackupService(platform: platform);
    addTearDown(service.dispose);

    await service.backupAll(sessions);

    expect(platform.enqueuedBatches.map((batch) => batch.length), <int>[
      100,
      100,
      5,
    ]);
  });

  test('入队边界拒绝空或多条录像记录', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-cardinality-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File video = File('${root.path}/video.mp4');
    await video.writeAsBytes(<int>[1, 2, 3]);
    final MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/lan_backup_cardinality_${root.path.hashCode}',
    );
    var enqueueCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'enqueue') enqueueCalls++;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);
    final DateTime startedAt = DateTime.utc(2026, 7, 25, 10);
    RecordingSession session(String id) => RecordingSession(
      id: id,
      filePath: video.path,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 1)),
      markers: const <BarcodeMarker>[],
    );

    await expectLater(
      service.enqueueFinalizedFile(video.path, const <RecordingSession>[]),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      service.enqueueFinalizedFile(video.path, <RecordingSession>[
        session('first'),
        session('second'),
      ]),
      throwsA(isA<StateError>()),
    );
    expect(enqueueCalls, 0);
  });

  test('备份失败日志只记录状态边沿变化', () async {
    final List<({String kind, Map<String, Object?> extra})> events =
        <({String kind, Map<String, Object?> extra})>[];
    final LanBackupService service = LanBackupService(
      logEvent: (String kind, Map<String, Object?> extra) async {
        events.add((kind: kind, extra: extra));
      },
    );
    addTearDown(service.dispose);

    BackupJobDto failedJob() => BackupJobDto(
      revision: 1,
      id: 'job-1',
      filePath: '/tmp/job-1.mp4',
      state: 'failed',
      uploadedBytes: 0,
      totalBytes: 1,
      failureKind: 'unknown',
      errorMessage: '录像片段 ID 无效',
      waitingCleanup: false,
      destinationComputerId: '',
    );
    BackupSummaryDto summaryWithProblem(BackupJobDto? problem, int revision) =>
        _backupSnapshot(deviceName: '手机1')
          ..revision = revision
          ..failedCount = problem == null ? 0 : 1
          ..problemJob = problem;

    service.debugApplyNativeSummaryForTesting(
      summaryWithProblem(failedJob(), 1),
    );
    service.debugApplyNativeSummaryForTesting(
      summaryWithProblem(failedJob(), 1),
    );
    expect(
      events.where((event) => event.kind == 'backup_job_failed'),
      hasLength(1),
    );

    service.debugApplyNativeSummaryForTesting(summaryWithProblem(null, 2));
    service.debugApplyNativeSummaryForTesting(
      summaryWithProblem(failedJob(), 3),
    );

    final List<Map<String, Object?>> failures = events
        .where((event) => event.kind == 'backup_job_failed')
        .map((event) => event.extra)
        .toList();
    expect(failures, hasLength(2));
    expect(failures.last['jobId'], 'job-1');
    expect(failures.last['errorMessage'], '录像片段 ID 无效');
  });

  test('等待续传不会记录为备份失败', () async {
    final List<({String kind, Map<String, Object?> extra})> events =
        <({String kind, Map<String, Object?> extra})>[];
    final LanBackupService service = LanBackupService(
      logEvent: (String kind, Map<String, Object?> extra) async {
        events.add((kind: kind, extra: extra));
      },
    );
    addTearDown(service.dispose);

    final BackupJobDto pausedJob = BackupJobDto(
      revision: 1,
      id: 'job-paused',
      filePath: '/tmp/job-paused.mp4',
      state: 'paused',
      uploadedBytes: 0,
      totalBytes: 1,
      waitingCleanup: false,
      destinationComputerId: '',
    );
    service.debugApplyNativeSummaryForTesting(
      _backupSnapshot(deviceName: '手机1')
        ..revision = pausedJob.revision
        ..pausedCount = 1
        ..problemJob = pausedJob,
    );

    expect(events.where((event) => event.kind == 'backup_job_failed'), isEmpty);
  });

  test('空录像不会创建无法完成的备份任务', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-empty-backup-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File video = File('${root.path}/empty.mp4');
    await video.create();
    final MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/lan_backup_empty_test_${root.path.hashCode}',
    );
    int enqueueCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'enqueue') enqueueCount++;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);
    final DateTime startedAt = DateTime.utc(2026, 7, 24, 10);

    await service.backupAll(<RecordingSession>[
      RecordingSession(
        id: 'empty-session',
        filePath: video.path,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 1)),
        markers: const <BarcodeMarker>[],
      ),
    ]);

    expect(enqueueCount, 0);
  });

  test('获取网络诊断并解析 Wi-Fi 信号', () async {
    final MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/lan_backup_network_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method != 'getNetworkDiagnostics') return null;
          return <Object?, Object?>{
            'wifiConnected': true,
            'rssiDbm': -55,
            'linkSpeedMbps': 866,
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);

    final NetworkDiagnostics? diagnostics = await service
        .getNetworkDiagnostics();

    expect(diagnostics, isNotNull);
    expect(diagnostics!.wifiConnected, isTrue);
    expect(diagnostics.rssiDbm, -55);
    expect(diagnostics.linkSpeedMbps, 866);
  });

  test('未连接 Wi-Fi 时网络诊断返回空信号字段', () async {
    final MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/lan_backup_network_empty_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'getNetworkDiagnostics') {
            return <Object?, Object?>{'wifiConnected': false};
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);

    final NetworkDiagnostics? diagnostics = await service
        .getNetworkDiagnostics();

    expect(diagnostics, isNotNull);
    expect(diagnostics!.wifiConnected, isFalse);
    expect(diagnostics.rssiDbm, isNull);
    expect(diagnostics.linkSpeedMbps, isNull);
  });

  test('保存主机允许后才保存设备专属令牌', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_v3_enrollment_test',
    );
    Map<Object?, Object?>? saved;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'saveConnection') {
            saved = Map<Object?, Object?>.from(call.arguments! as Map);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final _SequenceHttpClient httpClient =
        _SequenceHttpClient(<_StreamHttpResponse>[
          _nodeInfo('computer-1', '仓库电脑'),
          _enrollment('computer-1', '仓库电脑', 'a' * 64, deviceName: '手机3'),
        ]);
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
      httpClient: httpClient,
      wifiConnected: () async => true,
    );
    addTearDown(service.dispose);

    await service.connectToHost(Uri.parse('http://192.168.1.20:5280'));

    expect(saved?['accessKey'], 'a' * 64);
    expect(saved?['computerId'], 'computer-1');
    expect(saved?['deviceName'], '手机3');
    expect(service.snapshot.deviceName, '手机3');
    expect(service.snapshot.message, '保存主机已允许连接');
    final Map<String, Object?> enrollmentRequest = Map<String, Object?>.from(
      jsonDecode(utf8.decode(httpClient.postBodies.single)) as Map,
    );
    expect(enrollmentRequest['clientVersion'], '0.5.25');
    expect(enrollmentRequest['clientBuildNumber'], 11040);
    expect(enrollmentRequest['backupProtocol'], 'mobile-backup-v2');
    expect(enrollmentRequest['enrollmentVersion'], 2);
    expect(enrollmentRequest['authVersion'], 3);
    // 主机靠平台分配"安卓N/苹果N"昵称，注册请求必须带上它。
    expect(enrollmentRequest['platform'], currentDevicePlatformId());
  });

  test('心跳分配的新昵称会立即显示并持久化', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_heartbeat_name_test',
    );
    Map<Object?, Object?>? saved;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'saveConnection') {
            saved = Map<Object?, Object?>.from(call.arguments! as Map);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        deviceName: '设备 A1B2C3',
        endpoint: LanBackupEndpoint(
          baseUri: Uri.parse('http://192.168.1.20:5280'),
          accessKey: '',
          computerId: 'computer-1',
          computerName: '仓库电脑',
        ),
      ),
    );

    await service.debugApplyHeartbeatResponseForTesting(
      '{"assignedDisplayName":"手机3"}',
    );

    expect(service.snapshot.deviceName, '手机3');
    expect(saved?['deviceName'], '手机3');
  });

  test('心跳带回的新电脑名与昵称合并成一次写盘并立即生效', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_heartbeat_computer_name_test',
    );
    final List<Map<Object?, Object?>> saved = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'saveConnection') {
            saved.add(Map<Object?, Object?>.from(call.arguments! as Map));
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        deviceName: '设备 A1B2C3',
        endpoint: LanBackupEndpoint(
          baseUri: Uri.parse('http://192.168.1.20:5280'),
          accessKey: '',
          computerId: 'computer-1',
          computerName: '仓库电脑',
        ),
      ),
    );
    int notifications = 0;
    service.addListener(() => notifications++);

    await service.debugApplyHeartbeatResponseForTesting(
      '{"assignedDisplayName":"手机3","computerName":"打包电脑"}',
    );

    expect(service.snapshot.deviceName, '手机3');
    expect(service.snapshot.endpoint?.computerName, '打包电脑');
    // 改名不能带走配对身份和主机地址。
    expect(service.snapshot.endpoint?.computerId, 'computer-1');
    expect(
      service.snapshot.endpoint?.baseUri.toString(),
      'http://192.168.1.20:5280',
    );
    expect(saved, hasLength(1));
    expect(saved.single['deviceName'], '手机3');
    expect(saved.single['computerName'], '打包电脑');
    expect(saved.single['computerId'], 'computer-1');
    expect(notifications, 1);
  });

  test('心跳缺少或空白电脑名时保留已存电脑名', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_heartbeat_absent_name_test',
    );
    final List<Map<Object?, Object?>> saved = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'saveConnection') {
            saved.add(Map<Object?, Object?>.from(call.arguments! as Map));
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        deviceName: '手机3',
        endpoint: LanBackupEndpoint(
          baseUri: Uri.parse('http://192.168.1.20:5280'),
          accessKey: '',
          computerId: 'computer-1',
          computerName: '仓库电脑',
        ),
      ),
    );
    int notifications = 0;
    service.addListener(() => notifications++);

    // 旧电脑端不回这个字段，或主机暂时拿不到电脑名。
    await service.debugApplyHeartbeatResponseForTesting(
      '{"assignedDisplayName":"手机3"}',
    );
    await service.debugApplyHeartbeatResponseForTesting(
      '{"assignedDisplayName":"手机3","computerName":""}',
    );
    await service.debugApplyHeartbeatResponseForTesting(
      '{"assignedDisplayName":"手机3","computerName":"   "}',
    );

    expect(service.snapshot.endpoint?.computerName, '仓库电脑');
    expect(saved, isEmpty);
    expect(notifications, 0);
  });

  test('心跳电脑名没变化时不重复写盘也不通知', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_heartbeat_same_name_test',
    );
    final List<Map<Object?, Object?>> saved = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'saveConnection') {
            saved.add(Map<Object?, Object?>.from(call.arguments! as Map));
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
    );
    addTearDown(service.dispose);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        deviceName: '手机3',
        endpoint: LanBackupEndpoint(
          baseUri: Uri.parse('http://192.168.1.20:5280'),
          accessKey: '',
          computerId: 'computer-1',
          computerName: '仓库电脑',
        ),
      ),
    );
    int notifications = 0;
    service.addListener(() => notifications++);

    await service.debugApplyHeartbeatResponseForTesting(
      '{"assignedDisplayName":"手机3","computerName":"仓库电脑"}',
    );
    await service.debugApplyHeartbeatResponseForTesting(
      '{"assignedDisplayName":"手机3","computerName":"仓库电脑"}',
    );

    expect(service.snapshot.endpoint?.computerName, '仓库电脑');
    expect(saved, isEmpty);
    expect(notifications, 0);
  });

  test('能力刷新回写连接信息时使用心跳刚更新的电脑名', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_host_features_name_test',
    );
    final List<Map<Object?, Object?>> saved = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'saveConnection') {
            saved.add(Map<Object?, Object?>.from(call.arguments! as Map));
          }
          if (call.method == 'loadAccessKey') return 'a' * 64;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final Completer<HttpClientResponse> capabilities =
        Completer<HttpClientResponse>();
    final _DeferredCapabilitiesHttpClient client =
        _DeferredCapabilitiesHttpClient(capabilities);
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(
        channel,
        summary: _backupSnapshot(deviceName: '手机3')
          ..deviceId = 'device-features'
          ..baseUrl = 'http://192.168.1.20:5280'
          ..computerId = 'computer-1'
          ..computerName = '仓库电脑',
      ),
      httpClient: client,
      hostLocator: _FakeHostLocator(null),
      packageInfoLoader: () async => PackageInfo(
        appName: 'PackingProof',
        packageName: 'app.packingproof.mobile',
        version: '0.5.25',
        buildNumber: '11040',
      ),
    );
    addTearDown(service.dispose);

    await service.initialize(
      autoEnabled: true,
      unbackedRetention: UnbackedRetentionPolicy.days30,
      backedRetention: BackedRetentionPolicy.days7,
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.capabilitiesRequested, isTrue);

    // 能力请求还没回来时，心跳先带来了新电脑名。
    await service.debugApplyHeartbeatResponseForTesting(
      '{"assignedDisplayName":"手机3","computerName":"打包电脑"}',
    );
    capabilities.complete(
      _StreamHttpResponse(
        HttpStatus.ok,
        '{"features":{"uploadVideoCodec":true}}',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(service.snapshot.endpoint?.computerName, '打包电脑');
    expect(saved, hasLength(2));
    // 后写的能力刷新不能把旧电脑名覆盖回磁盘。
    expect(saved.last['computerName'], '打包电脑');
  });

  test('保存主机拒绝时不写入连接配置', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_v3_denied_test',
    );
    int savedConnections = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'saveConnection') savedConnections++;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
      httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
        _nodeInfo('computer-1', '仓库电脑'),
        _StreamHttpResponse(
          HttpStatus.forbidden,
          '{"errorCode":"enrollment_denied"}',
        ),
      ]),
      wifiConnected: () async => true,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.connectToHost(Uri.parse('http://192.168.1.20:5280')),
      throwsA(isA<LanBackupApprovalDeniedException>()),
    );
    expect(savedConnections, 0);
    expect(service.snapshot.endpoint, isNull);
    expect(
      service.snapshot.connectionStatus,
      LanConnectionStatus.approvalDenied,
    );
    expect(service.snapshot.message, '电脑端已拒绝本次连接');
  });

  test('重新申请被拒绝时保留原电脑和待备份任务', () async {
    final LanBackupService service = LanBackupService(
      platform: _TrackingBackupPlatform(),
      httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
        _nodeInfo('computer-1', '仓库电脑'),
        _StreamHttpResponse(
          HttpStatus.forbidden,
          '{"errorCode":"enrollment_denied"}',
        ),
      ]),
      wifiConnected: () async => true,
    );
    addTearDown(service.dispose);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        endpoint: LanBackupEndpoint(
          baseUri: Uri.parse('http://192.168.1.20:5280'),
          accessKey: '',
          computerId: 'computer-1',
          computerName: '仓库电脑',
        ),
        summary: const LanBackupSummary(
          totalCount: 1,
          pendingCount: 1,
          unfinishedTotalBytes: 100,
          activeJob: LanBackupJob(
            id: 'pending-job',
            filePath: 'pending.mp4',
            state: LanBackupJobState.pending,
            uploadedBytes: 0,
            totalBytes: 100,
            destinationComputerId: 'computer-1',
          ),
        ),
        connectionStatus: LanConnectionStatus.rePair,
      ),
    );

    await expectLater(
      service.connectToHost(Uri.parse('http://192.168.1.20:5280')),
      throwsA(isA<LanBackupApprovalDeniedException>()),
    );

    expect(service.snapshot.endpoint?.computerId, 'computer-1');
    expect(service.snapshot.summary.activeJob?.id, 'pending-job');
    expect(
      service.snapshot.connectionStatus,
      LanConnectionStatus.approvalDenied,
    );
  });

  test('等待电脑审批时显示明确状态并可取消恢复', () async {
    final Completer<HttpClientResponse> enrollment =
        Completer<HttpClientResponse>();
    final _DeferredEnrollmentHttpClient client = _DeferredEnrollmentHttpClient(
      _nodeInfo('computer-1', '仓库电脑'),
      enrollment,
    );
    final LanBackupService service = LanBackupService(
      httpClient: client,
      wifiConnected: () async => true,
    );
    addTearDown(service.dispose);

    final Future<void> pairing = service.connectToHost(
      Uri.parse('http://192.168.1.20:5280'),
    );
    while (!client.postRequested) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(
      service.snapshot.connectionStatus,
      LanConnectionStatus.awaitingApproval,
    );
    expect(service.snapshot.message, contains('请在电脑上点击“允许连接”'));
    service.cancelPairing();
    enrollment.complete(_enrollment('computer-1', '仓库电脑', 'a' * 64));
    await pairing;
    expect(service.snapshot.connectionStatus, LanConnectionStatus.disconnected);
    expect(service.snapshot.endpoint, isNull);
  });

  test('审批不可用和限流均显示友好提示且不暴露状态码', () async {
    for (final ({int status, String body, String expected}) sample
        in <({int status, String body, String expected})>[
          (
            status: HttpStatus.serviceUnavailable,
            body: '{"errorCode":"enrollment_approval_unavailable"}',
            expected: '电脑端暂时无法显示确认窗口，请打开保存主机界面后重试',
          ),
          (
            status: HttpStatus.tooManyRequests,
            body: '',
            expected: '申请太频繁，请稍等几秒再试',
          ),
        ]) {
      final LanBackupService service = LanBackupService(
        httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
          _nodeInfo('computer-1', '仓库电脑'),
          _StreamHttpResponse(sample.status, sample.body),
        ]),
        wifiConnected: () async => true,
      );
      addTearDown(service.dispose);

      await expectLater(
        service.connectToHost(Uri.parse('http://192.168.1.20:5280')),
        throwsA(isA<LanBackupApprovalUnavailableException>()),
      );
      expect(service.snapshot.message, sample.expected);
      expect(service.snapshot.message, isNot(contains('${sample.status}')));
      expect(
        service.snapshot.connectionStatus,
        LanConnectionStatus.approvalUnavailable,
      );
    }
  });

  test('保存主机正在确认其他设备时自动重试并保持等待状态', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_approval_busy_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final List<Duration> delays = <Duration>[];
    late final LanBackupService service;
    service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
      httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
        _nodeInfo('computer-1', '仓库电脑'),
        _StreamHttpResponse(
          HttpStatus.tooManyRequests,
          '{"errorCode":"enrollment_approval_busy","retryAfterSeconds":3}',
        ),
        _enrollment('computer-1', '仓库电脑', 'a' * 64),
      ]),
      wifiConnected: () async => true,
      retryDelay: (Duration delay) async {
        delays.add(delay);
        expect(
          service.snapshot.connectionStatus,
          LanConnectionStatus.awaitingApproval,
        );
        expect(service.snapshot.message, contains('稍后会自动继续'));
      },
    );
    addTearDown(service.dispose);

    await service.connectToHost(Uri.parse('http://192.168.1.20:5280'));

    expect(delays, <Duration>[const Duration(seconds: 3)]);
    expect(service.snapshot.connectionStatus, LanConnectionStatus.connected);
  });

  test('旧保存主机在申请令牌前提示更新电脑端', () async {
    final _SequenceHttpClient client =
        _SequenceHttpClient(<_StreamHttpResponse>[
          _StreamHttpResponse(
            HttpStatus.ok,
            '{"protocol":"packingproof","protocolVersion":1,'
            '"nodeId":"old-computer","nodeName":"旧电脑",'
            '"capabilities":["host","mobile-backup"],'
            '"backupCompatibility":{"hostVersion":"0.0.54",'
            '"protocol":"mobile-backup-v2","enrollmentVersion":2,'
            '"authVersion":3,"minimumMobileVersion":"0.5.23",'
            '"minimumMobileBuildNumber":11036}}',
          ),
          _enrollment('old-computer', '旧电脑', 'a' * 64),
        ]);
    final LanBackupService service = LanBackupService(
      httpClient: client,
      wifiConnected: () async => true,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.connectToHost(Uri.parse('http://192.168.1.20:5280')),
      throwsA(isA<LanBackupHostUpgradeRequiredException>()),
    );
    expect(client.responses, hasLength(1));
    expect(service.snapshot.message, contains('更新 PackingProof'));
  });

  test('已配对电脑升级兼容后仅请求恢复该目标的兼容失败任务', () async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final Uri baseUri = Uri.parse('http://192.168.1.20:5280');
    final LanBackupService service = LanBackupService(
      platform: platform,
      httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
        _nodeInfo('computer-1', '仓库电脑'),
        _StreamHttpResponse(HttpStatus.ok, '{}'),
      ]),
      wifiConnected: () async => true,
      hostLocator: _FixedBackupHostLocator(baseUri),
    );
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        endpoint: LanBackupEndpoint(
          baseUri: baseUri,
          accessKey: '',
          computerId: 'computer-1',
          computerName: '仓库电脑',
        ),
        deviceId: 'device-1',
        deviceName: '测试手机',
        connectionStatus: LanConnectionStatus.offline,
        summary: const LanBackupSummary(
          failedCount: 1,
          dominantFailureKind: LanBackupFailureKind.incompatibleVersion,
        ),
      ),
    );
    service.debugSetAccessKeyForTesting('a' * 64);
    addTearDown(service.dispose);

    expect(await service.retryConnection(), isTrue);

    expect(platform.savedConnections, hasLength(1));
    expect(
      platform.savedConnections.single['recoverIncompatibleFailuresOnly'],
      isTrue,
    );
    expect(platform.savedConnections.single['computerId'], 'computer-1');
  });

  test('兼容失败摘要再次出现后下次心跳会重新恢复', () async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform();
    final Uri baseUri = Uri.parse('http://192.168.1.20:5280');
    final LanBackupService service = LanBackupService(
      platform: platform,
      httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
        _StreamHttpResponse(HttpStatus.ok, '{}'),
        _nodeInfo('computer-1', '仓库电脑'),
        _StreamHttpResponse(HttpStatus.ok, '{}'),
        _nodeInfo('computer-1', '仓库电脑'),
        _StreamHttpResponse(HttpStatus.ok, '{}'),
        _nodeInfo('computer-1', '仓库电脑'),
      ]),
      wifiConnected: () async => true,
      hostLocator: _FixedBackupHostLocator(baseUri),
    );
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        endpoint: LanBackupEndpoint(
          baseUri: baseUri,
          accessKey: '',
          computerId: 'computer-1',
          computerName: '仓库电脑',
        ),
        deviceId: 'device-1',
        deviceName: '测试手机',
        connectionStatus: LanConnectionStatus.connected,
      ),
    );
    service.debugSetAccessKeyForTesting('a' * 64);
    addTearDown(service.dispose);

    await service.debugSendConnectionHeartbeatForTesting();
    await service.debugSendConnectionHeartbeatForTesting();
    expect(platform.savedConnections, hasLength(1));

    service.debugApplyNativeSummaryForTesting(
      _backupSnapshot(
        deviceName: '测试手机',
        revision: 2,
        baseUrl: baseUri.toString(),
        computerId: 'computer-1',
        failedCount: 1,
        dominantFailureKind: 'incompatible_version',
      ),
    );
    await service.debugSendConnectionHeartbeatForTesting();

    expect(platform.savedConnections, hasLength(2));
  });

  test('主机要求新版手机时保留连接配置并提示更新 App', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_client_upgrade_test',
    );
    int savedConnections = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'saveConnection') savedConnections++;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
      httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
        _nodeInfo('computer-1', '仓库电脑'),
        _StreamHttpResponse(
          426,
          '{"errorCode":"backup_client_upgrade_required",'
          '"error":"手机 App 版本过低，请更新后重新连接"}',
        ),
      ]),
      wifiConnected: () async => true,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.connectToHost(Uri.parse('http://192.168.1.20:5280')),
      throwsA(isA<LanBackupClientUpgradeRequiredException>()),
    );
    expect(savedConnections, 0);
    expect(service.snapshot.message, '手机 App 版本过低，请更新后重新连接');
  });

  test('主机返回空白 426 时仍使用手机版本升级提示', () async {
    final LanBackupService service = LanBackupService(
      httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
        _nodeInfo('computer-1', '仓库电脑'),
        _StreamHttpResponse(426, 'Proxy rejected request'),
      ]),
      wifiConnected: () async => true,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.connectToHost(Uri.parse('http://192.168.1.20:5280')),
      throwsA(isA<LanBackupClientUpgradeRequiredException>()),
    );
    expect(service.snapshot.message, '手机 App 版本过低，请更新后重新连接');
    expect(service.snapshot.message, isNot(contains('426')));
  });

  test('当前主机存在时更换主机要先确认且确认前不申请令牌', () async {
    final _TrackingBackupPlatform platform = _TrackingBackupPlatform()
      ..hasPendingOutside = true;
    final LanBackupService service = LanBackupService(
      platform: platform,
      httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
        _nodeInfo('computer-2', '新电脑'),
      ]),
      wifiConnected: () async => true,
    );
    addTearDown(service.dispose);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        endpoint: LanBackupEndpoint(
          baseUri: Uri.parse('http://192.168.1.20:5280'),
          accessKey: '',
          computerId: 'computer-1',
          computerName: '原电脑',
        ),
        summary: const LanBackupSummary(
          totalCount: 1,
          pendingCount: 1,
          unfinishedTotalBytes: 10,
        ),
      ),
    );

    final LanBackupHostMismatchException mismatch = await _expectHostMismatch(
      service.connectToHost(Uri.parse('http://192.168.1.30:5280')),
    );
    expect(mismatch.candidateEndpoint.computerId, 'computer-2');
  });

  test('删除电脑后连接新主机不再要求更换确认并直接申请令牌', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_forgot_host_test',
    );
    Map<Object?, Object?>? saved;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'saveConnection') {
            saved = Map<Object?, Object?>.from(call.arguments! as Map);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final LanBackupService service = LanBackupService(
      platform: _TestChannelBackupPlatform(channel),
      httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
        _nodeInfo('computer-2', '新电脑'),
        _enrollment('computer-2', '新电脑', 'a' * 64),
      ]),
      wifiConnected: () async => true,
    );
    addTearDown(service.dispose);
    service.debugSetSnapshotForTesting(const LanBackupSnapshot());

    await service.connectToHost(Uri.parse('http://192.168.1.30:5280'));

    expect(saved?['computerId'], 'computer-2');
    expect(service.snapshot.message, '保存主机已允许连接');
  });
}

LanBackupService _testBackupService(_TrackingBackupPlatform platform) {
  return LanBackupService(
    platform: platform,
    httpClient: _UnexpectedHttpClient(),
    hostLocator: _FakeHostLocator(null),
    packageInfoLoader: () async => PackageInfo(
      appName: 'PackingProof',
      packageName: 'app.packingproof.mobile',
      version: '0.5.25',
      buildNumber: '11040',
    ),
  );
}

BackupSummaryDto _backupSnapshot({
  required String deviceName,
  int schemaVersion = 1,
  int revision = 0,
  String? baseUrl,
  String? computerId,
  int failedCount = 0,
  String? dominantFailureKind,
}) => BackupSummaryDto(
  schemaVersion: schemaVersion,
  revision: revision,
  completedRevision: 0,
  cleanupHighWatermark: 0,
  deviceId: 'snapshot-device',
  deviceName: deviceName,
  baseUrl: baseUrl,
  computerId: computerId,
  computerName: computerId == null ? null : '测试电脑',
  totalCount: 0,
  pendingCount: 0,
  uploadingCount: 0,
  pausedCount: 0,
  completedCount: 0,
  failedCount: failedCount,
  waitingCleanupCount: 0,
  localDeletedCount: 0,
  unfinishedUploadedBytes: 0,
  unfinishedTotalBytes: 0,
  dominantFailureKind: dominantFailureKind,
);

class _TestChannelBackupPlatform implements BackupNativePlatform {
  _TestChannelBackupPlatform(this._channel, {BackupSummaryDto? summary})
    : _summary = summary ?? _backupSnapshot(deviceName: '');

  final MethodChannel _channel;
  final BackupSummaryDto _summary;
  int summaryCalls = 0;

  @override
  Future<int?> availableRecordingStorageBytes() async => 1 << 50;

  @override
  void setSummaryListener(void Function(BackupSummaryDto summary)? listener) {}

  @override
  Future<BackupSummaryDto> summary() async {
    summaryCalls++;
    return _summary;
  }

  @override
  Future<BackupSummaryDto> initialize(Map<Object?, Object?> request) async =>
      _summary;

  @override
  Future<void> setAutoEnabled(bool enabled) =>
      _channel.invokeMethod<void>('setAutoEnabled', enabled);

  @override
  Future<BackupJobsByPathsDto> jobsForPaths(List<String> paths) async =>
      BackupJobsByPathsDto(
        revision: _summary.revision,
        jobs: <BackupJobDto>[],
        missingPaths: paths,
      );

  @override
  Future<BackupCleanupPageDto> cleanupEvents({
    required int afterRevision,
    required int limit,
  }) async => BackupCleanupPageDto(
    latestRevision: afterRevision,
    nextAfterRevision: afterRevision,
    hasMore: false,
    events: <BackupCleanupEventDto>[],
  );

  @override
  Future<void> acknowledgeCleanupEvents(int throughRevision) async {}

  @override
  Future<bool> hasPendingJobsOutsideDestination(String computerId) async =>
      false;

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
  Future<void> enqueueJobs(List<Map<Object?, Object?>> requests) async {
    for (final Map<Object?, Object?> request in requests) {
      await enqueueJob(request);
    }
  }

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
  Future<void> dispose() async {}
}

class _TrackingBackupPlatform extends Fake implements BackupNativePlatform {
  void Function(BackupSummaryDto summary)? _listener;
  final List<Completer<BackupSummaryDto>> snapshotResults =
      <Completer<BackupSummaryDto>>[];
  final List<Completer<BackupJobsByPathsDto>> jobResults =
      <Completer<BackupJobsByPathsDto>>[];
  final List<List<String>> requestedJobPaths = <List<String>>[];
  int snapshotCalls = 0;
  int reclaimCalls = 0;
  int disposeCalls = 0;
  bool hasPendingOutside = false;
  final List<Map<Object?, Object?>> savedConnections =
      <Map<Object?, Object?>>[];
  final List<List<Map<Object?, Object?>>> enqueuedBatches =
      <List<Map<Object?, Object?>>>[];
  Map<Object?, Object?>? lastInitializeRequest;
  Map<Object?, Object?>? lastRetentionScheduleRequest;

  @override
  Future<void> updateRetentionSchedule(Map<Object?, Object?> request) async {
    lastRetentionScheduleRequest = request;
  }

  @override
  Future<void> enqueueJobs(List<Map<Object?, Object?>> requests) async {
    enqueuedBatches.add(requests);
  }

  @override
  void setSummaryListener(void Function(BackupSummaryDto summary)? listener) {
    _listener = listener;
  }

  void emitSnapshot(BackupSummaryDto summary) => _listener?.call(summary);

  @override
  Future<BackupSummaryDto> summary() {
    snapshotCalls++;
    if (snapshotResults.isEmpty) {
      return Future<BackupSummaryDto>.value(
        _backupSnapshot(deviceName: '显式刷新'),
      );
    }
    return snapshotResults.removeAt(0).future;
  }

  @override
  Future<BackupSummaryDto> initialize(Map<Object?, Object?> request) async {
    lastInitializeRequest = request;
    return _backupSnapshot(deviceName: '初始化');
  }

  @override
  Future<void> setAutoEnabled(bool enabled) async {}

  @override
  Future<BackupJobsByPathsDto> jobsForPaths(List<String> paths) async {
    requestedJobPaths.add(List<String>.of(paths));
    return jobResults.isEmpty
        ? BackupJobsByPathsDto(
            revision: 0,
            jobs: <BackupJobDto>[],
            missingPaths: paths,
          )
        : jobResults.removeAt(0).future;
  }

  @override
  Future<BackupCleanupPageDto> cleanupEvents({
    required int afterRevision,
    required int limit,
  }) async => BackupCleanupPageDto(
    latestRevision: afterRevision,
    nextAfterRevision: afterRevision,
    hasMore: false,
    events: <BackupCleanupEventDto>[],
  );

  @override
  Future<void> acknowledgeCleanupEvents(int throughRevision) async {}

  @override
  Future<bool> hasPendingJobsOutsideDestination(String computerId) async =>
      hasPendingOutside;

  @override
  Future<String?> loadAccessKey() async => null;

  @override
  Future<void> saveConnection(Map<Object?, Object?> connection) async {
    savedConnections.add(Map<Object?, Object?>.from(connection));
  }

  @override
  Future<Map<Object?, Object?>?> reclaimStorageIfNeeded() async {
    reclaimCalls++;
    return <Object?, Object?>{
      'availableBytes': 4 * 1024 * 1024 * 1024,
      'availableBytesBefore': 4 * 1024 * 1024 * 1024,
      'freedBytes': 0,
      'deletedCount': 0,
      'warning': false,
      'insufficient': false,
    };
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    _listener = null;
  }
}

class _FixedBackupHostLocator implements LanBackupHostLocator {
  const _FixedBackupHostLocator(this.uri);

  final Uri uri;

  @override
  Future<LanBackupLocateResult> locate({
    required Uri currentBaseUri,
    required String nodeId,
  }) async => LanBackupLocateResult.located(uri);

  @override
  void dispose() {}
}

_StreamHttpResponse _nodeInfo(String id, String name) => _StreamHttpResponse(
  HttpStatus.ok,
  '{"protocol":"packingproof","protocolVersion":1,"nodeId":"$id",'
  '"nodeName":"$name","capabilities":["host","mobile-backup"],'
  '"backupCompatibility":{"hostVersion":"0.0.55",'
  '"protocol":"mobile-backup-v2","enrollmentVersion":2,"authVersion":3,'
  '"minimumMobileVersion":"0.5.23","minimumMobileBuildNumber":11036}}',
);

_StreamHttpResponse _enrollment(
  String id,
  String name,
  String token, {
  String? deviceName,
}) {
  final Map<String, Object?> payload = <String, Object?>{
    'protocol': 'mobile-backup-v2',
    'version': 2,
    'authVersion': 3,
    'computerId': id,
    'computerName': name,
    'deviceId': '00000000-0000-0000-0000-000000000001',
    'deviceToken': token,
  };
  if (deviceName != null) payload['deviceName'] = deviceName;
  return _StreamHttpResponse(HttpStatus.ok, jsonEncode(payload));
}

Future<LanBackupHostMismatchException> _expectHostMismatch(
  Future<void> pairing,
) async {
  try {
    await pairing;
  } on LanBackupHostMismatchException catch (error) {
    return error;
  }
  throw TestFailure('预期要求确认更换备份电脑');
}

class _UnexpectedHttpClient extends Fake implements HttpClient {
  bool requested = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requested = true;
    throw StateError('未连接 Wi-Fi 时不应发起请求');
  }

  @override
  void close({bool force = false}) {}
}

class _SequenceHttpClient extends Fake implements HttpClient {
  _SequenceHttpClient(this.responses);

  final List<_StreamHttpResponse> responses;
  final List<List<int>> postBodies = <List<int>>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    return _CompletedHttpClientRequest(responses.removeAt(0));
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    return _CompletedHttpClientRequest(
      responses.removeAt(0),
      onBytes: postBodies.add,
    );
  }

  @override
  void close({bool force = false}) {}
}

class _CompletedHttpClientRequest extends Fake implements HttpClientRequest {
  _CompletedHttpClientRequest(this.response, {this.onBytes});

  final _StreamHttpResponse response;
  final void Function(List<int> bytes)? onBytes;
  final HttpHeaders _headers = _IgnoringHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  set followRedirects(bool value) {}

  @override
  set contentLength(int value) {}

  @override
  void add(List<int> data) => onBytes?.call(List<int>.from(data));

  @override
  void write(Object? object) {
    onBytes?.call(utf8.encode('$object'));
  }

  @override
  Future<HttpClientResponse> close() async => response;
}

class _DeferredEnrollmentHttpClient extends Fake implements HttpClient {
  _DeferredEnrollmentHttpClient(this.nodeInfo, this.enrollment);

  final _StreamHttpResponse nodeInfo;
  final Completer<HttpClientResponse> enrollment;
  bool postRequested = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    return _CompletedHttpClientRequest(nodeInfo);
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    postRequested = true;
    return _DeferredHttpClientRequest(enrollment.future);
  }

  @override
  void close({bool force = false}) {}
}

class _DeferredCapabilitiesHttpClient extends Fake implements HttpClient {
  _DeferredCapabilitiesHttpClient(this.capabilities);

  final Completer<HttpClientResponse> capabilities;
  bool capabilitiesRequested = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    // 只挂起能力请求；其余探测（/api/node-info）照常返回，心跳路径保持可预期。
    if (!url.path.endsWith('/api/mobile-backup/capabilities')) {
      return _CompletedHttpClientRequest(
        _StreamHttpResponse(
          HttpStatus.ok,
          '{"protocol":"packingproof","capabilities":["host","mobile-backup"]}',
        ),
      );
    }
    capabilitiesRequested = true;
    return _DeferredHttpClientRequest(capabilities.future);
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) async =>
      _CompletedHttpClientRequest(
        _StreamHttpResponse(HttpStatus.ok, '{"ok":true}'),
      );

  @override
  void close({bool force = false}) {}
}

class _DeferredHttpClientRequest extends Fake implements HttpClientRequest {
  _DeferredHttpClientRequest(this.response);

  final Future<HttpClientResponse> response;
  final HttpHeaders _headers = _IgnoringHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  set followRedirects(bool value) {}

  @override
  set contentLength(int value) {}

  @override
  void add(List<int> data) {}

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  Future<HttpClientResponse> close() => response;
}

class _StreamHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _StreamHttpResponse(this.statusCode, String body)
    : _bytes = utf8.encode(body);

  @override
  final int statusCode;
  final List<int> _bytes;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(_bytes).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _IgnoringHttpHeaders extends Fake implements HttpHeaders {
  @override
  set contentType(ContentType? value) {}

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _FakeHostLocator implements LanBackupHostLocator {
  _FakeHostLocator(this.result);

  final Uri? result;
  int requests = 0;

  @override
  Future<LanBackupLocateResult> locate({
    required Uri currentBaseUri,
    required String nodeId,
  }) async {
    requests++;
    final Uri? located = result;
    return located == null
        ? const LanBackupLocateResult.failed(LanBackupLocateFailure.unreachable)
        : LanBackupLocateResult.located(located);
  }

  @override
  void dispose() {}
}

/// 返回"地址连通但电脑身份与配对记录不符"的定位器。
class _IdentityMismatchHostLocator implements LanBackupHostLocator {
  int requests = 0;

  @override
  Future<LanBackupLocateResult> locate({
    required Uri currentBaseUri,
    required String nodeId,
  }) async {
    requests++;
    return const LanBackupLocateResult.failed(
      LanBackupLocateFailure.identityMismatch,
      reportedNodeId: '202f543f-7b88-407d-b636-61fc0958abe8',
    );
  }

  @override
  void dispose() {}
}

class _FailThenSucceedHttpClient extends Fake implements HttpClient {
  final List<String> requestedHosts = <String>[];
  final List<Uri> requestedUris = <Uri>[];
  bool echoMode = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requestedHosts.add(url.host);
    requestedUris.add(url);
    if (requestedHosts.length == 1) {
      throw const SocketException('旧地址不可达');
    }
    return _CompletedHttpClientRequest(
      _StreamHttpResponse(
        HttpStatus.ok,
        jsonEncode({
          'data': [],
          'page': 1,
          'pageSize': 5,
          'total': 0,
          'deviceTotal': 0,
          if (echoMode) 'mode': url.queryParameters['mode'],
        }),
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}

class _HeartbeatHttpClient extends Fake implements HttpClient {
  int heartbeatPosts = 0;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    heartbeatPosts++;
    return _CompletedHttpClientRequest(
      _StreamHttpResponse(
        HttpStatus.ok,
        '{"ok":true,"heartbeatIntervalSeconds":15,"expiresInSeconds":45}',
      ),
    );
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    return _CompletedHttpClientRequest(
      _StreamHttpResponse(
        HttpStatus.ok,
        '{"protocol":"packingproof","capabilities":["mobile-backup"]}',
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}
