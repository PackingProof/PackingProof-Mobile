part of 'packing_session_controller.dart';

mixin _PackingSessionStorageCoordinator on _PackingSessionBackupCoordinator {
  bool get isWorking;
  bool get isBusy;
  CameraDiagnosticsService get _cameraDiagnostics;
  Future<RecordingSession?> stopWork();

  Timer? _storageMonitorTimer;
  String? _storageWarningMessage;
  bool _storageCheckRunning = false;
  int _queuedStorageNoticePriority = -1;
  StorageNotice? _storageNoticeToShow;
  int _storageNoticeRevision = 0;
  bool _storageStopRequested = false;

  StorageNotice? takeStorageNoticeForDisplay() {
    final StorageNotice? notice = _storageNoticeToShow;
    _storageNoticeToShow = null;
    return notice;
  }

  void _startStorageMonitor() {
    _storageMonitorTimer?.cancel();
    _storageMonitorTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _runInBackground(_checkAndHandleStorage(allowStop: true)),
    );
  }

  void _stopStorageMonitor() {
    _storageMonitorTimer?.cancel();
    _storageMonitorTimer = null;
  }

  Future<StorageSpaceResult> _checkAndHandleStorage({
    required bool allowStop,
  }) async {
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
      if (result.deletedCount > 0) {
        final String message =
            '存储空间不足，已提前清理 ${result.deletedCount} 个已备份录像，'
            '释放 ${_formatStorageBytes(result.freedBytes)}。建议缩短本机保留时间';
        await _queueStorageNotice(
          StorageNotice(
            severity: StorageNoticeSeverity.reclaimed,
            message: message,
          ),
        );
        _storageWarningMessage = '空间不足，已清理已备份录像';
      } else if (result.warning) {
        await _queueStorageNotice(
          const StorageNotice(
            severity: StorageNoticeSeverity.warning,
            message: '手机剩余空间不足 3GB，建议连接电脑备份或缩短本机录像保留时间',
          ),
        );
        _storageWarningMessage = '手机存储空间不足 3GB';
      }
      if (result.insufficient) {
        await _queueStorageNotice(
          const StorageNotice(
            severity: StorageNoticeSeverity.stopped,
            message: '已备份录像不足以释放空间，录像已停止。请清理手机空间或连接电脑完成备份',
          ),
        );
        _storageWarningMessage = '存储空间不足 2GB，正在停止录像';
        notifyListeners();
        if (allowStop && isWorking && !isBusy) {
          _storageStopRequested = true;
          try {
            await stopWork();
          } finally {
            _storageStopRequested = false;
          }
        }
      } else if (!_disposed) {
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
    await _checkAndHandleStorage(allowStop: false);
    await _queueStorageNotice(
      const StorageNotice(
        severity: StorageNoticeSeverity.stopped,
        message: '存储空间不足导致录像写入失败，当前录像已停止。请清理手机空间或连接电脑完成备份',
      ),
    );
    _storageWarningMessage = '存储空间不足，正在停止录像';
    if (!_disposed) notifyListeners();
    if (!isWorking || isBusy) return;
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

  static String _formatStorageBytes(int bytes) {
    final double gigabytes = bytes / (1024 * 1024 * 1024);
    if (gigabytes >= 1) return '${gigabytes.toStringAsFixed(1)}GB';
    return '${(bytes / (1024 * 1024)).round()}MB';
  }
}
