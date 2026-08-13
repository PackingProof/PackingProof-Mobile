import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/contracts/media_platform.dart';
import '../platform/platform_container.dart';

typedef VideoShareProgress = void Function(double progress, String message);

class VideoShareService {
  VideoShareService({
    MethodChannel? channel,
    Directory? cacheDirectory,
    bool? nativeExportSupported,
    MediaProcessingPlatform? platform,
  }) : _providedCacheDirectory = cacheDirectory,
       _nativeExportSupported = nativeExportSupported ?? Platform.isAndroid,
       _platform =
           platform ??
           (channel != null
               ? _LegacyVideoExportPlatform(channel)
               : AppContainer.forCurrentPlatform().mediaProcessing);

  static const Duration _maximumAge = Duration(hours: 24);
  static const int _maximumBytes = 512 * 1024 * 1024;

  final Directory? _providedCacheDirectory;
  final bool _nativeExportSupported;
  final MediaProcessingPlatform _platform;

  Future<File> prepare({
    required String sourcePath,
    Uri? remoteUri,
    Map<String, String> remoteHeaders = const <String, String>{},
    required Duration mediaStart,
    required Duration mediaEnd,
    required Duration sourceDuration,
    VideoShareProgress? onProgress,
  }) async {
    final Directory cache = await _cacheDirectory();
    await _cleanCache(cache);
    final File source = remoteUri == null
        ? File(sourcePath)
        : await _downloadRemote(
            cache,
            remoteUri,
            remoteHeaders,
            onProgress: onProgress,
          );
    if (!await source.exists()) {
      throw StateError('录像文件不存在');
    }

    final bool fullRange =
        mediaStart <= const Duration(milliseconds: 50) &&
        mediaEnd >= sourceDuration - const Duration(milliseconds: 50);
    if (fullRange) {
      onProgress?.call(1, '准备分享');
      return source;
    }
    if (!_nativeExportSupported) {
      throw UnsupportedError('当前平台暂不支持分享剪辑范围');
    }

    final FileStat stat = await source.stat();
    final String key = sha256
        .convert(
          utf8.encode(
            '${source.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}|'
            '${mediaStart.inMilliseconds}|${mediaEnd.inMilliseconds}',
          ),
        )
        .toString();
    final File output = File(p.join(cache.path, 'clip_$key.mp4'));
    if (await output.exists() && await output.length() > 0) {
      await output.setLastModified(DateTime.now());
      onProgress?.call(1, '准备分享');
      return output;
    }

    onProgress?.call(0.5, '正在生成分享视频');
    bool completed = false;
    final Timer progressTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_reportNativeProgress(onProgress)),
    );
    try {
      final String exported = await _platform.exportRange(
        inputPath: source.path,
        outputPath: output.path,
        startMs: mediaStart.inMilliseconds,
        endMs: mediaEnd.inMilliseconds,
      );
      completed = true;
      final File result = File(exported.isEmpty ? output.path : exported);
      if (!await result.exists() || await result.length() == 0) {
        throw StateError('分享视频生成失败');
      }
      onProgress?.call(1, '准备分享');
      return result;
    } finally {
      progressTimer.cancel();
      if (!completed && await output.exists()) {
        await output.delete();
      }
    }
  }

  Future<void> _reportNativeProgress(VideoShareProgress? callback) async {
    if (callback == null) return;
    try {
      final int value = await _platform.exportProgress();
      callback(0.5 + value.clamp(0, 100) / 200, '正在生成分享视频');
    } on PlatformException {
      // Export completion or cancellation can race with the final progress poll.
    }
  }

  Future<File> _downloadRemote(
    Directory cache,
    Uri uri,
    Map<String, String> headers, {
    VideoShareProgress? onProgress,
  }) async {
    final String key = sha256.convert(utf8.encode(uri.toString())).toString();
    final File destination = File(p.join(cache.path, 'remote_$key.mp4'));
    if (await destination.exists() && await destination.length() > 0) {
      await destination.setLastModified(DateTime.now());
      onProgress?.call(0.45, '电脑录像已下载');
      return destination;
    }
    final File partial = File('${destination.path}.partial');
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(uri);
      headers.forEach(request.headers.set);
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('电脑录像下载失败（${response.statusCode}）', uri: uri);
      }
      final int total = response.contentLength;
      int received = 0;
      final IOSink sink = partial.openWrite();
      await for (final List<int> chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        final double fraction = total > 0 ? received / total : 0;
        onProgress?.call(fraction.clamp(0, 1) * 0.45, '正在下载电脑录像');
      }
      await sink.close();
      await partial.rename(destination.path);
      return destination;
    } finally {
      client.close(force: true);
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<Directory> _cacheDirectory() async {
    final Directory cache;
    if (_providedCacheDirectory != null) {
      cache = _providedCacheDirectory;
    } else {
      final Directory root = await getTemporaryDirectory();
      cache = Directory(p.join(root.path, 'video_share'));
    }
    await cache.create(recursive: true);
    return cache;
  }

  Future<void> _cleanCache(Directory cache) async {
    final DateTime cutoff = DateTime.now().subtract(_maximumAge);
    final List<File> files = await cache
        .list()
        .where((FileSystemEntity entity) => entity is File)
        .cast<File>()
        .toList();
    for (final File file in files) {
      final FileStat stat = await file.stat();
      if (stat.modified.isBefore(cutoff)) await file.delete();
    }
    final List<File> retained = await cache
        .list()
        .where((FileSystemEntity entity) => entity is File)
        .cast<File>()
        .toList();
    final List<({File file, FileStat stat})> entries =
        <({File file, FileStat stat})>[];
    int total = 0;
    for (final File file in retained) {
      final FileStat stat = await file.stat();
      entries.add((file: file, stat: stat));
      total += stat.size;
    }
    entries.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    for (final entry in entries) {
      if (total <= _maximumBytes) break;
      await entry.file.delete();
      total -= entry.stat.size;
    }
  }
}

class _LegacyVideoExportPlatform implements MediaProcessingPlatform {
  const _LegacyVideoExportPlatform(this.channel);

  final MethodChannel channel;

  @override
  Future<String> applyWatermark({
    required String inputPath,
    required String outputPath,
    required int startedAtMs,
    required String trackingNumber,
    required String videoCodec,
  }) {
    throw UnsupportedError('导出通道不支持水印');
  }

  @override
  Future<String> exportRange({
    required String inputPath,
    required String outputPath,
    required int startMs,
    required int endMs,
  }) async {
    final String? exported = await channel.invokeMethod<String>('export', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'startMs': startMs,
      'endMs': endMs,
    });
    return exported ?? '';
  }

  @override
  Future<int> exportProgress() async =>
      await channel.invokeMethod<int>('progress') ?? 0;
}
