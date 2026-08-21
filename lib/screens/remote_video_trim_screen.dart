import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/remote_video_clip_service.dart';

class RemoteVideoTrimScreen extends StatefulWidget {
  const RemoteVideoTrimScreen({
    required this.videoId,
    required this.playUri,
    required this.duration,
    required this.service,
    super.key,
  });

  final int videoId;
  final Uri playUri;
  final Duration duration;
  final RemoteVideoClipSink service;

  @override
  State<RemoteVideoTrimScreen> createState() => _RemoteVideoTrimScreenState();
}

class _RemoteVideoTrimScreenState extends State<RemoteVideoTrimScreen> {
  static final Map<int, RangeValues> _drafts = <int, RangeValues>{};
  late final VideoPlayerController _video;
  late final Future<void> _initialized;
  late RangeValues _range;
  List<RemoteClipFrame> _frames = const <RemoteClipFrame>[];
  String? _taskId;
  bool _busy = false;
  bool _previewingRange = false;
  double? _progress;
  String _status = '';

  @override
  void initState() {
    super.initState();
    final double total = widget.duration.inMilliseconds / 1000;
    _range = _drafts[widget.videoId] ?? RangeValues(0, total < 1 ? 1 : total);
    _video = VideoPlayerController.networkUrl(
      widget.playUri,
      httpHeaders: widget.service.headers,
    );
    _initialized = _video.initialize().then((_) async {
      await _video.setVolume(1);
      _video.addListener(_handleVideoTick);
      await _video.seekTo(
        Duration(milliseconds: (_range.start * 1000).round()),
      );
    });
    unawaited(_loadFrames());
  }

  void _handleVideoTick() {
    if (!_previewingRange || !_video.value.isInitialized) return;
    final double seconds =
        _video.value.position.inMilliseconds / Duration.millisecondsPerSecond;
    if (seconds + 0.03 < _range.end) return;
    _previewingRange = false;
    unawaited(_video.pause());
    if (mounted) setState(() {});
  }

  Future<void> _toggleRangePreview() async {
    if (_busy || !_video.value.isInitialized) return;
    if (_previewingRange && _video.value.isPlaying) {
      _previewingRange = false;
      await _video.pause();
      if (mounted) setState(() {});
      return;
    }
    final double position =
        _video.value.position.inMilliseconds / Duration.millisecondsPerSecond;
    if (position < _range.start || position >= _range.end - 0.05) {
      await _video.seekTo(
        Duration(milliseconds: (_range.start * 1000).round()),
      );
    }
    _previewingRange = true;
    await _video.play();
    if (mounted) setState(() {});
  }

  void _updateRange(RangeValues value) {
    final RangeValues previous = _range;
    final bool startMoved =
        (value.start - previous.start).abs() >=
        (value.end - previous.end).abs();
    _previewingRange = false;
    unawaited(_video.pause());
    unawaited(
      _video.seekTo(
        Duration(
          milliseconds: ((startMoved ? value.start : value.end) * 1000).round(),
        ),
      ),
    );
    setState(() => _range = value);
  }

  Future<void> _loadFrames() async {
    try {
      final frames = await widget.service.loadTimeline(widget.videoId);
      if (mounted) setState(() => _frames = frames);
    } on Object {
      // The source video remains usable when timeline frames are unavailable.
    }
  }

  Future<void> _generate() async {
    if (_busy) return;
    _drafts[widget.videoId] = _range;
    setState(() {
      _busy = true;
      _progress = null;
      _status = '电脑正在生成剪辑';
    });
    try {
      _taskId = await widget.service.start(
        widget.videoId,
        _range.start,
        _range.end,
      );
      while (mounted) {
        final task = await widget.service.task(_taskId!);
        final String status = '${task['status'] ?? ''}';
        if (status == 'completed') {
          final Uri uri = widget.playUri.resolve(
            '${task['downloadUrl'] ?? ''}',
          );
          setState(() => _status = '正在下载剪辑');
          final File file = await widget.service.download(
            uri,
            onProgress: (value) {
              if (mounted) setState(() => _progress = value);
            },
          );
          if (mounted) Navigator.of(context).pop(file);
          return;
        }
        if (status == 'failed' ||
            status == 'canceled' ||
            status == 'not_found') {
          throw StateError('${task['message'] ?? '剪辑生成失败'}');
        }
        if (mounted) {
          setState(() => _status = '${task['message'] ?? '电脑正在生成剪辑'}');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
          _progress = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    }
  }

  Future<void> _cancel() async {
    final taskId = _taskId;
    if (taskId != null) await widget.service.cancel(taskId);
    if (mounted) {
      setState(() {
        _busy = false;
        _taskId = null;
        _status = '已取消';
      });
    }
  }

  @override
  void dispose() {
    _video.removeListener(_handleVideoTick);
    unawaited(_video.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double total = widget.duration.inMilliseconds / 1000;
    return Scaffold(
      appBar: AppBar(title: const Text('剪辑电脑录像')),
      body: FutureBuilder<void>(
        future: _initialized,
        builder: (context, snapshot) => ListView(
          padding: const EdgeInsets.all(18),
          children: <Widget>[
            AspectRatio(
              aspectRatio: _video.value.isInitialized
                  ? _video.value.aspectRatio
                  : 16 / 9,
              child: snapshot.connectionState == ConnectionState.done
                  ? GestureDetector(
                      onTap: _toggleRangePreview,
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          VideoPlayer(_video),
                          if (!_previewingRange)
                            const Center(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Color(0x66000000),
                                  shape: BoxShape.circle,
                                ),
                                child: Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 34,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    )
                  : const Center(child: CircularProgressIndicator()),
            ),
            const SizedBox(height: 12),
            if (_frames.isNotEmpty)
              SizedBox(
                height: 58,
                child: Row(
                  children: _frames
                      .map(
                        (frame) => Expanded(
                          child: Image.network(
                            frame.uri.toString(),
                            headers: widget.service.headers,
                            height: 58,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => ColoredBox(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                            ),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
            RangeSlider(
              values: _range,
              min: 0,
              max: total < 1 ? 1 : total,
              onChanged: _busy ? null : _updateRange,
              onChangeEnd: _busy
                  ? null
                  : (RangeValues value) => _drafts[widget.videoId] = value,
            ),
            Text(
              '${_range.start.toStringAsFixed(1)} 秒 – ${_range.end.toStringAsFixed(1)} 秒',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _toggleRangePreview,
              icon: Icon(
                _previewingRange
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
              label: Text(_previewingRange ? '暂停预览' : '播放选区'),
            ),
            if (_busy) ...<Widget>[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text(_status, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 20),
            Row(
              children: <Widget>[
                if (_busy) ...<Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _cancel,
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _generate,
                    icon: const Icon(Icons.content_cut_rounded),
                    label: const Text('生成并分享'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
