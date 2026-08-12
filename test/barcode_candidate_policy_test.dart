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

    test('工作识别拒绝商品码制，历史扫码不受影响', () {
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
      expect(BarcodeCandidatePolicy.isValid('6901234567890'), isTrue);
    });

    test('工作识别按最短长度过滤 Code128 防伪码，历史扫码不受影响', () {
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
    });
  });

  group('手机版指令码', () {
    test('切发货/切退货/停止录制被识别', () {
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
        BarcodeCandidatePolicy.mobileCommandFor('STOP'),
        MobileBarcodeCommand.stopRecording,
      );
      expect(
        BarcodeCandidatePolicy.mobileCommandFor('停止录制'),
        MobileBarcodeCommand.stopRecording,
      );
    });

    test('手机版不支持 START/CLEAR，普通单号不当作指令', () {
      expect(BarcodeCandidatePolicy.mobileCommandFor('START'), isNull);
      expect(BarcodeCandidatePolicy.mobileCommandFor('开始录制'), isNull);
      expect(BarcodeCandidatePolicy.mobileCommandFor('CLEAR'), isNull);
      expect(BarcodeCandidatePolicy.mobileCommandFor('清除'), isNull);
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
