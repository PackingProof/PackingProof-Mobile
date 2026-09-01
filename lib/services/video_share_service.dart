import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/contracts/media_platform.dart';
import '../platform/platform_capabilities.dart';
import '../platform/platform_container.dart';

typedef VideoShareProgress = void Function(double progress, String message);

class VideoShareService {
  VideoShareService({
    MethodChannel? channel,
    Directory? cacheDirectory,
    bool? nativeExportSupported,
    bool? remuxFullRangeHevc,
    MediaProcessingPlatform? platform,
    SystemMediaPresenter? systemMediaPresenter,
  }) : _providedCacheDirectory = cacheDirectory,
       _nativeExportSupported =
           nativeExportSupported ??
           AppContainer.forCurrentPlatform().capabilities.supports(
             PlatformCapability.videoExport,
           ),
       _remuxFullRangeHevc = remuxFullRangeHevc ?? Platform.isIOS,
       _platform =
           platform ??
           (channel != null
               ? _LegacyVideoExportPlatform(channel)
               : AppContainer.forCurrentPlatform().mediaProcessing),
       _systemMediaPresenter =
           systemMediaPresenter ??
           AppContainer.forCurrentPlatform().systemMediaPresenter;

  static const Duration _maximumAge = Duration(hours: 24);
  static const int _maximumBytes = 512 * 1024 * 1024;

  final Directory? _providedCacheDirectory;
  final bool _nativeExportSupported;
  final bool _remuxFullRangeHevc;
  final MediaProcessingPlatform _platform;
  final SystemMediaPresenter _systemMediaPresenter;

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
    final bool remux = fullRange && await _requiresHevcRemux(source);
    if (fullRange && !remux) {
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
            '${mediaStart.inMilliseconds}|${mediaEnd.inMilliseconds}|'
            '$remux',
          ),
        )
        .toString();
    final String outputPrefix = remux ? 'remux' : 'clip';
    final File output = File(p.join(cache.path, '${outputPrefix}_$key.mp4'));
    if (await output.exists() && await output.length() > 0) {
      await output.setLastModified(DateTime.now());
      onProgress?.call(1, '准备分享');
      return output;
    }

    final String exportMessage = remux ? '正在整理视频文件' : '正在生成分享视频';
    onProgress?.call(0.5, exportMessage);
    bool completed = false;
    final Timer progressTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_reportNativeProgress(onProgress, exportMessage)),
    );
    try {
      final String exported = await _platform.exportRange(
        inputPath: source.path,
        outputPath: output.path,
        startMs: mediaStart.inMilliseconds,
        endMs: mediaEnd.inMilliseconds,
        passthrough: remux,
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

  Future<File> prepareForSharing(
    File source, {
    required String fileName,
  }) async {
    if (p.basename(source.path) == fileName) return source;
    final Directory cache = await _cacheDirectory();
    final String safeName = _sanitizeShareFileName(fileName);
    String destinationPath = p.join(cache.path, safeName);
    if (p.normalize(destinationPath) == p.normalize(source.path)) return source;
    if (await File(destinationPath).exists()) {
      final FileStat stat = await source.stat();
      final String key = sha256
          .convert(
            utf8.encode(
              '${source.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}',
            ),
          )
          .toString()
          .substring(0, 8);
      final String stem = p.basenameWithoutExtension(safeName);
      final String extension = p.extension(safeName);
      destinationPath = p.join(cache.path, '${stem}_分享_$key$extension');
    }
    final File destination = await source.copy(destinationPath);
    await destination.setLastModified(DateTime.now());
    return destination;
  }

  static String _sanitizeShareFileName(String value) {
    final String normalized = value.trim();
    final String safe = normalized.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return safe.isEmpty ? '未识别面单_录像.mp4' : safe;
  }

  Future<bool> _requiresHevcRemux(File source) async {
    if (!_remuxFullRangeHevc || !_nativeExportSupported) return false;
    try {
      final String mime =
          (await _systemMediaPresenter.getVideoTrackMime(source.path) ?? '')
              .trim()
              .toLowerCase();
      if (mime.isEmpty) return true;
      return mime.contains('hevc') ||
          mime.contains('h265') ||
          mime.contains('hvc1') ||
          mime.contains('hev1');
    } on Object {
      return true;
    }
  }

  Future<void> _reportNativeProgress(
    VideoShareProgress? callback,
    String message,
  ) async {
    if (callback == null) return;
    try {
      final int value = await _platform.exportProgress();
      callback(0.5 + value.clamp(0, 100) / 200, message);
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
    String recordingOrientation = 'portrait',
  }) {
    throw UnsupportedError('导出通道不支持水印');
  }

  @override
  Future<void> cancelWatermark() {
    throw UnsupportedError('导出通道不支持水印');
  }

  @override
  Future<String> exportRange({
    required String inputPath,
    required String outputPath,
    required int startMs,
    required int endMs,
    required bool passthrough,
  }) async {
    final String? exported = await channel.invokeMethod<String>('export', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'startMs': startMs,
      'endMs': endMs,
      'passthrough': passthrough,
    });
    return exported ?? '';
  }

  @override
  Future<int> exportProgress() async =>
      await channel.invokeMethod<int>('progress') ?? 0;
}
