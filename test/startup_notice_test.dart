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
}
