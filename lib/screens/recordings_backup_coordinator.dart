part of 'recordings_screen.dart';

mixin _RecordingsBackupCoordinator on State<RecordingsScreen> {
  late LanBackupSnapshot _backupSnapshot;
  Map<String, List<LanBackupJob>> _backupJobsByPath =
      <String, List<LanBackupJob>>{};
  late final LanBackupHostDiscovery _backupHostDiscovery;
  late final bool _ownsBackupHostDiscovery;
  LanBackupDiscoverySnapshot _backupDiscoverySnapshot =
      const LanBackupDiscoverySnapshot();
  bool _backupDiscoveryStarted = false;
  bool _autoConnectStarted = false;
  bool _approvalRequestInFlight = false;
  LanBackupDiscoveredHost? _lastApprovalHost;

  bool get _lanBackupSupported;
  bool get _loadingRemote;
  set _loadingRemote(bool value);
  bool get _remoteCacheDirty;
  set _remoteCacheDirty(bool value);
  List<RemoteRecording> get _remoteRecordings;
  Map<int, List<RemoteRecording>> get _remotePages;
  set _remoteTotal(int value);
  set _remoteDeviceTotal(int value);
  int get _remoteRequestGeneration;
  set _remoteRequestGeneration(int value);
  set _historyPage(int value);

  void _refreshLocalRecordingStats();

  Future<void> _loadRemote({
    bool reset = false,
    required int pageNumber,
    bool prefetchNext = false,
  });

  void _initializeBackupCoordinator() {
    _backupSnapshot = widget.backupSnapshot;
    _backupJobsByPath = _buildBackupJobsByPath(_backupSnapshot);
    _ownsBackupHostDiscovery = widget.backupHostDiscovery == null;
    _backupHostDiscovery =
        widget.backupHostDiscovery ?? LanBackupHostDiscoveryService();
    _backupDiscoverySnapshot = _backupHostDiscovery.snapshot;
    _backupHostDiscovery.addListener(_refreshBackupDiscovery);
  }

  void _attachBackupSnapshotListener() {
    if (_lanBackupSupported) {
      widget.backupListenable?.addListener(_refreshBackupSnapshot);
    }
  }

  void _disposeBackupCoordinator() {
    widget.backupListenable?.removeListener(_refreshBackupSnapshot);
    _backupHostDiscovery.removeListener(_refreshBackupDiscovery);
    _backupHostDiscovery.cancel();
    if (_ownsBackupHostDiscovery &&
        _backupHostDiscovery is LanBackupHostDiscoveryService) {
      _backupHostDiscovery.dispose();
    }
  }

  void _refreshBackupDiscovery() {
    if (!mounted || !_lanBackupSupported) return;
    final LanBackupDiscoverySnapshot next = _backupHostDiscovery.snapshot;
    if (!_backupDiscoverySnapshot.searching && next.searching) {
      _autoConnectStarted = false;
    }
    setState(() => _backupDiscoverySnapshot = next);
    final List<LanBackupDiscoveredHost> reachableHosts = next.hosts
        .where(
          (LanBackupDiscoveredHost host) => host.compatible && host.reachable,
        )
        .toList(growable: false);
    final LanBackupDiscoveredHost? automaticHost = reachableHosts.length == 1
        ? reachableHosts.single
        : null;
    if (!next.searching &&
        automaticHost != null &&
        widget.active &&
        widget.mode == RecordingsScreenMode.history &&
        !_autoConnectStarted &&
        _backupSnapshot.endpoint == null &&
        widget.onConnectBackupHost != null) {
      _autoConnectStarted = true;
      unawaited(_connectDiscoveredHost(automaticHost));
    }
  }

  void _startBackupHostDiscoveryIfNeeded() {
    if (!mounted ||
        !_lanBackupSupported ||
        widget.backupHostDiscovery == null ||
        !widget.active ||
        widget.mode != RecordingsScreenMode.history ||
        _backupSnapshot.endpoint != null ||
        _backupDiscoveryStarted ||
        _backupDiscoverySnapshot.searching) {
      return;
    }
    _backupDiscoveryStarted = true;
    unawaited(_backupHostDiscovery.search());
  }

  Future<void> _connectDiscoveredHost(LanBackupDiscoveredHost host) async {
    if (!host.compatible) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(host.compatibilityMessage ?? '保存主机版本过低，请更新电脑端'),
          ),
        );
      }
      return;
    }
    final Future<void> Function(
      LanBackupDiscoveredHost host,
      LanBackupPairingConfirmation? replacementConfirmation,
    )?
    connect = widget.onConnectBackupHost;
    if (connect == null) return;
    _lastApprovalHost = host;
    _autoConnectStarted = true;
    _approvalRequestInFlight = true;
    if (mounted) {
      setState(() {
        _backupSnapshot = _backupSnapshot.copyWith(
          connectionStatus: LanConnectionStatus.awaitingApproval,
          message: '已向“${host.name}”发送连接申请，请在电脑上点击“允许连接”',
        );
      });
    }
    try {
      await connect(host, null);
      _refreshBackupSnapshot();
    } on LanBackupHostMismatchException catch (error) {
      if (!mounted) return;
      _refreshBackupSnapshot();
      final bool replace =
          await showDialog<bool>(
            context: context,
            builder: (BuildContext dialogContext) => AlertDialog(
              title: const Text('更换备份电脑？'),
              content: Text(
                '当前：${error.currentEndpoint.computerName}\n'
                '新的电脑：${error.candidateEndpoint.computerName}\n\n'
                '仍有待备份录像，确认后才会向新电脑申请连接',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('继续连接'),
                ),
              ],
            ),
          ) ??
          false;
      if (replace) await connect(host, error.confirmation);
    } on Object catch (error) {
      // broad-catch: 连接适配器错误类型不统一，统一转换为安全的用户提示。
      if (!mounted) return;
      _refreshBackupSnapshot();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyBackupConnectionError(error))),
      );
    } finally {
      _approvalRequestInFlight = false;
      if (mounted) _refreshBackupSnapshot();
    }
  }

  void _cancelBackupApproval() {
    _approvalRequestInFlight = false;
    widget.onCancelBackupPairing?.call();
  }

  void _refreshBackupSnapshot() {
    if (!mounted) {
      return;
    }
    LanBackupSnapshot next =
        widget.backupSnapshotProvider?.call() ?? widget.backupSnapshot;
    if (_approvalRequestInFlight &&
        (next.connectionStatus == LanConnectionStatus.disconnected ||
            next.connectionStatus == LanConnectionStatus.connecting)) {
      next = next.copyWith(
        connectionStatus: LanConnectionStatus.awaitingApproval,
        message: _backupSnapshot.message,
      );
    }
    final Set<String> previousCompleted = _completedBackupSignatures(
      _backupSnapshot,
    );
    final Set<String> nextCompleted = _completedBackupSignatures(next);
    final bool completedChanged = nextCompleted
        .difference(previousCompleted)
        .isNotEmpty;
    final Set<String> previousDeleted = _deletedLocalPaths(_backupSnapshot);
    final Set<String> nextDeleted = _deletedLocalPaths(next);
    final bool localCleanupChanged = nextDeleted
        .difference(previousDeleted)
        .isNotEmpty;
    final bool reconnected =
        _backupSnapshot.connectionStatus != LanConnectionStatus.connected &&
        next.connectionStatus == LanConnectionStatus.connected;
    final bool endpointChanged = !_sameBackupEndpoint(
      _backupSnapshot.endpoint,
      next.endpoint,
    );
    if (localCleanupChanged) {
      _refreshLocalRecordingStats();
    }
    _backupJobsByPath = _buildBackupJobsByPath(next);
    setState(() {
      _backupSnapshot = next;
      if (completedChanged) _remoteCacheDirty = true;
      if (next.connectionStatus != LanConnectionStatus.connected) {
        _remoteRequestGeneration++;
        _loadingRemote = false;
      }
      if (endpointChanged) {
        _remoteRecordings.clear();
        _remotePages.clear();
        _remoteTotal = 0;
        _remoteDeviceTotal = 0;
        _historyPage = 0;
      }
    });
    if (reconnected) {
      unawaited(_loadRemote(reset: true, pageNumber: 1, prefetchNext: true));
    } else if (completedChanged) {
      _reloadRemoteAfterBackup();
    } else if (widget.active &&
        _backupSnapshot.connectionStatus == LanConnectionStatus.connected &&
        _remoteRecordings.isEmpty) {
      unawaited(_loadRemote(reset: true, pageNumber: 1, prefetchNext: true));
    }
  }

  bool _sameBackupEndpoint(LanBackupEndpoint? left, LanBackupEndpoint? right) {
    if (left == null || right == null) {
      return left == null && right == null;
    }
    return left.computerId == right.computerId && left.baseUri == right.baseUri;
  }

  Map<String, List<LanBackupJob>> _buildBackupJobsByPath(
    LanBackupSnapshot snapshot,
  ) {
    final Map<String, List<LanBackupJob>> jobs = <String, List<LanBackupJob>>{};
    for (final LanBackupJob job in snapshot.jobs) {
      jobs
          .putIfAbsent(
            lanBackupFileIdentity(job.filePath),
            () => <LanBackupJob>[],
          )
          .add(job);
    }
    return jobs;
  }

  Set<String> _completedBackupSignatures(LanBackupSnapshot snapshot) => snapshot
      .jobs
      .where(
        (LanBackupJob job) =>
            job.state == LanBackupJobState.completed &&
            job.remoteRecordId != null,
      )
      .map(
        (LanBackupJob job) =>
            '${job.id}:${job.destinationComputerId}:${job.remoteRecordId}',
      )
      .toSet();

  Set<String> _deletedLocalPaths(LanBackupSnapshot snapshot) => snapshot.jobs
      .where((LanBackupJob job) => job.localDeletedAt != null)
      .map((LanBackupJob job) => lanBackupFileIdentity(job.filePath))
      .toSet();

  void _reloadRemoteAfterBackup({bool force = false}) {
    if ((!_remoteCacheDirty && !force) ||
        !mounted ||
        !widget.active ||
        _loadingRemote ||
        _backupSnapshot.connectionStatus != LanConnectionStatus.connected) {
      return;
    }
    _remoteCacheDirty = false;
    unawaited(_loadRemote(reset: true, pageNumber: 1, prefetchNext: true));
  }
}
