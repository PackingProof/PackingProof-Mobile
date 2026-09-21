part of 'packing_session_controller.dart';

mixin _PackingSessionStorageCoordinator on _PackingSessionBackupCoordinator {
  bool get isWorking;
  bool get isBusy;
  CameraDiagnosticsService get _cameraDiagnostics;
  Future<RecordingSession?> stopWork();

  Timer? _storageMonitorTimer;
  String? _storageWarningMessage;
  bool _storageCheckRunning = false;
  StorageSpaceResult? _lastStorageResult;
  int _queuedStorageNoticePriority = -1;
  StorageNotice? _storageNoticeToShow;
  int _storageNoticeRevision = 0;
  bool _storageStopRequested = false;
  Future<void>? _storageStopFuture;

  bool get _cachedStorageInsufficient =>
      _lastStorageResult?.insufficient == true;

  StorageNotice? takeStorageNoticeForDisplay() {
    final StorageNotice? notice = _storageNoticeToShow;
    _storageNoticeToShow = null;
    return notice;
  }

  void _startStorageMonitor() {
    _storageMonitorTimer?.cancel();
    _storageMonitorTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _runInBackground(_checkStorageWhileWorking()),
    );
  }

  void _stopStorageMonitor() {
    _storageMonitorTimer?.cancel();
    _storageMonitorTimer = null;
  }

  /// 工作期间巡检：先尽力回收，确实腾不出空间才停止录像。
  Future<StorageSpaceResult> _checkStorageWhileWorking() async {
    final StorageSpaceResult result = await _reclaimStorage();
    if (result.insufficient && isWorking) {
      await _requestStorageStopWhenIdle();
    }
    return result;
  }

  /// 回收空间：一次没清够就继续清，直到够用、没有进展或达到轮次上限。录像普遍只有
  /// 几十兆，单次回收常常只能腾出一部分；确实腾不出空间时才提示人工处理。
  Future<StorageSpaceResult> _reclaimStorage() async {
    StorageSpaceResult result = await _reclaimStorageOnce();
    for (
      int round = 1;
      round < 3 && result.insufficient && result.deletedCount > 0;
      round++
    ) {
      result = await _reclaimStorageOnce();
    }
    if (result.insufficient) {
      await _queueStorageNotice(
        const StorageNotice(
          severity: StorageNoticeSeverity.stopped,
          message: '已备份录像不足以释放空间，录像已停止。请清理手机空间或连接电脑完成备份',
        ),
      );
      _storageWarningMessage =
          '存储空间不足 ${BackupStoragePolicy.minimumLabel}，正在停止录像';
      if (!_disposed) notifyListeners();
    }
    return result;
  }

  /// 已知空间不足时先回收，回收不出空间才放弃当前切段。
  Future<bool> _ensureStorageForSegment() async {
    if (!_cachedStorageInsufficient) return true;
    return !(await _reclaimStorage()).insufficient;
  }

  /// 相机在剩余空间不足时拒绝切段。这里先立即回收空间再重试一次，避免因为一次
  /// 存储抖动就丢掉这一段；回收不出空间时把原错误交回上层处理。
  Future<NativeRecordingSplit> _splitNativeWithStorageRecovery(
    ContinuousCameraService camera,
    String nextPath,
    String code,
  ) async {
    try {
      return await camera.split(nextPath, trackingNumber: code);
    } on PlatformException catch (error) {
      if (error.code != 'storage_low') rethrow;
      final StorageSpaceResult result = await _reclaimStorage();
      if (result.insufficient) rethrow;
      return await camera.split(nextPath, trackingNumber: code);
    }
  }

  /// 单次检查与回收；不做停止决定，空间是否够用、要不要停由调用方判断。
  Future<StorageSpaceResult> _reclaimStorageOnce() async {
    if (_storageCheckRunning || _disposed) {
      return const StorageSpaceResult(
        availableBytes: 1 << 62,
        availableBytesBefore: 1 << 62,
        freedBytes: 0,
        deletedCount: 0,
        warning: false,
        insufficient: false,
      );
    }
    _storageCheckRunning = true;
    try {
      final StorageSpaceResult result = await _lanBackupService
          .checkAndReclaimStorage();
      _lastStorageResult = result;
      if (result.deletedCount > 0) {
        final String message =
            '存储空间不足，已提前清理 ${result.deletedCount} 个已备份录像，'
            '释放 ${BackupStoragePolicy.label(result.freedBytes)}。建议缩短本机保留时间';
        await _queueStorageNotice(
          StorageNotice(
            severity: StorageNoticeSeverity.reclaimed,
            message: message,
          ),
        );
        _storageWarningMessage = '空间不足，已清理已备份录像';
      } else if (result.warning) {
        await _queueStorageNotice(
          StorageNotice(
            severity: StorageNoticeSeverity.warning,
            message:
                '手机剩余空间不足 ${BackupStoragePolicy.warningLabel}，'
                '建议连接电脑备份或缩短本机录像保留时间',
          ),
        );
        _storageWarningMessage = '手机存储空间不足 ${BackupStoragePolicy.warningLabel}';
      }
      if (!result.insufficient &&
          !_disposed &&
          (result.deletedCount > 0 || result.warning)) {
        notifyListeners();
      }
      return result;
    } on Object {
      // broad-catch: Storage inspection failure must not delete files or stop
      // an otherwise healthy recording; the next periodic check retries it.
      return const StorageSpaceResult(
        availableBytes: 1 << 62,
        availableBytesBefore: 1 << 62,
        freedBytes: 0,
        deletedCount: 0,
        warning: false,
        insufficient: false,
      );
    } finally {
      _storageCheckRunning = false;
    }
  }

  Future<void> _queueStorageNotice(StorageNotice notice) async {
    if (notice.priority <= _queuedStorageNoticePriority) return;
    _queuedStorageNoticePriority = notice.priority;
    await _repository.queueStorageNotice(notice);
  }

  Future<void> _handleNativeStorageCritical() async {
    unawaited(_cameraDiagnostics.recordEvent(kind: 'storage_critical'));
    _runInBackground(_reclaimStorage());
    await _queueStorageNotice(
      const StorageNotice(
        severity: StorageNoticeSeverity.stopped,
        message: '存储空间不足导致录像写入失败，当前录像已停止。请清理手机空间或连接电脑完成备份',
      ),
    );
    _storageWarningMessage = '存储空间不足，正在停止录像';
    if (!_disposed) notifyListeners();
    if (isWorking) await _requestStorageStopWhenIdle();
  }

  Future<void> _requestStorageStopWhenIdle() {
    final Future<void>? pending = _storageStopFuture;
    if (pending != null) return pending;
    late final Future<void> task;
    task = _stopForStorageWhenIdle().whenComplete(() {
      if (identical(_storageStopFuture, task)) _storageStopFuture = null;
    });
    _storageStopFuture = task;
    return task;
  }

  Future<void> _stopForStorageWhenIdle() async {
    if (_disposed || !isWorking) return;
    while (!_disposed && isWorking && isBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_disposed || !isWorking || _storageStopRequested) return;
    _storageStopRequested = true;
    try {
      await stopWork();
    } finally {
      _storageStopRequested = false;
    }
  }

  Future<void> _releaseStorageNoticeAfterWork() async {
    final StorageNotice? notice = await _repository.takeStorageNoticeAfterWork(
      DateTime.now(),
    );
    _storageWarningMessage = null;
    if (notice == null || _disposed) return;
    _storageNoticeToShow = notice;
    _storageNoticeRevision++;
    notifyListeners();
  }

  @visibleForTesting
  Future<StorageSpaceResult> checkStorageForTesting() => _reclaimStorageOnce();

  @visibleForTesting
  Future<StorageSpaceResult> checkStorageWhileWorkingForTesting() =>
      _checkStorageWhileWorking();
}
