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

  /// 面单识别**唯一**接受的码制集合：只有一维码。
  ///
  /// 与电脑端 `CameraBarcodeRecognitionService.AllowedFormats` 严格一致
  /// （CODE_128 / CODE_39 / CODE_93 / CODABAR）。两端必须同时修改，
  /// `barcode_scan_format_guard_test.dart` 会锁死这份清单。
  ///
  /// 二维码（qr / dataMatrix / pdf417 / aztec）一律不参与面单识别：
  /// 面单上的二维码面积远大于条形码，一旦被当作有效单号就会先被确认并加锁，
  /// 用户随后扫条形码只会命中同一个值而被静默忽略，表现为"扫不动"。
  /// 手机端二维码只服务于扫码连接电脑（见 `packing_session_pairing_coordinator.dart`）。
  static const Set<String> workScanFormats = <String>{
    'code128',
    'code39',
    'code93',
    'codabar',
  };

  /// 商品零售条码码制：工作识别时忽略，避免把商品条码当成面单号。
  /// 这些是 Dart 与原生通道共用的内部稳定标识，不是界面文案；
  /// 后续切换英文界面时不需要修改这里。
  static const Set<String> productFormats = <String>{
    'ean13',
    'ean8',
    'upca',
    'upce',
    'itf',
  };

  /// 工作识别中**完全静默**、不给任何用户反馈的码制。
  ///
  /// 面单二维码在等待条形码时一直停在画面里，每帧都提示会淹没真正的错误提示，
  /// 因此二维码与商品码只写诊断日志，不弹提示、不出声、不播报。
  /// 只有内容形态明显不对的一维码（长度不符等）才值得打扰操作员。
  static const Set<String> silentWorkScanFormats = <String>{
    'qr',
    'dataMatrix',
    'pdf417',
    'aztec',
    'ean13',
    'ean8',
    'upca',
    'upce',
    'itf',
  };

  /// 这个码制是否需要给操作员可见/可听的反馈。
  ///
  /// [format] 为空表示调用点没有提供码制信息（例如手动输入），按需要反馈处理。
  static bool acknowledgesScanFeedback(String? format) =>
      format == null || !silentWorkScanFormats.contains(format);

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

  /// 手机版支持的指令码。提交内容只要包含指令词，就按指令处理。
  static MobileBarcodeCommand? mobileCommandFor(String? value) {
    final String normalized = normalize(value);
    if (normalized.isEmpty) {
      return null;
    }
    if (normalized.contains('FLASH')) {
      return MobileBarcodeCommand.openFlash;
    }
    if (normalized.contains('CLEAR') ||
        normalized.contains('CLEAN') ||
        normalized.contains('清除')) {
      return MobileBarcodeCommand.clearInput;
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

  /// 工作识别只接受 [workScanFormats] 里的一维码制；商品零售码制与二维码
  /// 都严格拒绝，不受单号内容形态影响。
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
    if (productFormats.contains(format)) {
      return WorkScanRejection.productFormat;
    }
    if (workScanFormats.contains(format)) {
      return null;
    }
    return WorkScanRejection.unsupportedFormat;
  }
}

enum WorkScanRejection { tooShort, productFormat, unsupportedFormat, invalid }

/// 手机版摄像头可执行的指令码动作。
enum MobileBarcodeCommand {
  clearInput,
  openFlash,
  switchShipping,
  switchReturn,
  startWork,
  stopWork,
}
