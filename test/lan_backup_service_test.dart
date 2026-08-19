import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/models/recording_operation_mode.dart';
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
      channel: channel,
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
      channel: channel,
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
  });

  test('心跳看门狗在定时器丢失时自动补发心跳并记录状态', () async {
    final MethodChannel channel = const MethodChannel(
      'app.packingproof.mobile/lan_backup_heartbeat_watchdog_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'snapshot') {
            return <Object?, Object?>{
              'deviceId': 'android-watchdog-test',
              'deviceName': '手机1',
              'connection': <Object?, Object?>{
                'baseUrl': 'http://192.168.31.250:5280',
                'computerId': 'host-1',
                'computerName': '电脑1',
                'lastConnectedAt': '',
              },
              'jobs': <Object?>[],
              'migrationHost': null,
            };
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final List<String> logKinds = <String>[];
    final _HeartbeatHttpClient client = _HeartbeatHttpClient();
    final LanBackupService service = LanBackupService(
      channel: channel,
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
        jobs: <LanBackupJob>[invalidKey],
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
        jobs: <LanBackupJob>[wrongRole],
      ),
      LanConnectionStatus.notBackupHost,
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
          'incompatible_version': LanBackupRecoveryAction.updateComputer,
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
    );

    expect(uri.path, '/api/mobile-backup/videos');
    expect(uri.queryParameters['page'], '2');
    expect(uri.queryParameters['size'], '10');
    expect(uri.queryParameters['keyword'], 'TRACK-1');
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
    );

    final Map<String, Object?> value = recordingSessionBackupMap(session);
    expect(value['trackingNumber'], 'SF1234567890');
    expect(value['mediaStartMs'], 2000);
    expect(value['mediaEndMs'], 10000);
    expect(value['markers'], hasLength(1));
    expect(value['mode'], 'return');
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
    final LanBackupService service = LanBackupService(channel: channel);
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
    ]);

    expect(enqueueCall?.method, 'enqueue');
    final Map<Object?, Object?> arguments =
        enqueueCall!.arguments! as Map<Object?, Object?>;
    expect(arguments['startUpload'], isTrue);
    expect(arguments['forceRestart'], isTrue);
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final List<({String kind, Map<String, Object?> extra})> events =
        <({String kind, Map<String, Object?> extra})>[];
    final LanBackupService service = LanBackupService(
      channel: channel,
      logEvent: (String kind, Map<String, Object?> extra) async {
        events.add((kind: kind, extra: extra));
      },
    );
    addTearDown(service.dispose);
    await service.setAutoEnabled(false);
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
        .where((event) => event.kind == 'backup_enqueue')
        .map((event) => event.extra)
        .toList();
    expect(enqueueLogs, isNotEmpty);
    expect(enqueueLogs.last['startUpload'], isFalse);
    expect(enqueueLogs.last['forceRestart'], isFalse);
    expect(enqueueLogs.last['sessionCount'], 1);
    final List<Map<String, Object?>> toggleLogs = events
        .where((event) => event.kind == 'backup_auto_toggle')
        .map((event) => event.extra)
        .toList();
    expect(toggleLogs, isNotEmpty);
    expect(toggleLogs.last['enabled'], isFalse);
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

    Map<Object?, Object?> failedJob() => <Object?, Object?>{
      'id': 'job-1',
      'filePath': '/tmp/job-1.mp4',
      'state': 'failed',
      'failureKind': 'unknown',
      'statusCode': 400,
      'errorCode': 'invalid_session_id',
      'errorMessage': '录像片段 ID 无效',
    };
    Map<Object?, Object?> pendingJob() => <Object?, Object?>{
      'id': 'job-1',
      'filePath': '/tmp/job-1.mp4',
      'state': 'pending',
    };

    service.debugApplyNativeSnapshotForTesting(<Object?, Object?>{
      'jobs': <Object?>[failedJob()],
    });
    service.debugApplyNativeSnapshotForTesting(<Object?, Object?>{
      'jobs': <Object?>[failedJob()],
    });
    expect(
      events.where((event) => event.kind == 'backup_job_failed'),
      hasLength(1),
    );

    service.debugApplyNativeSnapshotForTesting(<Object?, Object?>{
      'jobs': <Object?>[pendingJob()],
    });
    service.debugApplyNativeSnapshotForTesting(<Object?, Object?>{
      'jobs': <Object?>[failedJob()],
    });

    final List<Map<String, Object?>> failures = events
        .where((event) => event.kind == 'backup_job_failed')
        .map((event) => event.extra)
        .toList();
    expect(failures, hasLength(2));
    expect(failures.last['jobId'], 'job-1');
    expect(failures.last['statusCode'], 400);
    expect(failures.last['errorCode'], 'invalid_session_id');
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
    final LanBackupService service = LanBackupService(channel: channel);
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
    final LanBackupService service = LanBackupService(channel: channel);
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
    final LanBackupService service = LanBackupService(channel: channel);
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
      channel: channel,
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
    expect(enrollmentRequest['clientVersion'], '0.5.11');
    expect(enrollmentRequest['clientBuildNumber'], 11011);
    expect(enrollmentRequest['backupProtocol'], 'mobile-backup-v2');
    expect(enrollmentRequest['enrollmentVersion'], 2);
    expect(enrollmentRequest['authVersion'], 3);
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
    final LanBackupService service = LanBackupService(channel: channel);
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
      channel: channel,
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
        jobs: const <LanBackupJob>[
          LanBackupJob(
            id: 'pending-job',
            filePath: 'pending.mp4',
            state: LanBackupJobState.pending,
            uploadedBytes: 0,
            totalBytes: 100,
            destinationComputerId: 'computer-1',
          ),
        ],
        connectionStatus: LanConnectionStatus.rePair,
      ),
    );

    await expectLater(
      service.connectToHost(Uri.parse('http://192.168.1.20:5280')),
      throwsA(isA<LanBackupApprovalDeniedException>()),
    );

    expect(service.snapshot.endpoint?.computerId, 'computer-1');
    expect(service.snapshot.jobs.single.id, 'pending-job');
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
      channel: channel,
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
            '"capabilities":["host","mobile-backup"]}',
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
      channel: channel,
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
    final LanBackupService service = LanBackupService(
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
        jobs: <LanBackupJob>[
          LanBackupJob(
            id: 'pending',
            filePath: 'pending.mp4',
            state: LanBackupJobState.pending,
            uploadedBytes: 0,
            totalBytes: 10,
            destinationComputerId: 'computer-1',
          ),
        ],
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
      channel: channel,
      httpClient: _SequenceHttpClient(<_StreamHttpResponse>[
        _nodeInfo('computer-2', '新电脑'),
        _enrollment('computer-2', '新电脑', 'a' * 64),
      ]),
      wifiConnected: () async => true,
    );
    addTearDown(service.dispose);
    service.debugSetSnapshotForTesting(
      LanBackupSnapshot(
        jobs: <LanBackupJob>[
          LanBackupJob(
            id: 'pending',
            filePath: 'pending.mp4',
            state: LanBackupJobState.pending,
            uploadedBytes: 0,
            totalBytes: 10,
            destinationComputerId: 'computer-1',
          ),
        ],
      ),
    );

    await service.connectToHost(Uri.parse('http://192.168.1.30:5280'));

    expect(saved?['computerId'], 'computer-2');
    expect(service.snapshot.message, '保存主机已允许连接');
  });
}

_StreamHttpResponse _nodeInfo(String id, String name) => _StreamHttpResponse(
  HttpStatus.ok,
  '{"protocol":"packingproof","protocolVersion":1,"nodeId":"$id",'
  '"nodeName":"$name","capabilities":["host","mobile-backup"],'
  '"backupCompatibility":{"hostVersion":"0.0.32",'
  '"protocol":"mobile-backup-v2","enrollmentVersion":2,"authVersion":3,'
  '"minimumMobileVersion":"0.5.10","minimumMobileBuildNumber":11010}}',
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
  Future<Uri?> locate({
    required Uri currentBaseUri,
    required String nodeId,
  }) async {
    requests++;
    return result;
  }

  @override
  void dispose() {}
}

class _FailThenSucceedHttpClient extends Fake implements HttpClient {
  final List<String> requestedHosts = <String>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requestedHosts.add(url.host);
    if (requestedHosts.length == 1) {
      throw const SocketException('旧地址不可达');
    }
    return _CompletedHttpClientRequest(
      _StreamHttpResponse(
        HttpStatus.ok,
        '{"data":[],"page":1,"pageSize":5,"total":0,"deviceTotal":0}',
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
