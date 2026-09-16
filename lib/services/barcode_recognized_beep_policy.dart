import 'barcode_candidate_policy.dart';

/// 识别滴声去重策略：任意非空条码（含 CLEAR/SHIP 等指令码）首次出现响一声，
/// 同码连续可见不重复，离开画面（空帧）后再次出现重新响。
///
/// 工作识别中静默码制（二维码、商品码）不触发滴声：面单二维码会一直停在
/// 画面里等待条形码，响个不停只会干扰操作员，而且它并不是可用单号。
/// 配对扫码与历史扫码不传码制或传 `null`，行为保持不变。
class BarcodeRecognizedBeepPolicy {
  BarcodeRecognizedBeepPolicy({String Function(String)? normalize})
    : _normalize = normalize ?? BarcodeCandidatePolicy.normalize;

  final String Function(String) _normalize;
  String? _lastCode;

  bool shouldBeep(
    Iterable<({String value, String? format})> candidates, {
    bool skipSilentFormats = false,
  }) {
    String? visible;
    for (final ({String value, String? format}) candidate in candidates) {
      if (skipSilentFormats &&
          !BarcodeCandidatePolicy.acknowledgesScanFeedback(candidate.format)) {
        continue;
      }
      final String normalized = _normalize(candidate.value);
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
