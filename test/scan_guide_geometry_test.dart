import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/scan_guide_geometry.dart';

void main() {
  test('70% 识别框是居中的正方形', () {
    final Rect rect = scanGuideSquareRect(
      sourceSize: const Size(1080, 1920),
      canvasSize: const Size(540, 960),
    );

    expect(rect.width, closeTo(378, 0.001));
    expect(rect.height, closeTo(378, 0.001));
    expect(rect.center.dx, closeTo(270, 0.001));
    expect(rect.center.dy, closeTo(480, 0.001));
  });

  test('画布比例不同时保持居中且不超出画面', () {
    final Rect rect = scanGuideSquareRect(
      sourceSize: const Size(1080, 1920),
      canvasSize: const Size(600, 800),
    );

    expect(rect.width, closeTo(315, 0.001));
    expect(rect.center.dx, closeTo(300, 0.001));
    expect(rect.center.dy, closeTo(400, 0.001));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(600));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(800));
  });

  test('未知源尺寸时退回画布短边 70%', () {
    final Rect rect = scanGuideSquareRect(
      sourceSize: Size.zero,
      canvasSize: const Size(540, 960),
    );

    expect(rect.width, closeTo(378, 0.001));
    expect(rect.center, const Offset(270, 480));
  });

  test('按镜头选择覆盖比例', () {
    expect(scanGuideCoverageForLens(0.7), 0.7);
    expect(scanGuideCoverageForLens(1.0), 1.0);
    expect(scanGuideCoverageForLens(2.0), 1.0);
  });

  test('100% 识别框取满短边', () {
    final Rect rect = scanGuideSquareRect(
      sourceSize: const Size(1080, 1920),
      canvasSize: const Size(540, 960),
      coverage: scanGuideCoverageForLens(1.0),
    );

    expect(rect.width, closeTo(540, 0.001));
    expect(rect.height, closeTo(540, 0.001));
    expect(rect.center, const Offset(270, 480));
  });
}
