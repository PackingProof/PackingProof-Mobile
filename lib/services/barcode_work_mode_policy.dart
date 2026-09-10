import '../models/work_mode.dart';
import 'jd_barcode_policy.dart';

enum BarcodeWorkAction { bindCurrentVideo, startNextVideo, stopVideo, ignore }

class BarcodeWorkModePolicy {
  const BarcodeWorkModePolicy._();

  static BarcodeWorkAction decide({
    required WorkMode mode,
    required String currentCode,
    required String scannedCode,
  }) {
    if (currentCode.isEmpty) {
      return BarcodeWorkAction.bindCurrentVideo;
    }
    return switch (mode) {
      WorkMode.continuousScan =>
        JdBarcodePolicy.sameRecordingCode(currentCode, scannedCode)
            ? BarcodeWorkAction.ignore
            : BarcodeWorkAction.startNextVideo,
      WorkMode.sameCodeStop =>
        JdBarcodePolicy.sameRecordingCode(currentCode, scannedCode)
            ? BarcodeWorkAction.stopVideo
            : BarcodeWorkAction.ignore,
    };
  }
}
