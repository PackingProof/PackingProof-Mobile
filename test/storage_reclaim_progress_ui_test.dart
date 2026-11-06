import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/screens/packing_home_screen.dart';

void main() {
  testWidgets('空间回收期间显示可理解的清理提示', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.starting,
          elapsed: Duration.zero,
          scanWarningMessage: '正在清理存储空间，请稍候',
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.text('正在清理存储空间，请稍候'), findsOneWidget);
    expect(find.byKey(const Key('scan-warning-toast')), findsOneWidget);
  });
}
