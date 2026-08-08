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
  const RejectedBarcodeDecision({required this.code, required this.message});

  final String code;
  final String message;
}

/// 工作识别被过滤条码的轻提示决策：仅整帧无有效面单码时提示，并按码节流。
class RejectedBarcodePolicy {
  const RejectedBarcodePolicy._();

  static const Duration perCodeThrottle = Duration(seconds: 3);

  static RejectedBarcodeDecision? decide({
    required List<RejectedBarcodeCandidate> candidates,
    required int minimumLength,
    required DateTime now,
    String? lastCode,
    DateTime? lastShownAt,
  }) {
    if (candidates.isEmpty) {
      return null;
    }
    final bool hasValid = candidates.any(
      (RejectedBarcodeCandidate candidate) =>
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
    for (final RejectedBarcodeCandidate candidate in candidates) {
      if (largest == null || candidate.area > largest.area) {
        largest = candidate;
      }
    }
    if (largest == null) {
      return null;
    }

    final String code = BarcodeCandidatePolicy.normalize(largest.value);
    if (code == lastCode &&
        lastShownAt != null &&
        now.difference(lastShownAt) < perCodeThrottle) {
      return null;
    }
    return RejectedBarcodeDecision(
      code: code,
      message: _messageFor(largest, minimumLength),
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
