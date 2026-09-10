import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/barcode_candidate_policy.dart';
import 'package:packing_proof_mobile/services/barcode_stability_tracker.dart';
import 'package:packing_proof_mobile/services/jd_barcode_policy.dart';

void main() {
  const vectors = <String, String>{
    'JD123456789012-1-1-': 'JD123456789012-1-1-',
    ' jdva1234567891234-1-1- ': 'JDVA1234567891234-1-1-',
    'JD123456789012-1-2-': 'JD123456789012-1-2-',
    'JD123456789012-2-2-': 'JD123456789012-2-2-',
    'JD123456789012-1-1': 'JD123456789012-1-1',
    'YT123456789012-1-1-': 'YT123456789012-1-1-',
    'JD123456789012-0-1-': 'JD123456789012-0-1-',
    'JD123456789012-2-1-': 'JD123456789012-2-1-',
    'JD123456789012-01-1-': 'JD123456789012-01-1-',
    'JD123456789012-1-2147483648-': 'JD123456789012-1-2147483648-',
  };
  for (final entry in vectors.entries) {
    test('shared desktop normalization vector ${entry.key}', () {
      expect(BarcodeCandidatePolicy.normalize(entry.key), entry.value);
    });
  }

  for (final suffix in ['-1-1-', '-1-2-', '-2-2-']) {
    for (final bareFirst in [true, false]) {
      test('same frame $suffix bareFirst=$bareFirst', () {
        final result = BarcodeCandidatePolicy.selectForWorkScan([
          (
            value: 'JD123456789012',
            area: bareFirst ? 300.0 : 100.0,
            format: 'code128',
          ),
          (value: 'JD123456789012$suffix', area: 200.0, format: 'code128'),
        ], minimumLength: 11);
        expect(result, 'JD123456789012$suffix');
      });
    }
  }
  test('bare fallback and unrelated package keep original selection', () {
    expect(JdBarcodePolicy.select(['JD123456789012']), 'JD123456789012');
    expect(
      JdBarcodePolicy.select(['JD123456789012', 'JD999999999999-1-2-']),
      'JD123456789012',
    );
    expect(
      JdBarcodePolicy.select(['YT123456789012', 'JD123456789012-1-2-']),
      'YT123456789012',
    );
    expect(
      JdBarcodePolicy.select([
        'JD123456789012',
        'JD123456789012-2-2-',
        'JD123456789012-1-2-',
      ]),
      'JD123456789012-2-2-',
    );
  });
  test('single package alias cannot rearm the current camera code', () {
    final tracker = BarcodeStabilityTracker();
    final now = DateTime(2026, 9, 11);
    tracker.observe('JD123456789012', now);
    expect(
      tracker
          .observe(
            'JD123456789012-1-1-',
            now.add(const Duration(milliseconds: 100)),
          )
          .confirmedCode,
      'JD123456789012-1-1-',
    );
    expect(
      tracker
          .observe('JD123456789012', now.add(const Duration(seconds: 4)))
          .confirmedCode,
      isEmpty,
    );
    expect(
      tracker
          .observe('JD123456789012-1-1-', now.add(const Duration(seconds: 5)))
          .confirmedCode,
      isEmpty,
    );
  });
}
