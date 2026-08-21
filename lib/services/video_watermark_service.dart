import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/recording_video_codec.dart';
import '../models/recording_orientation.dart';
import '../platform/contracts/media_platform.dart';
import '../platform/platform_container.dart';

abstract interface class VideoWatermarkSink {
  Future<String> apply({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    RecordingVideoCodec videoCodec = RecordingVideoCodec.hevc,
  });
}

abstract interface class OrientedVideoWatermarkSink {
  Future<String> applyWithOrientation({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    required RecordingVideoCodec videoCodec,
    required RecordingOrientation recordingOrientation,
  });
}

class VideoWatermarkService
    implements VideoWatermarkSink, OrientedVideoWatermarkSink {
  VideoWatermarkService({
    MethodChannel? channel,
    bool? isAndroid,
    bool? isIOS,
    MediaProcessingPlatform? platform,
  }) : _platform =
           platform ??
           (channel != null
               ? _LegacyVideoWatermarkPlatform(channel)
               : AppContainer.forCurrentPlatform().mediaProcessing),
       _isAndroid = isAndroid ?? Platform.isAndroid,
       _isIOS = isIOS ?? Platform.isIOS;

  final MediaProcessingPlatform _platform;
  final bool _isAndroid;
  final bool _isIOS;
  Future<void> _tail = Future<void>.value();

  @override
  Future<String> apply({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    RecordingVideoCodec videoCodec = RecordingVideoCodec.hevc,
    RecordingOrientation recordingOrientation = RecordingOrientation.portrait,
  }) {
    final Completer<String> result = Completer<String>();
    _tail = _tail.catchError((Object _) {}).then((_) async {
      try {
        result.complete(
          await _applyNow(
            inputPath: inputPath,
            startedAt: startedAt,
            trackingNumber: trackingNumber,
            videoCodec: videoCodec,
            recordingOrientation: recordingOrientation,
          ),
        );
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  @override
  Future<String> applyWithOrientation({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    required RecordingVideoCodec videoCodec,
    required RecordingOrientation recordingOrientation,
  }) => apply(
    inputPath: inputPath,
    startedAt: startedAt,
    trackingNumber: trackingNumber,
    videoCodec: videoCodec,
    recordingOrientation: recordingOrientation,
  );

  Future<String> _applyNow({
    required String inputPath,
    required DateTime startedAt,
    required String trackingNumber,
    required RecordingVideoCodec videoCodec,
    required RecordingOrientation recordingOrientation,
  }) async {
    if (!_isAndroid && !_isIOS) return inputPath;
    final int dot = inputPath.lastIndexOf('.');
    final String outputPath = dot > 0
        ? '${inputPath.substring(0, dot)}_watermarked.mp4'
        : '${inputPath}_watermarked.mp4';
    final String result = await _platform.applyWatermark(
      inputPath: inputPath,
      outputPath: outputPath,
      startedAtMs: startedAt.millisecondsSinceEpoch,
      trackingNumber: trackingNumber,
      videoCodec: videoCodec.storageValue,
      recordingOrientation: recordingOrientation.storageValue,
    );
    final File output = File(result);
    if (result.isEmpty ||
        !await output.exists() ||
        await output.length() <= 0) {
      throw StateError('水印视频生成失败');
    }
    return result;
  }
}

class _LegacyVideoWatermarkPlatform implements MediaProcessingPlatform {
  const _LegacyVideoWatermarkPlatform(this.channel);

  final MethodChannel channel;

  @override
  Future<String> applyWatermark({
    required String inputPath,
    required String outputPath,
    required int startedAtMs,
    required String trackingNumber,
    required String videoCodec,
    String recordingOrientation = 'portrait',
  }) async {
    final String? result = await channel.invokeMethod<String>('apply', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'startedAtMs': startedAtMs,
      'trackingNumber': trackingNumber,
      'videoCodec': videoCodec,
      'recordingOrientation': recordingOrientation,
    });
    return result ?? '';
  }

  @override
  Future<String> exportRange({
    required String inputPath,
    required String outputPath,
    required int startMs,
    required int endMs,
  }) {
    throw UnsupportedError('水印通道不支持导出');
  }

  @override
  Future<int> exportProgress() async => 100;
}
