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

  test('三种方向都把水印目标放在最终成片顶部水平居中', () {
    for (final orientation in RecordingOrientation.values) {
      final geometry = watermarkGeometry(
        orientation: orientation,
        videoSize: const Size(1080, 1920),
        watermarkSize: const Size(300, 80),
      );
      final Size output = orientation == RecordingOrientation.portrait
          ? const Size(1080, 1920)
          : const Size(1920, 1080);
      expect(geometry.outputRect.center.dx, output.width / 2);
      expect(geometry.outputRect.top, output.height * 0.1);
    }
  });

  test('预览水印按实际采集尺寸映射竖屏与横屏字号描边', () {
    final WatermarkPreviewMetrics portrait = watermarkPreviewMetrics(
      orientation: RecordingOrientation.portrait,
      viewportWidth: 390,
      sourceVideoSize: const Size(1080, 1920),
    );
    expect(portrait.fontSize, closeTo(61 * 390 / 1080, 0.0001));
    expect(portrait.strokeWidth, closeTo(6.1 * 390 / 1080, 0.0001));

    for (final RecordingOrientation orientation in <RecordingOrientation>[
      RecordingOrientation.landscapeLeft,
      RecordingOrientation.landscapeRight,
    ]) {
      final WatermarkPreviewMetrics landscape = watermarkPreviewMetrics(
        orientation: orientation,
        viewportWidth: 390,
        sourceVideoSize: const Size(1080, 1920),
      );
      expect(landscape.fontSize, closeTo(35 * 390 / 1080, 0.0001));
      expect(landscape.strokeWidth, closeTo(3.5 * 390 / 1080, 0.0001));
    }

    final WatermarkPreviewMetrics smoothLandscape = watermarkPreviewMetrics(
      orientation: RecordingOrientation.landscapeLeft,
      viewportWidth: 390,
      sourceVideoSize: const Size(1280, 720),
    );
    expect(smoothLandscape.fontSize, closeTo(35 * 390 / 720, 0.0001));
    expect(smoothLandscape.strokeWidth, closeTo(3.5 * 390 / 720, 0.0001));
  });

  test('预览水印拒绝无效视口并为无效采集尺寸使用安全回退', () {
    for (final Size sourceVideoSize in <Size>[
      Size.zero,
      const Size(double.infinity, 720),
    ]) {
      final WatermarkPreviewMetrics fallback = watermarkPreviewMetrics(
        orientation: RecordingOrientation.portrait,
        viewportWidth: 390,
        sourceVideoSize: sourceVideoSize,
      );
      expect(fallback.fontSize, closeTo(61 * 390 / 1080, 0.0001));
      expect(fallback.strokeWidth, closeTo(6.1 * 390 / 1080, 0.0001));
    }

    for (final double viewportWidth in <double>[
      0,
      -1,
      double.nan,
      double.infinity,
    ]) {
      final WatermarkPreviewMetrics invalidViewport = watermarkPreviewMetrics(
        orientation: RecordingOrientation.portrait,
        viewportWidth: viewportWidth,
        sourceVideoSize: const Size(1080, 1920),
      );
      expect(invalidViewport.fontSize, 0);
      expect(invalidViewport.strokeWidth, 0);
    }
  });
}
