part of 'packing_session_controller.dart';

final class _WatermarkFinalizationPersistenceException implements Exception {
  const _WatermarkFinalizationPersistenceException();
}

final class _WatermarkFinalizationStateUnknownException implements Exception {
  const _WatermarkFinalizationStateUnknownException();
}

/// 发布水印成片并将最终可用文件衔接到备份队列。
mixin _PackingSessionWatermarkCoordinator on _PackingSessionStorageCoordinator {
  static const int _maximumWatermarkAttempts = 3;

  VideoWatermarkSink get _videoWatermarkService;
  ContinuousCameraInitialization? get _nativeInitialization;
  RecordingVideoCodec get _preferredVideoCodec;
  String _firstTrackingNumber(List<RecordingSession> sessions);
  final Set<String> _activeWatermarkSessionIds = <String>{};
  final Set<String> _queuedWatermarkResumeSessionIds = <String>{};

  Future<void> _watermarkAndBackup(
    String savedPath,
    RecordingSession session,
    RecordingOrientation recordingOrientation,
  ) async {
    if (!_activeWatermarkSessionIds.add(session.id)) return;
    final Stopwatch stopwatch = Stopwatch()..start();
    var processingSession = session;
    var inputBytes = 0;
    try {
      try {
        if (session.watermarkStatus == WatermarkProcessingStatus.pending) {
          final WatermarkAttemptClaim? claim = await _repository
              .claimPendingWatermarkAttempt(
                sessionId: session.id,
                expectedAttempt: session.watermarkAttemptCount,
                maximumAttempts: _maximumWatermarkAttempts,
              );
          if (claim == null || !claim.claimed) {
            _sessions = await _repository.loadSessions(
              includeMissingFiles: true,
            );
            await _logWatermarkEvent(
              kind: 'watermark_claim_skipped',
              extra: <String, Object?>{
                'sessionId': session.id,
                'attempt':
                    claim?.session.watermarkAttemptCount ??
                    session.watermarkAttemptCount,
                'exhausted': claim?.exhausted ?? false,
              },
            );
            if (!_disposed) notifyListeners();
            return;
          }
          processingSession = claim.session;
          _sessions = await _repository.loadSessions(includeMissingFiles: true);
        }
        inputBytes = await _watermarkFileBytes(savedPath);
        await _logWatermarkEvent(
          kind: 'watermark_started',
          extra: <String, Object?>{
            'sessionId': session.id,
            'orientation': recordingOrientation.storageValue,
            'inputBytes': inputBytes,
            'outputBytes': 0,
            'elapsedMs': 0,
            'attempt': processingSession.watermarkAttemptCount,
          },
        );
        final String trackingNumber = _firstTrackingNumber(<RecordingSession>[
          processingSession,
        ]);
        final String watermarkedPath =
            await (_videoWatermarkService is OrientedVideoWatermarkSink
                ? (_videoWatermarkService as OrientedVideoWatermarkSink)
                      .applyWithOrientation(
                        inputPath: savedPath,
                        startedAt: processingSession.startedAt,
                        trackingNumber: trackingNumber,
                        // 相机可能因设备不支持偏好编码而回退，水印必须跟随实际录制的编码。
                        videoCodec: recordingVideoCodecFromMime(
                          _nativeInitialization?.videoMime,
                          fallback: _preferredVideoCodec,
                        ),
                        recordingOrientation: recordingOrientation,
                      )
                : _videoWatermarkService.apply(
                    inputPath: savedPath,
                    startedAt: processingSession.startedAt,
                    trackingNumber: trackingNumber,
                    videoCodec: recordingVideoCodecFromMime(
                      _nativeInitialization?.videoMime,
                      fallback: _preferredVideoCodec,
                    ),
                  ));
        final String finalPath = await _repository.finalizeVideo(
          sourcePath: watermarkedPath,
          sessionId: processingSession.id,
          startedAt: processingSession.startedAt,
          trackingNumber: trackingNumber,
          operationMode: processingSession.operationMode,
        );
        final RecordingSession finalized = processingSession.copyWith(
          filePath: finalPath,
          watermarkStatus: WatermarkProcessingStatus.completed,
        );
        if (processingSession.watermarkStatus ==
            WatermarkProcessingStatus.pending) {
          try {
            _sessions = await _repository.updateSession(finalized);
          } on Object {
            // upsert 可能已提交、仅后续 recent reload 失败；先重读再决定补偿。
            late final List<RecordingSession> latestSessions;
            try {
              latestSessions = await _repository.loadSessions(
                includeMissingFiles: true,
              );
            } on Object {
              throw const _WatermarkFinalizationStateUnknownException();
            }
            final bool completedWasPersisted = latestSessions.any(
              (RecordingSession current) =>
                  current.id == finalized.id &&
                  current.filePath == finalPath &&
                  current.watermarkStatus ==
                      WatermarkProcessingStatus.completed,
            );
            if (completedWasPersisted) {
              _sessions = latestSessions;
            } else if (finalPath != savedPath) {
              // 只有确认 DB 未指向新成片时才清理，绝不删原片或状态不明的成片。
              try {
                await _repository.deleteFileIfUnreferenced(finalPath);
              } on Object {
                // 清理失败不覆盖“状态未落库”这一主故障，后续维护仍可识别孤立文件。
              }
            }
            if (!completedWasPersisted) {
              throw const _WatermarkFinalizationPersistenceException();
            }
          }
        }
        if (finalized.filePath != processingSession.filePath) {
          try {
            await _repository.deleteFileIfUnreferenced(savedPath);
          } on Object {
            await _logWatermarkEvent(
              kind: 'watermark_source_cleanup_failed',
              extra: <String, Object?>{
                'sessionId': finalized.id,
                'attempt': finalized.watermarkAttemptCount,
              },
            );
          }
        }
        stopwatch.stop();
        await _logWatermarkEvent(
          kind: 'watermark_completed',
          extra: <String, Object?>{
            'sessionId': session.id,
            'orientation': recordingOrientation.storageValue,
            'inputBytes': inputBytes,
            'outputBytes': await _watermarkFileBytes(finalPath),
            'elapsedMs': stopwatch.elapsedMilliseconds,
            'attempt': finalized.watermarkAttemptCount,
          },
        );
        await _enqueueBackupIfNeeded(finalPath, <RecordingSession>[finalized]);
      } on Object catch (error) {
        stopwatch.stop();
        if (error is _WatermarkFinalizationStateUnknownException) {
          await _logWatermarkEvent(
            kind: 'watermark_state_unknown',
            extra: <String, Object?>{
              'sessionId': session.id,
              'orientation': recordingOrientation.storageValue,
              'inputBytes': inputBytes,
              'outputBytes': 0,
              'elapsedMs': stopwatch.elapsedMilliseconds,
              'errorType': error.runtimeType.toString(),
              'attempt': processingSession.watermarkAttemptCount,
            },
          );
          if (!_disposed) notifyListeners();
          return;
        }
        final bool retryable = _isRetryableWatermarkError(error);
        final bool retryPending =
            retryable &&
            processingSession.watermarkAttemptCount < _maximumWatermarkAttempts;
        var statusPersisted =
            processingSession.watermarkStatus !=
            WatermarkProcessingStatus.pending;
        if (processingSession.watermarkStatus ==
            WatermarkProcessingStatus.pending) {
          final RecordingSession updated = processingSession.copyWith(
            watermarkStatus: retryPending
                ? WatermarkProcessingStatus.pending
                : WatermarkProcessingStatus.failed,
          );
          try {
            _sessions = await _repository.updateSession(updated);
            statusPersisted = true;
          } on Object {
            statusPersisted = false;
          }
        }
        // 可恢复的系统中断保持 pending，返回前台后重试；其余失败不进入备份。
        await _logWatermarkEvent(
          kind: retryPending ? 'watermark_retry_pending' : 'watermark_failed',
          extra: <String, Object?>{
            'sessionId': session.id,
            'orientation': recordingOrientation.storageValue,
            'inputBytes': inputBytes,
            'outputBytes': 0,
            'elapsedMs': stopwatch.elapsedMilliseconds,
            'errorType': error.runtimeType.toString(),
            'attempt': processingSession.watermarkAttemptCount,
            'retryable': retryable,
            'statusPersisted': statusPersisted,
          },
        );
      }
      if (!_disposed) notifyListeners();
    } finally {
      _activeWatermarkSessionIds.remove(session.id);
      await _resumeQueuedWatermarkIfNeeded(session.id);
    }
  }

  bool _isRetryableWatermarkError(Object error) =>
      error is _WatermarkFinalizationPersistenceException ||
      (error is PlatformException && error.code == 'watermark_interrupted');

  Future<int> _watermarkFileBytes(String path) async {
    try {
      final File file = File(path);
      return await file.exists() ? await file.length() : 0;
    } on FileSystemException {
      return 0;
    }
  }

  Future<void> _logWatermarkEvent({
    required String kind,
    required Map<String, Object?> extra,
  }) async {
    try {
      await _runtimeLog.log(kind: kind, extra: extra);
    } on Object {
      // 诊断写入不得改变水印状态机或阻断最终成片。
    }
  }

  Future<void> _resumePendingWatermarks() async {
    final List<RecordingSession> pending = await _repository
        .loadPendingWatermarkSessions();
    for (final RecordingSession session in pending) {
      if (_activeWatermarkSessionIds.contains(session.id)) {
        _queuedWatermarkResumeSessionIds.add(session.id);
        continue;
      }
      _runInBackground(
        _watermarkAndBackup(
          session.filePath,
          session,
          session.recordingOrientation,
        ),
      );
    }
  }

  Future<void> _resumeQueuedWatermarkIfNeeded(String sessionId) async {
    if (!_queuedWatermarkResumeSessionIds.remove(sessionId) || _disposed) {
      return;
    }
    final List<RecordingSession> pending = await _repository
        .loadPendingWatermarkSessions();
    for (final RecordingSession session in pending) {
      if (session.id != sessionId) continue;
      _runInBackground(
        _watermarkAndBackup(
          session.filePath,
          session,
          session.recordingOrientation,
        ),
      );
      return;
    }
  }

  @visibleForTesting
  Future<void> watermarkAndBackupForTesting(
    String savedPath,
    RecordingSession session, [
    RecordingOrientation recordingOrientation = RecordingOrientation.portrait,
  ]) => _watermarkAndBackup(savedPath, session, recordingOrientation);

  @visibleForTesting
  Future<void> resumePendingWatermarksForTesting() =>
      _resumePendingWatermarks();
}
