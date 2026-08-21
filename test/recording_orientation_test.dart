import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:packing_proof_mobile/models/recording_orientation.dart';
import 'package:packing_proof_mobile/services/watermark_geometry.dart';

void main() {
  test('方向只使用语义名称并未知值回到竖屏', () {
    expect(RecordingOrientation.values, hasLength(3));
    expect(
      recordingOrientationFromStorage('90'),
      RecordingOrientation.portrait,
    );
    expect(recordingOrientationFromStorage('landscapeLeft').label, '横右');
    expect(recordingOrientationFromStorage('landscapeRight').label, '横左');
  });

  test('三种方向都把水印目标放在最终成片右上角', () {
    for (final orientation in RecordingOrientation.values) {
      final geometry = watermarkGeometry(
        orientation: orientation,
        videoSize: const Size(1080, 1920),
        watermarkSize: const Size(300, 80),
      );
      expect(geometry.outputRect.top, 24);
      expect(
        geometry.outputRect.right,
        orientation == RecordingOrientation.portrait ? 1056 : 1896,
      );
    }
  });
}
