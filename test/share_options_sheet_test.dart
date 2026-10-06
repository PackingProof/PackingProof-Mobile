import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/widgets/share_options_sheet.dart';

void main() {
  testWidgets('分享入口同时提供系统分享与保存到相册', (WidgetTester tester) async {
    ShareOption? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showShareOptionsSheet(
                  context,
                  canSaveToGallery: true,
                );
              },
              child: const Text('打开分享'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开分享'));
    await tester.pumpAndSettle();

    expect(find.text('用其他应用分享'), findsOneWidget);
    expect(find.text('保存到本地相册'), findsOneWidget);

    await tester.tap(find.text('保存到本地相册'));
    await tester.pumpAndSettle();
    expect(selected, ShareOption.gallery);
  });

  testWidgets('平台不支持相册时隐藏保存选项', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showShareOptionsSheet(context, canSaveToGallery: false),
              child: const Text('打开分享'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开分享'));
    await tester.pumpAndSettle();

    expect(find.text('用其他应用分享'), findsOneWidget);
    expect(find.text('保存到本地相册'), findsNothing);
  });
}
