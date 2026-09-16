import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/barcode_candidate_policy.dart';
import 'package:packing_proof_mobile/services/barcode_recognized_beep_policy.dart';
import 'package:packing_proof_mobile/services/barcode_stability_tracker.dart';
import 'package:packing_proof_mobile/services/rejected_barcode_policy.dart';

/// 面单识别码制契约守卫。
///
/// 背景：面单上的二维码面积远大于条形码。一旦二维码被当作有效单号，它会先被
/// 确认并加锁，用户随后扫条形码只会命中同一个值而被静默忽略，表现为"条形码
/// 扫不动"。二维码在手机端只服务于扫码连接电脑，不参与面单识别。
///
/// 这个文件锁死四件事，任何一件被改动都会立刻失败：
/// 1. 面单识别只认一维码制，与电脑端 `AllowedFormats` 完全一致；
/// 2. 二维码内容无论如何伪装成承运商单号都不放行；
/// 3. 二维码候选不能挤掉同帧的条形码，也不能抢先加锁；
/// 4. 二维码在工作识别中完全静默：不弹提示、不出声、不触发拒绝提示。
void main() {
  /// 电脑端 CameraBarcodeRecognitionService.AllowedFormats 的逐字对应。
  /// 改动这里必须同时改电脑端，并同步更新本清单。
  const Set<String> pcAllowedFormats = <String>{
    'code128',
    'code39',
    'code93',
    'codabar',
  };

  /// 全部二维码制。手机端与原生通道共用的稳定标识。
  const List<String> matrixFormats = <String>[
    'qr',
    'dataMatrix',
    'pdf417',
    'aztec',
  ];

  /// 商品零售码制。
  const List<String> productFormats = <String>[
    'ean13',
    'ean8',
    'upca',
    'upce',
    'itf',
  ];

  /// 典型的"二维码内容长得像运单号"，覆盖主要承运商形态。
  const List<String> courierShapedCodes = <String>[
    'SF6048285539252',
    'YT0066717686457',
    'JT0025164133000',
    'JD0123456789012',
    'EA123456789CN',
    '785123456789',
  ];

  group('码制契约', () {
    test('面单识别只接受这一组一维码制，不得新增', () {
      expect(
        BarcodeCandidatePolicy.workScanFormats,
        pcAllowedFormats,
        reason: '手机端放行码制必须与电脑端 AllowedFormats 逐字一致',
      );
    });

    test('二维码不是面单识别码制，也不得混进放行清单', () {
      for (final String format in matrixFormats) {
        expect(
          BarcodeCandidatePolicy.workScanFormats,
          isNot(contains(format)),
          reason: '$format 不得出现在面单识别放行清单里',
        );
      }
    });

    test('静默码制清单覆盖二维码与商品码，且不含任何一维面单码制', () {
      for (final String format in <String>[
        ...matrixFormats,
        ...productFormats,
      ]) {
        expect(
          BarcodeCandidatePolicy.silentWorkScanFormats,
          contains(format),
          reason: '$format 必须静默',
        );
      }
      for (final String format in pcAllowedFormats) {
        expect(
          BarcodeCandidatePolicy.silentWorkScanFormats,
          isNot(contains(format)),
          reason: '$format 是可用面单码制，必须给出反馈',
        );
      }
    });

    test('原生可能上报的每个码制名都被明确归类，没有漏网的', () {
      // 这份清单对应 barcodeFormatName() 的 when 分支，由
      // android/app/src/test/.../BarcodeFormatNameTest.kt 钉死。
      // 原生若新增码制名，这里会失败，逼迫同时决定它属于"放行"还是"静默"，
      // 避免新码制默认变成会弹提示的"非面单条码"。
      const Set<String> nativeReportedNames = <String>{
        'code128',
        'code39',
        'code93',
        'codabar',
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
      for (final String format in nativeReportedNames) {
        final bool allowed = BarcodeCandidatePolicy.workScanFormats.contains(
          format,
        );
        final bool silent = BarcodeCandidatePolicy.silentWorkScanFormats
            .contains(format);
        expect(
          allowed || silent,
          isTrue,
          reason: '$format 既不放行也不静默，会退回弹提示分支',
        );
        expect(
          allowed && silent,
          isFalse,
          reason: '$format 不能既放行又静默',
        );
      }
      // 反向：Dart 认得的码制名不能超出原生会上报的范围。
      expect(
        <String>{
          ...BarcodeCandidatePolicy.workScanFormats,
          ...BarcodeCandidatePolicy.silentWorkScanFormats,
        },
        nativeReportedNames,
      );
    });

    test('放行清单里的每一种码制都能通过识别并需要反馈', () {
      for (final String format in BarcodeCandidatePolicy.workScanFormats) {
        expect(
          BarcodeCandidatePolicy.rejectionForWorkScan(
            'SF6048285539252',
            format: format,
          ),
          isNull,
          reason: 'format=$format',
        );
        expect(
          BarcodeCandidatePolicy.acknowledgesScanFeedback(format),
          isTrue,
          reason: 'format=$format 应当给出反馈',
        );
      }
    });
  });

  group('二维码不放行', () {
    test('二维码内容伪装成各承运商单号仍然被拒', () {
      for (final String format in matrixFormats) {
        for (final String code in courierShapedCodes) {
          expect(
            BarcodeCandidatePolicy.rejectionForWorkScan(code, format: format),
            WorkScanRejection.unsupportedFormat,
            reason: 'format=$format code=$code',
          );
          expect(
            BarcodeCandidatePolicy.isValidForHistoryScan(code, format: format),
            isFalse,
            reason: '历史扫码同样不得放行 format=$format code=$code',
          );
        }
      }
    });

    test('缺少码制信息的历史识别调用也不放行二维码', () {
      // 旧调用点不传 format 时必须拒绝，避免绕过码制判断。
      expect(
        BarcodeCandidatePolicy.rejectionForWorkScan('JT1234567890'),
        WorkScanRejection.unsupportedFormat,
      );
    });
  });

  group('二维码完全静默', () {
    test('二维码不触发任何被拒提示', () {
      for (final String format in matrixFormats) {
        expect(
          _rejectedDecisionFor(value: 'YT0066717686457', format: format),
          isNull,
          reason: '$format 不得产生提示',
        );
      }
    });

    test('商品码同样静默', () {
      for (final String format in productFormats) {
        expect(
          _rejectedDecisionFor(value: '6901234567892', format: format),
          isNull,
          reason: '$format 不得产生提示',
        );
      }
    });

    test('内容形态不当的一维码仍然提示，静默只针对码制', () {
      final RejectedBarcodeDecision? decision = _rejectedDecisionFor(
        value: 'JT123456',
        format: 'code128',
      );
      expect(decision, isNotNull, reason: '一维码长度不符必须提示操作员');
      expect(decision!.reason, WorkScanRejection.tooShort);
      expect(decision.message, contains('已忽略'));
    });

    test('同帧有可用一维码时不出提示，二维码不参与决策', () {
      final RejectedBarcodeDecision? decision = RejectedBarcodePolicy.decide(
        candidates: <RejectedBarcodeCandidate>[
          const RejectedBarcodeCandidate(
            value: 'JD0123456789012',
            area: 40000,
            format: 'qr',
          ),
          const RejectedBarcodeCandidate(
            value: 'SF6048285539252',
            area: 9000,
            format: 'code128',
          ),
        ],
        minimumLength: BarcodeCandidatePolicy.defaultMinimumLength,
        now: DateTime(2026, 9, 13, 9),
      );
      expect(decision, isNull);
    });

    test('二维码不触发滴声，条形码正常滴声', () {
      final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
      // 面单二维码连续停在画面里，一声都不该响。
      for (int i = 0; i < 5; i++) {
        expect(
          policy.shouldBeep(
            const <({String value, String? format})>[
              (value: 'JD0123456789012', format: 'qr'),
            ],
            skipSilentFormats: true,
          ),
          isFalse,
          reason: '第 $i 帧二维码不得出声',
        );
      }
      // 条形码进入画面立刻响一声。
      expect(
        policy.shouldBeep(
          const <({String value, String? format})>[
            (value: 'JD0123456789012', format: 'code128'),
          ],
          skipSilentFormats: true,
        ),
        isTrue,
      );
    });

    test('配对扫码仍需为二维码出声', () {
      final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
      expect(
        policy.shouldBeep(
          const <({String value, String? format})>[
            (value: 'HTTP://192.168.31.250:5280/PAIR?K=ABC', format: 'qr'),
          ],
        ),
        isTrue,
        reason: '配对二维码必须响，否则用户不知道扫到了',
      );
    });
  });

  group('同帧优先级', () {
    test('同帧同时有二维码和条形码时选中条形码', () {
      final String? picked = BarcodeCandidatePolicy.selectForWorkScan(
        <({String value, double area, String? format})>[
          // 二维码面积大得多，历史缺陷正是在这里被选中。
          (value: 'JD0123456789012', area: 40000, format: 'qr'),
          (value: 'JD0123456789012', area: 9000, format: 'code128'),
        ],
        minimumLength: 11,
      );
      expect(picked, 'JD0123456789012');
    });

    test('整帧只有二维码时不产生任何有效单号', () {
      expect(
        BarcodeCandidatePolicy.selectForWorkScan(
          <({String value, double area, String? format})>[
            (value: 'SF6048285539252', area: 40000, format: 'qr'),
            (value: '6901234567892', area: 20000, format: 'ean13'),
          ],
          minimumLength: 11,
        ),
        isNull,
      );
    });
  });

  group('回归场景：二维码先入画，条形码仍可确认', () {
    test('二维码帧不会加锁，同帧条形码正常确认', () {
      final BarcodeStabilityTracker tracker = BarcodeStabilityTracker();
      final DateTime t0 = DateTime(2026, 9, 13, 9);

      // 用户动作：把面单对准画面，二维码面积大、条形码同在画面内。
      String confirmed = '';
      for (int i = 0; i < 4; i++) {
        final String? picked = BarcodeCandidatePolicy.selectForWorkScan(
          <({String value, double area, String? format})>[
            (value: 'JD0123456789012', area: 40000, format: 'qr'),
            (value: 'JD0123456789012', area: 9000, format: 'code128'),
          ],
          minimumLength: 11,
        );
        final BarcodeObservation observation = tracker.observe(
          picked,
          t0.add(Duration(milliseconds: i * 100)),
        );
        if (observation.confirmedCode.isNotEmpty) {
          confirmed = observation.confirmedCode;
          break;
        }
      }
      expect(
        confirmed,
        'JD0123456789012',
        reason: '同帧有条形码时必须能确认，二维码不得拦截',
      );
    });

    test('只有二维码时锁一直为空，不会堵住之后的条形码', () {
      final BarcodeStabilityTracker tracker = BarcodeStabilityTracker();
      final DateTime t0 = DateTime(2026, 9, 13, 9);

      // 连续 20 帧画面里只有二维码。
      for (int i = 0; i < 20; i++) {
        final String? picked = BarcodeCandidatePolicy.selectForWorkScan(
          <({String value, double area, String? format})>[
            (value: 'JD0123456789012', area: 40000, format: 'qr'),
          ],
          minimumLength: 11,
        );
        expect(picked, isNull);
        expect(
          tracker
              .observe(picked, t0.add(Duration(milliseconds: i * 100)))
              .confirmedCode,
          isEmpty,
        );
      }

      // 条形码随后进入画面，无需等待二维码消失满 3 秒即可确认。
      String confirmed = '';
      for (int i = 0; i < 4; i++) {
        final BarcodeObservation observation = tracker.observe(
          'JD0123456789012',
          t0.add(Duration(milliseconds: 2000 + i * 100)),
        );
        if (observation.confirmedCode.isNotEmpty) {
          confirmed = observation.confirmedCode;
          break;
        }
      }
      expect(confirmed, 'JD0123456789012');
    });
  });
}

/// 通过被拒策略拿提示内容，验证静默码制不会产生任何提示。
RejectedBarcodeDecision? _rejectedDecisionFor({
  required String value,
  required String format,
}) {
  return RejectedBarcodePolicy.decide(
    candidates: <RejectedBarcodeCandidate>[
      RejectedBarcodeCandidate(value: value, area: 1, format: format),
    ],
    minimumLength: BarcodeCandidatePolicy.defaultMinimumLength,
    now: DateTime(2026, 9, 13, 9),
  );
}
