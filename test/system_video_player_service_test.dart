import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/system_video_player_service.dart';

void main() {
  test('VideoDecodeSupport 解析原生能力映射', () {
    final VideoDecodeSupport support = VideoDecodeSupport.fromMap(
      <Object?, Object?>{
        'manufacturer': 'HUAWEI',
        'brand': 'HUAWEI',
        'model': 'test-model',
        'sdkInt': 31,
        'release': 'HarmonyOS',
        'hasHevcDecoder': true,
        'hasAvcDecoder': true,
        'preferH264': true,
      },
    );
    expect(support.manufacturer, 'HUAWEI');
    expect(support.model, 'test-model');
    expect(support.sdkInt, 31);
    expect(support.release, 'HarmonyOS');
    expect(support.hasHevcDecoder, isTrue);
    expect(support.hasAvcDecoder, isTrue);
    expect(support.preferH264, isTrue);
    expect(support.hevcRecommended, isFalse);
  });

  test('VideoDecodeSupport 容忍缺失字段', () {
    final VideoDecodeSupport support = VideoDecodeSupport.fromMap(
      <Object?, Object?>{},
    );
    expect(support.manufacturer, '');
    expect(support.sdkInt, 0);
    expect(support.hasHevcDecoder, isFalse);
    expect(support.hasAvcDecoder, isFalse);
    expect(support.preferH264, isFalse);
    expect(support.hevcRecommended, isFalse);
  });
}
