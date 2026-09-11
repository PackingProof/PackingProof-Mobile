import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/barcode_candidate_policy.dart';
import 'package:packing_proof_mobile/services/rejected_barcode_policy.dart';

void main() {
  group('BarcodeCandidatePolicy', () {
    test('标准化并接受常见物流条码', () {
      expect(
        BarcodeCandidatePolicy.normalize('  jt 1234567890 '),
        'JT1234567890',
      );
      expect(BarcodeCandidatePolicy.isValid('JT1234567890'), isTrue);
      expect(BarcodeCandidatePolicy.isValid('SF-1234567890'), isTrue);
      expect(BarcodeCandidatePolicy.isValid('12345678'), isTrue);
      expect(
        BarcodeCandidatePolicy.isValid('YT123456789012345678901234567890'),
        isTrue,
      );
    });

    test('过滤短码和操作指令', () {
      expect(BarcodeCandidatePolicy.isValid('12345'), isFalse);
      expect(BarcodeCandidatePolicy.isValid('START1234567890'), isFalse);
      expect(BarcodeCandidatePolicy.isValid('https://example.com'), isFalse);
    });

    test('工作识别兼容国内快递常见一维码制并继续过滤商品码', () {
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          '6901234567890',
          format: 'ean13',
        ),
        isFalse,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan('12345678', format: 'ean8'),
        isFalse,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          '123456789012',
          format: 'upca',
        ),
        isFalse,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          '123456789012',
          format: 'upce',
        ),
        isFalse,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan('1234567890', format: 'itf'),
        isFalse,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          '6901234567890',
          format: 'code128',
        ),
        isTrue,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          'SF6048285539252',
          format: 'code39',
        ),
        isTrue,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          'JT0025164133000',
          format: 'code93',
        ),
        isTrue,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          'YT0066717686457',
          format: 'qr',
        ),
        isTrue,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          'QR12345678901',
          format: 'qr',
        ),
        isFalse,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan('YT123456789012'),
        isFalse,
      );
      expect(BarcodeCandidatePolicy.isValid('6901234567890'), isTrue);
    });

    test('历史记录扫码同样兼容快递码制并拒绝未知或商品码制', () {
      expect(
        BarcodeCandidatePolicy.isValidForHistoryScan(
          'YT123456789012',
          format: 'code128',
        ),
        isTrue,
      );
      for (final String format in <String>['code39', 'code93', 'codabar']) {
        expect(
          BarcodeCandidatePolicy.isValidForHistoryScan(
            'SF6048285539252',
            format: format,
          ),
          isTrue,
          reason: 'format=$format',
        );
      }
      for (final String? format in <String?>['ean13', 'unknown', null]) {
        expect(
          BarcodeCandidatePolicy.isValidForHistoryScan(
            'YT123456789012',
            format: format,
          ),
          isFalse,
          reason: 'format=$format',
        );
      }
      expect(BarcodeCandidatePolicy.isValid('YT123456789012'), isTrue);
    });

    test('工作识别按最短长度过滤 Code128 防伪码', () {
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          '1234567890',
          format: 'code128',
        ),
        isFalse,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          '12345678901',
          format: 'code128',
        ),
        isTrue,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          '1234567890',
          format: 'code128',
          minimumLength: 10,
        ),
        isTrue,
      );
      expect(
        BarcodeCandidatePolicy.isValidForWorkScan(
          '12345678901',
          format: 'code128',
          minimumLength: 12,
        ),
        isFalse,
      );
      expect(BarcodeCandidatePolicy.isValid('1234567890'), isTrue);
    });

    test('拒绝原因分类覆盖长度、商品码制和其他无效', () {
      expect(
        BarcodeCandidatePolicy.rejectionForWorkScan(
          '1234567890',
          format: 'code128',
        ),
        WorkScanRejection.tooShort,
      );
      expect(
        BarcodeCandidatePolicy.rejectionForWorkScan(
          '6901234567890',
          format: 'ean13',
        ),
        WorkScanRejection.productFormat,
      );
      expect(
        BarcodeCandidatePolicy.rejectionForWorkScan(
          'START1234567890',
          format: 'code128',
        ),
        WorkScanRejection.invalid,
      );
      expect(
        BarcodeCandidatePolicy.rejectionForWorkScan(
          'JT1234567890',
          format: 'code128',
        ),
        isNull,
      );
      expect(
        BarcodeCandidatePolicy.rejectionForWorkScan(
          'JT1234567890',
          format: 'qr',
        ),
        isNull,
      );
      expect(
        BarcodeCandidatePolicy.rejectionForWorkScan(
          'QR12345678901',
          format: 'qr',
        ),
        WorkScanRejection.unsupportedFormat,
      );
    });

    test('国内常见承运商代表单号均可通过对应面单码制', () {
      const Map<String, String> examples = <String, String>{
        'SF6048285539252': 'code39', // 顺丰
        'YT0066717686457': 'code128', // 圆通
        'JT0025164133000': 'code93', // 极兔
        'JD0123456789012': 'code128', // 京东物流
        'EA123456789CN': 'qr', // 中国邮政 EMS
        '785123456789': 'code128', // 中通数字单号
        '773123456789': 'code39', // 申通数字单号
        '4312345678901': 'code128', // 韵达数字单号
        '601234567890': 'code93', // 德邦数字单号
      };
      for (final MapEntry<String, String> example in examples.entries) {
        expect(
          BarcodeCandidatePolicy.isValidForWorkScan(
            example.key,
            format: example.value,
          ),
          isTrue,
          reason: '${example.key} (${example.value})',
        );
      }
    });
  });

  group('手机版指令码', () {
    test('切发货/切退货/开始工作/停止工作被识别', () {
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('SHIP'),
        MobileBarcodeCommand.switchShipping,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('发货'),
        MobileBarcodeCommand.switchShipping,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('FAHUO'),
        MobileBarcodeCommand.switchShipping,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('BACK'),
        MobileBarcodeCommand.switchReturn,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('退货'),
        MobileBarcodeCommand.switchReturn,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('TUIHUO'),
        MobileBarcodeCommand.switchReturn,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('START'),
        MobileBarcodeCommand.startWork,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('开始工作'),
        MobileBarcodeCommand.startWork,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('开始录制'),
        MobileBarcodeCommand.startWork,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('STOP'),
        MobileBarcodeCommand.stopWork,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('停止工作'),
        MobileBarcodeCommand.stopWork,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('停止录制'),
        MobileBarcodeCommand.stopWork,
      );
    });

    test('手机版按包含内容识别指令码，普通单号不当作指令', () {
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('1234 FLASH 1234'),
        MobileBarcodeCommand.openFlash,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('1234 CLEAR 1234'),
        MobileBarcodeCommand.clearInput,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('1234 CLEAN 1234'),
        MobileBarcodeCommand.clearInput,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('清除输入'),
        MobileBarcodeCommand.clearInput,
      );
      expect(BarcodeCandidatePolicy.mobileCommandFor('YT123456789012'), isNull);
      expect(BarcodeCandidatePolicy.mobileCommandFor(''), isNull);
    });

    test('整帧含指令码时不触发拒绝提示，仅商品码时仍提示', () {
      final RejectedBarcodeDecision? withCommand = RejectedBarcodePolicy.decide(
        candidates: const <RejectedBarcodeCandidate>[
          RejectedBarcodeCandidate(value: 'SHIP', area: 100),
          RejectedBarcodeCandidate(value: 'YT123456789012', area: 200),
        ],
        minimumLength: 11,
        now: DateTime(2026, 1, 1),
      );
      expect(withCommand, isNull);

      final RejectedBarcodeDecision? invalidOnly = RejectedBarcodePolicy.decide(
        candidates: const <RejectedBarcodeCandidate>[
          RejectedBarcodeCandidate(value: '1234', area: 100),
        ],
        minimumLength: 11,
        now: DateTime(2026, 1, 1),
      );
      expect(invalidOnly, isNotNull);
    });
  });
}
