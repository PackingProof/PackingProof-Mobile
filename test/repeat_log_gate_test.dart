import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/repeat_log_gate.dart';

void main() {
  late DateTime now;
  late RepeatLogGate gate;

  setUp(() {
    now = DateTime(2026, 10, 26, 9);
    gate = RepeatLogGate(window: const Duration(minutes: 10), clock: () => now);
  });

  void advance(Duration duration) => now = now.add(duration);

  test('相同签名在窗口内只放行一次并累计省略条数', () {
    final Map<String, Object?> signature = <String, Object?>{
      'status': 200,
      'connected': true,
    };

    expect(gate.shouldEmit(signature), isTrue);
    expect(gate.takeSuppressedCount(), 0);

    for (int index = 0; index < 5; index++) {
      advance(const Duration(seconds: 15));
      expect(gate.shouldEmit(signature), isFalse);
    }
    expect(gate.takeSuppressedCount(), 5);

    // 取走之后归零，下一次省略重新计数。
    expect(gate.takeSuppressedCount(), 0);
    advance(const Duration(seconds: 15));
    expect(gate.shouldEmit(signature), isFalse);
    expect(gate.takeSuppressedCount(), 1);
  });

  test('窗口到期后放行采样并带出省略条数', () {
    final Map<String, Object?> signature = <String, Object?>{'status': 200};
    expect(gate.shouldEmit(signature), isTrue);

    for (int index = 0; index < 39; index++) {
      advance(const Duration(seconds: 15));
      expect(gate.shouldEmit(signature), isFalse);
    }

    advance(const Duration(seconds: 15));
    expect(gate.shouldEmit(signature), isTrue);
    expect(gate.takeSuppressedCount(), 39);
  });

  test('签名变化立即放行，且不会把旧状态的省略数算进新状态', () {
    final Map<String, Object?> healthy = <String, Object?>{'status': 200};
    expect(gate.shouldEmit(healthy), isTrue);

    advance(const Duration(seconds: 15));
    expect(gate.shouldEmit(healthy), isFalse);

    advance(const Duration(seconds: 15));
    expect(gate.shouldEmit(<String, Object?>{'status': 500}), isTrue);
    expect(gate.takeSuppressedCount(), 0);

    advance(const Duration(seconds: 15));
    expect(gate.shouldEmit(<String, Object?>{'status': 500}), isFalse);
    expect(gate.takeSuppressedCount(), 1);
  });

  test('窗口为零时只做状态变化过滤', () {
    final RepeatLogGate noWindow = RepeatLogGate(window: Duration.zero);
    final Map<String, Object?> signature = <String, Object?>{'working': true};

    expect(noWindow.shouldEmit(signature), isTrue);
    expect(noWindow.shouldEmit(signature), isTrue);
    expect(noWindow.takeSuppressedCount(), 0);
  });
}
