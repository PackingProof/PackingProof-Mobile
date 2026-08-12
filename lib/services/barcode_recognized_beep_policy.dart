import 'barcode_candidate_policy.dart';

/// 识别滴声去重策略：任意非空条码（含 CLEAR/SHIP 等指令码与商品码）
/// 首次出现响一声，同码连续可见不重复，离开画面（空帧）后再次出现重新响。
class BarcodeRecognizedBeepPolicy {
  BarcodeRecognizedBeepPolicy({String Function(String)? normalize})
    : _normalize = normalize ?? BarcodeCandidatePolicy.normalize;

  final String Function(String) _normalize;
  String? _lastCode;

  bool shouldBeep(Iterable<String> candidates) {
    String? visible;
    for (final String candidate in candidates) {
      final String normalized = _normalize(candidate);
      if (normalized.isNotEmpty) {
        visible = normalized;
        break;
      }
    }
    if (visible == null) {
      _lastCode = null;
      return false;
    }
    if (visible == _lastCode) {
      return false;
    }
    _lastCode = visible;
    return true;
  }
}
