import 'barcode_candidate_policy.dart';

/// 一帧中解码出的候选条码（供拒绝提示决策使用）。
class RejectedBarcodeCandidate {
  const RejectedBarcodeCandidate({
    required this.value,
    required this.area,
    this.format,
  });

  final String value;
  final double area;
  final String? format;
}

class RejectedBarcodeDecision {
  const RejectedBarcodeDecision({
    required this.code,
    required this.message,
    required this.reason,
    this.format,
  });

  final String code;
  final String message;
  final WorkScanRejection reason;
  final String? format;
}

/// 工作识别被过滤条码的轻提示决策：仅整帧无有效面单码时提示，并按码节流。
///
/// 二维码与商品码属于静默码制（见
/// [BarcodeCandidatePolicy.silentWorkScanFormats]）：它们不产生任何提示，
/// 只由调用点写诊断日志。面单二维码会一直停在画面里等待条形码，
/// 若每帧都提示就会淹没真正的错误提示。
class RejectedBarcodePolicy {
  const RejectedBarcodePolicy._();

  static const Duration perCodeThrottle = Duration(seconds: 3);

  static RejectedBarcodeDecision? decide({
    required List<RejectedBarcodeCandidate> candidates,
    required int minimumLength,
    required DateTime now,
    String? lastCode,
    DateTime? lastShownAt,
    bool throttle = true,
  }) {
    // 先剔除静默码制，避免二维码决定本帧的提示内容。
    final List<RejectedBarcodeCandidate> visible = candidates
        .where(
          (RejectedBarcodeCandidate candidate) =>
              BarcodeCandidatePolicy.acknowledgesScanFeedback(candidate.format),
        )
        .toList(growable: false);
    if (visible.isEmpty) {
      return null;
    }
    final bool hasValid = visible.any(
      (RejectedBarcodeCandidate candidate) =>
          BarcodeCandidatePolicy.mobileCommandFor(candidate.value) != null ||
          BarcodeCandidatePolicy.isValidForWorkScan(
            candidate.value,
            format: candidate.format,
            minimumLength: minimumLength,
          ),
    );
    if (hasValid) {
      return null;
    }

    RejectedBarcodeCandidate? largest;
    for (final RejectedBarcodeCandidate candidate in visible) {
      if (largest == null || candidate.area > largest.area) {
        largest = candidate;
      }
    }
    if (largest == null) {
      return null;
    }

    final String code = BarcodeCandidatePolicy.normalize(largest.value);
    if (throttle &&
        code == lastCode &&
        lastShownAt != null &&
        now.difference(lastShownAt) < perCodeThrottle) {
      return null;
    }
    final WorkScanRejection reason =
        BarcodeCandidatePolicy.rejectionForWorkScan(
          largest.value,
          format: largest.format,
          minimumLength: minimumLength,
        )!;
    return RejectedBarcodeDecision(
      code: code,
      message: _messageFor(largest, minimumLength),
      reason: reason,
      format: largest.format,
    );
  }

  static String _messageFor(
    RejectedBarcodeCandidate candidate,
    int minimumLength,
  ) {
    final String code = BarcodeCandidatePolicy.normalize(candidate.value);
    final WorkScanRejection? reason =
        BarcodeCandidatePolicy.rejectionForWorkScan(
          candidate.value,
          format: candidate.format,
          minimumLength: minimumLength,
        );
    if (reason == WorkScanRejection.tooShort) {
      return '条码长度不符：实际 ${code.length} 位（需至少 $minimumLength 位），已忽略';
    }
    return '识别到非面单条码：$code，已忽略';
  }
}
