part of 'recordings_screen.dart';

/// 打开录像播放页：本地还有原片就播本地，否则用电脑上的播放地址。
///
/// 播放页信息卡片里的手动上传入口需要「本机原片是否还在」和备份任务状态，
/// 所以统一从录像行状态里取下传。
mixin _RecordingsPlaybackLauncher on _RecordingsHistoryManagement {
  Future<bool?> _openRecordingPlayback({
    required BuildContext context,
    required RecordingHistoryItem item,
    required RecordingSession session,
    required bool localAvailable,
    required bool remoteAvailable,
    required LanBackupJob? completedBackupJob,
    required LanBackupJob? backupJob,
    required bool unavailable,
    required Future<void> Function(RecordingSession session) onSessionUpdated,
  }) async {
    if (_managing) {
      _toggleSelection(session.id);
      return null;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final String? watermarkBlockMessage =
        recordingWatermarkPlaybackBlockMessage(
          session,
          localAvailable: item.local != null && localAvailable,
        );
    if (watermarkBlockMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(watermarkBlockMessage)));
      return null;
    }
    if (unavailable) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('录像已清理或文件不存在，无法播放')));
      return null;
    }
    RecordingSession playbackSession = session;
    if (localAvailable) {
      final Future<RecordingSession> Function(String sessionId)? prepare =
          widget.onPrepareLocalPlayback;
      if (prepare == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法准备独立录像文件')));
        return null;
      }
      try {
        playbackSession = await prepare(session.id);
      } on RecordingFilePreparationException {
        if (!context.mounted) return null;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法准备独立录像文件')));
        return null;
      } on Object {
        // broad-catch: 所有文件准备失败都转换成同一用户提示
        if (!context.mounted) return null;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法准备独立录像文件')));
        return null;
      }
    }
    Uri? resolvedRemoteUri;
    if (!localAvailable && remoteAvailable && item.remote != null) {
      final Future<Uri?> Function(Uri remoteUri)? resolver =
          widget.onResolveRemoteUri;
      final Uri? currentRemoteUri = resolver == null
          ? item.remote!.playUri
          : await resolver(item.remote!.playUri);
      if (!context.mounted) return null;
      if (currentRemoteUri == null) {
        // 电脑换了身份或重装过时，旧配对凭据已经作废，
        // 这时提示"离线"会让人反复重试；要直接让他重新连接。
        final bool needsRepair =
            widget.remoteConnectionNeedsRepair?.call() ?? false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              needsRepair
                  ? '这台电脑的配对已失效，请在电脑备份里重新连接'
                  : '暂时连不上电脑，请确认电脑端程序仍在运行后重试',
            ),
          ),
        );
        return null;
      }
      final VideoDecodeSupport? decodeSupport = await SystemVideoPlayerService()
          .getVideoDecodeSupport();
      resolvedRemoteUri = RemotePlaybackCompat.resolvePlaybackUri(
        currentRemoteUri,
        decodeSupport: decodeSupport,
        videoCodec: item.remote!.videoCodec,
      );
    }
    if (!context.mounted) return null;
    final bool? deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => VideoPlaybackScreen(
          session: playbackSession,
          onSessionUpdated: onSessionUpdated,
          onDelete: item.local == null
              ? null
              : () => widget.onDeleteSessions(<String>{item.local!.id}),
          remoteUri: localAvailable
              ? null
              : remoteAvailable
              ? resolvedRemoteUri
              : null,
          remoteVideoId: localAvailable
              ? null
              : remoteAvailable
              ? item.remote?.id
              : null,
          remoteHeaders: widget.remotePlaybackHeaders,
          backedUpOffline: completedBackupJob != null,
          sourceLabel: _recordingSourceLabel(item),
          backedUp:
              (remoteAvailable && _isRemoteFromThisDevice(item.remote!)) ||
              completedBackupJob != null,
          backupInProgress: backupJob?.state == LanBackupJobState.uploading,
          onUpload: widget.onUploadRecording == null || item.local == null
              ? null
              : () => widget.onUploadRecording!(playbackSession),
          backupStatusLoader: widget.onLoadBackupJobsForPaths == null
              ? null
              : () async {
                  final LanBackupJobsByPaths jobs =
                      await widget.onLoadBackupJobsForPaths!(<String>[
                        playbackSession.filePath,
                      ]);
                  return LanBackupPlaybackStatus(
                    // 与录像列表同一判定：电脑端录像记录可用才算已备份。
                    backedUp: jobs.jobs.any(_isJobKnownAvailable),
                    job: jobs.jobs.isEmpty ? null : jobs.jobs.first,
                  );
                },
          backupListenable: widget.backupListenable,
          remoteClipService: localAvailable
              ? null
              : item.remote == null
              ? null
              : widget.remoteClipServiceFactory?.call(resolvedRemoteUri!),
          networkDiagnosticsLoader: widget.onNetworkDiagnostics,
        ),
      ),
    );
    return deleted;
  }
}
