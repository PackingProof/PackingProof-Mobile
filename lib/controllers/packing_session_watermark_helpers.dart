part of 'packing_session_controller.dart';

@visibleForTesting
WatermarkProcessingStatus nativeWatermarkStatus(
  NativeWatermarkDisposition disposition,
) => switch (disposition) {
  NativeWatermarkDisposition.completed => WatermarkProcessingStatus.completed,
  NativeWatermarkDisposition.postProcessRequired =>
    WatermarkProcessingStatus.pending,
  NativeWatermarkDisposition.failedPartial => WatermarkProcessingStatus.failed,
};

@visibleForTesting
bool nativeWatermarkNeedsPostProcess(NativeWatermarkDisposition disposition) =>
    switch (disposition) {
      NativeWatermarkDisposition.completed => false,
      NativeWatermarkDisposition.postProcessRequired => true,
      NativeWatermarkDisposition.failedPartial => false,
    };
