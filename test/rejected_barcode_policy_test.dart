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

  test('商品码静默，不参与提示竞争，面积更大的一维码也不被顶掉', () {
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

    // 商品码属静默码制直接剔除，剩下的一维码照常给出长度提示。
    expect(decision, isNotNull);
    expect(decision!.code, '1234567890');
    expect(decision.message, contains('条码长度不符'));
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

  test('外部提交关闭提示节流后重复非法码仍会被拒绝', () {
    const List<RejectedBarcodeCandidate> candidates =
        <RejectedBarcodeCandidate>[
          RejectedBarcodeCandidate(
            value: '1234567890',
            area: 100,
            format: 'code128',
          ),
        ];
    final RejectedBarcodeDecision? repeated = RejectedBarcodePolicy.decide(
      candidates: candidates,
      minimumLength: 11,
      now: now.add(const Duration(seconds: 1)),
      lastCode: '1234567890',
      lastShownAt: now,
      throttle: false,
    );
    expect(repeated, isNotNull);
  });

  test('顺丰 Code39 是有效面单码且不再显示拦截横幅', () {
    final RejectedBarcodeDecision? decision = RejectedBarcodePolicy.decide(
      candidates: const <RejectedBarcodeCandidate>[
        RejectedBarcodeCandidate(
          value: 'SF6048285539252',
          area: 100,
          format: 'code39',
        ),
      ],
      minimumLength: 11,
      now: now,
    );

    expect(decision, isNull);
  });
}
