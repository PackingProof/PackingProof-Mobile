part of 'packing_session_controller.dart';

/// 协调本地录像仓库与局域网备份队列，不负责配对 UI、远程播放或录像生成。
mixin _PackingSessionBackupCoordinator on ChangeNotifier {
  SessionRepository get _repository;
  LanBackupSink get _lanBackupService;
  DiagnosticsLogService get _runtimeLog;
  // Declared for mixins constrained by this coordinator.
  // ignore: unused_element
  List<RecordingSession> get _sessions;
  set _sessions(List<RecordingSession> value);
  set _unbackedRetention(UnbackedRetentionPolicy value);
  set _backedRetention(BackedRetentionPolicy value);
  set _returnUnbackedRetention(UnbackedRetentionPolicy value);
  set _returnBackedRetention(BackedRetentionPolicy value);
  bool get _disposed;

  /// 空间不足时的取舍策略（设置项，默认优先保留录像）。
  StoragePressurePolicy _storagePressurePolicy =
      StoragePressurePolicy.preserveFootage;
  bool _cleanupDrainRunning = false;
  bool _cleanupCursorLoaded = false;
  int _cleanupAfterRevision = 0;
  Future<void> _repositoryBackupTail = Future<void>.value();
  bool _automaticBackupBootstrapRunning = false;
  bool _automaticFullBackupPending = false;
  bool _automaticIncrementalBackupPending = false;
  int _automaticBackupGeneration = 0;
  String _automaticFullBackupReason = 'automatic';
  String _automaticIncrementalBackupReason = 'app_start';
  bool _autoRetrySweepRunning = false;
  DateTime? _lastAutoRetrySweepAt;
  Timer? _autoRetrySweepTimer;

  /// 整文件重传类失败的自动重排计数：任务一旦有进展（或需要人工处理）就清空。
  final Map<String, int> _limitedAutoRetryAttempts = <String, int>{};

  /// 自动重传扫描的节流与单轮上限：暂停任务重新排队后会变成待上传，
  /// 下一轮自然处理后面的任务。
  static const Duration _autoRetrySweepInterval = Duration(seconds: 30);
  static const int _autoRetrySweepLimit = 20;

  /// 节流间隔在测试里需要缩短，才能覆盖「节流窗口内的请求会被补扫」。
  @visibleForTesting
  Duration autoRetrySweepIntervalForTesting = _autoRetrySweepInterval;

  void _runInBackground(Future<void> task);
  Future<void> _refreshLocalStatistics();

  Future<void> setLanBackupAutoEnabled(bool enabled) async {
    await _lanBackupService.setAutoEnabled(enabled);
    await _repository.saveLanBackupAutoEnabled(enabled);
    if (enabled) {
      _scheduleAutomaticBackupBootstrap('auto_toggle_enabled');
    } else {
      _automaticBackupGeneration++;
      _automaticFullBackupPending = false;
      _automaticIncrementalBackupPending = false;
    }
  }

  Future<void> setBackupRetention({
    required UnbackedRetentionPolicy unbacked,
    required BackedRetentionPolicy backed,
    required UnbackedRetentionPolicy returnUnbacked,
    required BackedRetentionPolicy returnBacked,
    StoragePressurePolicy storagePressurePolicy =
        StoragePressurePolicy.preserveFootage,
  }) async {
    _unbackedRetention = unbacked;
    _backedRetention = backed;
    _returnUnbackedRetention = returnUnbacked;
    _returnBackedRetention = returnBacked;
    _storagePressurePolicy = storagePressurePolicy;
    notifyListeners();
    await _lanBackupService.setRetentionPolicies(
      unbacked: unbacked,
      backed: backed,
      returnUnbacked: returnUnbacked,
      returnBacked: returnBacked,
      storagePressurePolicy: storagePressurePolicy,
    );
    await _repository.saveBackupRetention(
      unbacked: unbacked,
      backed: backed,
      returnUnbacked: returnUnbacked,
      returnBacked: returnBacked,
      storagePressurePolicy: storagePressurePolicy,
    );
  }

  /// 初始化备份服务并下发保留与存储策略；控制器已释放时返回 false。
  Future<bool> _initializeBackupService(AppSettings settings) async {
    try {
      await _lanBackupService
          .initialize(
            autoEnabled: settings.lanBackupAutoEnabled,
            unbackedRetention: settings.unbackedRetention,
            backedRetention: settings.backedRetention,
            returnUnbackedRetention: settings.returnUnbackedRetention,
            returnBackedRetention: settings.returnBackedRetention,
            storagePressurePolicy: _storagePressurePolicy,
          )
          .timeout(const Duration(seconds: 8));
    } on Object catch (error) {
      // 备份服务初始化失败不影响摄像头；记录原因，服务侧看门狗会自愈重试。
      unawaited(
        _runtimeLog.log(
          kind: 'backup_service_init_failed',
          extra: <String, Object?>{'error': error.toString()},
        ),
      );
    }
    return !_disposed;
  }

  Future<void> backupAllSessions() =>
      _serializeRepositoryBackup(() => _backupAllRepositorySessions('manual'));

  Future<LanBackupJobsByPaths> loadBackupJobsForPaths(Iterable<String> paths) =>
      _lanBackupService.jobsForPaths(paths);

  Future<void> retryBackupConnection() async {
    final bool connected = await _lanBackupService.retryConnection();
    if (connected && _lanBackupService.snapshot.autoEnabled) {
      _scheduleAutomaticBackupBootstrap('connection_restored');
    }
  }

  void _scheduleAutomaticBackupBootstrap(String reason) {
    if (reason == 'app_start') {
      _automaticIncrementalBackupPending = true;
      _automaticIncrementalBackupReason = reason;
    } else {
      _automaticFullBackupPending = true;
      _automaticFullBackupReason = reason;
    }
    if (_automaticBackupBootstrapRunning) return;
    _automaticBackupBootstrapRunning = true;
    _runInBackground(_drainAutomaticBackupBootstrap());
  }

  Future<void> _drainAutomaticBackupBootstrap() async {
    try {
      while (!_disposed &&
          (_automaticFullBackupPending || _automaticIncrementalBackupPending)) {
        final bool full = _automaticFullBackupPending;
        final String reason = full
            ? _automaticFullBackupReason
            : _automaticIncrementalBackupReason;
        final int generation = _automaticBackupGeneration;
        if (full) {
          // 全量扫描覆盖当前待处理的启动增量；扫描期间到达的新请求仍会
          // 重新置位并在下一轮处理。
          _automaticFullBackupPending = false;
          _automaticIncrementalBackupPending = false;
        } else {
          _automaticIncrementalBackupPending = false;
        }
        await _serializeRepositoryBackup(
          () => _backupAutomaticRepositorySessions(reason, generation),
        );
      }
    } finally {
      _automaticBackupBootstrapRunning = false;
      if (!_disposed &&
          (_automaticFullBackupPending || _automaticIncrementalBackupPending)) {
        _automaticBackupBootstrapRunning = true;
        _runInBackground(_drainAutomaticBackupBootstrap());
      }
    }
  }

  Future<void> _serializeRepositoryBackup(Future<void> Function() action) {
    final Future<void> next = _repositoryBackupTail.then((_) => action());
    _repositoryBackupTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _backupAutomaticRepositorySessions(
    String reason,
    int generation,
  ) async {
    bool shouldContinue() =>
        !_disposed &&
        _lanBackupService.snapshot.autoEnabled &&
        generation == _automaticBackupGeneration;
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
        shouldContinue: shouldContinue,
      );
      return;
    }
    await _forEachRepositoryBackupBatch(
      (List<RecordingSession> sessions) =>
          _lanBackupService.backupAll(sessions, forceRestart: false),
      shouldContinue: shouldContinue,
    );
  }

  @visibleForTesting
  void scheduleAutomaticBackupBootstrapForTesting(String reason) =>
      _scheduleAutomaticBackupBootstrap(reason);

  @visibleForTesting
  Future<void> waitForAutomaticBackupBootstrapForTesting() async {
    while (_automaticBackupBootstrapRunning) {
      await _repositoryBackupTail;
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 等待进行中的自动重排巡检结束：巡检会读写仓库文件，测试清理临时目录前
  /// 必须先等它收尾，否则 Windows 上会因文件仍被占用而删除失败。
  @visibleForTesting
  Future<void> waitForAutoRetrySweepForTesting() async {
    while (_autoRetrySweepRunning) {
      await _repositoryBackupTail;
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _enqueueBackupIfNeeded(
    String filePath,
    List<RecordingSession> sessions,
  ) async {
    final List<RecordingSession> finalized = sessions
        .where(
          (RecordingSession session) =>
              session.watermarkStatus != WatermarkProcessingStatus.pending &&
              session.watermarkStatus != WatermarkProcessingStatus.processing,
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
    if (_lanBackupService.snapshot.summary.cleanupHighWatermark >
            _cleanupAfterRevision &&
        !_cleanupDrainRunning) {
      _runInBackground(_drainCleanupEvents());
    }
    _scheduleAutoRetrySweep();
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _scheduleAutoRetrySweep() {
    if (_disposed || _autoRetrySweepRunning) return;
    final LanBackupSnapshot snapshot = _lanBackupService.snapshot;
    if (!snapshot.autoEnabled ||
        snapshot.connectionStatus != LanConnectionStatus.connected) {
      _cancelAutoRetrySweepTimer();
      return;
    }
    final DateTime now = DateTime.now();
    final DateTime? last = _lastAutoRetrySweepAt;
    final Duration interval = autoRetrySweepIntervalForTesting;
    if (last != null && now.difference(last) < interval) {
      // 节流窗口内到达的请求不能直接丢掉：补一次定时扫描，否则暂停任务要等到
      // 下一次备份事件（可能很久都不来）才会恢复。
      _scheduleAutoRetrySweepTimer(interval - now.difference(last));
      return;
    }
    _cancelAutoRetrySweepTimer();
    _lastAutoRetrySweepAt = now;
    _autoRetrySweepRunning = true;
    _runInBackground(
      _retryAutoRecoverableBackupFailures().whenComplete(() {
        _autoRetrySweepRunning = false;
      }),
    );
  }

  void _scheduleAutoRetrySweepTimer(Duration delay) {
    if (_disposed || _autoRetrySweepTimer != null) return;
    _autoRetrySweepTimer = Timer(delay, () {
      _autoRetrySweepTimer = null;
      if (_disposed) return;
      _scheduleAutoRetrySweep();
    });
  }

  void _cancelAutoRetrySweepTimer() {
    _autoRetrySweepTimer?.cancel();
    _autoRetrySweepTimer = null;
  }

  @override
  void dispose() {
    _cancelAutoRetrySweepTimer();
    super.dispose();
  }

  @visibleForTesting
  Future<void> runAutoRetrySweepForTesting() =>
      _retryAutoRecoverableBackupFailures();

  /// Android 由 WorkManager 自动重试暂时性失败；iOS 失败后只停在暂停态，所以这里在
  /// 电脑连上时把可自动恢复的暂停任务重新排队，避免老视频永远不再上传。
  Future<void> _retryAutoRecoverableBackupFailures() async {
    int retried = 0;
    try {
      await _forEachRepositoryBackupBatch(
        (List<RecordingSession> sessions) async {
          if (retried >= _autoRetrySweepLimit) return;
          final LanBackupJobsByPaths result = await _lanBackupService
              .jobsForPaths(
                sessions.map((RecordingSession session) => session.filePath),
              );
          for (final LanBackupJob job in result.jobs) {
            if (retried >= _autoRetrySweepLimit) break;
            if (!_shouldAutoRetryBackupJob(job)) {
              // 任务已经有进展或需要人工处理，下一次再排队时重新给足重试预算。
              _limitedAutoRetryAttempts.remove(job.id);
              continue;
            }
            if (!_reserveLimitedAutoRetryAttempt(job)) continue;
            retried++;
            await _lanBackupService.retry(job.id);
          }
        },
        shouldContinue: () => !_disposed,
        materializeSessionFiles: false,
      );
    } on Object catch (error) {
      // broad-catch: 自动重传是尽力而为，失败不能影响预览、录像或手动备份。
      unawaited(
        _runtimeLog.log(
          kind: 'backup_auto_retry_failed',
          extra: <String, Object?>{'error': error.toString()},
        ),
      );
    }
    if (retried > 0) {
      unawaited(
        _runtimeLog.log(
          kind: 'backup_auto_retry',
          extra: <String, Object?>{'count': retried},
        ),
      );
    }
  }

  bool _shouldAutoRetryBackupJob(LanBackupJob job) {
    if (job.localDeletedAt != null) return false;
    if (job.state != LanBackupJobState.paused &&
        job.state != LanBackupJobState.failed) {
      return false;
    }
    final LanBackupFailureKind? kind = job.failureKind;
    // 没有失败原因的暂停任务来自旧版本「仅登记也写成 paused」的问题（或自动备份关闭时
    // 登记的任务）：自动备份已经开启时应当恢复上传。
    return kind == null || kind.autoRetryable || kind.limitedAutoRetryable;
  }

  /// 整文件重传类失败（上传任务过期、校验失败、未分类失败）每个任务每个周期只
  /// 自动重排 [lanBackupAutoRetryAttemptLimit] 次，避免坏文件反复吃掉流量；超过后
  /// 仍保留设置页的人工「重试备份」入口。
  bool _reserveLimitedAutoRetryAttempt(LanBackupJob job) {
    final LanBackupFailureKind? kind = job.failureKind;
    if (kind == null || !kind.limitedAutoRetryable) return true;
    final int attempts = _limitedAutoRetryAttempts[job.id] ?? 0;
    if (attempts >= lanBackupAutoRetryAttemptLimit) return false;
    _limitedAutoRetryAttempts[job.id] = attempts + 1;
    return true;
  }

  Future<void> _drainCleanupEvents() async {
    if (_cleanupDrainRunning) return;
    _cleanupDrainRunning = true;
    var changed = false;
    try {
      if (!_cleanupCursorLoaded) {
        _cleanupAfterRevision = await _repository.loadBackupCleanupCursor();
        _cleanupCursorLoaded = true;
      }
      if (_cleanupAfterRevision > 0) {
        await _lanBackupService.acknowledgeCleanupEvents(_cleanupAfterRevision);
      }
      while (!_disposed) {
        final LanBackupCleanupPage page = await _lanBackupService.cleanupEvents(
          afterRevision: _cleanupAfterRevision,
        );
        if (page.nextAfterRevision > _cleanupAfterRevision) {
          await _repository.recordAutomaticCleanupPage(
            events: page.events
                .map(
                  (LanBackupCleanupEvent event) => (
                    eventId: event.eventId,
                    filePath: event.filePath,
                    fileSizeBytes: event.fileSizeBytes,
                    deletedAt: event.deletedAt,
                    reason: event.reason,
                  ),
                )
                .toList(growable: false),
            nextAfterRevision: page.nextAfterRevision,
          );
          changed = changed || page.events.isNotEmpty;
          _cleanupAfterRevision = page.nextAfterRevision;
          await _lanBackupService.acknowledgeCleanupEvents(
            _cleanupAfterRevision,
          );
        }
        if (!page.hasMore) break;
        await Future<void>.delayed(Duration.zero);
      }
    } on Object catch (error) {
      unawaited(
        _runtimeLog.log(
          kind: 'backup_cleanup_reconcile_failed',
          extra: <String, Object?>{'error': error.toString()},
        ),
      );
    } finally {
      _cleanupDrainRunning = false;
    }
    if (changed) {
      await _refreshLocalStatistics();
      if (!_disposed) notifyListeners();
    }
  }

  @visibleForTesting
  Future<void> drainCleanupEventsForTesting() => _drainCleanupEvents();

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
    Future<void> Function(List<RecordingSession> sessions) action, {
    bool Function()? shouldContinue,
  }) async {
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
        if (_disposed || shouldContinue?.call() == false) return;
        final BackupIncrementPage? page = await _repository.loadBackupIncrement(
          after: after,
          highWatermark: highWatermark,
        );
        if (page == null) {
          await _repository.saveBackupRegistrationCursor(highWatermark);
          return;
        }
        await action(page.sessions);
        await _repository.saveBackupRegistrationCursor(page.nextAfter);
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

  /// 从第一条录像开始重扫整库的入口（自动重传与全量备份）。
  ///
  /// 每轮都从头覆盖，所以单条录像取不到原片时跳过该条即可；不能像增量游标那样
  /// 让一条本地已删除的旧录像挡住后面所有录像的排队与重传。
  /// [materializeSessionFiles] 为 false 时只解析路径，用于查找已有备份任务。
  Future<void> _forEachRepositoryBackupBatch(
    Future<void> Function(List<RecordingSession> sessions) action, {
    bool Function()? shouldContinue,
    bool materializeSessionFiles = true,
  }) async {
    final BackupRegistrationCursor? highWatermark = await _repository
        .loadBackupRegistrationHighWatermark();
    if (highWatermark == null) return;
    BackupRegistrationCursor? after;
    while (!_disposed && shouldContinue?.call() != false) {
      final BackupIncrementPage? page = await _repository.loadBackupIncrement(
        after: after,
        highWatermark: highWatermark,
        materializeSessionFiles: materializeSessionFiles,
        skipUnavailableSessions: true,
      );
      if (page == null) return;
      await action(page.sessions);
      after = page.nextAfter;
    }
  }

  Future<void> _registerSessionsForRetention(
    List<RecordingSession> sessions,
  ) async {
    final Map<String, List<RecordingSession>> grouped =
        <String, List<RecordingSession>>{};
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
      grouped[session.filePath] = <RecordingSession>[session];
    }
    await _lanBackupService.enqueueFinalizedFiles(grouped);
  }
}

bool lanBackupForceRestartForReason(String reason) => reason == 'manual';
