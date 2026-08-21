import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/app/packing_proof_mobile_app.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/screens/packing_home_screen.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';

const double _goldenDiffTolerance = 0.001;

class _TolerantGoldenFileComparator extends LocalFileComparator {
  _TolerantGoldenFileComparator(LocalFileComparator comparator)
    : super(comparator.basedir.resolve('home_golden_test.dart'));

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final ComparisonResult result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _goldenDiffTolerance) {
      result.dispose();
      return true;
    }

    final String error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(
      '$error\n'
      'Allowed pixel difference: '
      '${(_goldenDiffTolerance * 100).toStringAsFixed(2)}%.',
    );
  }
}

Future<void> _loadAppFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final Uint8List textFont = await File(
      'assets/fonts/NotoSansSC-Subset.ttf',
    ).readAsBytes();
    final File executable = File(Platform.resolvedExecutable);
    Directory flutterRoot = executable.parent;
    while (!Directory(
      '${flutterRoot.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}flutter',
    ).existsSync()) {
      if (flutterRoot.parent.path == flutterRoot.path) {
        throw StateError('无法从 Dart 运行时定位 Flutter SDK');
      }
      flutterRoot = flutterRoot.parent;
    }
    final Uint8List iconFont = await File(
      '${flutterRoot.path}${Platform.pathSeparator}bin${Platform.pathSeparator}'
      'cache${Platform.pathSeparator}artifacts${Platform.pathSeparator}'
      'material_fonts${Platform.pathSeparator}MaterialIcons-Regular.otf',
    ).readAsBytes();
    final Uint8List robotoFont = await File(
      '${flutterRoot.path}${Platform.pathSeparator}bin${Platform.pathSeparator}'
      'cache${Platform.pathSeparator}artifacts${Platform.pathSeparator}'
      'material_fonts${Platform.pathSeparator}roboto-regular.ttf',
    ).readAsBytes();
    await (FontLoader(
      'NotoSansSC',
    )..addFont(Future<ByteData>.value(ByteData.sublistView(textFont)))).load();
    await (FontLoader('Roboto')
          ..addFont(Future<ByteData>.value(ByteData.sublistView(robotoFont))))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(Future<ByteData>.value(ByteData.sublistView(iconFont)))).load();
  });
}

ThemeData _goldenTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: PackingProofMobileApp.forest,
    surface: Colors.white,
  ),
  scaffoldBackgroundColor: Colors.white,
  fontFamily: 'Roboto',
  fontFamilyFallback: const <String>['NotoSansSC'],
  textTheme: ThemeData.light().textTheme.apply(
    fontFamily: 'Roboto',
    fontFamilyFallback: const <String>['NotoSansSC'],
    bodyColor: PackingProofMobileApp.ink,
    displayColor: PackingProofMobileApp.ink,
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: PackingProofMobileApp.forest,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(58),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    ),
  ),
);

void main() {
  final GoldenFileComparator comparator = goldenFileComparator;
  if (comparator is LocalFileComparator) {
    goldenFileComparator = _TolerantGoldenFileComparator(comparator);
  }

  testWidgets('390x844 首页视觉基线', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _loadAppFonts(tester);

    final MemoryImage preview = MemoryImage(
      File('assets/images/packing-preview.png').readAsBytesSync(),
    );
    final ThemeData theme = _goldenTheme();

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: PackingHomeView(
          phase: PackingSessionPhase.ready,
          elapsed: Duration.zero,
          nativePreviewSize: const Size(1080, 1920),
          backCameraLenses: const <NativeCameraLens>[
            NativeCameraLens(
              cameraId: 'ultra',
              focalLength: 2.2,
              zoomRatio: 0.5,
            ),
            NativeCameraLens(
              cameraId: 'wide',
              focalLength: 5.4,
              zoomRatio: 1.0,
              isMain: true,
            ),
            NativeCameraLens(
              cameraId: 'tele',
              focalLength: 6.8,
              zoomRatio: 3.0,
            ),
          ],
          activeCameraId: 'wide',
          watermarkTimestamp: DateTime(2026, 7, 20, 10, 57, 50),
          previewOverride: Image(image: preview, fit: BoxFit.cover),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );
    await tester.runAsync(() async {
      await precacheImage(
        preview,
        tester.element(find.byType(PackingHomeView)),
      );
    });
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(PackingHomeView),
      matchesGoldenFile('goldens/home_ready.png'),
    );
  }, skip: Platform.isWindows, tags: <String>['golden']);

  testWidgets('390x844 录像中压缩半透明面板视觉基线', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _loadAppFonts(tester);

    final MemoryImage preview = MemoryImage(
      File('assets/images/packing-preview.png').readAsBytesSync(),
    );

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _goldenTheme(),
        home: PackingHomeView(
          phase: PackingSessionPhase.recording,
          elapsed: const Duration(seconds: 8),
          currentCode: '770017871213193',
          nativePreviewSize: const Size(1080, 1920),
          watermarkTimestamp: DateTime(2026, 7, 20, 10, 57, 58),
          previewOverride: Image(image: preview, fit: BoxFit.cover),
          onPrimaryPressed: () {},
          onRetryPressed: () {},
        ),
      ),
    );
    await tester.runAsync(() async {
      await precacheImage(
        preview,
        tester.element(find.byType(PackingHomeView)),
      );
    });
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 100));

    await expectLater(
      find.byType(PackingHomeView),
      matchesGoldenFile('goldens/home_working.png'),
    );
  }, skip: Platform.isWindows, tags: <String>['golden']);
}
