part of 'recordings_screen.dart';

mixin _RecordingsHistoryDataCoordinator on _RecordingsBackupCoordinator {
  @override
  final List<RemoteRecording> _remoteRecordings = <RemoteRecording>[];
  @override
  final Map<int, List<RemoteRecording>> _remotePages =
      <int, List<RemoteRecording>>{};
  final Map<int, LocalRecordingPage> _localPages = <int, LocalRecordingPage>{};
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
  String? _remoteFilterError;
  int _localRecordingBytes = 0;
  Set<String> _localRecordingPaths = <String>{};
  int _localRecordingStatsGeneration = 0;
  @override
  int _historyPage = 0;
  @override
  int _remoteRequestGeneration = 0;
  int _localRequestGeneration = 0;

  int get _historyPageSize;
  List<RecordingSession> get _sessions;
  String get _query;
  RecordingOperationMode? get _operationFilter;
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
      final LocalRecordingPage? result = await _fetchLocalPage(pageNumber);
      if (result == null) return;
      if (!mounted || generation != _localRequestGeneration) return;
      setState(() {
        _localPages[result.page] = result;
        _localTotal = result.total;
        _trimLocalPageCache();
        _rebuildLocalRecordings();
        _refreshLocalRecordingStats();
      });
      if (prefetchNext && result.page < result.pageCount) {
        await _loadLocalPageWithoutBusy(result.page + 1, generation);
      }
      await _refreshBackupJobsForPaths();
    } on Object {
      // broad-catch: Keep loaded rows visible for any local database failure.
    } finally {
      if (mounted && generation == _localRequestGeneration) {
        setState(() => _loadingLocal = false);
      }
    }
  }

  Future<void> _loadLocalPageWithoutBusy(int pageNumber, int generation) async {
    if (_localPages.containsKey(pageNumber)) return;
    final LocalRecordingPage? page = await _fetchLocalPage(pageNumber);
    if (page == null) return;
    if (!mounted || generation != _localRequestGeneration) return;
    setState(() {
      _localPages[page.page] = page;
      _localTotal = page.total;
      _trimLocalPageCache();
      _rebuildLocalRecordings();
      _refreshLocalRecordingStats();
    });
  }

  void _rebuildLocalRecordings() {
    _sessions
      ..clear()
      ..addAll(
        flattenRecordingHistoryPages(<int, List<RecordingSession>>{
          for (final MapEntry<int, LocalRecordingPage> entry
              in _localPages.entries)
            entry.key: entry.value.data,
        }),
      );
  }

  Future<LocalRecordingPage?> _fetchLocalPage(int pageNumber) async {
    final callback = widget.onLoadLocalRecordings;
    if (callback == null) return null;
    if (pageNumber == 1) {
      return callback(
        page: 1,
        pageSize: _historyPageSize,
        keyword: _query,
        operationMode: _operationFilter,
        start: _activeDateWindow?.start,
        end: _activeDateWindow?.end,
      );
    }
    final adjacentCallback = widget.onLoadAdjacentLocalRecordings;
    if (adjacentCallback != null) {
      final LocalRecordingPage? previousPage = _localPages[pageNumber - 1];
      final LocalRecordingCursor? olderCursor = previousPage?.lastCursor;
      if (olderCursor != null) {
        return adjacentCallback(
          page: pageNumber,
          pageSize: _historyPageSize,
          cursor: olderCursor,
          direction: LocalRecordingPageDirection.older,
          knownTotal: _localTotal,
          keyword: _query,
          operationMode: _operationFilter,
          start: _activeDateWindow?.start,
          end: _activeDateWindow?.end,
        );
      }
      final LocalRecordingPage? nextPage = _localPages[pageNumber + 1];
      final LocalRecordingCursor? newerCursor = nextPage?.firstCursor;
      if (newerCursor != null) {
        return adjacentCallback(
          page: pageNumber,
          pageSize: _historyPageSize,
          cursor: newerCursor,
          direction: LocalRecordingPageDirection.newer,
          knownTotal: _localTotal,
          keyword: _query,
          operationMode: _operationFilter,
          start: _activeDateWindow?.start,
          end: _activeDateWindow?.end,
        );
      }
      return null;
    }
    // 仅供未迁移的注入式测试/嵌入方兼容；正式仓库加载器始终走上面的游标 API。
    return callback(
      page: pageNumber,
      pageSize: _historyPageSize,
      keyword: _query,
      operationMode: _operationFilter,
      start: _activeDateWindow?.start,
      end: _activeDateWindow?.end,
    );
  }

  void _trimLocalPageCache() {
    trimRecordingHistoryPageCache(
      _localPages,
      currentDataPage: _historyPage + 1,
    );
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
      _remoteFilterError = null;
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
        operationMode: _operationFilter,
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
    } on UnsupportedError catch (error) {
      if (mounted && requestGeneration == _remoteRequestGeneration) {
        setState(() => _remoteFilterError = error.message?.toString());
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
      operationMode: _operationFilter,
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
    final Set<int> ids = page.map((item) => item.id).toSet();
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

  @override
  void _refreshLocalRecordingStats() {
    final ({int bytes, Set<String> paths})? databaseSummary =
        _localRecordingStatsFromPages();
    final int generation = ++_localRecordingStatsGeneration;
    if (databaseSummary != null) {
      _localRecordingBytes = databaseSummary.bytes;
      _localRecordingPaths = databaseSummary.paths;
      return;
    }
    if (widget.onLoadLocalRecordings != null && _localPages.isEmpty) {
      _localRecordingBytes = 0;
      _localRecordingPaths = <String>{};
      return;
    }
    final List<String> paths = _sessions
        .map((RecordingSession session) => session.filePath)
        .where((String path) => path.isNotEmpty)
        .toSet()
        .toList(growable: false);
    unawaited(_measureLocalRecordingStatsAsync(paths, generation));
  }

  ({int bytes, Set<String> paths})? _localRecordingStatsFromPages() {
    if (_localPages.isEmpty ||
        _localPages.values.any(
          (LocalRecordingPage page) => page.availableFileBytesById == null,
        )) {
      return null;
    }
    int bytes = 0;
    final Set<String> paths = <String>{};
    for (final LocalRecordingPage page in _localPages.values) {
      final Map<String, int> available = page.availableFileBytesById!;
      for (final RecordingSession session in page.data) {
        final int? fileBytes = available[session.id];
        if (fileBytes == null || session.filePath.isEmpty) continue;
        paths.add(session.filePath);
        bytes += fileBytes;
      }
    }
    return (bytes: bytes, paths: paths);
  }

  Future<void> _measureLocalRecordingStatsAsync(
    List<String> paths,
    int generation,
  ) async {
    int bytes = 0;
    final Set<String> existingPaths = <String>{};
    for (var offset = 0; offset < paths.length; offset += 4) {
      if (!mounted || generation != _localRecordingStatsGeneration) return;
      final List<String> batch = paths.sublist(
        offset,
        offset + 4 < paths.length ? offset + 4 : paths.length,
      );
      final List<({String path, bool exists, int bytes})> results =
          await Future.wait(
            batch.map((String path) async {
              final ({bool exists, int bytes}) result =
                  await _probeLocalRecordingFile(path);
              return (path: path, exists: result.exists, bytes: result.bytes);
            }),
          );
      for (final ({String path, bool exists, int bytes}) result in results) {
        if (!result.exists) continue;
        existingPaths.add(result.path);
        bytes += result.bytes;
      }
    }
    if (!mounted || generation != _localRecordingStatsGeneration) return;
    setState(() {
      _localRecordingBytes = bytes;
      _localRecordingPaths = existingPaths;
    });
  }

  Future<({bool exists, int bytes})> _probeLocalRecordingFile(
    String path,
  ) async {
    final LocalRecordingFileProbe? probe = widget.localRecordingFileProbe;
    if (probe != null) return probe(path);
    try {
      final FileStat stat = await File(path).stat();
      return (exists: stat.type == FileSystemEntityType.file, bytes: stat.size);
    } on FileSystemException {
      return (exists: false, bytes: 0);
    }
  }

  List<RecordingSession> get _existingLocalSessions => _sessions
      .where(
        (RecordingSession session) =>
            session.filePath.isNotEmpty &&
            _localRecordingPaths.contains(session.filePath),
      )
      .toList(growable: false);

  bool _isJobConfirmedAvailable(LanBackupJob job) {
    final String currentComputerId = _backupSnapshot.endpoint?.computerId ?? '';
    if (currentComputerId.isEmpty ||
        job.destinationComputerId != currentComputerId) {
      return false;
    }
    return _isJobKnownAvailable(job);
  }

  bool _isRemoteFromThisDevice(RemoteRecording recording) {
    final String deviceId = _backupSnapshot.deviceId.trim();
    return deviceId.isNotEmpty && recording.sourceDeviceId == deviceId;
  }

  String _recordingSourceLabel(RecordingHistoryItem item) {
    final RemoteRecording? remote = item.remote;
    if (remote != null) {
      if (remote.sourceType.toLowerCase() != 'external') {
        final String computerName = remote.sourceDeviceName.trim();
        if (computerName.isNotEmpty) return computerName;
        final String pairedComputerName =
            _backupSnapshot.endpoint?.computerName.trim() ?? '';
        if (pairedComputerName.isNotEmpty) return pairedComputerName;
        return '电脑';
      }
      final String remoteName = remote.sourceDeviceName.trim();
      if (remoteName.isNotEmpty) return remoteName;
    }
    final String currentDeviceName = _backupSnapshot.deviceName.trim();
    if (item.local != null ||
        (remote != null && _isRemoteFromThisDevice(remote))) {
      return currentDeviceName.isEmpty ? '手机' : currentDeviceName;
    }
    return '手机';
  }

  String _recordingSourceIdentity(RecordingHistoryItem item) {
    final RemoteRecording? remote = item.remote;
    if (remote != null) {
      if (remote.sourceType.toLowerCase() != 'external') return 'computer';
      final String remoteDeviceId = remote.sourceDeviceId.trim();
      if (remoteDeviceId.isNotEmpty) return remoteDeviceId;
      final String remoteDeviceName = remote.sourceDeviceName.trim();
      if (remoteDeviceName.isNotEmpty) return remoteDeviceName;
    }
    final String currentDeviceId = _backupSnapshot.deviceId.trim();
    if (currentDeviceId.isNotEmpty) return currentDeviceId;
    final String currentDeviceName = _backupSnapshot.deviceName.trim();
    return currentDeviceName.isEmpty ? 'mobile' : currentDeviceName;
  }

  bool _isJobKnownAvailable(LanBackupJob job) {
    final int? remoteRecordId = job.remoteRecordId;
    if (job.state != LanBackupJobState.completed || remoteRecordId == null) {
      return false;
    }
    final status = _remoteStatuses[remoteRecordId];
    return status == null ||
        (status.status == RemoteRecordingStatus.available && status.exists);
  }
}

bool _sameSessionSnapshot(
  List<RecordingSession> first,
  List<RecordingSession> second,
) {
  if (identical(first, second)) return true;
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    final RecordingSession left = first[index];
    final RecordingSession right = second[index];
    if (left.id != right.id ||
        left.filePath != right.filePath ||
        left.startedAt != right.startedAt ||
        left.endedAt != right.endedAt ||
        left.mediaStart != right.mediaStart ||
        left.mediaEnd != right.mediaEnd) {
      return false;
    }
  }
  return true;
}
