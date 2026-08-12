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

  /// 手机版支持的指令码：切发货、切退货、停止录制。
  /// 手机版刻意不支持 START（扫码即自动开始）与 CLEAR（无输入框可清）。
  static MobileBarcodeCommand? mobileCommandFor(String? value) {
    final String normalized = normalize(value);
    if (normalized.isEmpty) {
      return null;
    }
    if (normalized.contains('SHIP') ||
        normalized.contains('发货') ||
        normalized.contains('FAHUO')) {
      return MobileBarcodeCommand.switchShipping;
    }
    if (normalized.contains('BACK') ||
        normalized.contains('退货') ||
        normalized.contains('TUIHUO')) {
      return MobileBarcodeCommand.switchReturn;
    }
    if (normalized.contains('STOP') || normalized.contains('停止录制')) {
      return MobileBarcodeCommand.stopRecording;
    }
    return null;
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
  }) =>
      rejectionForWorkScan(
        value,
        format: format,
        minimumLength: minimumLength,
      ) ==
      null;

  /// 工作识别被拒绝的原因；返回 null 表示可接受。
  static WorkScanRejection? rejectionForWorkScan(
    String? value, {
    String? format,
    int minimumLength = defaultMinimumLength,
  }) {
    final String normalized = normalize(value);
    if (!isValid(value)) {
      return WorkScanRejection.invalid;
    }
    if (normalized.length < minimumLength) {
      return WorkScanRejection.tooShort;
    }
    if (_productFormats.contains(format)) {
      return WorkScanRejection.productFormat;
    }
    return null;
  }
}

enum WorkScanRejection { tooShort, productFormat, invalid }

/// 手机版摄像头可执行的指令码动作。
enum MobileBarcodeCommand { switchShipping, switchReturn, stopRecording }
