import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'lan_backup_compatibility.dart';

class LanBackupDiscoveredHost {
  const LanBackupDiscoveredHost({
    required this.nodeId,
    required this.name,
    required this.address,
    this.compatible = true,
    this.compatibilityMessage,
    this.reachable = true,
  });

  final String nodeId;
  final String name;
  final String address;
  final bool compatible;
  final String? compatibilityMessage;
  final bool reachable;

  Uri get baseUri => Uri.parse('http://$address');

  LanBackupDiscoveredHost copyWith({
    String? nodeId,
    String? name,
    String? address,
    bool? compatible,
    String? compatibilityMessage,
    bool? reachable,
  }) => LanBackupDiscoveredHost(
    nodeId: nodeId ?? this.nodeId,
    name: name ?? this.name,
    address: address ?? this.address,
    compatible: compatible ?? this.compatible,
    compatibilityMessage: compatibilityMessage ?? this.compatibilityMessage,
    reachable: reachable ?? this.reachable,
  );
}

class LanBackupDiscoverySnapshot {
  const LanBackupDiscoverySnapshot({
    this.searching = false,
    this.completed = 0,
    this.total = 0,
    this.hosts = const <LanBackupDiscoveredHost>[],
    this.message,
  });

  final bool searching;
  final int completed;
  final int total;
  final List<LanBackupDiscoveredHost> hosts;
  final String? message;

  double? get progress => total <= 0 ? null : completed / total;
}

abstract interface class LanBackupHostDiscovery implements Listenable {
  LanBackupDiscoverySnapshot get snapshot;
  Future<void> search();
  void cancel();
  Future<void> forgetHost({required String nodeId, required String address});
}

abstract interface class LanBackupHostCache {
  Future<List<LanBackupDiscoveredHost>> load();
  Future<void> save(List<LanBackupDiscoveredHost> hosts);
}

typedef LanBackupCandidateProvider = Future<List<Uri>> Function();
typedef LanBackupHostProbe = Future<LanBackupDiscoveredHost?> Function(Uri uri);

@visibleForTesting
List<int> buildLanBackupHostScanOrder({int? localHost}) {
  final List<int> result = <int>[];
  for (int low = 1; low <= 127; low++) {
    final int high = 255 - low;
    if (low != localHost) result.add(low);
    if (high != localHost) result.add(high);
  }
  return result;
}

@visibleForTesting
LanBackupDiscoveredHost? parseLanBackupDiscoveredHost(Uri uri, String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map ||
      decoded['protocol'] != 'packingproof' ||
      decoded['protocolVersion'] != 1) {
    return null;
  }
  final Set<String> capabilities = decoded['capabilities'] is List
      ? (decoded['capabilities'] as List)
            .map((Object? value) => '$value'.toLowerCase())
            .toSet()
      : const <String>{};
  if (!capabilities.contains('host') ||
      !capabilities.contains('mobile-backup')) {
    return null;
  }
  final String nodeId = '${decoded['nodeId'] ?? ''}'.trim();
  if (nodeId.isEmpty) return null;
  final int advertisedPort = (decoded['httpPort'] as num?)?.toInt() ?? uri.port;
  final int port = advertisedPort > 0 && advertisedPort <= 65535
      ? advertisedPort
      : uri.port;
  final LanBackupHostCompatibility? compatibility =
      parseLanBackupHostCompatibility(decoded['backupCompatibility']);
  final bool compatible = compatibility?.supportsCurrentMobile == true;
  return LanBackupDiscoveredHost(
    nodeId: nodeId,
    name: '${decoded['nodeName'] ?? ''}'.trim().isEmpty
        ? '录像文件备份主机'
        : '${decoded['nodeName']}'.trim(),
    address: '${uri.host}:$port',
    compatible: compatible,
    compatibilityMessage: compatible ? null : '保存主机版本过低，请在电脑端更新 PackingProof',
  );
}

class LanBackupHostDiscoveryService extends ChangeNotifier
    implements LanBackupHostDiscovery {
  LanBackupHostDiscoveryService({
    LanBackupCandidateProvider? candidateProvider,
    LanBackupHostProbe? probe,
    HttpClient? httpClient,
    this.cache,
  }) : _candidateProvider = candidateProvider ?? _defaultCandidates,
       _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null,
       _probeOverride = probe {
    // 探测 /24 网段时会并发连接大量不可达主机，若连接阶段无限期挂起，
    // 半开 socket 会迅速耗尽文件描述符（EMFILE）。显式收紧连接与空闲超时。
    // 仅对自行创建的客户端设置默认值，避免覆盖调用方注入的客户端配置。
    if (_ownsHttpClient) {
      _httpClient
        ..connectionTimeout = const Duration(seconds: 5)
        ..idleTimeout = const Duration(seconds: 10);
    }
  }

  final LanBackupCandidateProvider _candidateProvider;
  final LanBackupHostProbe? _probeOverride;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;
  final LanBackupHostCache? cache;
  int _revision = 0;
  Future<void>? _activeSearch;
  bool _cacheLoaded = false;
  LanBackupDiscoverySnapshot _snapshot = const LanBackupDiscoverySnapshot();

  @override
  LanBackupDiscoverySnapshot get snapshot => _snapshot;

  @override
  Future<void> search() {
    final Future<void>? activeSearch = _activeSearch;
    if (activeSearch != null) return activeSearch;

    final Future<void> search = _runSearch();
    _activeSearch = search;
    return search.whenComplete(() {
      if (identical(_activeSearch, search)) _activeSearch = null;
    });
  }

  Future<void> _runSearch() async {
    final int revision = ++_revision;
    List<LanBackupDiscoveredHost> retainedHosts = _snapshot.hosts
        .map((LanBackupDiscoveredHost host) => host.copyWith(reachable: false))
        .toList(growable: true);
    _snapshot = LanBackupDiscoverySnapshot(
      searching: true,
      hosts: List<LanBackupDiscoveredHost>.unmodifiable(retainedHosts),
      message: retainedHosts.isEmpty
          ? '正在查找同一 Wi-Fi 下的录像文件备份主机'
          : '正在重新搜索，已保留上次找到的电脑',
    );
    notifyListeners();
    if (!_cacheLoaded && cache != null) {
      _cacheLoaded = true;
      try {
        final List<LanBackupDiscoveredHost> cached = await cache!.load();
        if (revision != _revision) return;
        retainedHosts = _mergeHosts(retainedHosts, cached);
        _snapshot = LanBackupDiscoverySnapshot(
          searching: true,
          hosts: List<LanBackupDiscoveredHost>.unmodifiable(retainedHosts),
          message: retainedHosts.isEmpty
              ? '正在查找同一 Wi-Fi 下的录像文件备份主机'
              : '正在重新搜索，已保留上次找到的电脑',
        );
        notifyListeners();
      } on Object {
        // 搜索仍可继续，缓存损坏或暂不可读不应阻断连接。
      }
    }
    final List<Uri> candidates;
    try {
      candidates = await _candidateProvider();
    } on Object {
      if (revision != _revision) return;
      _snapshot = const LanBackupDiscoverySnapshot(
        message: '暂时无法读取局域网地址，可重新搜索或扫码连接',
      );
      if (retainedHosts.isNotEmpty) {
        _snapshot = LanBackupDiscoverySnapshot(
          hosts: List<LanBackupDiscoveredHost>.unmodifiable(retainedHosts),
          message: '暂时无法搜索，已保留上次找到的电脑',
        );
      }
      notifyListeners();
      return;
    }
    if (revision != _revision) return;
    if (candidates.isEmpty) {
      _snapshot = LanBackupDiscoverySnapshot(
        hosts: List<LanBackupDiscoveredHost>.unmodifiable(retainedHosts),
        message: retainedHosts.isEmpty
            ? '未连接 Wi-Fi，请连接后重新搜索或扫码连接'
            : '未连接 Wi-Fi，已保留上次找到的电脑',
      );
      notifyListeners();
      return;
    }
    final List<LanBackupDiscoveredHost> hosts = retainedHosts;
    int cursor = 0;
    int completed = 0;
    _snapshot = LanBackupDiscoverySnapshot(
      searching: true,
      total: candidates.length,
      hosts: List<LanBackupDiscoveredHost>.unmodifiable(hosts),
      message: '正在搜索 0 / ${candidates.length}',
    );
    notifyListeners();
    Future<void> worker() async {
      while (revision == _revision) {
        final int index = cursor++;
        if (index >= candidates.length) return;
        final LanBackupDiscoveredHost? host = await _probe(candidates[index]);
        if (revision != _revision) return;
        if (host != null) {
          final int existingIndex = hosts.indexWhere(
            (LanBackupDiscoveredHost item) => _isSameDiscoveredHost(item, host),
          );
          if (existingIndex >= 0) {
            hosts[existingIndex] = host;
          } else {
            hosts.add(host);
          }
          hosts.sort((a, b) => a.name.compareTo(b.name));
        }
        completed++;
        if (completed == candidates.length ||
            completed % 4 == 0 ||
            host != null) {
          _snapshot = LanBackupDiscoverySnapshot(
            searching: true,
            completed: completed,
            total: candidates.length,
            hosts: List<LanBackupDiscoveredHost>.unmodifiable(hosts),
            message: '正在搜索 $completed / ${candidates.length}',
          );
          notifyListeners();
        }
      }
    }

    await Future.wait(<Future<void>>[
      ...List<Future<void>>.generate(
        candidates.length < 32 ? candidates.length : 32,
        (_) => worker(),
      ),
      _runUdpDiscovery(hosts, revision),
    ]);
    if (revision != _revision) return;
    final List<LanBackupDiscoveredHost> reachableHosts = hosts
        .where((LanBackupDiscoveredHost host) => host.reachable)
        .toList(growable: false);
    _snapshot = LanBackupDiscoverySnapshot(
      completed: completed,
      total: candidates.length,
      hosts: List<LanBackupDiscoveredHost>.unmodifiable(hosts),
      message: reachableHosts.isEmpty && hosts.isNotEmpty
          ? '未找到在线保存主机，已保留上次搜索结果'
          : hosts.isEmpty
          ? '未找到录像文件备份主机，可重新搜索或扫码连接'
          : reachableHosts.every(
              (LanBackupDiscoveredHost host) => !host.compatible,
            )
          ? '找到保存主机，但电脑端版本过低，请先更新 PackingProof'
          : reachableHosts.length == 1
          ? '已找到保存主机，正在请求电脑允许连接'
          : '找到 ${reachableHosts.length} 台保存主机，请选择一台连接',
    );
    notifyListeners();
    final LanBackupHostCache? hostCache = cache;
    if (hostCache != null && hosts.isNotEmpty) {
      try {
        await hostCache.save(List<LanBackupDiscoveredHost>.unmodifiable(hosts));
      } on Object {
        // 缓存失败不影响本次搜索结果和连接。
      }
    }
  }

  static List<LanBackupDiscoveredHost> _mergeHosts(
    List<LanBackupDiscoveredHost> current,
    List<LanBackupDiscoveredHost> cached,
  ) {
    final List<LanBackupDiscoveredHost> merged = <LanBackupDiscoveredHost>[
      for (final LanBackupDiscoveredHost host in cached)
        host.copyWith(reachable: false),
    ];
    for (final LanBackupDiscoveredHost host in current) {
      final int index = merged.indexWhere(
        (LanBackupDiscoveredHost item) => _isSameDiscoveredHost(item, host),
      );
      if (index >= 0) {
        merged[index] = host;
      } else {
        merged.add(host);
      }
    }
    merged.sort((a, b) => a.name.compareTo(b.name));
    return merged;
  }

  @override
  Future<void> forgetHost({
    required String nodeId,
    required String address,
  }) async {
    _revision++;
    final LanBackupDiscoveredHost forgotten = LanBackupDiscoveredHost(
      nodeId: nodeId,
      name: '',
      address: address,
    );
    final List<LanBackupDiscoveredHost> remaining = _snapshot.hosts
        .where(
          (LanBackupDiscoveredHost host) =>
              !_isSameDiscoveredHost(host, forgotten),
        )
        .toList(growable: false);
    _snapshot = LanBackupDiscoverySnapshot(
      completed: _snapshot.completed,
      total: _snapshot.total,
      hosts: List<LanBackupDiscoveredHost>.unmodifiable(remaining),
      message: '已删除电脑，可重新搜索或扫码连接',
    );
    notifyListeners();
    final LanBackupHostCache? hostCache = cache;
    if (hostCache != null) {
      try {
        await hostCache.save(
          List<LanBackupDiscoveredHost>.unmodifiable(remaining),
        );
      } on Object {
        // 清理缓存失败不影响删除结果，下次搜索会重新写入。
      }
    }
  }

  Future<LanBackupDiscoveredHost?> _probe(Uri uri) async {
    final LanBackupHostProbe? override = _probeOverride;
    if (override != null) return override(uri);
    try {
      final HttpClientRequest request = await _httpClient
          .getUrl(uri.replace(path: '/api/node-info'))
          .timeout(const Duration(milliseconds: 450));
      request.followRedirects = false;
      final HttpClientResponse response = await request.close().timeout(
        const Duration(milliseconds: 650),
      );
      final String body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) return null;
      return parseLanBackupDiscoveredHost(uri, body);
    } on Object {
      return null;
    }
  }

  /// Android 专用：UDP 广播探测主机候选，announce 立即走 HTTP 确认并并入结果。
  Future<void> _runUdpDiscovery(
    List<LanBackupDiscoveredHost> hosts,
    int revision,
  ) async {
    if (!Platform.isAndroid) return;
    await for (final UdpDiscoveryAnnounce announce in _discoverUdpAnnounces()) {
      if (revision != _revision) return;
      final LanBackupDiscoveredHost? host = await _probe(
        Uri(scheme: 'http', host: announce.sourceIp, port: announce.httpPort),
      );
      if (revision != _revision) return;
      if (host == null) continue;
      final int existingIndex = hosts.indexWhere(
        (LanBackupDiscoveredHost item) => _isSameDiscoveredHost(item, host),
      );
      if (existingIndex >= 0) {
        hosts[existingIndex] = host;
      } else {
        hosts.add(host);
      }
      hosts.sort((a, b) => a.name.compareTo(b.name));
    }
  }

  Stream<UdpDiscoveryAnnounce> _discoverUdpAnnounces() async* {
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException {
      return;
    }
    socket.broadcastEnabled = true;
    socket.readEventsEnabled = true;

    Timer? timeout;
    try {
      final List<int> request = utf8.encode(
        jsonEncode(const <String, Object>{
          'protocol': 'packingproof',
          'protocolVersion': 1,
          'action': 'discover',
        }),
      );
      socket.send(
        request,
        InternetAddress('255.255.255.255'),
        udpDiscoveryPort,
      );
      // 600ms 仅用于停止等待新的 announce；收到即 yield，不等窗口结束。
      timeout = Timer(const Duration(milliseconds: 600), socket.close);
      await for (final RawSocketEvent event in socket) {
        if (event != RawSocketEvent.read) continue;
        final Datagram? datagram = socket.receive();
        if (datagram == null) continue;
        final UdpDiscoveryAnnounce? announce = parseUdpAnnounce(
          datagram.data,
          datagram.address.address,
        );
        if (announce != null) yield announce;
      }
    } finally {
      timeout?.cancel();
      socket.close();
    }
  }

  @override
  void cancel() {
    _revision++;
    _activeSearch = null;
    if (_snapshot.searching) {
      _snapshot = LanBackupDiscoverySnapshot(
        completed: _snapshot.completed,
        total: _snapshot.total,
        hosts: _snapshot.hosts,
        message: '搜索已停止',
      );
      notifyListeners();
    }
  }

  @override
  void dispose() {
    cancel();
    if (_ownsHttpClient) _httpClient.close(force: true);
    super.dispose();
  }

  static Future<List<Uri>> _defaultCandidates() async {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final Set<String> localAddresses = interfaces
        .expand((item) => item.addresses)
        .map((item) => item.address)
        .toSet();
    final Set<String> candidates = <String>{};
    for (final String address in localAddresses) {
      final List<int>? octets = _privateIpv4Octets(address);
      if (octets == null) continue;
      final String prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
      for (final int host in buildLanBackupHostScanOrder(
        localHost: octets[3],
      )) {
        final String candidate = '$prefix.$host';
        if (!localAddresses.contains(candidate)) candidates.add(candidate);
      }
    }
    return candidates.map((host) => Uri.parse('http://$host:5280')).toList();
  }

  static List<int>? _privateIpv4Octets(String value) {
    final List<int> parts = value
        .split('.')
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    if (parts.length != 4 || parts.any((part) => part < 0 || part > 255)) {
      return null;
    }
    final bool isPrivate =
        parts[0] == 10 ||
        (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) ||
        (parts[0] == 192 && parts[1] == 168);
    return isPrivate ? parts : null;
  }
}

bool _isSameDiscoveredHost(
  LanBackupDiscoveredHost left,
  LanBackupDiscoveredHost right,
) {
  final String leftId = left.nodeId.trim();
  final String rightId = right.nodeId.trim();
  if (leftId.isNotEmpty && rightId.isNotEmpty && leftId == rightId) {
    return true;
  }
  return _normalizedDiscoveredAddress(left.address) ==
      _normalizedDiscoveredAddress(right.address);
}

String _normalizedDiscoveredAddress(String value) {
  final Uri? uri = Uri.tryParse(
    value.contains('://') ? value : 'http://$value',
  );
  if (uri == null || uri.host.isEmpty) {
    return value.trim().toLowerCase();
  }
  return '${uri.host.toLowerCase()}:${uri.hasPort ? uri.port : 5280}';
}

/// 跨端 UDP 广播主机发现协议：固定 UDP 5281，广播 255.255.255.255，
/// 报文为 UTF-8 JSON，单包不超过 512 字节。iOS 暂不启用。
const int udpDiscoveryPort = 5281;
const int udpDiscoveryMaxPacketBytes = 512;

@visibleForTesting
class UdpDiscoveryAnnounce {
  const UdpDiscoveryAnnounce(this.nodeId, this.httpPort, this.sourceIp);

  final String nodeId;
  final int httpPort;
  final String sourceIp;
}

@visibleForTesting
UdpDiscoveryAnnounce? parseUdpAnnounce(List<int> data, String sourceIp) {
  if (data.length > udpDiscoveryMaxPacketBytes) return null;
  try {
    final Object? decoded = jsonDecode(utf8.decode(data));
    if (decoded is! Map) return null;
    if (decoded['protocol'] != 'packingproof') return null;
    if (decoded['protocolVersion'] != 1) return null;
    if (decoded['action'] != 'announce') return null;
    final String nodeId = '${decoded['nodeId'] ?? ''}'.trim();
    if (!_isUuid(nodeId)) return null;
    final int httpPort = (decoded['httpPort'] as num?)?.toInt() ?? 0;
    if (httpPort <= 0 || httpPort > 65535) return null;
    return UdpDiscoveryAnnounce(nodeId, httpPort, sourceIp);
  } on Object {
    return null;
  }
}

bool _isUuid(String value) {
  final RegExp uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  return uuid.hasMatch(value);
}
