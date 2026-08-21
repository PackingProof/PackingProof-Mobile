import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/app/packing_proof_mobile_app.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/recording_operation_mode.dart';
import 'package:packing_proof_mobile/models/recording_orientation.dart';
import 'package:packing_proof_mobile/screens/packing_home_screen.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';

void main() {
  test('下拉通知栏不会暂停打包录像', () {
    expect(shouldSuspendPackingSession(AppLifecycleState.inactive), isFalse);
    expect(shouldSuspendPackingSession(AppLifecycleState.resumed), isFalse);
    expect(shouldSuspendPackingSession(AppLifecycleState.hidden), isTrue);
    expect(shouldSuspendPackingSession(AppLifecycleState.paused), isTrue);
    expect(shouldSuspendPackingSession(AppLifecycleState.detached), isTrue);
  });

  testWidgets('首页只保留一个主要开始动作', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: PackingProofMobileApp.forest,
            ),
          ),
        ),
        home: PackingHomeView(
          phase: PackingSessionPhase.ready,
          elapsed: Duration.zero,
          previewOverride: const ColoredBox(color: Color(0xFF313A36)),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.text('开始工作'), findsOneWidget);
    expect(find.text('查看历史'), findsNothing);
    expect(find.text('对准面单条码'), findsOneWidget);
    expect(find.text('摄像头已就绪'), findsNothing);
    expect(find.text('连续录像 · 面单自动标记 · 仅存本机'), findsNothing);
    expect(find.byKey(const Key('scan-guide')), findsOneWidget);
    final ColoredBox backing = tester.widget<ColoredBox>(
      find.byKey(const Key('camera-preview-backing')),
    );
    expect(
      backing.color,
      Theme.of(
        tester.element(find.byKey(const Key('camera-preview-backing'))),
      ).colorScheme.surface,
    );
    final PhysicalShape controlPanelShape = tester.widget<PhysicalShape>(
      find.byKey(const Key('recording-control-panel')),
    );
    expect(controlPanelShape.color.a, closeTo(0.66, 0.01));
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('recording-button-shimmer')), findsNothing);
  });

  testWidgets('工作前可选择发货退货且工作中只显示当前模式', (WidgetTester tester) async {
    RecordingOperationMode selected = RecordingOperationMode.shipping;
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.ready,
          elapsed: Duration.zero,
          previewOverride: const ColoredBox(color: Colors.black),
          operationMode: selected,
          onOperationModeChanged: (RecordingOperationMode mode) {
            selected = mode;
          },
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(
      find.byKey(const Key('operation-mode-shipping-pill')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('operation-mode-return-pill')), findsOneWidget);
    final Rect readyShippingPill = tester.getRect(
      find.byKey(const Key('operation-mode-shipping-pill')),
    );
    final Rect readyReturnPill = tester.getRect(
      find.byKey(const Key('operation-mode-return-pill')),
    );
    expect(readyShippingPill.width, greaterThanOrEqualTo(96));
    expect(readyShippingPill.height, greaterThanOrEqualTo(48));
    expect(readyReturnPill.width, greaterThanOrEqualTo(96));
    expect(readyReturnPill.height, greaterThanOrEqualTo(48));
    final Rect readyModePills = tester.getRect(
      find.byKey(const Key('recording-operation-mode-pills')),
    );
    final Rect readyControlPanel = tester.getRect(
      find.byKey(const Key('recording-control-panel')),
    );
    expect(readyModePills.bottom, lessThanOrEqualTo(readyControlPanel.top));
    final ColorScheme readyColors = Theme.of(
      tester.element(find.byKey(const Key('operation-mode-shipping-pill'))),
    ).colorScheme;
    final Ink shippingInk = tester.widget<Ink>(
      find.descendant(
        of: find.byKey(const Key('operation-mode-shipping-pill')),
        matching: find.byType(Ink),
      ),
    );
    expect(
      (shippingInk.decoration! as BoxDecoration).color,
      readyColors.primary,
    );
    await tester.tap(find.byKey(const Key('operation-mode-return-pill')));
    expect(selected, RecordingOperationMode.returnGoods);
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.ready,
          elapsed: Duration.zero,
          previewOverride: const ColoredBox(color: Colors.black),
          operationMode: selected,
          onOperationModeChanged: (RecordingOperationMode mode) {
            selected = mode;
          },
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );
    final Ink returnInk = tester.widget<Ink>(
      find.descendant(
        of: find.byKey(const Key('operation-mode-return-pill')),
        matching: find.byType(Ink),
      ),
    );
    expect(
      (returnInk.decoration! as BoxDecoration).color,
      const Color(0xFFFFA726),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 2),
          previewOverride: const ColoredBox(color: Colors.black),
          operationMode: RecordingOperationMode.returnGoods,
          onOperationModeChanged: (RecordingOperationMode mode) {
            selected = mode;
          },
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('operation-mode-shipping-pill')), findsNothing);
    expect(find.byKey(const Key('operation-mode-return-pill')), findsOneWidget);
    final Rect workingModePills = tester.getRect(
      find.byKey(const Key('recording-operation-mode-pills')),
    );
    final Rect workingReturnPill = tester.getRect(
      find.byKey(const Key('operation-mode-return-pill')),
    );
    expect(workingReturnPill.width, greaterThanOrEqualTo(96));
    expect(workingReturnPill.height, greaterThanOrEqualTo(48));
    final Rect workingControlPanel = tester.getRect(
      find.byKey(const Key('recording-control-panel')),
    );
    expect(workingModePills.bottom, lessThanOrEqualTo(workingControlPanel.top));
    await tester.tap(find.byKey(const Key('operation-mode-return-pill')));
    expect(selected, RecordingOperationMode.returnGoods);
  });

  testWidgets('电脑配对成功后显示带地址的绿色提示', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.ready,
          elapsed: Duration.zero,
          previewOverride: const ColoredBox(color: Colors.black),
          pairingMessage: '电脑连接成功 · 仓库电脑 · 192.168.1.20:5280',
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.text('电脑连接成功 · 仓库电脑 · 192.168.1.20:5280'), findsOneWidget);
    final Material banner = tester.widget<Material>(
      find
          .ancestor(
            of: find.text('电脑连接成功 · 仓库电脑 · 192.168.1.20:5280'),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(banner.color, const Color(0xF0087454));
  });

  testWidgets('支持在预览和录制期间控制闪光灯', (WidgetTester tester) async {
    int toggleCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.ready,
          elapsed: Duration.zero,
          flashAvailable: true,
          previewOverride: const ColoredBox(color: Colors.black),
          onTorchPressed: () => toggleCount++,
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('torch-button')), findsOneWidget);
    expect(find.byIcon(Icons.flash_off_rounded), findsOneWidget);
    await tester.tap(find.byKey(const Key('torch-button')));
    expect(toggleCount, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 2),
          flashAvailable: true,
          torchEnabled: true,
          previewOverride: const ColoredBox(color: Colors.black),
          onTorchPressed: () => toggleCount++,
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );
    expect(find.byIcon(Icons.flash_on_rounded), findsOneWidget);
  });

  testWidgets('仅在待机时显示前后摄像头切换按钮', (WidgetTester tester) async {
    int switchCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.ready,
          elapsed: Duration.zero,
          cameraSwitchAvailable: true,
          previewOverride: const ColoredBox(color: Colors.black),
          onCameraSwitchPressed: () => switchCount++,
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('switch-camera-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('switch-camera-button')));
    expect(switchCount, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 2),
          cameraSwitchAvailable: true,
          previewOverride: const ColoredBox(color: Colors.black),
          onCameraSwitchPressed: () => switchCount++,
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );
    expect(find.byKey(const Key('switch-camera-button')), findsNothing);
  });

  testWidgets('待机顶部胶囊列出后置镜头且工作中隐藏', (WidgetTester tester) async {
    String? selected;
    const List<NativeCameraLens> lenses = <NativeCameraLens>[
      NativeCameraLens(cameraId: 'ultra', focalLength: 2.2, zoomRatio: 0.4),
      NativeCameraLens(
        cameraId: 'wide',
        focalLength: 5.4,
        zoomRatio: 1.0,
        isMain: true,
      ),
      NativeCameraLens(cameraId: 'tele', focalLength: 6.8, zoomRatio: 1.3),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.ready,
          elapsed: Duration.zero,
          backCameraLenses: lenses,
          activeCameraId: 'wide',
          previewOverride: const ColoredBox(color: Colors.black),
          onCameraSelected: (String id) => selected = id,
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('camera-lens-capsule')), findsOneWidget);
    expect(find.text('0.4x'), findsOneWidget);
    expect(find.text('1x'), findsOneWidget);
    expect(find.text('1.3x'), findsOneWidget);
    final ColorScheme lensColors = Theme.of(
      tester.element(find.byKey(const Key('camera-lens-capsule'))),
    ).colorScheme;
    final Ink activeLensInk = tester.widget<Ink>(
      find.descendant(
        of: find.byKey(const Key('camera-lens-wide')),
        matching: find.byType(Ink),
      ),
    );
    expect(
      (activeLensInk.decoration! as BoxDecoration).color,
      lensColors.primary,
    );
    final Text activeLensText = tester.widget<Text>(find.text('1x'));
    expect(activeLensText.style?.color, lensColors.onPrimary);
    final Rect activeLensRect = tester.getRect(
      find.byKey(const Key('camera-lens-wide')),
    );
    final Rect activeLensTextRect = tester.getRect(find.text('1x'));
    expect(
      (activeLensRect.center - activeLensTextRect.center).distance,
      lessThanOrEqualTo(2),
    );
    await tester.tap(find.byKey(const Key('camera-lens-tele')));
    expect(selected, 'tele');

    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 2),
          backCameraLenses: lenses,
          activeCameraId: 'wide',
          previewOverride: const ColoredBox(color: Colors.black),
          onCameraSelected: (String id) => selected = id,
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );
    expect(find.byKey(const Key('camera-lens-capsule')), findsNothing);
  });

  testWidgets('启动录像时保持摄像头预览可见', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.starting,
          elapsed: Duration.zero,
          previewOverride: const ColoredBox(color: Colors.red),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('camera-transition-cover')), findsNothing);
    expect(find.byKey(const Key('scan-guide')), findsOneWidget);
    expect(find.text('正在启动录像'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('保存录像时保持摄像头预览可见', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.saving,
          elapsed: const Duration(seconds: 8),
          previewOverride: const ColoredBox(color: Colors.red),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('camera-transition-cover')), findsNothing);
    expect(find.byKey(const Key('scan-guide')), findsOneWidget);
    expect(find.text('正在保存录像'), findsOneWidget);
  });

  testWidgets('开始工作后等待面单且不显示录像计时', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.waitingForBarcode,
          elapsed: Duration.zero,
          cameraSwitchAvailable: true,
          previewOverride: const ColoredBox(color: Colors.black),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.text('等待面单'), findsOneWidget);
    expect(find.text('识别面单后自动开始录像'), findsOneWidget);
    expect(find.text('结束工作'), findsOneWidget);
    expect(find.byKey(const Key('recording-duration-pill')), findsNothing);
    expect(find.byKey(const Key('switch-camera-button')), findsNothing);
  });

  testWidgets('录像中显示时长胶囊、加粗单号和红色结束按钮', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 8),
          currentCode: '770017871213193',
          nativePreviewSize: const Size(1080, 1920),
          previewOverride: const ColoredBox(color: Colors.black),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('recording-duration-pill')), findsOneWidget);
    expect(find.text('00:08'), findsOneWidget);
    expect(find.text('770017871213193'), findsOneWidget);
    expect(find.text('结束工作'), findsOneWidget);
    expect(find.byKey(const Key('recording-button-shimmer')), findsOneWidget);
    expect(find.byKey(const Key('camera-watermark-preview')), findsOneWidget);
    expect(find.textContaining('Order:770017871213193'), findsNWidgets(2));

    final Positioned watermarkPosition = tester.widget<Positioned>(
      find.byKey(const Key('camera-watermark-position')),
    );
    expect(watermarkPosition.top, 68);
    expect(watermarkPosition.left, 72);
    expect(watermarkPosition.right, isNull);

    final Text watermarkOutline = tester.widget<Text>(
      find.byKey(const Key('camera-watermark-outline')),
    );
    final Text watermarkFill = tester.widget<Text>(
      find.byKey(const Key('camera-watermark-fill')),
    );
    expect(watermarkOutline.textAlign, TextAlign.right);
    expect(watermarkOutline.style?.foreground?.style, PaintingStyle.stroke);
    expect(watermarkOutline.style?.foreground?.color, Colors.black);
    expect(watermarkOutline.style?.fontSize, closeTo(61 * 390 / 1080, 0.0001));
    expect(
      watermarkOutline.style?.foreground?.strokeWidth,
      closeTo(6.1 * 390 / 1080, 0.0001),
    );
    expect(watermarkFill.textAlign, TextAlign.right);
    expect(watermarkFill.style?.color, Colors.white);
    expect(
      find.descendant(
        of: find.byKey(const Key('camera-watermark-preview')),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
    );

    final Rect previewViewport = tester.getRect(
      find.byKey(const Key('camera-preview-viewport')),
    );
    final Rect durationPill = tester.getRect(
      find.byKey(const Key('recording-duration-pill')),
    );
    final Rect operationModePills = tester.getRect(
      find.byKey(const Key('recording-operation-mode-pills')),
    );
    final Rect controlPanel = tester.getRect(
      find.byKey(const Key('recording-control-panel')),
    );
    expect(previewViewport.size.aspectRatio, closeTo(9 / 16, 0.001));
    expect(controlPanel.height, inInclusiveRange(112, 122));
    expect(controlPanel.top, greaterThan(previewViewport.bottom - 24));
    expect(controlPanel.bottom, lessThanOrEqualTo(844 - 36));
    expect(durationPill.bottom, lessThan(controlPanel.top));
    expect(durationPill.center.dx, closeTo(previewViewport.center.dx, 1));
    expect(
      durationPill.center.dy,
      lessThan(previewViewport.top + previewViewport.height * 0.2),
    );
    expect(operationModePills.bottom, lessThanOrEqualTo(controlPanel.top));
    expect(
      operationModePills.center.dy,
      greaterThan(previewViewport.top + previewViewport.height * 0.65),
    );
    expect(durationPill.bottom, lessThan(operationModePills.top));

    final Text shippingCode = tester.widget<Text>(
      find.byKey(const Key('current-shipping-code')),
    );
    expect(shippingCode.style?.fontWeight, FontWeight.w800);

    final FilledButton stopButton = tester.widget<FilledButton>(
      find.byKey(const Key('primary-work-button')),
    );
    expect(
      tester.getSize(find.byKey(const Key('primary-work-button'))).height,
      greaterThanOrEqualTo(54),
    );
    expect(
      stopButton.style?.backgroundColor?.resolve(<WidgetState>{}),
      const Color(0xFFD92D20),
    );
  });

  testWidgets('横屏预览水印使用成片比例且不随系统文字缩放', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.2)),
          child: child!,
        ),
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 8),
          currentCode: '770017871213193',
          recordingOrientation: RecordingOrientation.landscapeLeft,
          nativePreviewSize: const Size(1080, 1920),
          previewOverride: const ColoredBox(color: Colors.black),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    final Text outline = tester.widget<Text>(
      find.byKey(const Key('camera-watermark-outline')),
    );
    final Text fill = tester.widget<Text>(
      find.byKey(const Key('camera-watermark-fill')),
    );
    expect(outline.textScaler, TextScaler.noScaling);
    expect(fill.textScaler, TextScaler.noScaling);
    expect(outline.style?.fontSize, closeTo(35 * 390 / 1080, 0.0001));
    expect(
      outline.style?.foreground?.strokeWidth,
      closeTo(3.5 * 390 / 1080, 0.0001),
    );
  });

  testWidgets('扫码时隐藏模式选择且小屏录像覆盖层不重叠', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.ready,
          elapsed: Duration.zero,
          pairingScanActive: true,
          previewOverride: const ColoredBox(color: Colors.black),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );
    expect(
      find.byKey(const Key('recording-operation-mode-pills')),
      findsNothing,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.ready,
          elapsed: Duration.zero,
          historyScanActive: true,
          previewOverride: const ColoredBox(color: Colors.black),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );
    expect(
      find.byKey(const Key('recording-operation-mode-pills')),
      findsNothing,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 8),
          previewOverride: const ColoredBox(color: Colors.black),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    final Rect durationPill = tester.getRect(
      find.byKey(const Key('recording-duration-pill')),
    );
    final Rect operationModePills = tester.getRect(
      find.byKey(const Key('recording-operation-mode-pills')),
    );
    final Rect controlPanel = tester.getRect(
      find.byKey(const Key('recording-control-panel')),
    );
    expect(durationPill.bottom, lessThan(operationModePills.top));
    expect(operationModePills.bottom, lessThanOrEqualTo(controlPanel.top));
    expect(operationModePills.width, lessThanOrEqualTo(320));
    expect(operationModePills.height, greaterThanOrEqualTo(48));
    expect(controlPanel.bottom, lessThanOrEqualTo(640 - 36));
  });
}
