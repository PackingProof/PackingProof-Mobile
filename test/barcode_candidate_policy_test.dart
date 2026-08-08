import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/barcode_candidate_policy.dart';

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
  });
}
