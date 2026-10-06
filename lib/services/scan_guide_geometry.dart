import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'preview_cover_transform.dart';

/// 超广角裁剪使用的中心正方形边长占源图短边的比例。
///
/// 必须与 Android `BarcodeAnalysisPassPolicy` 里的 `crop70` 保持一致；
/// 预览画面上的四个方角就是这个裁剪区域的可视化。
const double scanGuideCoverage = 0.7;

/// 当前镜头对应的识别框覆盖比例：超广角 70%，主摄/长焦 100%。
double scanGuideCoverageForLens(double zoomRatio) =>
    zoomRatio < 1.0 ? scanGuideCoverage : 1.0;

/// 计算识别框在预览画布上的矩形。
///
/// 预览按 contain 布局，正方形居中于画面；[sourceSize] 是竖屏预览源图尺寸，
/// [canvasSize] 是摄像头区域的实际大小。
Rect scanGuideSquareRect({
  required Size sourceSize,
  required Size canvasSize,
  double coverage = scanGuideCoverage,
}) {
  final double safeCoverage = coverage.clamp(0.1, 1.0).toDouble();
  if (sourceSize.width <= 0 ||
      sourceSize.height <= 0 ||
      canvasSize.width <= 0 ||
      canvasSize.height <= 0) {
    final double side =
        math.min(canvasSize.width, canvasSize.height) * safeCoverage;
    return Rect.fromLTWH(
      (canvasSize.width - side) / 2,
      (canvasSize.height - side) / 2,
      side,
      side,
    );
  }
  final PreviewCoverTransform transform = PreviewCoverTransform.contain(
    sourceSize: sourceSize,
    canvasSize: canvasSize,
  );
  final double shortSide = math.min(sourceSize.width, sourceSize.height);
  final double side = shortSide * safeCoverage;
  final double sourceLeft = (sourceSize.width - side) / 2;
  final double sourceTop = (sourceSize.height - side) / 2;
  return Rect.fromLTWH(
    transform.destinationRect.left + sourceLeft * transform.scale,
    transform.destinationRect.top + sourceTop * transform.scale,
    side * transform.scale,
    side * transform.scale,
  );
}
