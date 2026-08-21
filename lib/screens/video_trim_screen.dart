import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/recording_session.dart';

class VideoTrimScreen extends StatefulWidget {
  const VideoTrimScreen({required this.session, super.key});

  final RecordingSession session;

  @override
  State<VideoTrimScreen> createState() => _VideoTrimScreenState();
}

class _VideoTrimScreenState extends State<VideoTrimScreen> {
  static const double _minimumClipMilliseconds = 500;

  late final VideoPlayerController _video;
  late final Future<void> _initialized;
  late RangeValues _range;
  late double _maximumMilliseconds;
  bool _handlingBoundary = false;
  bool _listenerAdded = false;

  Duration get _previewStart => Duration(milliseconds: _range.start.round());

  Duration get _previewEnd => Duration(milliseconds: _range.end.round());

  @override
  void initState() {
    super.initState();
    _maximumMilliseconds = widget.session.playbackEnd.inMilliseconds.toDouble();
    _range = RangeValues(
      widget.session.mediaStart.inMilliseconds.toDouble(),
      widget.session.playbackEnd.inMilliseconds.toDouble(),
    );
    _video = VideoPlayerController.file(File(widget.session.filePath));
    _initialized = _video.initialize().then((_) async {
      await _video.setVolume(1);
      final double availableMilliseconds = _video.value.duration.inMilliseconds
          .toDouble();
      _maximumMilliseconds = availableMilliseconds;
      final double start = widget.session.mediaStart.inMilliseconds
          .clamp(0, availableMilliseconds)
          .toDouble();
      final double end = widget.session.playbackEnd.inMilliseconds
          .clamp(start, availableMilliseconds)
          .toDouble();
      _range = RangeValues(start, end);
      await _video.seekTo(_previewStart);
      _video.addListener(_handlePlaybackBoundary);
      _listenerAdded = true;
      await _video.play();
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    if (_listenerAdded) {
      _video.removeListener(_handlePlaybackBoundary);
    }
    unawaited(_video.dispose());
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_video.value.isPlaying) {
      await _video.pause();
    } else {
      final Duration position = _video.value.position;
      if (position < _previewStart || position >= _previewEnd) {
        await _video.seekTo(_previewStart);
      }
      await _video.play();
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _handlePlaybackBoundary() {
    if (_handlingBoundary ||
        !_video.value.isInitialized ||
        _video.value.position < _previewEnd) {
      return;
    }
    _handlingBoundary = true;
    unawaited(_rewindAtBoundary());
  }

  Future<void> _rewindAtBoundary() async {
    await _video.pause();
    await _video.seekTo(_previewStart);
    _handlingBoundary = false;
    if (mounted) {
      setState(() {});
    }
  }

  void _setRange(RangeValues values) {
    final double minimumLength = _maximumMilliseconds < _minimumClipMilliseconds
        ? _maximumMilliseconds
        : _minimumClipMilliseconds;
    if (values.end - values.start < minimumLength) {
      return;
    }
    setState(() => _range = values);
  }

  Future<void> _previewRange(RangeValues _) async {
    await _video.seekTo(_previewStart);
    await _video.play();
    if (mounted) {
      setState(() {});
    }
  }

  void _save() {
    final RecordingSession updated = widget.session.trimmedToMediaRange(
      mediaStart: Duration(milliseconds: _range.start.round()),
      mediaEnd: Duration(milliseconds: _range.end.round()),
    );
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('剪辑片段')),
      body: FutureBuilder<void>(
        future: _initialized,
        builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || _maximumMilliseconds <= 0) {
            return const Center(child: Text('录像无法剪辑，请检查文件是否仍在本机'));
          }
          final int divisions = (_maximumMilliseconds / 250).round().clamp(
            1,
            600,
          );
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: AspectRatio(
                  aspectRatio: _video.value.aspectRatio,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      VideoPlayer(_video),
                      Center(
                        child: IconButton.filled(
                          onPressed: _togglePlayback,
                          iconSize: 32,
                          icon: Icon(
                            _video.value.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                '保留范围',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                '拖动两端选择要保留的内容，不会修改或复制原始视频',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              RangeSlider(
                key: const Key('trim-range'),
                values: _range,
                min: 0,
                max: _maximumMilliseconds,
                divisions: divisions,
                labels: RangeLabels(
                  _duration(Duration(milliseconds: _range.start.round())),
                  _duration(Duration(milliseconds: _range.end.round())),
                ),
                onChanged: _setRange,
                onChangeEnd: _previewRange,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(
                    '起点 ${_duration(Duration(milliseconds: _range.start.round()))}',
                  ),
                  Text(
                    '终点 ${_duration(Duration(milliseconds: _range.end.round()))}',
                  ),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.content_cut_rounded),
                label: const Text('保存剪辑'),
              ),
            ],
          );
        },
      ),
    );
  }
}

String _duration(Duration value) {
  String two(int number) => number.toString().padLeft(2, '0');
  final int minutes = value.inMinutes;
  final int seconds = value.inSeconds.remainder(60);
  final int tenths = value.inMilliseconds.remainder(1000) ~/ 100;
  return '${two(minutes)}:${two(seconds)}.$tenths';
}
