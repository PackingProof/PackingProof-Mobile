import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../models/lan_backup.dart';
import '../models/recording_session.dart';
import '../services/camera_diagnostics_service.dart';
import '../services/continuous_camera_service.dart';
import '../services/diagnostics_log_service.dart';
import '../services/recording_path_diagnostics.dart';
import '../services/remote_playback_compat.dart';
import '../services/remote_playback_probe.dart';
import '../services/system_video_player_service.dart';
import '../services/video_share_service.dart';
import '../services/remote_video_clip_service.dart';
import '../widgets/two_button_confirm_dialog.dart';
import '../widgets/order_info_sheet.dart';
import '../widgets/playback_error_panel.dart';
import 'video_trim_screen.dart';
import 'remote_video_trim_screen.dart';

/// 统计播放过程中进入缓冲的次数与最近播放位置，供诊断日志使用。
class PlaybackBufferingTracker {
  int bufferingCount = 0;
  int lastPositionMs = 0;
  bool _wasBuffering = false;

  void observe(VideoPlayerValue value) {
    if (value.isBuffering && !_wasBuffering) {
      bufferingCount++;
      _wasBuffering = true;
    } else if (!value.isBuffering) {
      _wasBuffering = false;
    }
    lastPositionMs = value.position.inMilliseconds;
  }
}

class PlaybackBufferingOverlay extends StatelessWidget {
  const PlaybackBufferingOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color(0x99000000),
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 10),
                Text(
                  '缓冲中…',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class VideoPlaybackScreen extends StatefulWidget {
  const VideoPlaybackScreen({
    required this.session,
    required this.onSessionUpdated,
    this.onDelete,
    this.remoteUri,
    this.remoteVideoId,
    this.remoteHeaders = const <String, String>{},
    this.remoteClipService,
    this.backedUpOffline = false,
    this.networkDiagnosticsLoader,
    super.key,
  });

  final RecordingSession session;
  final Future<void> Function(RecordingSession session) onSessionUpdated;
  final Future<void> Function()? onDelete;
  final Uri? remoteUri;
  final int? remoteVideoId;
  final Map<String, String> remoteHeaders;
  final RemoteVideoClipSink? remoteClipService;
  final bool backedUpOffline;
  final Future<NetworkDiagnostics?> Function()? networkDiagnosticsLoader;

  @override
  State<VideoPlaybackScreen> createState() => _VideoPlaybackScreenState();
}

class _VideoPlaybackScreenState extends State<VideoPlaybackScreen> {
  late VideoPlayerController _video;
  late Future<void> _initialized;
  bool _remoteCompatRetryTried = false;
  late RecordingSession _session;
  late Duration _playbackStart;
  late Duration _playbackEnd;
  bool _handlingBoundary = false;
  bool get _canTrim =>
      widget.remoteUri == null ||
      (widget.remoteVideoId != null && widget.remoteClipService != null);
  bool _resumeAfterScrub = false;
  double? _scrubMilliseconds;
  final PlaybackBufferingTracker _bufferingTracker = PlaybackBufferingTracker();
  bool _playbackEndLogged = false;
  final VideoShareService _shareService = VideoShareService();
  bool _sharing = false;
  double _shareProgress = 0;
  String _shareMessage = '';
  String? _playbackErrorDetail;
  String? _localVideoMime;
  VideoDecodeSupport? _deviceDecodeSupport;
  bool _fallbackBusy = false;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _playbackStart = _session.mediaStart;
    _playbackEnd = _session.playbackEnd;
    _video = _createVideoController();
    _initialized = _initializePlayback();
  }

  VideoPlayerController _createVideoController() {
    return widget.remoteUri == null
        ? VideoPlayerController.file(File(_session.filePath))
        : VideoPlayerController.networkUrl(
            widget.remoteUri!,
            httpHeaders: widget.remoteHeaders,
          );
  }

  Future<void> _initializePlayback() async {
    unawaited(
      DiagnosticsLogService().log(
        kind: 'playback_start',
        extra: <String, Object?>{
          'source': widget.remoteUri == null ? 'local' : 'remote',
          'sessionId': _session.id,
          'pathOrUri': widget.remoteUri?.toString() ?? _session.filePath,
        },
      ),
    );
    unawaited(_logPlaybackEnvironment());
    try {
      await _video.initialize();
      await _video.setVolume(1);
      final Duration sourceDuration = _video.value.duration;
      if (_playbackStart > sourceDuration) {
        _playbackStart = Duration.zero;
      }
      if (_playbackEnd > sourceDuration || _playbackEnd <= _playbackStart) {
        _playbackEnd = sourceDuration;
      }
      await _video.seekTo(_playbackStart);
      _video.addListener(_handlePlaybackBoundary);
      await _video.play();
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      if (widget.remoteUri != null &&
          !_remoteCompatRetryTried &&
          RemotePlaybackCompat.isDirect(widget.remoteUri!)) {
        _remoteCompatRetryTried = true;
        final Uri retryUri = RemotePlaybackCompat.withCompat(
          widget.remoteUri!,
          RemotePlaybackCompat.transcode,
        );
        unawaited(
          DiagnosticsLogService().log(
            kind: 'playback_retry',
            extra: <String, Object?>{
              'sessionId': _session.id,
              'fromCompat': RemotePlaybackCompat.direct,
              'toCompat': RemotePlaybackCompat.transcode,
              'uri': retryUri.toString(),
            },
          ),
        );
        await _video.dispose();
        _video = VideoPlayerController.networkUrl(
          retryUri,
          httpHeaders: widget.remoteHeaders,
        );
        await _initializePlayback();
        return;
      }
      _playbackErrorDetail = _playbackErrorSummary(error);
      if (widget.remoteUri == null) {
        await _loadLocalPlaybackContext();
      }
      unawaited(_recordPlaybackFailure(error));
      if (mounted) {
        setState(() {});
      }
      rethrow;
    }
  }

  String _playbackErrorSummary(Object error) {
    if (error is PlatformException) {
      final String message = error.message?.isNotEmpty == true
          ? error.message!
          : '';
      return message.isEmpty ? error.code : '${error.code}：$message';
    }
    return '$error';
  }

  Future<void> _loadLocalPlaybackContext() async {
    final File file = File(_session.filePath);
    if (!file.existsSync()) return;
    _localVideoMime = await SystemVideoPlayerService().getVideoTrackMime(
      _session.filePath,
    );
    _deviceDecodeSupport = await SystemVideoPlayerService()
        .getVideoDecodeSupport();
  }

  Future<void> _recordPlaybackFailure(Object error) async {
    final bool remote = widget.remoteUri != null;
    final String pathOrUri = remote
        ? widget.remoteUri.toString()
        : _session.filePath;
    String? videoMime = _localVideoMime;
    int? fileSizeBytes;
    if (!remote) {
      final File file = File(_session.filePath);
      if (file.existsSync()) {
        fileSizeBytes = file.lengthSync();
      }
      videoMime ??= await SystemVideoPlayerService().getVideoTrackMime(
        _session.filePath,
      );
    }
    final VideoDecodeSupport? decodeSupport =
        _deviceDecodeSupport ??
        await SystemVideoPlayerService().getVideoDecodeSupport();
    RemotePlaybackProbeResult? probe;
    if (remote) {
      probe = await RemotePlaybackProbe().probe(widget.remoteUri!);
    }
    await RecordingPathDiagnostics().recordPlaybackFailure(
      source: remote ? 'remote' : 'local',
      sessionId: _session.id,
      pathOrUri: pathOrUri,
      fileSizeBytes: fileSizeBytes,
      videoMime: videoMime,
      deviceManufacturer: decodeSupport?.manufacturer,
      deviceModel: decodeSupport?.model,
      deviceSdkInt: decodeSupport?.sdkInt,
      deviceHasHevcDecoder: decodeSupport?.hasHevcDecoder,
      deviceHasAvcDecoder: decodeSupport?.hasAvcDecoder,
      errorCode: error is PlatformException
          ? error.code
          : error.runtimeType.toString(),
      errorMessage: _playbackErrorSummary(error),
      httpStatus: probe?.statusCode,
      hostErrorCode: probe?.hostErrorCode,
      hostError: probe?.hostError,
      probeError: probe?.networkError,
    );
  }

  @override
  void dispose() {
    _video.removeListener(_handlePlaybackBoundary);
    unawaited(_logPlaybackEnd());
    _video.dispose();
    super.dispose();
  }

  Future<void> _logPlaybackEnvironment() async {
    final Map<String, Object?> extra = <String, Object?>{};
    final CameraDiagnosticsSnapshot? camera = await CameraDiagnosticsService()
        .loadSnapshot();
    if (camera != null) {
      extra['storageAvailableBytes'] = camera.storageAvailableBytes;
      extra['storageTotalBytes'] = camera.storageTotalBytes;
    }
    final Future<NetworkDiagnostics?> Function()? loader =
        widget.networkDiagnosticsLoader;
    if (loader != null) {
      final NetworkDiagnostics? network = await loader();
      if (network != null) {
        extra['wifiConnected'] = network.wifiConnected;
        extra['wifiRssiDbm'] = network.rssiDbm;
        extra['wifiLinkSpeedMbps'] = network.linkSpeedMbps;
      }
    }
    if (extra.isEmpty) return;
    await DiagnosticsLogService().log(kind: 'playback_env', extra: extra);
  }

  Future<void> _logPlaybackEnd() async {
    if (_playbackEndLogged) return;
    _playbackEndLogged = true;
    await DiagnosticsLogService().log(
      kind: 'playback_end',
      extra: <String, Object?>{
        'source': widget.remoteUri == null ? 'local' : 'remote',
        'sessionId': _session.id,
        'watchedMs': _bufferingTracker.lastPositionMs,
        'bufferingCount': _bufferingTracker.bufferingCount,
      },
    );
  }

  Future<void> _togglePlayback() async {
    if (_video.value.isPlaying) {
      await _video.pause();
    } else {
      final Duration position = _video.value.position;
      if (position < _playbackStart || position >= _playbackEnd) {
        await _video.seekTo(_playbackStart);
      }
      await _video.play();
    }
    if (mounted) {
      setState(() {});
    }
  }

  Duration get _playbackDuration => _playbackEnd - _playbackStart;

  double _relativePositionMilliseconds(VideoPlayerValue value) {
    final double maximum = _playbackDuration.inMilliseconds.toDouble();
    if (maximum <= 0) {
      return 0;
    }
    return (_scrubMilliseconds ??
            (value.position - _playbackStart).inMilliseconds.toDouble())
        .clamp(0, maximum);
  }

  void _startScrubbing(double value) {
    _resumeAfterScrub = _video.value.isPlaying;
    _handlingBoundary = true;
    if (_resumeAfterScrub) {
      unawaited(_video.pause());
    }
    setState(() => _scrubMilliseconds = value);
  }

  void _scrubTo(double value) {
    setState(() => _scrubMilliseconds = value);
    if (widget.remoteUri != null) {
      return;
    }
    unawaited(
      _video.seekTo(_playbackStart + Duration(milliseconds: value.round())),
    );
  }

  Future<void> _finishScrubbing(double value) async {
    await _video.seekTo(_playbackStart + Duration(milliseconds: value.round()));
    _scrubMilliseconds = null;
    _handlingBoundary = false;
    if (_resumeAfterScrub && value < _playbackDuration.inMilliseconds) {
      await _video.play();
    }
    _resumeAfterScrub = false;
    if (mounted) {
      setState(() {});
    }
  }

  String _formatDuration(Duration duration) {
    final int totalSeconds = duration.inSeconds.clamp(0, 359999);
    final int hours = totalSeconds ~/ 3600;
    final int minutes = totalSeconds.remainder(3600) ~/ 60;
    final int seconds = totalSeconds.remainder(60);
    final String minuteText = minutes.toString().padLeft(2, '0');
    final String secondText = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minuteText:$secondText';
    }
    return '$minuteText:$secondText';
  }

  void _handlePlaybackBoundary() {
    _bufferingTracker.observe(_video.value);
    if (_handlingBoundary ||
        !_video.value.isInitialized ||
        _video.value.position < _playbackEnd) {
      return;
    }
    _handlingBoundary = true;
    unawaited(_rewindAtBoundary());
  }

  Future<void> _rewindAtBoundary() async {
    await _video.pause();
    await _video.seekTo(_playbackStart);
    _handlingBoundary = false;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openTrim() async {
    await _video.pause();
    if (!mounted) {
      return;
    }
    if (widget.remoteUri != null && widget.remoteVideoId != null) {
      final Uri remote = widget.remoteUri!;
      final RemoteVideoClipSink? service = widget.remoteClipService;
      if (service == null) return;
      final File? clip = await Navigator.of(context).push<File>(
        MaterialPageRoute<File>(
          builder: (_) => RemoteVideoTrimScreen(
            videoId: widget.remoteVideoId!,
            playUri: remote,
            duration: _video.value.duration,
            service: service,
          ),
        ),
      );
      if (clip != null && mounted) {
        await SharePlus.instance.share(
          ShareParams(
            title: _session.displayCode,
            files: <XFile>[XFile(clip.path, mimeType: 'video/mp4')],
          ),
        );
      }
      if (mounted) await _video.play();
      return;
    }
    final RecordingSession? updated = await Navigator.of(context)
        .push<RecordingSession>(
          MaterialPageRoute<RecordingSession>(
            builder: (BuildContext context) =>
                VideoTrimScreen(session: _session),
          ),
        );
    if (updated == null || !mounted) {
      await _video.play();
      return;
    }
    try {
      await widget.onSessionUpdated(updated);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('剪辑保存失败，请稍后重试')));
        await _video.play();
      }
      return;
    }
    _handlingBoundary = true;
    _session = updated;
    _playbackStart = updated.mediaStart;
    _playbackEnd = updated.playbackEnd;
    await _video.seekTo(_playbackStart);
    _handlingBoundary = false;
    await _video.play();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _share() async {
    if (_sharing || !_video.value.isInitialized) return;
    await _video.pause();
    setState(() {
      _sharing = true;
      _shareProgress = 0;
      _shareMessage = widget.remoteUri == null ? '正在准备分享' : '正在下载电脑录像';
    });
    try {
      final File file = await _shareService.prepare(
        sourcePath: _session.filePath,
        remoteUri: widget.remoteUri,
        remoteHeaders: widget.remoteHeaders,
        mediaStart: _playbackStart,
        mediaEnd: _playbackEnd,
        sourceDuration: _video.value.duration,
        onProgress: (double progress, String message) {
          if (!mounted) return;
          setState(() {
            _shareProgress = progress;
            _shareMessage = message;
          });
        },
      );
      await SharePlus.instance.share(
        ShareParams(
          title: _session.displayCode,
          files: <XFile>[XFile(file.path, mimeType: 'video/mp4')],
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '分享失败：${error.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _sharing = false;
          _shareProgress = 0;
          _shareMessage = '';
        });
      }
    }
  }

  Future<void> _deleteLocalRecording() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => const TwoButtonConfirmDialog(
        title: '删除这段录像？',
        message: '将删除手机中的录像和记录，电脑中的备份不会受到影响',
        confirmLabel: '删除',
        dangerous: true,
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.onDelete?.call();
      if (mounted) Navigator.of(context).pop(true);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('删除失败，请稍后重试')));
      }
    }
  }

  Future<void> _openWithSystemPlayer() async {
    setState(() => _fallbackBusy = true);
    try {
      await SystemVideoPlayerService().openWithSystemPlayer(_session.filePath);
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开系统播放器：${error.message ?? error.code}')),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开系统播放器，请稍后重试')));
      }
    } finally {
      if (mounted) {
        setState(() => _fallbackBusy = false);
      }
    }
  }

  Future<void> _shareRawFile() async {
    final File file = File(_session.filePath);
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('录像文件不存在，无法分享')));
      }
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        title: _session.displayCode,
        files: <XFile>[XFile(file.path, mimeType: 'video/mp4')],
      ),
    );
  }

  Future<void> _downloadAndPlayRemote() async {
    final RemoteVideoClipSink? service = widget.remoteClipService;
    final Uri? remote = widget.remoteUri;
    if (service == null || remote == null) return;
    setState(() => _fallbackBusy = true);
    try {
      final File file = await service.download(remote);
      await SystemVideoPlayerService().openWithSystemPlayer(file.path);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('下载或打开失败，请稍后重试')));
      }
    } finally {
      if (mounted) {
        setState(() => _fallbackBusy = false);
      }
    }
  }

  Future<void> _downloadAndShareRemote() async {
    final RemoteVideoClipSink? service = widget.remoteClipService;
    final Uri? remote = widget.remoteUri;
    if (service == null || remote == null) return;
    setState(() => _fallbackBusy = true);
    try {
      final File file = await service.download(remote);
      await SharePlus.instance.share(
        ShareParams(
          title: _session.displayCode,
          files: <XFile>[XFile(file.path, mimeType: 'video/mp4')],
        ),
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('下载或分享失败，请稍后重试')));
      }
    } finally {
      if (mounted) {
        setState(() => _fallbackBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_session.displayCode),
        actions: <Widget>[
          if (_session.orderInfo != null)
            IconButton(
              key: const Key('recording-order-info'),
              tooltip: '订单信息',
              onPressed: () => showOrderInfoSheet(context, _session.orderInfo!),
              icon: const Icon(Icons.receipt_long_outlined),
            ),
          if (widget.remoteUri == null && widget.onDelete != null)
            IconButton(
              key: const Key('delete-local-recording'),
              tooltip: '删除本机录像',
              onPressed: _sharing ? null : _deleteLocalRecording,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initialized,
        builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return widget.remoteUri == null
                ? PlaybackErrorPanel(
                    message: localPlaybackErrorMessage(
                      fileExists: File(_session.filePath).existsSync(),
                      backedUpOffline: widget.backedUpOffline,
                      videoMime: _localVideoMime,
                      decodeSupport: _deviceDecodeSupport,
                    ),
                    errorDetail: _playbackErrorDetail,
                    primaryAction: _openWithSystemPlayer,
                    primaryActionLabel: '用系统播放器打开',
                    secondaryAction: _shareRawFile,
                    secondaryActionLabel: '分享原文件',
                    destructiveAction: widget.onDelete == null
                        ? null
                        : _deleteLocalRecording,
                    destructiveActionLabel: '删除本机录像',
                    busy: _fallbackBusy,
                  )
                : PlaybackErrorPanel(
                    message: '电脑录像暂时无法播放，请检查局域网连接',
                    errorDetail: _playbackErrorDetail,
                    primaryAction: widget.remoteClipService == null
                        ? null
                        : _downloadAndPlayRemote,
                    primaryActionLabel: '下载后播放',
                    secondaryAction: widget.remoteClipService == null
                        ? null
                        : _downloadAndShareRemote,
                    secondaryActionLabel: '下载并分享原文件',
                    busy: _fallbackBusy,
                  );
          }
          return ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: _video,
            builder:
                (BuildContext context, VideoPlayerValue value, Widget? child) {
                  final double maximum = _playbackDuration.inMilliseconds
                      .toDouble();
                  final double position = _relativePositionMilliseconds(value);
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: AspectRatio(
                          aspectRatio: value.aspectRatio,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _togglePlayback,
                            child: Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                VideoPlayer(_video),
                                if (!value.isPlaying &&
                                    _scrubMilliseconds == null)
                                  const Center(
                                    child: IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Color(0x66000000),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Padding(
                                          padding: EdgeInsets.all(14),
                                          child: Icon(
                                            Icons.play_arrow_rounded,
                                            color: Colors.white,
                                            size: 38,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (value.isBuffering && value.isInitialized)
                                  const PlaybackBufferingOverlay(
                                    key: Key('playback-buffering-indicator'),
                                  ),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: IgnorePointer(
                                    child: Container(
                                      height: 104,
                                      decoration: const BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: <Color>[
                                            Colors.transparent,
                                            Color(0x99000000),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: 10,
                                  right: 10,
                                  bottom: 4,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                        ),
                                        child: Row(
                                          children: <Widget>[
                                            Text(
                                              _formatDuration(
                                                Duration(
                                                  milliseconds: position
                                                      .round(),
                                                ),
                                              ),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const Spacer(),
                                            Text(
                                              _formatDuration(
                                                _playbackDuration,
                                              ),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          activeTrackColor: Colors.white,
                                          inactiveTrackColor: const Color(
                                            0x66FFFFFF,
                                          ),
                                          thumbColor: Colors.white,
                                          overlayColor: const Color(0x33FFFFFF),
                                          trackHeight: 3,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                enabledThumbRadius: 6,
                                              ),
                                        ),
                                        child: Slider(
                                          value: maximum > 0 ? position : 0,
                                          max: maximum > 0 ? maximum : 1,
                                          onChangeStart: maximum > 0
                                              ? _startScrubbing
                                              : null,
                                          onChanged: maximum > 0
                                              ? _scrubTo
                                              : null,
                                          onChangeEnd: maximum > 0
                                              ? _finishScrubbing
                                              : null,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_sharing) ...<Widget>[
                        LinearProgressIndicator(value: _shareProgress),
                        const SizedBox(height: 8),
                        Text(_shareMessage, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        children: <Widget>[
                          if (_canTrim) ...<Widget>[
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _sharing ? null : _openTrim,
                                icon: const Icon(Icons.content_cut_rounded),
                                label: const Text('剪辑'),
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: FilledButton.tonalIcon(
                              key: const Key('share-recording'),
                              onPressed: _sharing ? null : _share,
                              icon: const Icon(Icons.share_rounded),
                              label: Text(
                                widget.remoteUri == null ? '分享' : '下载并分享',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
          );
        },
      ),
    );
  }
}

@visibleForTesting
String localPlaybackErrorMessage({
  required bool fileExists,
  required bool backedUpOffline,
  String? videoMime,
  VideoDecodeSupport? decodeSupport,
}) {
  if (backedUpOffline) {
    return '录像已备份到电脑，电脑离线时暂时无法播放，请连接电脑后重试';
  }
  if (!fileExists) {
    return '录像文件不在本机，可能已被清理，无法播放';
  }
  final String? mime = videoMime?.trim().toLowerCase();
  if (mime != null && decodeSupport != null) {
    if (mime.contains('hevc')) {
      if (!decodeSupport.hasHevcDecoder) {
        return '该录像为 H.265 编码，当前设备不支持解码播放。请改用 H.264 重新录制，或分享原文件到电脑/其他设备查看';
      }
    }
    if (mime.contains('avc') && !decodeSupport.hasAvcDecoder) {
      return '该录像为 H.264 编码，当前设备不支持解码播放，请分享原文件到电脑/其他设备查看';
    }
  }
  return '录像文件不完整或已损坏，无法播放（可能是异常退出导致）';
}
