import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/remote_playback_probe.dart';

void main() {
  final Uri uri = Uri.parse(
    'http://192.168.31.63:5280/api/mobile-backup/videos/4/play?ticket=abc',
  );

  test('主机返回 403 时解析错误码与错误文案', () async {
    final RemotePlaybackProbe probe = RemotePlaybackProbe(
      requester: (Uri requested) async => const ProbeHttpResponse(
        statusCode: 403,
        contentType: 'application/json',
        body:
            '{"errorCode":"device_identity_required",'
            '"error":"设备身份验证失败，请重新连接"}',
      ),
    );

    final RemotePlaybackProbeResult result = await probe.probe(uri);

    expect(result.statusCode, 403);
    expect(result.hostErrorCode, 'device_identity_required');
    expect(result.hostError, contains('设备身份验证失败'));
    expect(result.networkError, isNull);
  });

  test('网络异常记录 probeError', () async {
    final RemotePlaybackProbe probe = RemotePlaybackProbe(
      requester: (Uri requested) async =>
          throw SocketException('Connection refused'),
    );

    final RemotePlaybackProbeResult result = await probe.probe(uri);

    expect(result.statusCode, isNull);
    expect(result.networkError, contains('Connection refused'));
    expect(result.toDiagnosticsMap()['probeError'], isNotNull);
  });

  test('超时记录 timeout', () async {
    final RemotePlaybackProbe probe = RemotePlaybackProbe(
      requester: (Uri requested) => Completer<ProbeHttpResponse>().future,
      timeout: const Duration(milliseconds: 20),
    );

    final RemotePlaybackProbeResult result = await probe.probe(uri);

    expect(result.networkError, startsWith('timeout'));
  });
}
