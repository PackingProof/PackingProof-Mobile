import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/screens/packing_home_screen.dart';
import 'package:packing_proof_mobile/widgets/text_selection_menu.dart';

/// iOS 16 及以上 Material 的 SearchBar 默认走系统编辑菜单，这条链在 UIKit
/// 内部抛异常会把 App 直接中止；输入框统一改回 Flutter 自带的选择菜单。
void main() {
  testWidgets('选择菜单回落到 Flutter 自带实现', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TextField())),
    );

    final Finder editable = find.byType(EditableText);
    final Widget menu = buildFlutterTextSelectionMenu(
      tester.element(editable),
      tester.state<EditableTextState>(editable),
    );

    expect(menu, isA<AdaptiveTextSelectionToolbar>());
    expect(menu, isNot(isA<SystemContextMenu>()));
  });

  testWidgets('手动输入面板不依赖 iOS 系统编辑菜单', (WidgetTester tester) async {
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

    showManualTrackingSheet(
      context,
      onSubmit: (String rawCode, {required bool validate}) async => true,
    ).ignore();
    await tester.pumpAndSettle();

    final SearchBar bar = tester.widget<SearchBar>(
      find.byKey(const Key('manual-tracking-input')),
    );
    expect(bar.contextMenuBuilder, buildFlutterTextSelectionMenu);

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });
}
