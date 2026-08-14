import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef RemoteClipRequestAuthorizer =
    void Function(
      HttpClientRequest request,
      List<int> body,
      String method,
      String path,
    );

class RemoteClipFrame {
  const RemoteClipFrame({required this.seconds, required this.uri});
  final double seconds;
  final Uri uri;
}

abstract interface class RemoteVideoClipSink {
  Future<List<RemoteClipFrame>> loadTimeline(
    int videoId, {
    int frameCount = 10,
  });
  Future<String> start(int videoId, double startSeconds, double endSeconds);
  Future<Map<String, Object?>> task(String taskId);
  Future<void> cancel(String taskId);
  Future<File> download(Uri uri, {void Function(double progress)? onProgress});
  Map<String, String> get headers;
}

class RemoteVideoClipService implements RemoteVideoClipSink {
  RemoteVideoClipService({
    required this.baseUri,
    required this.accessHeaders,
    this.deviceScoped = false,
    this.requestAuthorizer,
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  final Uri baseUri;
  final Map<String, String> accessHeaders;
  final bool deviceScoped;
  final RemoteClipRequestAuthorizer? requestAuthorizer;
  final HttpClient _client;

  @override
  Map<String, String> get headers => accessHeaders;

  @override
  Future<List<RemoteClipFrame>> loadTimeline(
    int videoId, {
    int frameCount = 10,
  }) async {
    final payload = await _json(
      'POST',
      deviceScoped
          ? '/api/mobile-backup/videos/$videoId/clip/timeline'
          : '/api/videos/$videoId/clip/timeline',
      body: <String, Object>{'frameCount': frameCount},
    );
    return ((payload['frames'] as List<Object?>?) ?? const <Object?>[])
        .whereType<Map>()
        .map(
          (frame) => RemoteClipFrame(
            seconds: (frame['seconds'] as num?)?.toDouble() ?? 0,
            uri: baseUri.resolve('${frame['url'] ?? ''}'),
          ),
        )
        .where((frame) => frame.uri.path.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<String> start(
    int videoId,
    double startSeconds,
    double endSeconds,
  ) async {
    final payload = await _json(
      'POST',
      deviceScoped
          ? '/api/mobile-backup/videos/$videoId/clip'
          : '/api/videos/$videoId/clip',
      body: <String, Object>{
        'startSeconds': startSeconds,
        'endSeconds': endSeconds,
      },
    );
    final String taskId = '${payload['taskId'] ?? ''}';
    if (taskId.isEmpty) throw const FormatException('电脑未返回剪辑任务');
    return taskId;
  }

  @override
  Future<Map<String, Object?>> task(String taskId) => _json(
    'GET',
    deviceScoped
        ? '/api/mobile-backup/clip-tasks/${Uri.encodeComponent(taskId)}'
        : '/api/clip-tasks/${Uri.encodeComponent(taskId)}',
  );

  @override
  Future<void> cancel(String taskId) async {
    await _json(
      'POST',
      deviceScoped
          ? '/api/mobile-backup/clip-tasks/${Uri.encodeComponent(taskId)}/cancel'
          : '/api/clip-tasks/${Uri.encodeComponent(taskId)}/cancel',
    );
  }

  @override
  Future<File> download(
    Uri uri, {
    void Function(double progress)? onProgress,
  }) async {
    final request = await _client.getUrl(uri);
    accessHeaders.forEach(request.headers.set);
    requestAuthorizer?.call(request, const <int>[], 'GET', uri.path);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      final String body = await utf8.decoder.bind(response).join();
      throw HttpException(_downloadErrorMessage(response.statusCode, body));
    }
    final directory = Directory(
      p.join((await getTemporaryDirectory()).path, 'remote_clips'),
    )..createSync(recursive: true);
    final file = File(
      p.join(
        directory.path,
        'PackingProof-${DateTime.now().millisecondsSinceEpoch}.mp4',
      ),
    );
    final sink = file.openWrite();
    int received = 0;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (response.contentLength > 0) {
          onProgress?.call(received / response.contentLength);
        }
      }
    } finally {
      await sink.close();
    }
    return file;
  }

  String _downloadErrorMessage(int statusCode, String body) {
    try {
      final Object? decoded = body.isEmpty ? null : jsonDecode(body);
      if (decoded is Map) {
        final String message = '${decoded['error'] ?? decoded['message'] ?? ''}'
            .trim();
        if (message.isNotEmpty) return message;
      }
    } on FormatException {
      // 非 JSON 响应体使用通用文案。
    }
    return '剪辑文件下载失败（$statusCode）';
  }

  Future<Map<String, Object?>> _json(
    String method,
    String path, {
    Map<String, Object>? body,
  }) async {
    final uri = baseUri.resolve(path);
    final List<int> encodedBody = body == null
        ? const <int>[]
        : utf8.encode(jsonEncode(body));
    final request = method == 'POST'
        ? await _client.postUrl(uri)
        : await _client.getUrl(uri);
    accessHeaders.forEach(request.headers.set);
    requestAuthorizer?.call(request, encodedBody, method, uri.path);
    if (encodedBody.isNotEmpty) {
      request.headers.contentType = ContentType.json;
      request.add(encodedBody);
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await utf8.decoder.bind(response).join();
    final payload = text.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(text) as Map);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        '${payload['error'] ?? payload['message'] ?? '电脑剪辑失败'}',
      );
    }
    return payload;
  }
}
