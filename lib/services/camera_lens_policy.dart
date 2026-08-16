import 'continuous_camera_service.dart';

/// 过滤掉会影响原生扫码的超广角档位。
///
/// iOS 的 AVCaptureMetadataOutput 与 Android 的 ML Kit 都需要条码在画面里足够大；
/// 0.5x/0.7x 这类超广角会显著缩小条码，导致用户“能看见画面但扫不上”。
/// 因此两端统一只保留主摄与长焦档位，避免用户误选后无法扫码。
List<NativeCameraLens> scannableBackLenses(Iterable<NativeCameraLens> lenses) {
  return lenses
      .where((NativeCameraLens lens) => lens.zoomRatio >= 1.0)
      .toList(growable: false);
}
