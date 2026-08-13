import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/platform/contracts/thumbnail_platform.dart';
import 'package:packing_proof_mobile/services/recording_thumbnail_service.dart';

class _FakeThumbnailPlatform implements ThumbnailPlatform {
  _FakeThumbnailPlatform(this.result);

  final String? result;

  @override
  Future<String?> generate(String filePath) async => result;
}

void main() {
  test('缩略图服务使用注入的平台实现', () async {
    final RecordingThumbnailService service = RecordingThumbnailService(
      platform: _FakeThumbnailPlatform('/tmp/preview.jpg'),
    );

    expect(await service.generate('/tmp/video.mp4'), '/tmp/preview.jpg');
  });

  test('空路径不请求平台实现', () async {
    final RecordingThumbnailService service = RecordingThumbnailService(
      platform: _FakeThumbnailPlatform('/tmp/preview.jpg'),
    );

    expect(await service.generate(''), isNull);
  });
}
