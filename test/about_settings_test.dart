import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:packing_proof_mobile/widgets/about_settings.dart';
import 'package:packing_proof_mobile/app/app_build_config.dart';

void main() {
  testWidgets('关于页显示版本、源码、Release 和开源项目', (WidgetTester tester) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutSettings(
            buildConfig: const AppBuildConfig(
              buildRevision: 'abc1234',
              buildTimestamp: '2026-07-19T14:00:00Z',
            ),
            packageInfoLoader: () async => PackageInfo(
              appName: '包裹留证',
              packageName: 'app.packingproof.mobile',
              version: '0.3.1',
              buildNumber: '9002',
            ),
            uriLauncher: (Uri uri) async {
              opened = uri;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('about-settings-open')));
    await tester.pumpAndSettle();
    expect(find.text('版本 0.3.1+9002 · abc1234'), findsOneWidget);
    expect(find.text('构建修订'), findsNothing);
    expect(find.text('版本 0.3.1+9002'), findsNothing);
    expect(find.text('源码仓库'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.byIcon(Icons.system_update_alt_rounded), findsOneWidget);
    expect(find.text('Flutter'), findsOneWidget);
    expect(find.text('SQLite / sqflite'), findsOneWidget);
    expect(find.text('AndroidX Media3'), findsOneWidget);
    expect(find.text('NanoHTTPD'), findsOneWidget);
    expect(find.text('wakelock_plus'), findsOneWidget);
    expect(find.text('Microsoft Edge TTS'), findsOneWidget);

    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(opened.toString(), packingProofReleasesUrl);
  });

  testWidgets('外部链接打开失败时显示提示', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutSettings(
            packageInfoLoader: () async => PackageInfo(
              appName: '包裹留证',
              packageName: 'app.packingproof.mobile',
              version: '0.3.1',
              buildNumber: '9002',
            ),
            uriLauncher: (_) async => false,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('about-settings-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('源码仓库'));
    await tester.pump();
    expect(find.text('无法打开链接，请稍后重试'), findsOneWidget);
  });

  testWidgets('点击版本可重新查看首次说明且只显示关闭按钮', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AboutScreen(
          packageInfoLoader: () async => PackageInfo(
            appName: '包裹留证',
            packageName: 'app.packingproof.mobile',
            version: '0.4.2',
            buildNumber: '10002',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('版本 0.4.2+10002'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('startup-notice-card')), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('开始使用'), findsNothing);
  });

  testWidgets('导出诊断日志在无记录时给出提示', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutSettings(
            packageInfoLoader: () async => PackageInfo(
              appName: '包裹留证',
              packageName: 'app.packingproof.mobile',
              version: '0.5.12',
              buildNumber: '11012',
            ),
            diagnosticsLoader: () async => null,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('about-settings-open')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出诊断日志'));
    await tester.pump();

    expect(find.text('暂无诊断记录'), findsOneWidget);
  });

  testWidgets('导出诊断日志在分享不可用时复制到剪贴板', (WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutSettings(
            packageInfoLoader: () async => PackageInfo(
              appName: '包裹留证',
              packageName: 'app.packingproof.mobile',
              version: '0.5.13',
              buildNumber: '11013',
            ),
            diagnosticsLoader: () async => 'line1\nline2',
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('about-settings-open')));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.text('导出诊断日志'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(find.text('分享不可用，诊断日志已复制到剪贴板'), findsOneWidget);
  });

  testWidgets('长按应用名触发爱心彩蛋', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AboutScreen(
          packageInfoLoader: () async => PackageInfo(
            appName: '包裹留证',
            packageName: 'app.packingproof.mobile',
            version: '0.5.20',
            buildNumber: '11020',
          ),
        ),
      ),
    );

    await tester.longPress(find.text('PackingProof-Mobile'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('heart-easter-egg-dialog')), findsOneWidget);
    expect(find.text('感谢你的陪伴'), findsOneWidget);
    expect(find.text('PackingProof ♥ 包裹留证'), findsOneWidget);

    await tester.tap(find.byKey(const Key('heart-easter-egg-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('heart-easter-egg-dialog')), findsNothing);
  });
}
