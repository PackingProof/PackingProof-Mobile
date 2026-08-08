import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/remote_playback_compat.dart';
import 'package:packing_proof_mobile/services/system_video_player_service.dart';

void main() {
  final Uri base = Uri.parse(
    'http://host/api/mobile-backup/videos/1/play?ticket=abc',
  );
  final VideoDecodeSupport hevcSupported = VideoDecodeSupport(
    manufacturer: '',
    brand: '',
    model: '',
    sdkInt: 0,
    release: '',
    hasHevcDecoder: true,
    hasAvcDecoder: true,
  );
  final VideoDecodeSupport hevcMissing = VideoDecodeSupport(
    manufacturer: '',
    brand: '',
    model: '',
    sdkInt: 0,
    release: '',
    hasHevcDecoder: false,
    hasAvcDecoder: true,
  );

  test('H.264 始终直传，不依赖设备能力', () {
    expect(
      RemotePlaybackCompat.resolvePlaybackUri(
        base,
        decodeSupport: hevcMissing,
        videoCodec: 'h264',
      ).queryParameters['compat'],
      '0',
    );
  });

  test('H.265 按设备 HEVC 能力选择直传或转码', () {
    expect(
      RemotePlaybackCompat.resolvePlaybackUri(
        base,
        decodeSupport: hevcSupported,
        videoCodec: 'h265',
      ).queryParameters['compat'],
      '0',
    );
    expect(
      RemotePlaybackCompat.resolvePlaybackUri(
        base,
        decodeSupport: hevcMissing,
        videoCodec: 'hevc',
      ).queryParameters['compat'],
      '1',
    );
  });

  test('编码缺失时按设备能力兜底', () {
    expect(
      RemotePlaybackCompat.resolvePlaybackUri(
        base,
        decodeSupport: hevcSupported,
      ).queryParameters['compat'],
      '0',
    );
    expect(
      RemotePlaybackCompat.resolvePlaybackUri(
        base,
        decodeSupport: hevcMissing,
      ).queryParameters['compat'],
      '1',
    );
    expect(
      RemotePlaybackCompat.resolvePlaybackUri(
        base,
        decodeSupport: null,
      ).queryParameters['compat'],
      '1',
    );
  });

  test('替换 compat 时保留 ticket 等参数', () {
    final Uri resolved = RemotePlaybackCompat.withCompat(
      Uri.parse('http://host/play?ticket=t&compat=1'),
      RemotePlaybackCompat.direct,
    );
    expect(resolved.queryParameters['ticket'], 't');
    expect(resolved.queryParameters['compat'], '0');
  });

  test('isDirect 只认 compat=0', () {
    expect(
      RemotePlaybackCompat.isDirect(Uri.parse('http://host/play?compat=0')),
      isTrue,
    );
    expect(
      RemotePlaybackCompat.isDirect(Uri.parse('http://host/play?compat=1')),
      isFalse,
    );
    expect(
      RemotePlaybackCompat.isDirect(Uri.parse('http://host/play')),
      isFalse,
    );
  });
}
