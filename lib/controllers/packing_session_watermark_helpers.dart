part of 'packing_session_controller.dart';

@visibleForTesting
WatermarkProcessingStatus nativeWatermarkStatus(
  NativeWatermarkDisposition disposition, {
  bool watermarkEnabled = true,
}) {
  // 关闭「添加水印」后原生不会再烧录水印，录像文件本身即最终成片。
  if (!watermarkEnabled) return WatermarkProcessingStatus.completed;
  return switch (disposition) {
    NativeWatermarkDisposition.completed => WatermarkProcessingStatus.completed,
    NativeWatermarkDisposition.postProcessRequired =>
      WatermarkProcessingStatus.pending,
    NativeWatermarkDisposition.failedPartial =>
      WatermarkProcessingStatus.failed,
  };
}

@visibleForTesting
bool nativeWatermarkNeedsPostProcess(
  NativeWatermarkDisposition disposition, {
  bool watermarkEnabled = true,
}) {
  if (!watermarkEnabled) return false;
  return switch (disposition) {
    NativeWatermarkDisposition.completed => false,
    NativeWatermarkDisposition.postProcessRequired => true,
    NativeWatermarkDisposition.failedPartial => false,
  };
}

/// Flutter 相机回退路径录下的片段：开启水印时仍要补录，关闭后直接成片。
@visibleForTesting
WatermarkProcessingStatus flutterRecordingWatermarkStatus({
  required bool watermarkEnabled,
}) => watermarkEnabled
    ? WatermarkProcessingStatus.pending
    : WatermarkProcessingStatus.completed;
