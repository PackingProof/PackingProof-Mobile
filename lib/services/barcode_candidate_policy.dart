class BarcodeCandidatePolicy {
  const BarcodeCandidatePolicy._();

  static const int defaultMinimumLength = 11;

  static final RegExp _allowed = RegExp(r'^[A-Z0-9-]{8,40}$');
  static const List<String> _blockedWords = <String>[
    'CLEAR',
    'SHIP',
    'FAHUO',
    'BACK',
    'TUIHUO',
    'START',
    'STOP',
    'HTTP',
  ];

  /// 商品零售条码码制：工作识别时忽略，避免把商品条码当成面单号。
  /// 这些是 Dart 与原生通道共用的内部稳定标识，不是界面文案；
  /// 后续切换英文界面时不需要修改这里。
  static const Set<String> _productFormats = <String>{
    'ean13',
    'ean8',
    'upca',
    'upce',
    'itf',
  };

  static String normalize(String? value) {
    return (value ?? '').trim().replaceAll(' ', '').toUpperCase();
  }

  static bool isValid(String? value) {
    final String normalized = normalize(value);
    if (!_allowed.hasMatch(normalized)) {
      return false;
    }
    return !_blockedWords.any(normalized.contains);
  }

  /// 工作识别专用：先按普通规则校验，再拒绝商品码制。
  /// 历史记录扫码继续使用 [isValid]，不受商品码制过滤影响。
  static bool isValidForWorkScan(
    String? value, {
    String? format,
    int minimumLength = defaultMinimumLength,
  }) {
    if (!isValid(value)) {
      return false;
    }
    final String normalized = normalize(value);
    return normalized.length >= minimumLength &&
        !_productFormats.contains(format);
  }
}
