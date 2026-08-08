import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 探测响应摘要（测试可注入）。
class ProbeHttpResponse {
  const ProbeHttpResponse({
    required this.statusCode,
    this.contentType,
    required this.body,
  });

  final int statusCode;
  final String? contentType;
  final String body;
}

typedef RemotePlaybackRequester = Future<ProbeHttpResponse> Function(Uri uri);

/// 远程播放源探测结果：记录 HTTP 状态、主机错误码与网络异常，
/// 用于把 ExoPlayer 的 `Source error` 细化为 403/404/网络不可达。
class RemotePlaybackProbeResult {
  const RemotePlaybackProbeResult({
    this.statusCode,
    this.contentType,
    this.hostErrorCode,
    this.hostError,
    this.networkError,
    required this.latencyMs,
  });

  final int? statusCode;
  final String? contentType;
  final String? hostErrorCode;
  final String? hostError;
  final String? networkError;
  final int latencyMs;

  Map<String, Object?> toDiagnosticsMap() => <String, Object?>{
    if (statusCode != null) 'httpStatus': statusCode,
    if (contentType != null) 'httpContentType': contentType,
    if (hostErrorCode != null) 'hostErrorCode': hostErrorCode,
    if (hostError != null) 'hostError': hostError,
    if (networkError != null) 'probeError': networkError,
    'probeLatencyMs': latencyMs,
  };
}

/// 远程播放失败时对播放地址做一次轻量 Range 探测。
class RemotePlaybackProbe {
  RemotePlaybackProbe({RemotePlaybackRequester? requester, Duration? timeout})
    : _requester = requester ?? _defaultRequester,
      _timeout = timeout ?? const Duration(seconds: 5);

  final RemotePlaybackRequester _requester;
  final Duration _timeout;

  Future<RemotePlaybackProbeResult> probe(Uri uri) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      final ProbeHttpResponse response = await _requester(
        uri,
      ).timeout(_timeout);
      (String?, String?) parsed = (null, null);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        parsed = _parseErrorBody(response.body);
      }
      return RemotePlaybackProbeResult(
        statusCode: response.statusCode,
        contentType: response.contentType,
        hostErrorCode: parsed.$1,
        hostError: parsed.$2 ?? (response.body.isEmpty ? null : response.body),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on TimeoutException catch (error) {
      return RemotePlaybackProbeResult(
        networkError: 'timeout: $error',
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on SocketException catch (error) {
      return RemotePlaybackProbeResult(
        networkError: 'socket: ${error.message}',
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on HttpException catch (error) {
      return RemotePlaybackProbeResult(
        networkError: 'http: ${error.message}',
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on Object catch (error) {
      return RemotePlaybackProbeResult(
        networkError: '$error',
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  (String?, String?) _parseErrorBody(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        return (decoded['errorCode'] as String?, decoded['error'] as String?);
      }
    } on Object {
      // 非 JSON 错误体，按原文记录。
    }
    return (null, null);
  }
}

Future<ProbeHttpResponse> _defaultRequester(Uri uri) async {
  final HttpClient client = HttpClient();
  try {
    client.connectionTimeout = const Duration(seconds: 5);
    final HttpClientRequest request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final HttpClientResponse response = await request.close();
    final String body = response.statusCode >= 200 && response.statusCode < 300
        ? ''
        : await _readLimitedBody(response);
    return ProbeHttpResponse(
      statusCode: response.statusCode,
      contentType: response.headers.contentType?.toString(),
      body: body,
    );
  } finally {
    client.close(force: true);
  }
}

Future<String> _readLimitedBody(HttpClientResponse response) async {
  try {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response) {
      builder.add(chunk);
      if (builder.length >= 4096) break;
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  } on Object {
    return '';
  }
}
