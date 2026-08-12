import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/barcode_stability_tracker.dart';

void main() {
  test('有效条码需要连续两次一致才确认', () {
    final BarcodeStabilityTracker tracker = BarcodeStabilityTracker();
    final DateTime now = DateTime(2026, 7, 16, 10);

    final BarcodeObservation first = tracker.observe('JT1234567890', now);
    expect(first.candidateCode, 'JT1234567890');
    expect(first.confirmedCode, isEmpty);

    final BarcodeObservation second = tracker.observe(
      'JT1234567890',
      now.add(const Duration(milliseconds: 100)),
    );
    expect(second.confirmedCode, 'JT1234567890');
  });

  test('空帧不增加命中次数且窗口内同码再次出现即确认', () {
    final BarcodeStabilityTracker tracker = BarcodeStabilityTracker();
    final DateTime now = DateTime(2026, 7, 16, 10);

    final BarcodeObservation first = tracker.observe('JT1234567890', now);
    expect(first.candidateCode, 'JT1234567890');

    final BarcodeObservation missed = tracker.observe(
      null,
      now.add(const Duration(milliseconds: 100)),
    );
    expect(missed.candidateCode, 'JT1234567890');
    expect(missed.confirmedCode, isEmpty);

    final BarcodeObservation confirmed = tracker.observe(
      'JT1234567890',
      now.add(const Duration(milliseconds: 200)),
    );
    expect(confirmed.confirmedCode, 'JT1234567890');
  });

  test('空帧后换码会切换候选并重新计数', () {
    final BarcodeStabilityTracker tracker = BarcodeStabilityTracker();
    final DateTime now = DateTime(2026, 7, 16, 10);

    tracker.observe('JT1234567890', now);
    tracker.observe(null, now.add(const Duration(milliseconds: 100)));
    final BarcodeObservation changed = tracker.observe(
      'SF1234567890',
      now.add(const Duration(milliseconds: 200)),
    );
    expect(changed.candidateCode, 'SF1234567890');
    expect(changed.confirmedCode, isEmpty);
    expect(
      tracker
          .observe('SF1234567890', now.add(const Duration(milliseconds: 300)))
          .confirmedCode,
      'SF1234567890',
    );
  });

  test('空帧超过确认窗口后候选过期需重新累计', () {
    final BarcodeStabilityTracker tracker = BarcodeStabilityTracker();
    final DateTime now = DateTime(2026, 7, 16, 10);

    tracker.observe('JT1234567890', now);
    final BarcodeObservation expired = tracker.observe(
      null,
      now.add(const Duration(milliseconds: 2100)),
    );
    expect(expired.candidateCode, isEmpty);

    final BarcodeObservation candidateAgain = tracker.observe(
      'JT1234567890',
      now.add(const Duration(milliseconds: 2200)),
    );
    expect(candidateAgain.candidateCode, 'JT1234567890');
    expect(candidateAgain.confirmedCode, isEmpty);
    expect(
      tracker
          .observe('JT1234567890', now.add(const Duration(milliseconds: 2300)))
          .confirmedCode,
      'JT1234567890',
    );
  });

  test('中途变化的条码会重新计数', () {
    final BarcodeStabilityTracker tracker = BarcodeStabilityTracker();
    final DateTime now = DateTime(2026, 7, 16, 10);

    tracker.observe('JT1234567890', now);
    final BarcodeObservation changed = tracker.observe(
      'SF1234567890',
      now.add(const Duration(milliseconds: 100)),
    );
    expect(changed.candidateCode, 'SF1234567890');
    expect(changed.confirmedCode, isEmpty);
    expect(
      tracker
          .observe('SF1234567890', now.add(const Duration(milliseconds: 200)))
          .confirmedCode,
      'SF1234567890',
    );
  });

  test('持续停留在画面中的同一条码不会重复确认', () {
    final BarcodeStabilityTracker tracker = BarcodeStabilityTracker();
    final DateTime now = DateTime(2026, 7, 16, 10);
    tracker.observe('JT1234567890', now);
    tracker.observe('JT1234567890', now.add(const Duration(milliseconds: 100)));

    final BarcodeObservation locked = tracker.observe(
      'JT1234567890',
      now.add(const Duration(seconds: 2)),
    );
    expect(locked.confirmedCode, isEmpty);
  });

  test('条码离开画面后再次进入可重新确认', () {
    final BarcodeStabilityTracker tracker = BarcodeStabilityTracker();
    final DateTime now = DateTime(2026, 7, 16, 10);
    tracker.observe('JT1234567890', now);
    tracker.observe('JT1234567890', now.add(const Duration(milliseconds: 100)));
    tracker.observe(null, now.add(const Duration(seconds: 2)));
    tracker.observe(null, now.add(const Duration(milliseconds: 5200)));
    final BarcodeObservation candidateAgain = tracker.observe(
      'JT1234567890',
      now.add(const Duration(milliseconds: 5400)),
    );
    final BarcodeObservation confirmedAgain = tracker.observe(
      'JT1234567890',
      now.add(const Duration(milliseconds: 5500)),
    );

    expect(candidateAgain.candidateCode, 'JT1234567890');
    expect(confirmedAgain.confirmedCode, 'JT1234567890');
  });
}
