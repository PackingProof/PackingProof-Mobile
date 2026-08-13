import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/screens/packing_home_screen.dart';
import 'package:packing_proof_mobile/services/preview_cover_transform.dart';

void main() {
  testWidgets('相机加载时仅显示轻量应用图标', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.initializing,
          elapsed: Duration.zero,
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    final Image image = tester.widget<Image>(
      find.byKey(const Key('camera-loading-app-icon')),
    );
    expect((image.image as AssetImage).assetName, 'assets/images/app-icon.png');
  });

  testWidgets('重复单号使用醒目的录像内警告', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 5),
          currentCode: 'TRACK-1',
          scanWarningMessage: '警告：重复单号，请确认',
          previewOverride: const ColoredBox(color: Colors.black),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('scan-warning-toast')), findsOneWidget);
    expect(find.text('警告：重复单号，请确认'), findsOneWidget);
  });

  testWidgets('相机兼容提示显示中性信息横幅', (WidgetTester tester) async {
    const String notice = '受硬件限制，录像时预览画面会暂停，扫码和录像不受影响';
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 5),
          cameraNotice: notice,
          previewOverride: const ColoredBox(color: Colors.black),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('camera-notice-banner')), findsOneWidget);
    expect(find.text(notice), findsOneWidget);
    expect(find.byKey(const Key('scan-warning-toast')), findsNothing);
  });

  testWidgets('只有扫描警告时不渲染相机提示横幅', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 5),
          scanWarningMessage: '警告：重复单号，请确认',
          previewOverride: const ColoredBox(color: Colors.black),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('scan-warning-toast')), findsOneWidget);
    expect(find.byKey(const Key('camera-notice-banner')), findsNothing);
  });

  testWidgets('扫描警告与相机提示并存时红色警告优先', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 5),
          scanWarningMessage: '警告：重复单号，请确认',
          cameraNotice: '受硬件限制，录像时预览画面会暂停，扫码和录像不受影响',
          previewOverride: const ColoredBox(color: Colors.black),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('scan-warning-toast')), findsOneWidget);
    expect(find.byKey(const Key('camera-notice-banner')), findsNothing);
  });

  testWidgets('无效条码 Toast 不覆盖已识别反馈', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 5),
          currentCode: 'TRACK-1',
          lastMarker: BarcodeMarker(
            code: 'TRACK-1',
            occurredAt: DateTime(2026, 8, 9, 10),
            offset: Duration.zero,
          ),
          rejectedBarcodeMessage: '识别到非面单条码：1234567890，已忽略',
          previewOverride: const ColoredBox(color: Colors.black),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('rejected-barcode-toast')), findsOneWidget);
    expect(find.text('已识别面单，当前录像已绑定'), findsOneWidget);
    expect(find.text('识别到非面单条码：1234567890，已忽略'), findsOneWidget);
  });

  testWidgets('录像前后都完整显示竖屏画面', (WidgetTester tester) async {
    final ValueNotifier<CameraValue> cameraValue = ValueNotifier<CameraValue>(
      _cameraValue(previewSize: const Size(1920, 1080)),
    );
    addTearDown(cameraValue.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 390,
            height: 560,
            child: CameraPreviewCoverLayout(
              cameraValue: cameraValue,
              preview: const ColoredBox(color: Colors.green),
            ),
          ),
        ),
      ),
    );

    final Size initialNaturalSize = tester.getSize(
      find.byKey(const Key('camera-preview-natural-size')),
    );
    expect(initialNaturalSize.aspectRatio, closeTo(9 / 16, 0.001));
    expect(find.byType(RotatedBox), findsNothing);

    cameraValue.value = _cameraValue(
      previewSize: const Size(1440, 1080),
      isRecordingVideo: true,
    );
    await tester.pump();

    final Size recordingNaturalSize = tester.getSize(
      find.byKey(const Key('camera-preview-natural-size')),
    );
    expect(recordingNaturalSize.aspectRatio, closeTo(3 / 4, 0.001));
    expect(recordingNaturalSize.width, lessThan(recordingNaturalSize.height));
    expect(find.byType(RotatedBox), findsNothing);
  });

  testWidgets('已是竖屏尺寸时不会再次旋转宽高比', (WidgetTester tester) async {
    final ValueNotifier<CameraValue> cameraValue = ValueNotifier<CameraValue>(
      _cameraValue(previewSize: const Size(1080, 1920)),
    );
    addTearDown(cameraValue.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 390,
          height: 560,
          child: CameraPreviewCoverLayout(
            cameraValue: cameraValue,
            preview: const ColoredBox(color: Colors.green),
          ),
        ),
      ),
    );

    final Size naturalSize = tester.getSize(
      find.byKey(const Key('camera-preview-natural-size')),
    );
    expect(naturalSize.aspectRatio, closeTo(9 / 16, 0.001));
  });

  testWidgets('原生纹理完整显示真实竖屏画面且保留过滤', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 390,
          height: 560,
          child: NativeCameraPreviewCover(
            textureId: 7,
            sourceSize: Size(1080, 1920),
          ),
        ),
      ),
    );

    final Size naturalSize = tester.getSize(
      find.byKey(const Key('native-camera-preview-natural-size')),
    );
    expect(naturalSize.aspectRatio, closeTo(9 / 16, 0.001));
    expect(
      tester.widget<Texture>(find.byType(Texture)).filterQuality,
      FilterQuality.low,
    );
  });

  testWidgets('原生前置预览不重复翻转 Camera2 镜像', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: NativeCameraPreviewCover(
          textureId: 8,
          sourceSize: Size(1080, 1920),
        ),
      ),
    );

    final Transform transform = tester.widget<Transform>(
      find.byType(Transform),
    );
    expect(transform.transform.storage[0], 1);
    expect(transform.transform.storage[5], 1);
  });

  test('完整显示模式保留全部源画面', () {
    final PreviewCoverTransform transform = PreviewCoverTransform.contain(
      sourceSize: const Size(1080, 1440),
      canvasSize: const Size(390, 560),
    );

    expect(transform.visibleSourceRect, Offset.zero & const Size(1080, 1440));
    expect(transform.sourceDestinationRect, transform.destinationRect);
    expect(transform.destinationRect.left, greaterThanOrEqualTo(0));
    expect(transform.destinationRect.top, greaterThanOrEqualTo(0));
    expect(transform.destinationRect.right, lessThanOrEqualTo(390));
    expect(transform.destinationRect.bottom, lessThanOrEqualTo(560));
  });
}

CameraValue _cameraValue({
  required Size previewSize,
  bool isRecordingVideo = false,
}) {
  const CameraDescription description = CameraDescription(
    name: 'test-camera',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
  );
  return CameraValue(
    isInitialized: true,
    previewSize: previewSize,
    isRecordingVideo: isRecordingVideo,
    isTakingPicture: false,
    isStreamingImages: isRecordingVideo,
    isRecordingPaused: false,
    flashMode: FlashMode.off,
    exposureMode: ExposureMode.auto,
    focusMode: FocusMode.auto,
    exposurePointSupported: true,
    focusPointSupported: true,
    deviceOrientation: DeviceOrientation.portraitUp,
    lockedCaptureOrientation: DeviceOrientation.portraitUp,
    recordingOrientation: isRecordingVideo
        ? DeviceOrientation.portraitUp
        : null,
    description: description,
  );
}
