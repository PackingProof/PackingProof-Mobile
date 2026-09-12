import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/screens/packing_home_screen.dart';
import 'package:packing_proof_mobile/widgets/tracking_number_keypad.dart';

/// 接扫码枪/外接键盘时系统会抑制软键盘，输入面板要退回应用内键盘。
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

  Future<void> openSheet(
    WidgetTester tester,
    BuildContext context, {
    required Future<bool> Function(String rawCode, {required bool validate})
    onSubmit,
  }) async {
    showManualTrackingSheet(context, onSubmit: onSubmit).ignore();
    await tester.pumpAndSettle();
    // 等过“系统键盘有没有顶起来”的探测窗口。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  // find.text 同样会匹配输入框里的内容，按键查找必须限定在键盘内部。
  Finder keyFinder(String label) => find.descendant(
    of: find.byType(TrackingNumberKeypad),
    matching: find.widgetWithText(InkWell, label),
  );

  String currentInput(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).controller.text;

  testWidgets('系统键盘弹出时不显示应用内键盘', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetDevicePixelRatio);

    final BuildContext context = await pumpHost(tester);
    await openSheet(
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
    await openSheet(
      tester,
      context,
      onSubmit: (String rawCode, {required bool validate}) async {
        submitted = rawCode;
        return true;
      },
    );

    expect(find.byKey(const Key('keypad-backspace-button')), findsOneWidget);

    Future<void> tapKey(String label) async {
      await tester.tap(keyFinder(label));
      await tester.pump();
    }

    // 字母和数字在同一套 QWERTY 键位上，不需要切页。
    for (final String key in <String>['7', '7', '3', 'A', '-', '9']) {
      await tapKey(key);
    }

    final EditableText input = tester.widget<EditableText>(
      find.byType(EditableText),
    );
    expect(input.controller.text, '773A-9');
    // 按键不能把光标从输入框里抢走，否则接着敲扫码枪就丢字。
    expect(input.focusNode.hasFocus, isTrue);

    await tester.tap(find.byKey(const Key('keypad-backspace-button')));
    await tester.pump();
    expect(currentInput(tester), '773A-');

    await tester.tap(find.byKey(const Key('keypad-clear-button')));
    await tester.pump();
    expect(currentInput(tester), isEmpty);

    await tapKey('1');
    await tester.tap(find.widgetWithText(FilledButton, '提交'));
    await tester.pumpAndSettle();
    expect(submitted, '1');
  });

  testWidgets('QWERTY 键位顺序与实体键盘一致', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    await openSheet(
      tester,
      context,
      onSubmit: (String rawCode, {required bool validate}) async => true,
    );

    double left(String label) => tester.getRect(keyFinder(label)).left;
    double top(String label) => tester.getRect(keyFinder(label)).top;

    // 第一排字母是 QWERTY 而不是 ABCDE。
    expect(left('Q'), lessThan(left('W')));
    expect(left('W'), lessThan(left('E')));
    expect(left('E'), lessThan(left('R')));
    expect(left('P'), greaterThan(left('Q')));
    // 数字排在字母上面，ASDF 排在 QWER 下面。
    expect(top('1'), lessThan(top('Q')));
    expect(top('Q'), lessThan(top('A')));
    expect(top('A'), lessThan(top('Z')));

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('收起应用内键盘后还能再呼出来', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    await openSheet(
      tester,
      context,
      onSubmit: (String rawCode, {required bool validate}) async => true,
    );

    final Finder toggle = find.byKey(
      const Key('manual-tracking-keyboard-button'),
    );
    expect(find.byKey(const Key('keypad-backspace-button')), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('keypad-backspace-button')), findsNothing);

    // 之前收起后只能退出重进，这里必须能原地叫回来。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('keypad-backspace-button')), findsOneWidget);

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('粘贴按钮把剪贴板内容填进输入框', (WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': ' TRACK-0001 '};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final BuildContext context = await pumpHost(tester);
    await openSheet(
      tester,
      context,
      onSubmit: (String rawCode, {required bool validate}) async => true,
    );

    await tester.tap(find.byKey(const Key('manual-tracking-paste-button')));
    await tester.pumpAndSettle();
    expect(currentInput(tester), 'TRACK-0001');

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('小屏展开应用内键盘不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final BuildContext context = await pumpHost(tester);
    await openSheet(
      tester,
      context,
      onSubmit: (String rawCode, {required bool validate}) async => true,
    );

    expect(find.byKey(const Key('keypad-backspace-button')), findsOneWidget);
    expect(tester.takeException(), isNull);

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });
}
