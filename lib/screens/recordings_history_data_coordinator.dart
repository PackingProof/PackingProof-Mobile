part of 'recordings_screen.dart';

mixin _RecordingsHistoryDataCoordinator on _RecordingsBackupCoordinator {
  @override
  final List<RemoteRecording> _remoteRecordings = <RemoteRecording>[];
  @override
  final Map<int, List<RemoteRecording>> _remotePages =
      <int, List<RemoteRecording>>{};
  final Map<int, List<RecordingSession>> _localPages =
      <int, List<RecordingSession>>{};
  final Map<int, ({RemoteRecordingStatus status, bool exists, String reason})>
  _remoteStatuses = {};
  @override
  bool _loadingRemote = false;
  @override
  bool _remoteCacheDirty = false;
  bool _manualRefreshing = false;
  DateTime? _lastManualRefreshAt;
  @override
  int _remoteTotal = 0;
  @override
  int _remoteDeviceTotal = 0;
  int _localTotal = 0;
  bool _loadingLocal = false;
  @override
  int _historyPage = 0;
  @override
  int _remoteRequestGeneration = 0;
  int _localRequestGeneration = 0;

  int get _historyPageSize;
  List<RecordingSession> get _sessions;
  String get _query;
  RecordingHistoryDateWindow? get _activeDateWindow;

  Future<void> _manualRefresh() async {
    final DateTime now = DateTime.now();
    if (_manualRefreshing ||
        (_lastManualRefreshAt != null &&
            now.difference(_lastManualRefreshAt!) <
                const Duration(milliseconds: 800))) {
      return;
    }
    _lastManualRefreshAt = now;
    setState(() => _manualRefreshing = true);
    try {
      await widget.onRefreshHistory?.call();
      if (!mounted) return;
      _localRequestGeneration++;
      _loadingLocal = false;
      await _loadLocal(reset: true, pageNumber: 1, prefetchNext: true);
      if (!mounted) return;
      _remoteRequestGeneration++;
      _loadingRemote = false;
      _remoteCacheDirty = false;
      if (_backupSnapshot.connectionStatus == LanConnectionStatus.connected) {
        await _loadRemote(reset: true, pageNumber: 1, prefetchNext: true);
      }
    } finally {
      if (mounted) setState(() => _manualRefreshing = false);
    }
  }

  Future<void> _loadLocal({
    bool reset = false,
    required int pageNumber,
    bool prefetchNext = false,
    bool preservePage = false,
  }) async {
    final callback = widget.onLoadLocalRecordings;
    if (callback == null || _loadingLocal || !widget.active) return;
    final int generation = ++_localRequestGeneration;
    setState(() {
      _loadingLocal = true;
      if (reset) {
        _localPages.clear();
        _sessions.clear();
        _localTotal = 0;
        if (!preservePage) _historyPage = 0;
      }
    });
    try {
      final LocalRecordingPage result = await callback(
        page: pageNumber,
        pageSize: _historyPageSize,
        keyword: _query,
        start: _activeDateWindow?.start,
        end: _activeDateWindow?.end,
      );
      if (!mounted || generation != _localRequestGeneration) return;
      setState(() {
        _localPages[result.page] = result.data;
        _localTotal = result.total;
        _rebuildLocalRecordings();
        _refreshLocalRecordingStats();
      });
      if (prefetchNext && result.page < result.pageCount) {
        await _loadLocalPageWithoutBusy(result.page + 1, generation);
      }
    } on Object {
      // broad-catch: Keep loaded rows visible for any local database failure.
    } finally {
      if (mounted && generation == _localRequestGeneration) {
        setState(() => _loadingLocal = false);
      }
    }
  }

  Future<void> _loadLocalPageWithoutBusy(int pageNumber, int generation) async {
    final callback = widget.onLoadLocalRecordings;
    if (callback == null || _localPages.containsKey(pageNumber)) return;
    final LocalRecordingPage page = await callback(
      page: pageNumber,
      pageSize: _historyPageSize,
      keyword: _query,
      start: _activeDateWindow?.start,
      end: _activeDateWindow?.end,
    );
    if (!mounted || generation != _localRequestGeneration) return;
    setState(() {
      _localPages[page.page] = page.data;
      _localTotal = page.total;
      _rebuildLocalRecordings();
      _refreshLocalRecordingStats();
    });
  }

  void _rebuildLocalRecordings() {
    _sessions
      ..clear()
      ..addAll(flattenRecordingHistoryPages(_localPages));
  }

  @override
  Future<void> _loadRemote({
    bool reset = false,
    required int pageNumber,
    bool prefetchNext = false,
  }) async {
    if (_loadingRemote ||
        !_lanBackupSupported ||
        !widget.active ||
        widget.onLoadRemoteRecordings == null ||
        _backupSnapshot.connectionStatus != LanConnectionStatus.connected) {
      return;
    }
    final int requestGeneration = ++_remoteRequestGeneration;
    setState(() {
      _loadingRemote = true;
      if (reset) {
        _remotePages.clear();
        _remoteRecordings.clear();
        _remoteTotal = 0;
        _remoteDeviceTotal = 0;
        _historyPage = 0;
      }
    });
    try {
      final RemoteRecordingPage result = await widget.onLoadRemoteRecordings!(
        page: pageNumber,
        pageSize: _historyPageSize,
        keyword: _query,
      );
      if (!mounted || requestGeneration != _remoteRequestGeneration) return;
      setState(() {
        _remotePages[result.page] = result.data;
        _remoteTotal = result.total;
        _remoteDeviceTotal = result.deviceTotal;
        _rebuildRemoteRecordings();
      });
      await _refreshRemoteStatuses(result.data);
      if (prefetchNext && result.hasMore && mounted) {
        await _loadRemotePageWithoutBusy(result.page + 1, requestGeneration);
      }
    } on Object {
      // broad-catch: Backup state owns all remote errors; keep cached rows visible.
    } finally {
      if (mounted && requestGeneration == _remoteRequestGeneration) {
        setState(() => _loadingRemote = false);
        _reloadRemoteAfterBackup();
      }
    }
  }

  Future<void> _loadRemotePageWithoutBusy(
    int pageNumber,
    int requestGeneration,
  ) async {
    if (_remotePages.containsKey(pageNumber) ||
        !_lanBackupSupported ||
        widget.onLoadRemoteRecordings == null ||
        _backupSnapshot.connectionStatus != LanConnectionStatus.connected) {
      return;
    }
    final RemoteRecordingPage page = await widget.onLoadRemoteRecordings!(
      page: pageNumber,
      pageSize: _historyPageSize,
      keyword: _query,
    );
    if (!mounted || requestGeneration != _remoteRequestGeneration) return;
    setState(() {
      _remotePages[page.page] = page.data;
      _remoteTotal = page.total;
      _remoteDeviceTotal = page.deviceTotal;
      _rebuildRemoteRecordings();
    });
    await _refreshRemoteStatuses(page.data);
  }

  void _rebuildRemoteRecordings() {
    _remoteRecordings
      ..clear()
      ..addAll(flattenRecordingHistoryPages(_remotePages));
  }

  Future<void> _refreshRemoteStatuses(List<RemoteRecording> page) async {
    final callback = widget.onLoadRemoteRecordingStatuses;
    if (callback == null) return;
    final Set<int> ids = page.map((item) => item.id).toSet()
      ..addAll(
        _backupSnapshot.jobs
            .where(
              (job) =>
                  job.destinationComputerId ==
                  _backupSnapshot.endpoint?.computerId,
            )
            .map((job) => job.remoteRecordId)
            .whereType<int>(),
      );
    if (ids.isEmpty) return;
    try {
      final statuses = await callback(ids);
      if (!mounted || statuses.isEmpty) return;
      setState(() {
        _remoteStatuses.addAll(statuses);
        for (final int pageNumber in _remotePages.keys.toList()) {
          _remotePages[pageNumber] = _remotePages[pageNumber]!
              .map((RemoteRecording item) {
                final status = statuses[item.id];
                return status == null
                    ? item
                    : item.withStatus(
                        status: status.status,
                        exists: status.exists,
                        reason: status.reason,
                      );
              })
              .toList(growable: false);
        }
        _rebuildRemoteRecordings();
      });
    } on Object {
      // broad-catch: Keep the page usable with availability from /api/videos.
    }
  }
}
