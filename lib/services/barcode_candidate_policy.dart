import 'jd_barcode_policy.dart';

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

  /// 国内快递面单常用的一维码制。顺丰等面单不保证始终由系统识别为
  /// Code 128，因此不能把码制当作承运商身份。
  static const Set<String> _shippingLinearFormats = <String>{
    'code128',
    'code39',
    'code93',
    'codabar',
  };

  /// 二维码可能同时承载营销链接或内部路由数据；仅当内容具有明确的
  /// 国内常见承运商单号形态时才作为运单号放行。
  static const Set<String> _shippingMatrixFormats = <String>{
    'qr',
    'dataMatrix',
    'pdf417',
    'aztec',
  };

  static const List<String> _knownCourierPrefixes = <String>[
    'SF', // 顺丰
    'YT', // 圆通
    'JT', // 极兔
    'JD', // 京东物流
    'ZTO', // 中通
    'STO', // 申通
    'YD', // 韵达
    'DB', // 德邦
    'EMS', // 中国邮政 EMS
    'ANE', // 安能
    'KYE', // 跨越
    'LP', // 菜鸟及跨境物流
  ];

  static final RegExp _internationalPostalNumber = RegExp(r'^[A-Z]{2}\d{9}CN$');

  static String normalize(String? value) {
    return normalizeRaw(value);
  }

  static String waybill(String code) =>
      JdBarcodePolicy.waybill(normalizeRaw(code));

  static String normalizeRaw(String? value) =>
      (value ?? '').trim().replaceAll(' ', '').toUpperCase();

  /// Both native and Flutter image paths use the same same-frame ranking.
  static String? selectForWorkScan(
    Iterable<({String value, double area, String? format})> candidates, {
    required int minimumLength,
  }) {
    final ranked = candidates
        .where(
          (candidate) => isValidForWorkScan(
            candidate.value,
            format: candidate.format,
            minimumLength: minimumLength,
          ),
        )
        .toList();
    // Insertion keeps the original ordering for equal areas.
    for (int i = 1; i < ranked.length; i++) {
      final candidate = ranked[i];
      int j = i;
      while (j > 0 && ranked[j - 1].area < candidate.area) {
        ranked[j] = ranked[j - 1];
        j--;
      }
      ranked[j] = candidate;
    }
    return JdBarcodePolicy.select(ranked.map((c) => normalizeRaw(c.value)));
  }

  /// 手机版支持的指令码：切发货、切退货、开始工作、停止工作。
  /// 手机版刻意不支持 CLEAR（无输入框可清）。
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
    if (normalized.contains('START') ||
        normalized.contains('开始工作') ||
        normalized.contains('开始录制')) {
      return MobileBarcodeCommand.startWork;
    }
    if (normalized.contains('STOP') ||
        normalized.contains('停止工作') ||
        normalized.contains('停止录制')) {
      return MobileBarcodeCommand.stopWork;
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

  /// 工作识别接受国内快递常见的一维码制；商品零售码制仍严格拒绝。
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

  static bool isValidForHistoryScan(
    String? value, {
    String? format,
    int minimumLength = defaultMinimumLength,
  }) =>
      rejectionForShippingScan(
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
    return rejectionForShippingScan(
      value,
      format: format,
      minimumLength: minimumLength,
    );
  }

  static WorkScanRejection? rejectionForShippingScan(
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
    if (_shippingLinearFormats.contains(format)) {
      return null;
    }
    if (_shippingMatrixFormats.contains(format) &&
        _hasKnownCourierShape(normalized)) {
      return null;
    }
    return WorkScanRejection.unsupportedFormat;
  }

  static bool _hasKnownCourierShape(String normalized) {
    if (_internationalPostalNumber.hasMatch(normalized)) {
      return true;
    }
    return _knownCourierPrefixes.any(
      (String prefix) =>
          normalized.startsWith(prefix) &&
          normalized.length >= prefix.length + 8,
    );
  }
}

enum WorkScanRejection { tooShort, productFormat, unsupportedFormat, invalid }

/// 手机版摄像头可执行的指令码动作。
enum MobileBarcodeCommand { switchShipping, switchReturn, startWork, stopWork }
