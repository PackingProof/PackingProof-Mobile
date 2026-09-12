import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/screens/packing_home_screen.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';

class _FakeRepository extends SessionRepository {}

/// 外接键盘／扫码枪敲了一半又改用别的入口时，残留缓冲不能和下一次输入拼在一起。
void main() {
  Future<void> typeExternalKeys(WidgetTester tester, String text) async {
    for (final String character in text.split('')) {
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.digit7,
        character: character,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit7);
    }
    await tester.pump();
  }

  testWidgets('打开手动输入弹窗会丢弃外接键盘敲了一半的内容', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: PackingHomeScreen(repository: _FakeRepository())),
    );
    await tester.pump(const Duration(milliseconds: 200));

    await typeExternalKeys(tester, '773');
    expect(find.text('正在确认 · 773'), findsOneWidget);

    await tester.tap(find.byKey(const Key('manual-tracking-button')));
    // 首页有常驻动画，不能用 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('输入单号'), findsOneWidget);
    expect(find.textContaining('正在确认'), findsNothing);

    // 取消弹窗后缓冲仍然是空的，之后的输入从头开始。
    await tester.tap(find.widgetWithText(OutlinedButton, '取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('正在确认'), findsNothing);

    await typeExternalKeys(tester, '99');
    expect(find.text('正在确认 · 99'), findsOneWidget);
  });
}
