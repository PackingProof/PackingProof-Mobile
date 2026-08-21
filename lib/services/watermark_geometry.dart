import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import '../models/recording_orientation.dart';

/// 以录像变换为唯一真相的水印几何结果。
class WatermarkGeometry {
  const WatermarkGeometry({
    required this.sourceOffset,
    required this.sourceSize,
    required this.previewQuarterTurns,
    required this.outputRect,
  });

  final Offset sourceOffset;
  final Size sourceSize;
  final int previewQuarterTurns;
  final Rect outputRect;
}

WatermarkGeometry watermarkGeometry({
  required RecordingOrientation orientation,
  required Size videoSize,
  required Size watermarkSize,
  double margin = 24,
}) {
  final bool swaps = orientation != RecordingOrientation.portrait;
  final Size output = swaps
      ? Size(videoSize.height, videoSize.width)
      : videoSize;
  final Rect target = Rect.fromLTWH(
    math.max(margin, output.width - margin - watermarkSize.width),
    margin,
    watermarkSize.width,
    watermarkSize.height,
  );
  final Offset outputTopLeft = target.topLeft;
  final Offset source = switch (orientation) {
    RecordingOrientation.portrait => outputTopLeft,
    RecordingOrientation.landscapeLeft => Offset(
      outputTopLeft.dy,
      videoSize.height - outputTopLeft.dx - watermarkSize.width,
    ),
    RecordingOrientation.landscapeRight => Offset(
      videoSize.width - outputTopLeft.dy - watermarkSize.height,
      outputTopLeft.dx,
    ),
  };
  return WatermarkGeometry(
    sourceOffset: source,
    sourceSize: watermarkSize,
    previewQuarterTurns: switch (orientation) {
      RecordingOrientation.portrait => 0,
      RecordingOrientation.landscapeLeft => 3,
      RecordingOrientation.landscapeRight => 1,
    },
    outputRect: target,
  );
}
