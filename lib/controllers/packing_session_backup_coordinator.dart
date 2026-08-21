part of 'packing_session_controller.dart';

/// 协调本地录像仓库与局域网备份队列，不负责配对 UI、远程播放或录像生成。
mixin _PackingSessionBackupCoordinator on ChangeNotifier {
  SessionRepository get _repository;
  LanBackupSink get _lanBackupService;
  DiagnosticsLogService get _runtimeLog;
  List<RecordingSession> get _sessions;
  set _sessions(List<RecordingSession> value);
  set _unbackedRetention(UnbackedRetentionPolicy value);
  set _backedRetention(BackedRetentionPolicy value);
  bool get _disposed;

  final Set<String> _handledDeletedBackupJobs = <String>{};

  void _runInBackground(Future<void> task);
  Future<void> _refreshLocalStatistics();

  Future<void> setLanBackupAutoEnabled(bool enabled) async {
    await _lanBackupService.setAutoEnabled(enabled);
    await _repository.saveLanBackupAutoEnabled(enabled);
    if (enabled) {
      await _backupAllRepositorySessions('auto_toggle_enabled');
    }
  }

  Future<void> setBackupRetention({
    required UnbackedRetentionPolicy unbacked,
    required BackedRetentionPolicy backed,
  }) async {
    _unbackedRetention = unbacked;
    _backedRetention = backed;
    notifyListeners();
    await _lanBackupService.setRetentionPolicies(
      unbacked: unbacked,
      backed: backed,
    );
    await _repository.saveBackupRetention(unbacked: unbacked, backed: backed);
  }

  Future<void> backupAllSessions() => _backupAllRepositorySessions('manual');

  Future<void> retryBackupConnection() async {
    final bool connected = await _lanBackupService.retryConnection();
    if (connected && _lanBackupService.snapshot.autoEnabled) {
      await _backupAllRepositorySessions('connection_restored');
    }
  }

  Future<void> _enqueueBackupIfNeeded(
    String filePath,
    List<RecordingSession> sessions,
  ) async {
    final List<RecordingSession> finalized = sessions
        .where(
          (RecordingSession session) =>
              session.watermarkStatus == WatermarkProcessingStatus.completed,
        )
        .toList(growable: false);
    if (finalized.isEmpty) return;
    try {
      await _lanBackupService.enqueueFinalizedFile(filePath, finalized);
    } on Object catch (error) {
      // broad-catch: Local recording persistence has already succeeded; backup
      // enqueue failure is diagnostic-only and must not fail the saved recording.
      unawaited(
        _runtimeLog.log(
          kind: 'backup_enqueue_failed',
          extra: <String, Object?>{
            'filePath': filePath,
            'sessionCount': sessions.length,
            'autoEnabled': _lanBackupService.snapshot.autoEnabled,
            'error': error.toString(),
          },
        ),
      );
    }
  }

  void _handleBackupChanged() {
    final List<LanBackupJob> newlyDeletedJobs = _lanBackupService.snapshot.jobs
        .where((LanBackupJob job) => job.localDeletedAt != null)
        .where(
          (LanBackupJob job) => !_handledDeletedBackupJobs.contains(job.id),
        )
        .toList(growable: false);
    if (newlyDeletedJobs.isNotEmpty) {
      _handledDeletedBackupJobs.addAll(
        newlyDeletedJobs.map((LanBackupJob job) => job.id),
      );
      _runInBackground(_recordDeletedBackupJobs(newlyDeletedJobs));
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> _recordDeletedBackupJobs(List<LanBackupJob> jobs) async {
    for (final LanBackupJob job in jobs) {
      try {
        await _repository.recordAutomaticCleanup(
          eventId: job.id,
          filePath: job.filePath,
          fileSizeBytes: job.totalBytes,
          deletedAt: job.localDeletedAt!,
          reason:
              job.cleanupReason ??
              (job.backupCompletedAt == null ? '未备份录像保留策略清理' : '已备份录像保留策略清理'),
        );
      } on Object {
        // broad-catch: Keep the cleanup job retryable when history persistence fails.
        _handledDeletedBackupJobs.remove(job.id);
      }
    }
    await _pruneDeletedBackupSessions();
  }

  Future<void> _backupAllRepositorySessions(String reason) async {
    unawaited(
      _runtimeLog.log(
        kind: 'backup_all',
        extra: <String, Object?>{'reason': reason},
      ),
    );
    if (reason == 'app_start') {
      await _processStartupBackupIncrement(
        (List<RecordingSession> sessions) =>
            _lanBackupService.backupAll(sessions, forceRestart: false),
      );
      return;
    }
    await _forEachRepositoryBackupBatch(
      (List<RecordingSession> sessions) => _lanBackupService.backupAll(
        sessions,
        forceRestart: lanBackupForceRestartForReason(reason),
      ),
    );
  }

  Future<void> _registerRepositorySessionsForRetention() =>
      _processStartupBackupIncrement(_registerSessionsForRetention);

  Future<void> _processStartupBackupIncrement(
    Future<void> Function(List<RecordingSession> sessions) action,
  ) async {
    try {
      final BackupRegistrationCursor? cursor = await _repository
          .loadBackupRegistrationCursor();
      final BackupRegistrationCursor? highWatermark = await _repository
          .loadBackupRegistrationHighWatermark();
      if (highWatermark == null) {
        return;
      }
      BackupRegistrationCursor? after = cursor;
      while (true) {
        if (_disposed) return;
        final BackupIncrementPage? page = await _repository.loadBackupIncrement(
          after: after,
          highWatermark: highWatermark,
        );
        if (page == null) {
          await _repository.saveBackupRegistrationCursor(highWatermark);
          return;
        }
        await action(page.sessions);
        after = page.nextAfter;
      }
    } on Object catch (error) {
      // broad-catch: Startup backup registration is best-effort; log failures so
      // a later startup or manual backup can retry without blocking app launch.
      unawaited(
        _runtimeLog.log(
          kind: 'backup_increment_failed',
          extra: <String, Object?>{'error': error.toString()},
        ),
      );
    }
  }

  @visibleForTesting
  Future<void> processStartupBackupIncrementForTesting(
    Future<void> Function(List<RecordingSession> sessions) action,
  ) => _processStartupBackupIncrement(action);

  Future<void> _forEachRepositoryBackupBatch(
    Future<void> Function(List<RecordingSession> sessions) action,
  ) async {
    var page = 1;
    while (!_disposed) {
      final List<RecordingSession> sessions = await _repository.loadBackupBatch(
        page: page,
      );
      if (sessions.isEmpty) return;
      await action(sessions);
      page++;
    }
  }

  Future<void> _registerSessionsForRetention(
    List<RecordingSession> sessions,
  ) async {
    final Map<String, List<RecordingSession>> grouped =
        <String, List<RecordingSession>>{};
    final Map<String, LanBackupJob> jobsByFile = _backupJobsByFile();
    for (final RecordingSession session in sessions) {
      final FileStat stat;
      try {
        stat = await File(session.filePath).stat();
      } on FileSystemException {
        continue;
      }
      if (stat.type == FileSystemEntityType.notFound || stat.size <= 0) {
        continue;
      }
      if (_hasRegisteredRetentionJob(session.filePath, stat, jobsByFile)) {
        continue;
      }
      grouped[session.filePath] = <RecordingSession>[session];
    }
    await _lanBackupService.enqueueFinalizedFiles(grouped);
  }

  Map<String, LanBackupJob> _backupJobsByFile() {
    final Map<String, LanBackupJob> jobs = <String, LanBackupJob>{};
    for (final LanBackupJob job in _lanBackupService.snapshot.jobs) {
      jobs.putIfAbsent(lanBackupFileIdentity(job.filePath), () => job);
    }
    return jobs;
  }

  bool _hasRegisteredRetentionJob(
    String filePath,
    FileStat stat,
    Map<String, LanBackupJob> jobsByFile,
  ) {
    final LanBackupJob? job = jobsByFile[lanBackupFileIdentity(filePath)];
    return job != null &&
        job.totalBytes == stat.size &&
        (job.lastModified?.millisecondsSinceEpoch ?? -1) ==
            stat.modified.millisecondsSinceEpoch;
  }

  Future<void> _pruneDeletedBackupSessions({bool notify = true}) async {
    final List<LanBackupJob> deletedBackupJobs = _lanBackupService.snapshot.jobs
        .where(
          (LanBackupJob job) =>
              job.state == LanBackupJobState.completed &&
              job.localDeletedAt != null,
        )
        .toList(growable: false);
    final Set<String> deletedBackupPaths = deletedBackupJobs
        .map((LanBackupJob job) => lanBackupFileIdentity(job.filePath))
        .toSet();
    final Set<String> backedPaths = _sessions
        .where(
          (RecordingSession session) => deletedBackupPaths.contains(
            lanBackupFileIdentity(session.filePath),
          ),
        )
        .map((RecordingSession session) => session.filePath)
        .toSet();
    _sessions = await _repository.pruneMissingSessions(
      retainedMissingPaths: backedPaths,
    );
    await _refreshLocalStatistics();
    if (notify && !_disposed) notifyListeners();
  }
}

bool lanBackupForceRestartForReason(String reason) => reason == 'manual';
