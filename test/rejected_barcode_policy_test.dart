import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/rejected_barcode_policy.dart';

void main() {
  final DateTime now = DateTime(2026, 8, 9, 10);

  test('整帧存在有效面单码时不提示被过滤码', () {
    final RejectedBarcodeDecision? decision = RejectedBarcodePolicy.decide(
      candidates: const <RejectedBarcodeCandidate>[
        RejectedBarcodeCandidate(
          value: '6901234567890',
          area: 2000,
          format: 'ean13',
        ),
        RejectedBarcodeCandidate(
          value: 'JT1234567890',
          area: 1000,
          format: 'code128',
        ),
      ],
      minimumLength: 11,
      now: now,
    );

    expect(decision, isNull);
  });

  test('仅被过滤码时选择最大候选并生成长度提示', () {
    final RejectedBarcodeDecision? decision = RejectedBarcodePolicy.decide(
      candidates: const <RejectedBarcodeCandidate>[
        RejectedBarcodeCandidate(
          value: '1234567890',
          area: 500,
          format: 'code128',
        ),
        RejectedBarcodeCandidate(
          value: '6901234567890',
          area: 2000,
          format: 'ean13',
        ),
      ],
      minimumLength: 11,
      now: now,
    );

    expect(decision, isNotNull);
    expect(decision!.code, '6901234567890');
    expect(decision.message, contains('识别到非面单条码'));
  });

  test('长度不足生成实际/期望长度文案', () {
    final RejectedBarcodeDecision? decision = RejectedBarcodePolicy.decide(
      candidates: const <RejectedBarcodeCandidate>[
        RejectedBarcodeCandidate(
          value: '1234567890',
          area: 100,
          format: 'code128',
        ),
      ],
      minimumLength: 11,
      now: now,
    );

    expect(decision?.message, '条码长度不符：实际 10 位（需至少 11 位），已忽略');
  });

  test('同一码 3 秒内节流，不同码或超时后可再提示', () {
    const List<RejectedBarcodeCandidate> candidates =
        <RejectedBarcodeCandidate>[
          RejectedBarcodeCandidate(
            value: '1234567890',
            area: 100,
            format: 'code128',
          ),
        ];

    final RejectedBarcodeDecision? first = RejectedBarcodePolicy.decide(
      candidates: candidates,
      minimumLength: 11,
      now: now,
    );
    expect(first, isNotNull);

    final RejectedBarcodeDecision? throttled = RejectedBarcodePolicy.decide(
      candidates: candidates,
      minimumLength: 11,
      now: now.add(const Duration(seconds: 2)),
      lastCode: first!.code,
      lastShownAt: now,
    );
    expect(throttled, isNull);

    final RejectedBarcodeDecision? afterWindow = RejectedBarcodePolicy.decide(
      candidates: candidates,
      minimumLength: 11,
      now: now.add(const Duration(seconds: 4)),
      lastCode: first.code,
      lastShownAt: now,
    );
    expect(afterWindow, isNotNull);
  });
}
