import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/lan_backup_discovery_service.dart';
import 'package:packing_proof_mobile/services/lan_backup_host_file_cache.dart';

void main() {
  test('只接受具备录像备份能力的主机', () {
    final Uri uri = Uri.parse('http://192.168.1.20:5280');
    final LanBackupDiscoveredHost? host = parseLanBackupDiscoveredHost(
      uri,
      '{"protocol":"packingproof","protocolVersion":1,'
      '"nodeId":"host-1","nodeName":"仓库电脑","httpPort":5280,'
      '"capabilities":["host","mobile-backup"],'
      '"backupCompatibility":{"hostVersion":"0.0.32",'
      '"protocol":"mobile-backup-v2","enrollmentVersion":2,"authVersion":3,'
      '"minimumMobileVersion":"0.5.10","minimumMobileBuildNumber":11010}}',
    );
    expect(host?.nodeId, 'host-1');
    expect(host?.address, '192.168.1.20:5280');
    expect(host?.compatible, isTrue);
    expect(
      parseLanBackupDiscoveredHost(
        uri,
        '{"protocol":"packingproof","protocolVersion":1,'
        '"nodeId":"client-1","capabilities":["recording"]}',
      ),
      isNull,
    );
  });

  test('旧保存主机保留在搜索结果但明确要求更新电脑端', () {
    final LanBackupDiscoveredHost? host = parseLanBackupDiscoveredHost(
      Uri.parse('http://192.168.1.20:5280'),
      '{"protocol":"packingproof","protocolVersion":1,'
      '"nodeId":"old-host","nodeName":"旧电脑","httpPort":5280,'
      '"capabilities":["host","mobile-backup"]}',
    );

    expect(host, isNotNull);
    expect(host!.compatible, isFalse);
    expect(host.compatibilityMessage, contains('更新 PackingProof'));
  });

  test('搜索进度来自真实候选地址完成数并合并同一主机', () async {
    final LanBackupHostDiscoveryService service = LanBackupHostDiscoveryService(
      candidateProvider: () async => <Uri>[
        Uri.parse('http://192.168.1.10:5280'),
        Uri.parse('http://192.168.1.11:5280'),
        Uri.parse('http://192.168.1.12:5280'),
      ],
      probe: (Uri uri) async => uri.host == '192.168.1.10'
          ? const LanBackupDiscoveredHost(
              nodeId: 'host-1',
              name: '保存主机',
              address: '192.168.1.10:5280',
            )
          : null,
    );
    addTearDown(service.dispose);
    final List<LanBackupDiscoverySnapshot> snapshots =
        <LanBackupDiscoverySnapshot>[];
    service.addListener(() => snapshots.add(service.snapshot));

    await service.search();

    expect(service.snapshot.searching, isFalse);
    expect(service.snapshot.completed, 3);
    expect(service.snapshot.total, 3);
    expect(service.snapshot.progress, 1);
    expect(service.snapshot.hosts.single.nodeId, 'host-1');
    expect(snapshots.any((item) => item.searching), isTrue);
  });

  test('局域网扫描从网段两端交错进行且排除本机地址', () {
    final List<int> order = buildLanBackupHostScanOrder(localHost: 104);

    expect(order.take(10), <int>[1, 254, 2, 253, 3, 252, 4, 251, 5, 250]);
    expect(order, isNot(contains(104)));
    expect(order.toSet().length, 253);
  });

  test('地址定位只接受相同 NodeId 的兼容主机并合并并发请求', () async {
    final Completer<void> releaseCurrentProbe = Completer<void>();
    int candidateRequests = 0;
    int currentProbeRequests = 0;
    final LanBackupHostLocatorService locator = LanBackupHostLocatorService(
      candidateProvider: () async {
        candidateRequests++;
        return <Uri>[
          Uri.parse('http://192.168.1.30:5280'),
          Uri.parse('http://192.168.1.40:5280'),
        ];
      },
      probe: (Uri uri) async {
        if (uri.host == '192.168.1.20') {
          currentProbeRequests++;
          await releaseCurrentProbe.future;
          return const LanBackupDiscoveredHost(
            nodeId: 'other-host',
            name: '其他电脑',
            address: '192.168.1.20:5280',
          );
        }
        if (uri.host == '192.168.1.30') {
          return const LanBackupDiscoveredHost(
            nodeId: 'host-1',
            name: '原电脑',
            address: '192.168.1.30:5280',
          );
        }
        return const LanBackupDiscoveredHost(
          nodeId: 'host-1',
          name: '不兼容电脑',
          address: '192.168.1.40:5280',
          compatible: false,
        );
      },
    );
    addTearDown(locator.dispose);

    final Future<Uri?> first = locator.locate(
      currentBaseUri: Uri.parse('http://192.168.1.20:5280'),
      nodeId: 'host-1',
    );
    final Future<Uri?> second = locator.locate(
      currentBaseUri: Uri.parse('http://192.168.1.20:5280'),
      nodeId: 'host-1',
    );
    releaseCurrentProbe.complete();

    expect(await first, Uri.parse('http://192.168.1.30:5280'));
    expect(await second, Uri.parse('http://192.168.1.30:5280'));
    expect(currentProbeRequests, 1);
    expect(candidateRequests, 1);
  });

  test('搜索进行中重复调用不会重启扫描或重复探测', () async {
    final Completer<void> allowProbe = Completer<void>();
    int candidateRequests = 0;
    int probeRequests = 0;
    final LanBackupHostDiscoveryService service = LanBackupHostDiscoveryService(
      candidateProvider: () async {
        candidateRequests++;
        return <Uri>[Uri.parse('http://192.168.1.250:5280')];
      },
      probe: (Uri uri) async {
        probeRequests++;
        await allowProbe.future;
        return null;
      },
    );
    addTearDown(service.dispose);

    final Future<void> first = service.search();
    final Future<void> second = service.search();
    await Future<void>.delayed(Duration.zero);

    expect(candidateRequests, 1);
    expect(probeRequests, 1);
    allowProbe.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(service.snapshot.completed, 1);
  });

  test('重新搜索期间保留缓存列表并在发现后更新在线地址', () async {
    final Completer<void> allowProbe = Completer<void>();
    final _MemoryBackupHostCache cache =
        _MemoryBackupHostCache(<LanBackupDiscoveredHost>[
          const LanBackupDiscoveredHost(
            nodeId: 'host-1',
            name: '电脑1',
            address: '192.168.1.20:5280',
            reachable: false,
          ),
        ]);
    final LanBackupHostDiscoveryService service = LanBackupHostDiscoveryService(
      cache: cache,
      candidateProvider: () async => <Uri>[
        Uri.parse('http://192.168.1.30:5280'),
      ],
      probe: (Uri uri) async {
        await allowProbe.future;
        return const LanBackupDiscoveredHost(
          nodeId: 'host-1',
          name: '电脑1',
          address: '192.168.1.30:5280',
        );
      },
    );
    addTearDown(service.dispose);

    final Future<void> search = service.search();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(service.snapshot.searching, isTrue);
    expect(service.snapshot.hosts.single.address, '192.168.1.20:5280');
    expect(service.snapshot.hosts.single.reachable, isFalse);

    allowProbe.complete();
    await search;
    expect(service.snapshot.hosts.single.address, '192.168.1.30:5280');
    expect(service.snapshot.hosts.single.reachable, isTrue);
    expect(cache.saved.single.address, '192.168.1.30:5280');
  });

  test('文件缓存可跨服务实例恢复主机且不会把缓存当作在线', () async {
    final Directory root = Directory.systemTemp.createTempSync(
      'packing-proof-host-cache-',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final LanBackupHostFileCache cache = LanBackupHostFileCache(
      rootDirectory: root,
    );
    final LanBackupHostDiscoveryService writer = LanBackupHostDiscoveryService(
      cache: cache,
      candidateProvider: () async => <Uri>[
        Uri.parse('http://192.168.1.88:5280'),
      ],
      probe: (Uri uri) async => const LanBackupDiscoveredHost(
        nodeId: 'host-88',
        name: '电脑2',
        address: '192.168.1.88:5280',
      ),
    );
    await writer.search();
    writer.dispose();

    final LanBackupHostDiscoveryService reader = LanBackupHostDiscoveryService(
      cache: cache,
      candidateProvider: () async => const <Uri>[],
    );
    addTearDown(reader.dispose);
    await reader.search();

    expect(reader.snapshot.hosts.single.nodeId, 'host-88');
    expect(reader.snapshot.hosts.single.reachable, isFalse);
    expect(reader.snapshot.message, contains('已保留'));
  });

  test('删除主机后从快照与缓存中移除', () async {
    final _MemoryBackupHostCache cache = _MemoryBackupHostCache(
      const <LanBackupDiscoveredHost>[],
    );
    final LanBackupHostDiscoveryService service = LanBackupHostDiscoveryService(
      cache: cache,
      candidateProvider: () async => <Uri>[
        Uri.parse('http://192.168.1.30:5280'),
      ],
      probe: (Uri uri) async => const LanBackupDiscoveredHost(
        nodeId: 'host-1',
        name: '电脑1',
        address: '192.168.1.30:5280',
      ),
    );
    addTearDown(service.dispose);

    await service.search();
    expect(service.snapshot.hosts.single.nodeId, 'host-1');
    expect(cache.saved.single.nodeId, 'host-1');

    await service.forgetHost(nodeId: 'host-1', address: '192.168.1.30:5280');
    expect(service.snapshot.hosts, isEmpty);
    expect(cache.saved, isEmpty);
    expect(service.snapshot.message, contains('已删除电脑'));
  });

  test('删除主机取消进行中的搜索避免旧条目被重新加回', () async {
    final _MemoryBackupHostCache cache = _MemoryBackupHostCache(
      const <LanBackupDiscoveredHost>[],
    );
    final Completer<void> allowProbe = Completer<void>();
    final LanBackupHostDiscoveryService service = LanBackupHostDiscoveryService(
      cache: cache,
      candidateProvider: () async => <Uri>[
        Uri.parse('http://192.168.1.30:5280'),
      ],
      probe: (Uri uri) async {
        await allowProbe.future;
        return const LanBackupDiscoveredHost(
          nodeId: 'host-1',
          name: '电脑1',
          address: '192.168.1.30:5280',
        );
      },
    );
    addTearDown(service.dispose);

    final Future<void> search = service.search();
    await Future<void>.delayed(Duration.zero);
    expect(service.snapshot.searching, isTrue);

    await service.forgetHost(nodeId: 'host-1', address: '192.168.1.30:5280');
    allowProbe.complete();
    await search;

    expect(service.snapshot.hosts, isEmpty);
    expect(cache.saved, isEmpty);
  });

  test('同一地址出现新电脑标识时替换旧条目而不是显示两台', () async {
    final _MemoryBackupHostCache cache =
        _MemoryBackupHostCache(const <LanBackupDiscoveredHost>[
          LanBackupDiscoveredHost(
            nodeId: 'host-1',
            name: '电脑1',
            address: '192.168.1.30:5280',
            reachable: false,
          ),
        ]);
    final LanBackupHostDiscoveryService service = LanBackupHostDiscoveryService(
      cache: cache,
      candidateProvider: () async => <Uri>[
        Uri.parse('http://192.168.1.30:5280'),
      ],
      probe: (Uri uri) async => const LanBackupDiscoveredHost(
        nodeId: 'host-2',
        name: '电脑1',
        address: '192.168.1.30:5280',
      ),
    );
    addTearDown(service.dispose);

    await service.search();

    expect(service.snapshot.hosts, hasLength(1));
    expect(service.snapshot.hosts.single.nodeId, 'host-2');
    expect(service.snapshot.hosts.single.reachable, isTrue);
    expect(cache.saved.single.nodeId, 'host-2');
  });

  group('UDP announce 解析', () {
    test('接受合法 announce', () {
      final UdpDiscoveryAnnounce? announce = parseUdpAnnounce(
        utf8.encode(
          jsonEncode(const <String, Object>{
            'protocol': 'packingproof',
            'protocolVersion': 1,
            'action': 'announce',
            'nodeId': '123e4567-e89b-12d3-a456-426614174000',
            'httpPort': 5381,
          }),
        ),
        '192.0.2.10',
      );
      expect(announce, isNotNull);
      expect(announce!.nodeId, '123e4567-e89b-12d3-a456-426614174000');
      expect(announce.httpPort, 5381);
      expect(announce.sourceIp, '192.0.2.10');
    });

    test('拒绝非法字段', () {
      const String nodeId = '123e4567-e89b-12d3-a456-426614174000';
      final List<Map<String, Object>> cases = <Map<String, Object>>[
        <String, Object>{
          'protocol': 'other',
          'protocolVersion': 1,
          'action': 'announce',
          'nodeId': nodeId,
          'httpPort': 5381,
        },
        <String, Object>{
          'protocol': 'packingproof',
          'protocolVersion': 2,
          'action': 'announce',
          'nodeId': nodeId,
          'httpPort': 5381,
        },
        <String, Object>{
          'protocol': 'packingproof',
          'protocolVersion': 1,
          'action': 'discover',
          'nodeId': nodeId,
          'httpPort': 5381,
        },
        <String, Object>{
          'protocol': 'packingproof',
          'protocolVersion': 1,
          'action': 'announce',
          'nodeId': 'not-a-uuid',
          'httpPort': 5381,
        },
        <String, Object>{
          'protocol': 'packingproof',
          'protocolVersion': 1,
          'action': 'announce',
          'nodeId': nodeId,
          'httpPort': 0,
        },
        <String, Object>{
          'protocol': 'packingproof',
          'protocolVersion': 1,
          'action': 'announce',
          'nodeId': nodeId,
          'httpPort': 65536,
        },
      ];
      for (final Map<String, Object> object in cases) {
        expect(
          parseUdpAnnounce(utf8.encode(jsonEncode(object)), '192.0.2.10'),
          isNull,
          reason: object.toString(),
        );
      }
    });
  });
}

class _MemoryBackupHostCache implements LanBackupHostCache {
  _MemoryBackupHostCache(this.values);

  final List<LanBackupDiscoveredHost> values;
  List<LanBackupDiscoveredHost> saved = const <LanBackupDiscoveredHost>[];

  @override
  Future<List<LanBackupDiscoveredHost>> load() async => values;

  @override
  Future<void> save(List<LanBackupDiscoveredHost> hosts) async {
    saved = List<LanBackupDiscoveredHost>.of(hosts);
  }
}
