part of 'packing_session_controller.dart';

/// 发布水印成片并将最终可用文件衔接到备份队列。
mixin _PackingSessionWatermarkCoordinator on _PackingSessionBackupCoordinator {
  VideoWatermarkSink get _videoWatermarkService;
  ContinuousCameraInitialization? get _nativeInitialization;
  RecordingVideoCodec get _preferredVideoCodec;
  RecordingOrientation get _recordingOrientation;
  String _firstTrackingNumber(List<RecordingSession> sessions);
  RecordingSession _sessionWithPath(
    RecordingSession session,
    String filePath, {
    OrderInfo? orderInfo,
  });
  Future<void> _watermarkAndBackup(
    String savedPath,
    RecordingSession session,
  ) async {
    final String trackingNumber = _firstTrackingNumber(<RecordingSession>[
      session,
    ]);
    try {
      final String watermarkedPath =
          await (_videoWatermarkService is OrientedVideoWatermarkSink
              ? (_videoWatermarkService as OrientedVideoWatermarkSink)
                    .applyWithOrientation(
                      inputPath: savedPath,
                      startedAt: session.startedAt,
                      trackingNumber: trackingNumber,
                      // 相机可能因设备不支持偏好编码而回退，水印必须跟随实际录制的编码。
                      videoCodec: recordingVideoCodecFromMime(
                        _nativeInitialization?.videoMime,
                        fallback: _preferredVideoCodec,
                      ),
                      recordingOrientation: _recordingOrientation,
                    )
              : _videoWatermarkService.apply(
                  inputPath: savedPath,
                  startedAt: session.startedAt,
                  trackingNumber: trackingNumber,
                  videoCodec: recordingVideoCodecFromMime(
                    _nativeInitialization?.videoMime,
                    fallback: _preferredVideoCodec,
                  ),
                ));
      final String finalPath = await _repository.finalizeVideo(
        sourcePath: watermarkedPath,
        sessionId: session.id,
        startedAt: session.startedAt,
        trackingNumber: trackingNumber,
        operationMode: session.operationMode,
      );
      final RecordingSession finalized = finalPath == session.filePath
          ? session
          : _sessionWithPath(session, finalPath, orderInfo: session.orderInfo);
      if (finalized.filePath != session.filePath) {
        _sessions = await _repository.updateSession(finalized);
        await _repository.deleteFileIfUnreferenced(savedPath);
      }
      await _enqueueBackupIfNeeded(finalPath, <RecordingSession>[finalized]);
    } on Object catch (error, stackTrace) {
      // The original recording is already safely indexed. A failed watermark
      // must not keep the work button blocked or discard the video.
      await _runtimeLog.log(
        kind: 'watermark_failed',
        extra: <String, Object?>{
          'sessionId': session.id,
          'filePath': savedPath,
          'errorType': error.runtimeType.toString(),
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
      if (await File(savedPath).exists()) {
        await _enqueueBackupIfNeeded(savedPath, <RecordingSession>[session]);
      }
    }
    if (!_disposed) notifyListeners();
  }

  @visibleForTesting
  Future<void> watermarkAndBackupForTesting(
    String savedPath,
    RecordingSession session,
  ) => _watermarkAndBackup(savedPath, session);
}
