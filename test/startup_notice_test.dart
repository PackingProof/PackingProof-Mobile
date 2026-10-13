import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/app/app_build_config.dart';
import 'package:packing_proof_mobile/app/packing_proof_mobile_app.dart';
import 'package:packing_proof_mobile/models/app_settings.dart';

void main() {
  testWidgets('启动初始化失败时显示错误并允许重试', (WidgetTester tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      PackingProofMobileApp(
        settingsLoader: () async {
          attempts++;
          if (attempts == 1) throw StateError('录像数据库无法打开');
          return const AppSettings(startupNoticeVersion: 1);
        },
      ),
    );
    await tester.pump();

    expect(find.text('应用启动失败'), findsOneWidget);
    expect(find.textContaining('录像数据库无法打开'), findsOneWidget);

    await tester.tap(find.text('重试启动'));
    await tester.pump();
    await tester.pump();

    expect(attempts, 2);
    expect(find.byKey(const Key('startup-load-error')), findsNothing);

    // 重试成功后进入 PackingHomeScreen，销毁时会创建有界音频 stop 超时计时器；
    // 测试环境需要显式卸载并推进时间，避免残留 Timer 被判定为测试失败。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('首次打开显示统一的开源与本地数据说明', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StartupNoticeScreen(
          buildConfig: const AppBuildConfig(),
          onConfirm: () async {},
        ),
      ),
    );

    expect(find.byKey(const Key('startup-notice-card')), findsOneWidget);
    final Text title = tester.widget<Text>(
      find.byKey(const Key('startup-notice-title')),
    );
    expect(title.textAlign, TextAlign.center);
    expect(
      find.descendant(
        of: find.byKey(const Key('startup-notice-card')),
        matching: find.text('欢迎使用包裹留证'),
      ),
      findsNothing,
    );
    final Text body = tester.widget<Text>(find.textContaining('开源且免费'));
    expect(body.textAlign, TextAlign.left);
    expect(find.textContaining('开源且免费'), findsOneWidget);
    expect(find.textContaining('才会通过局域网备份录像'), findsOneWidget);
  });

  testWidgets('系统字体放大时欢迎页不溢出且确认按钮仍可点击', (WidgetTester tester) async {
    const double viewportHeight = 568;
    tester.view.physicalSize = const Size(320, viewportHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var confirmCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: StartupNoticeScreen(
          buildConfig: const AppBuildConfig(),
          confirmLabel: '关闭',
          onConfirm: () async => confirmCount++,
        ),
      ),
    );

    final Finder scrollView = find.byKey(const Key('startup-notice-scroll'));
    expect(scrollView, findsOneWidget);
    // 说明内容高于可视区域时改为滚动查看，不再溢出屏幕。
    expect(tester.getSize(scrollView).height, lessThan(viewportHeight));
    expect(
      tester.getRect(find.byKey(const Key('startup-notice-card'))).top,
      lessThan(viewportHeight),
    );

    final Finder confirm = find.byKey(const Key('startup-notice-confirm'));
    expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(viewportHeight));
    await tester.tap(confirm);
    await tester.pump();
    expect(confirmCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认字体下欢迎页内容与确认按钮完整显示', (WidgetTester tester) async {
    const double viewportHeight = 568;
    tester.view.physicalSize = const Size(320, viewportHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: StartupNoticeScreen(
          buildConfig: const AppBuildConfig(),
          onConfirm: () async {},
        ),
      ),
    );

    final Rect card = tester.getRect(
      find.byKey(const Key('startup-notice-card')),
    );
    final Rect confirm = tester.getRect(
      find.byKey(const Key('startup-notice-confirm')),
    );
    expect(card.top, greaterThanOrEqualTo(0));
    expect(card.bottom, lessThanOrEqualTo(confirm.top));
    expect(confirm.bottom, lessThanOrEqualTo(viewportHeight));
    expect(tester.takeException(), isNull);
  });
}
