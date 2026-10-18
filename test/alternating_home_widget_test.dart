import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/screens/packing_home_screen.dart';
import 'package:packing_proof_mobile/services/camera_capability_policy.dart';

void main() {
  Widget buildHome({
    required bool alternating,
    required bool canFinish,
    String currentCode = '',
  }) {
    return MaterialApp(
      home: PackingHomeView(
        phase: PackingSessionPhase.recording,
        elapsed: const Duration(seconds: 8),
        currentCode: currentCode,
        capabilityMode: alternating
            ? CameraCapabilityMode.alternating
            : CameraCapabilityMode.full,
        canFinishCurrentOrder: canFinish,
        previewOverride: const ColoredBox(color: Colors.black),
        onPrimaryPressed: () {},
        onRetryPressed: () {},
        onFinishOrder: () {},
      ),
    );
  }

  testWidgets('轮换模式录像时显示常驻横幅与完成本单按钮', (WidgetTester tester) async {
    await tester.pumpWidget(buildHome(alternating: true, canFinish: true));
    await tester.pump();

    final Finder banner = find.byKey(
      const Key('alternating-recording-banner'),
    );
    expect(banner, findsOneWidget);
    // 条幅提示统一在下方显示，不能跑到画面上方
    final double screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(
      tester.getCenter(banner).dy,
      greaterThan(screenHeight / 2),
      reason: '常驻提醒应该和大屏提示一样落在下方',
    );
    expect(
      find.byKey(const Key('finish-current-order-button')),
      findsOneWidget,
    );
  });

  testWidgets('轮换模式录像时胶囊提示改为完成本单，不再提示扫下一张', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildHome(alternating: true, canFinish: true, currentCode: 'SF12345678'),
    );
    await tester.pump();

    expect(find.text('本次录像请点「完成本单」结束'), findsOneWidget);
    expect(find.text('扫描下一张面单自动分段'), findsNothing);
    expect(find.text('再次扫描相同面单后结束'), findsNothing);
  });

  for (final Size size in const <Size>[Size(390, 844), Size(320, 640)]) {
    testWidgets('完成本单按钮不会挤偏工作模式胶囊 ${size.width.toInt()}px', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildHome(alternating: true, canFinish: true));
      await tester.pump();

      final Finder pills = find.byKey(
        const Key('recording-operation-mode-pills'),
      );
      final Finder finish = find.byKey(
        const Key('finish-current-order-button'),
      );
      expect(pills, findsOneWidget);
      expect(finish, findsOneWidget);

      final Rect pillsRect = tester.getRect(pills);
      final Rect finishRect = tester.getRect(finish);
      expect(pillsRect.center.dx, closeTo(size.width / 2, 1));
      expect(finishRect.left, greaterThan(pillsRect.right));
    });
  }

  testWidgets('非轮换模式不显示完成本单按钮与横幅', (WidgetTester tester) async {
    await tester.pumpWidget(buildHome(alternating: false, canFinish: false));
    await tester.pump();

    expect(find.byKey(const Key('alternating-recording-banner')), findsNothing);
    expect(find.byKey(const Key('finish-current-order-button')), findsNothing);
  });
}
