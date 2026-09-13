import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../models/lan_backup.dart';
import '../models/recording_session.dart';
import '../models/recording_operation_mode.dart';
import '../models/recording_orientation.dart';
import '../services/camera_diagnostics_service.dart';
import '../services/continuous_camera_service.dart';
import '../services/diagnostics_log_service.dart';
import '../services/playback_display_mode_controller.dart';
import '../services/playback_fullscreen_policy.dart';
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

class PlaybackDisposalGuard {
  PlaybackDisposalGuard(this._dispose);

  final Future<void> Function() _dispose;
  Future<void>? _disposeFuture;

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> disposeAfter(Future<void> dependentsDetached) async {
    await dependentsDetached;
    await dispose();
  }
}

/// 视频底部渐隐遮罩，保证白色时间与进度条在任何画面上都清晰。
///
/// 直接作为 `Stack` 子项使用，用 `Align` 固定在底部并保持自身高度。
class _VideoSurfaceScrim extends StatelessWidget {
  const _VideoSurfaceScrim({this.height = 104});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: IgnorePointer(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Colors.transparent, Color(0x99000000)],
              ),
            ),
          ),
        ),
      ),
    );
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
    this.playbackDisplayPlatform,
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

  /// 测试可注入的系统显示设置通道；为空时直接下发 `SystemChrome`。
  final PlaybackDisplayPlatform? playbackDisplayPlatform;

  @override
  State<VideoPlaybackScreen> createState() => _VideoPlaybackScreenState();
}

class _VideoPlaybackScreenState extends State<VideoPlaybackScreen> {
  late VideoPlayerController _video;
  late Future<void> _initialized;
  late final PlaybackDisposalGuard _disposalGuard;
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
  late final PlaybackDisplayModeController _displayMode;

  /// 全屏时 AppBar 与页面留白全部让位给视频，方向按视频自身横竖版下发。
  bool get _fullscreen => _displayMode.isFullscreen;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _playbackStart = _session.mediaStart;
    _playbackEnd = _session.playbackEnd;
    _displayMode = PlaybackDisplayModeController(
      platform: widget.playbackDisplayPlatform,
    );
    _video = _createVideoController();
    _disposalGuard = PlaybackDisposalGuard(_disposePlayback);
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
    // 释放失败同样要记日志：这里不再有「先拦一次再补 pop」的兜底代码，
    // 播放器异常不能连累页面退出。
    unawaited(
      _disposalGuard.dispose().catchError((Object error) {
        unawaited(
          DiagnosticsLogService().log(
            kind: 'playback_dispose_failed',
            extra: <String, Object?>{
              'sessionId': _session.id,
              'error': error.toString(),
            },
          ),
        );
      }),
    );
    unawaited(_displayMode.dispose());
    super.dispose();
  }

  Future<void> _disposePlayback() async {
    _video.removeListener(_handlePlaybackBoundary);
    try {
      await _video.dispose();
    } on Object catch (error) {
      unawaited(
        DiagnosticsLogService().log(
          kind: 'playback_dispose_failed',
          extra: <String, Object?>{
            'sessionId': _session.id,
            'error': error.toString(),
          },
        ),
      );
    }
    unawaited(_logPlaybackEnd());
  }

  /// 主动关闭播放页（删除本机录像后调用）。
  ///
  /// 退出全屏恢复竖屏，然后直接让路由 pop；播放器释放交给 [dispose]，
  /// 不在这里等释放完成，避免任何一步卡住就把页面锁死。
  Future<void> _closePlayback([Object? result]) async {
    await _displayMode.restore();
    if (!mounted) return;
    Navigator.of(context).pop(result);
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

  /// 进入全屏：竖版视频铺满竖屏，横版视频铺满横屏。
  Future<void> _enterFullscreen() async {
    if (_fullscreen) return;
    final VideoPlayerValue value = _video.value;
    final List<DeviceOrientation> orientations =
        PlaybackFullscreenPolicy.orientationsFor(
          PlaybackFullscreenPolicy.layoutFor(
            videoAspectRatio: value.aspectRatio,
            videoInitialized: value.isInitialized,
            recordedOrientation: _session.recordingOrientation,
          ),
        );
    await _displayMode.enter(orientations: orientations);
    if (!mounted) return;
    setState(() {});
    unawaited(
      DiagnosticsLogService().log(
        kind: 'playback_fullscreen',
        extra: <String, Object?>{
          'action': 'enter',
          'sessionId': _session.id,
          'videoInitialized': value.isInitialized,
          'aspectRatio': value.aspectRatio,
          'recordedOrientation': _session.recordingOrientation.storageValue,
          'appliedOrientations': orientations
              .map((DeviceOrientation item) => item.name)
              .toList(growable: false),
          'positionMs': value.position.inMilliseconds,
        },
      ),
    );
  }

  Future<void> _exitFullscreen() async {
    if (!_fullscreen) return;
    await _displayMode.restore();
    if (!mounted) return;
    setState(() {});
    unawaited(
      DiagnosticsLogService().log(
        kind: 'playback_fullscreen',
        extra: <String, Object?>{
          'action': 'exit',
          'sessionId': _session.id,
          'positionMs': _video.value.position.inMilliseconds,
        },
      ),
    );
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
        final File shareFile = await _namedShareFile(clip, suffix: '剪辑');
        await SharePlus.instance.share(
          ShareParams(
            title: _session.displayCode,
            files: <XFile>[XFile(shareFile.path, mimeType: 'video/mp4')],
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
      final Duration total = _video.value.duration;
      final bool fullRange =
          _playbackStart <= const Duration(milliseconds: 50) &&
          _playbackEnd >= total - const Duration(milliseconds: 50);
      final File file;
      if (widget.remoteUri != null) {
        final RemoteVideoClipSink? service = widget.remoteClipService;
        if (service == null) {
          file = await _shareService.prepare(
            sourcePath: _session.filePath,
            remoteUri: widget.remoteUri,
            remoteHeaders: widget.remoteHeaders,
            mediaStart: _playbackStart,
            mediaEnd: _playbackEnd,
            sourceDuration: total,
            onProgress: (double progress, String message) {
              if (!mounted) return;
              setState(() {
                _shareProgress = progress;
                _shareMessage = message;
              });
            },
          );
        } else if (!fullRange) {
          file = await _prepareRemoteClip(
            start: _playbackStart,
            end: _playbackEnd,
            total: total,
          );
        } else {
          setState(() => _shareMessage = '正在下载电脑录像');
          file = await service.download(
            widget.remoteUri!,
            onProgress: (double progress) {
              if (!mounted) return;
              setState(() {
                _shareProgress = progress * 0.9;
                _shareMessage = '正在下载电脑录像';
              });
            },
          );
        }
      } else {
        file = await _shareService.prepare(
          sourcePath: _session.filePath,
          remoteUri: widget.remoteUri,
          remoteHeaders: widget.remoteHeaders,
          mediaStart: _playbackStart,
          mediaEnd: _playbackEnd,
          sourceDuration: total,
          onProgress: (double progress, String message) {
            if (!mounted) return;
            setState(() {
              _shareProgress = progress;
              _shareMessage = message;
            });
          },
        );
      }
      final File shareFile = await _namedShareFile(file);
      await SharePlus.instance.share(
        ShareParams(
          title: _session.displayCode,
          files: <XFile>[XFile(shareFile.path, mimeType: 'video/mp4')],
        ),
      );
    } on Object catch (error) {
      unawaited(
        DiagnosticsLogService().log(
          kind: 'share_failed',
          extra: <String, Object?>{
            'source': widget.remoteUri == null ? 'local' : 'remote',
            'sessionId': _session.id,
            'error': error.toString(),
          },
        ),
      );
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

  Future<File> _prepareRemoteClip({
    required Duration start,
    required Duration end,
    required Duration total,
  }) async {
    final RemoteVideoClipSink? service = widget.remoteClipService;
    final int? videoId = widget.remoteVideoId;
    final Uri? remoteUri = widget.remoteUri;
    if (service == null || videoId == null || remoteUri == null) {
      throw StateError('电脑剪辑服务不可用');
    }
    final double totalSeconds = total.inMilliseconds <= 0
        ? 1
        : total.inMilliseconds / 1000;
    final double startSeconds = (start.inMilliseconds / 1000).clamp(
      0,
      totalSeconds,
    );
    final double endSeconds = (end.inMilliseconds / 1000).clamp(
      startSeconds,
      totalSeconds,
    );
    if (endSeconds - startSeconds < 0.05) {
      throw StateError('分享范围过短');
    }
    final String taskId = await service.start(
      videoId,
      startSeconds,
      endSeconds,
    );
    while (mounted) {
      final Map<String, Object?> task = await service.task(taskId);
      final String status = '${task['status'] ?? ''}';
      if (status == 'completed') {
        final Uri uri = remoteUri.resolve('${task['downloadUrl'] ?? ''}');
        if (mounted) {
          setState(() {
            _shareProgress = 0.85;
            _shareMessage = '正在下载剪辑';
          });
        }
        return await service.download(
          uri,
          onProgress: (double progress) {
            if (mounted) {
              setState(() {
                _shareProgress = 0.85 + progress * 0.15;
                _shareMessage = '正在下载剪辑';
              });
            }
          },
        );
      }
      if (status == 'failed' || status == 'canceled' || status == 'not_found') {
        throw StateError('${task['message'] ?? '电脑剪辑生成失败'}');
      }
      if (mounted) {
        setState(() => _shareMessage = '${task['message'] ?? '电脑正在生成剪辑'}');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw StateError('电脑剪辑生成失败');
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
      if (mounted) await _closePlayback(true);
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

  Future<void> _shareRemuxedFile() async {
    final File file = File(_session.filePath);
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('录像文件不存在，无法分享')));
      }
      return;
    }
    setState(() => _fallbackBusy = true);
    try {
      final File prepared = await _shareService.prepare(
        sourcePath: file.path,
        mediaStart: Duration.zero,
        mediaEnd: _session.duration,
        sourceDuration: _session.duration,
      );
      final File shareFile = await _namedShareFile(prepared);
      await SharePlus.instance.share(
        ShareParams(
          title: _session.displayCode,
          files: <XFile>[XFile(shareFile.path, mimeType: 'video/mp4')],
        ),
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('视频整理失败，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => _fallbackBusy = false);
    }
  }

  Future<void> _downloadAndPlayRemote() async {
    final RemoteVideoClipSink? service = widget.remoteClipService;
    final Uri? remote = widget.remoteUri;
    if (service == null || remote == null) return;
    setState(() => _fallbackBusy = true);
    try {
      final File file = await service.download(remote);
      await SystemVideoPlayerService().openWithSystemPlayer(file.path);
    } on Object catch (error) {
      unawaited(
        DiagnosticsLogService().log(
          kind: 'share_failed',
          extra: <String, Object?>{
            'source': 'remote-download-play',
            'sessionId': _session.id,
            'error': error.toString(),
          },
        ),
      );
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
      final File shareFile = await _namedShareFile(file);
      await SharePlus.instance.share(
        ShareParams(
          title: _session.displayCode,
          files: <XFile>[XFile(shareFile.path, mimeType: 'video/mp4')],
        ),
      );
    } on Object catch (error) {
      unawaited(
        DiagnosticsLogService().log(
          kind: 'share_failed',
          extra: <String, Object?>{
            'source': 'remote-download-share',
            'sessionId': _session.id,
            'error': error.toString(),
          },
        ),
      );
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

  Future<File> _namedShareFile(File file, {String suffix = ''}) {
    final String stem = _shareNameStem();
    final String name = suffix.isEmpty ? '$stem.mp4' : '${stem}_$suffix.mp4';
    return _shareService.prepareForSharing(file, fileName: name);
  }

  String _shareNameStem() {
    final String sourceStem = p.basenameWithoutExtension(_session.filePath);
    final bool hasComputerNaming = RegExp(
      r'^.+_\d{8}_\d{6}_(发货|退货)(_.+)?$',
    ).hasMatch(sourceStem);
    if (hasComputerNaming) return sourceStem;
    final DateTime value = _session.startedAt;
    final String date =
        '${value.year.toString().padLeft(4, '0')}${value.month.toString().padLeft(2, '0')}${value.day.toString().padLeft(2, '0')}_'
        '${value.hour.toString().padLeft(2, '0')}${value.minute.toString().padLeft(2, '0')}${value.second.toString().padLeft(2, '0')}';
    return '${_session.displayCode}_${date}_${_session.operationMode.label}';
  }

  @override
  Widget build(BuildContext context) {
    // 刻意不套 PopScope：窗口态与全屏态都放行路由 pop，系统返回与 iOS 侧滑
    // 都能直接离开播放页（全屏也不例外）。方向恢复与播放器释放在 dispose 收尾，
    // 不再用「先拦一次再补 pop」的两段式流程——那种写法一旦没有下一帧，
    // 页面就永远关不上。
    return _buildScaffold(context);
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: _fullscreen
          ? null
          : AppBar(
              title: Text(_session.displayCode),
              actions: <Widget>[
                if (_session.orderInfo != null)
                  IconButton(
                    key: const Key('recording-order-info'),
                    tooltip: '订单信息',
                    onPressed: () =>
                        showOrderInfoSheet(context, _session.orderInfo!),
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
                    secondaryAction: _shareRemuxedFile,
                    secondaryActionLabel: '整理后分享',
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
                  if (_fullscreen) {
                    return _buildFullscreenBody(value);
                  }
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
                    children: <Widget>[
                      _buildVideoSurface(value),
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

  /// 全屏铺满：视频按自身宽高比在黑底上铺满整屏，控件只构建一次叠在其上。
  Widget _buildFullscreenBody(VideoPlayerValue value) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ColoredBox(color: Colors.black),
        Center(
          child: AspectRatio(
            aspectRatio: value.aspectRatio,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlayback,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  VideoPlayer(_video),
                  const _VideoSurfaceScrim(),
                  _buildPlayOverlay(value),
                  if (value.isBuffering && value.isInitialized)
                    const PlaybackBufferingOverlay(
                      key: Key('playback-buffering-indicator'),
                    ),
                ],
              ),
            ),
          ),
        ),
        const _VideoSurfaceScrim(height: 132),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: _buildPlaybackControls(value),
            ),
          ),
        ),
      ],
    );
  }

  /// 窗口态视频面：带圆角、控件内嵌；全屏态由 [_buildFullscreenBody] 自行铺满。
  Widget _buildVideoSurface(VideoPlayerValue value) {
    return ClipRRect(
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
              const _VideoSurfaceScrim(),
              _buildPlayOverlay(value),
              if (value.isBuffering && value.isInitialized)
                const PlaybackBufferingOverlay(
                  key: Key('playback-buffering-indicator'),
                ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 4,
                child: _buildPlaybackControls(value, compact: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 暂停时居中显示播放图标。
  Widget _buildPlayOverlay(VideoPlayerValue value) {
    if (value.isPlaying || _scrubMilliseconds != null) {
      return const SizedBox.shrink();
    }
    return const Center(
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
    );
  }

  /// 播放控件：时间行紧贴进度条，全屏按钮在进度条右侧。
  Widget _buildPlaybackControls(
    VideoPlayerValue value, {
    bool compact = false,
  }) {
    final double maximum = _playbackDuration.inMilliseconds.toDouble();
    final double position = _relativePositionMilliseconds(value);
    const TextStyle timeStyle = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 4),
          child: Row(
            children: <Widget>[
              Text(
                _formatDuration(Duration(milliseconds: position.round())),
                style: timeStyle,
              ),
              const Spacer(),
              Text(_formatDuration(_playbackDuration), style: timeStyle),
            ],
          ),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: const Color(0x66FFFFFF),
                  thumbColor: Colors.white,
                  overlayColor: const Color(0x33FFFFFF),
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Slider(
                  value: maximum > 0 ? position : 0,
                  max: maximum > 0 ? maximum : 1,
                  onChangeStart: maximum > 0 ? _startScrubbing : null,
                  onChanged: maximum > 0 ? _scrubTo : null,
                  onChangeEnd: maximum > 0 ? _finishScrubbing : null,
                ),
              ),
            ),
            IconButton(
              key: const Key('playback-fullscreen-toggle'),
              tooltip: _fullscreen ? '退出全屏' : '全屏',
              onPressed: _fullscreen ? _exitFullscreen : _enterFullscreen,
              icon: Icon(
                _fullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
              ),
              iconSize: 22,
              visualDensity: VisualDensity.compact,
              color: Colors.white,
            ),
          ],
        ),
      ],
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
