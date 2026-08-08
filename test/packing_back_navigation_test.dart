import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:packing_proof_mobile/screens/packing_home_screen.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';

void main() {
  final DateTime now = DateTime(2026, 7, 23, 12);

  test('返回键优先取消电脑连接和历史扫码', () {
    expect(
      _resolve(now, pairingActive: true, historyScanActive: true),
      PackingBackAction.cancelPairing,
    );
    expect(
      _resolve(now, historyScanActive: true),
      PackingBackAction.cancelHistoryScan,
    );
    expect(
      _resolve(now, pairingMessageVisible: true),
      PackingBackAction.cancelPairing,
    );
  });

  test('工作中拦截返回且其他主标签先回录像首页', () {
    expect(
      _resolve(now, workInProgress: true, selectedTab: 0),
      PackingBackAction.keepWorking,
    );
    expect(_resolve(now, selectedTab: 0), PackingBackAction.showHome);
    expect(_resolve(now, selectedTab: 2), PackingBackAction.showHome);
  });

  test('工作中切换历史或设置被拦截', () {
    expect(
      shouldBlockTabSwitch(workInProgress: true, busy: false, from: 1, to: 0),
      isTrue,
    );
    expect(
      shouldBlockTabSwitch(workInProgress: false, busy: true, from: 1, to: 2),
      isTrue,
    );
    expect(
      shouldBlockTabSwitch(workInProgress: true, busy: false, from: 1, to: 1),
      isFalse,
    );
    expect(
      shouldBlockTabSwitch(workInProgress: false, busy: false, from: 1, to: 0),
      isFalse,
    );
  });

  test('录像首页两秒内第二次返回才退出', () {
    expect(_resolve(now), PackingBackAction.armExit);
    expect(
      _resolve(now, exitArmedAt: now.subtract(const Duration(seconds: 2))),
      PackingBackAction.exitApp,
    );
    expect(
      _resolve(
        now,
        exitArmedAt: now.subtract(const Duration(seconds: 2, milliseconds: 1)),
      ),
      PackingBackAction.armExit,
    );
  });

  testWidgets('电脑连接失败使用弹窗显示友好提示', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showComputerPairingFailureDialog(
              context,
              '请先连接与电脑相同的 Wi-Fi 后重试',
            ),
            child: const Text('测试'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('测试'));
    await tester.pumpAndSettle();

    expect(find.text('连接电脑失败'), findsOneWidget);
    expect(find.text('请先连接与电脑相同的 Wi-Fi 后重试'), findsOneWidget);
  });

  testWidgets('更换备份电脑必须显示两端名称并由用户确认', (WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              result = await showComputerReplacementDialog(
                context,
                const ComputerReplacementPrompt(
                  currentComputer: '原电脑',
                  newComputer: '新电脑',
                ),
              );
            },
            child: const Text('测试换绑'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('测试换绑'));
    await tester.pumpAndSettle();
    expect(find.text('更换备份电脑？'), findsOneWidget);
    expect(find.textContaining('当前：原电脑'), findsOneWidget);
    expect(find.textContaining('新的电脑：新电脑'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('电脑推荐版本过高时使用不阻塞工作的更新横幅', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showMobileAppUpdateNotice(
                context,
                const MobileAppUpdateNotice(
                  minimumVersion: '0.5.6',
                  minimumBuildNumber: 11006,
                  message: '当前 APP 版本过低，需要更新',
                ),
              ),
              child: const Text('测试更新'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('测试更新'));
    await tester.pumpAndSettle();

    expect(find.text('手机 App 更新'), findsOneWidget);
    expect(find.textContaining('当前 APP 版本过低，需要更新'), findsOneWidget);
    expect(find.textContaining('最低兼容版本：0.5.6'), findsOneWidget);
    expect(find.textContaining('继续识别面单和录像'), findsOneWidget);
    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('稍后'), findsOneWidget);
    expect(find.text('打开下载页面'), findsOneWidget);
    expect(
      mobileAppDownloadUrl,
      'https://gitee.com/PackingProof/PackingProof-Mobile/releases/latest',
    );
  });
}

PackingBackAction _resolve(
  DateTime now, {
  bool pairingActive = false,
  bool pairingMessageVisible = false,
  bool historyScanActive = false,
  bool workInProgress = false,
  int selectedTab = 1,
  DateTime? exitArmedAt,
}) {
  return resolvePackingBackAction(
    pairingActive: pairingActive,
    pairingMessageVisible: pairingMessageVisible,
    historyScanActive: historyScanActive,
    workInProgress: workInProgress,
    selectedTab: selectedTab,
    now: now,
    exitArmedAt: exitArmedAt,
  );
}
