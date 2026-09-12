import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/screens/packing_home_screen.dart';

/// 接扫码枪/外接键盘时系统会抑制软键盘，弹窗要退回应用内键盘。
void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    return context;
  }

  Future<void> openDialog(
    WidgetTester tester,
    BuildContext context, {
    required Future<bool> Function(String rawCode, {required bool validate})
    onSubmit,
  }) async {
    unawaitedDialog(showManualTrackingDialog(context, onSubmit: onSubmit));
    await tester.pumpAndSettle();
    // 等过“系统键盘有没有顶起来”的探测窗口。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  testWidgets('系统键盘弹出时不显示应用内键盘', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetDevicePixelRatio);

    final BuildContext context = await pumpHost(tester);
    await openDialog(
      tester,
      context,
      onSubmit: (String rawCode, {required bool validate}) async => true,
    );

    expect(find.byKey(const Key('keypad-backspace-button')), findsNothing);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('系统键盘被抑制时用应用内键盘输入并提交', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    String? submitted;
    await openDialog(
      tester,
      context,
      onSubmit: (String rawCode, {required bool validate}) async {
        submitted = rawCode;
        return true;
      },
    );

    expect(find.byKey(const Key('keypad-backspace-button')), findsOneWidget);

    Future<void> tapKey(String label) async {
      await tester.tap(find.widgetWithText(InkWell, label));
      await tester.pump();
    }

    await tapKey('7');
    await tapKey('7');
    await tapKey('3');
    // 切到字母页补一个字母，再切回数字页。
    await tester.tap(find.byKey(const Key('keypad-mode-button')));
    await tester.pump();
    await tapKey('A');
    await tester.tap(find.byKey(const Key('keypad-mode-button')));
    await tester.pump();
    await tapKey('-');
    await tapKey('9');

    final EditableText input = tester.widget<EditableText>(
      find.byType(EditableText),
    );
    expect(input.controller.text, '773A-9');
    // 按键不能把光标从输入框里抢走，否则接着敲扫码枪就丢字。
    expect(input.focusNode.hasFocus, isTrue);

    await tester.tap(find.byKey(const Key('keypad-backspace-button')));
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '773A-',
    );

    await tester.tap(find.byKey(const Key('keypad-clear-button')));
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      isEmpty,
    );

    await tapKey('1');
    await tester.tap(find.widgetWithText(FilledButton, '提交'));
    await tester.pumpAndSettle();
    expect(submitted, '1');
  });

  testWidgets('小屏展开应用内键盘不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final BuildContext context = await pumpHost(tester);
    await openDialog(
      tester,
      context,
      onSubmit: (String rawCode, {required bool validate}) async => true,
    );

    expect(find.byKey(const Key('keypad-backspace-button')), findsOneWidget);
    expect(tester.takeException(), isNull);

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('应用内键盘可以手动收起', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    await openDialog(
      tester,
      context,
      onSubmit: (String rawCode, {required bool validate}) async => true,
    );

    expect(find.byKey(const Key('keypad-hide-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('keypad-hide-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('keypad-backspace-button')), findsNothing);

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });
}

void unawaitedDialog(Future<void> dialog) {
  dialog.ignore();
}
