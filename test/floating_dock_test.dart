import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:packing_proof_mobile/app/packing_proof_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/widgets/floating_dock.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('dock stays distinct from page in $brightness', (tester) async {
      final theme = brightness == Brightness.dark
          ? PackingProofTheme.dark()
          : PackingProofTheme.light();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            bottomNavigationBar: FloatingDock(child: SizedBox(height: 64)),
          ),
        ),
      );
      final material = tester.widget<Material>(
        find.descendant(
          of: find.byType(FloatingDock),
          matching: find.byType(Material),
        ),
      );
      double contrast(Color a, Color b) {
        final x = a.computeLuminance();
        final y = b.computeLuminance();
        return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
      }

      // 面板是半透明的，实际观感取决于它叠在什么背景之上。
      expect(material.color!.a, lessThan(1));
      expect(
        find.descendant(
          of: find.byType(FloatingDock),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );

      Color over(Color background) =>
          Color.alphaBlend(material.color!, background);

      // A raised panel stays at least as bright as the page; shadows define its edge.
      expect(
        over(theme.scaffoldBackgroundColor).computeLuminance(),
        greaterThanOrEqualTo(theme.scaffoldBackgroundColor.computeLuminance()),
      );
      // 录制页的底栏浮在摄像头画面上，最亮和最暗的背景都要读得清文字。
      for (final background in [
        theme.scaffoldBackgroundColor,
        Colors.black,
        Colors.white,
      ]) {
        expect(
          contrast(over(background), theme.colorScheme.onSurface),
          greaterThan(4.5),
          reason: 'background $background',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final bottom in [0.0, 34.0]) {
    testWidgets('dock respects safe area $bottom and switches tabs', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(320, 640),
              padding: EdgeInsets.only(bottom: bottom),
            ),
            child: Scaffold(
              bottomNavigationBar: FloatingDock(
                child: NavigationBar(
                  height: 64,
                  selectedIndex: selected,
                  onDestinationSelected: (value) => selected = value,
                  destinations: const [
                    NavigationDestination(icon: Icon(Icons.home), label: '首页'),
                    NavigationDestination(
                      icon: Icon(Icons.settings),
                      label: '设置',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(NavigationBar));
      expect(rect.left, 28);
      expect(rect.right, 292);
      expect(rect.height, 64);
      // 安全区之上再抬 6，避免贴着安卓手势条。
      expect(rect.bottom, 640 - (math.max(bottom, 8) + 6));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('选中项的胶囊高亮同时包住图标与文字 $brightness', (tester) async {
      // 窄屏也要放得下三个带文字的胶囊。
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ThemeData theme = brightness == Brightness.dark
          ? PackingProofTheme.dark()
          : PackingProofTheme.light();
      var selected = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            bottomNavigationBar: FloatingDock(
              child: StatefulBuilder(
                builder: (context, setState) => DockNavigationBar(
                  selectedIndex: selected,
                  onSelected: (value) => setState(() => selected = value),
                  destinations: const [
                    DockDestination(
                      icon: Icons.history_rounded,
                      selectedIcon: Icons.history_rounded,
                      label: '历史',
                    ),
                    DockDestination(
                      icon: Icons.videocam_outlined,
                      selectedIcon: Icons.videocam_rounded,
                      label: '录制',
                    ),
                    DockDestination(
                      icon: Icons.settings_outlined,
                      selectedIcon: Icons.settings_rounded,
                      label: '设置',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      ShapeDecoration decorationFor(String label) {
        return tester
                .widget<AnimatedContainer>(
                  find.ancestor(
                    of: find.text(label),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as ShapeDecoration;
      }

      // 选中项有胶囊底色，未选中项完全透明，三者形状一致。
      expect(decorationFor('录制').color, dockIndicatorColor(theme.colorScheme));
      expect(decorationFor('历史').color, Colors.transparent);
      expect(decorationFor('设置').color, Colors.transparent);
      for (final label in ['历史', '录制', '设置']) {
        expect(decorationFor(label).shape, isA<StadiumBorder>());
      }

      // 选中项的图标和文字都是强调色，且在胶囊底色上读得清。
      final Color selectedIconColor = tester
          .widget<Icon>(find.byIcon(Icons.videocam_rounded))
          .color!;
      final Color selectedTextColor = tester
          .widget<Text>(find.text('录制'))
          .style!
          .color!;
      expect(selectedIconColor, theme.colorScheme.primary);
      expect(selectedTextColor, theme.colorScheme.primary);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.settings_outlined)).color,
        theme.colorScheme.onSurfaceVariant,
      );
      double contrast(Color a, Color b) {
        final x = a.computeLuminance();
        final y = b.computeLuminance();
        return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
      }

      // 胶囊底色不透明，所以对比度不会被下面的摄像头画面影响。
      final Color pillColor = decorationFor('录制').color!;
      expect(pillColor.a, 1);
      expect(contrast(selectedTextColor, pillColor), greaterThan(4.5));

      // 图标在上、文字在下，高亮同时覆盖两者。
      final Rect pill = tester.getRect(
        find.ancestor(
          of: find.text('录制'),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final Rect icon = tester.getRect(find.byIcon(Icons.videocam_rounded));
      final Rect label = tester.getRect(find.text('录制'));
      expect(icon.bottom, lessThanOrEqualTo(label.top));
      expect(icon.center.dx, closeTo(label.center.dx, 0.5));
      expect(pill.top, lessThan(icon.top));
      expect(pill.bottom, greaterThan(label.bottom));
      expect(pill.left, lessThan(icon.left));
      expect(pill.right, greaterThan(label.right));

      // 高亮几乎铺满整个入口格子，不是紧贴文字的细条。
      final double cellWidth =
          tester.getSize(find.byType(DockNavigationBar)).width / 3;
      expect(pill.width, greaterThan(cellWidth - 16));
      expect(pill.width, greaterThan(label.width * 2));

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(decorationFor('设置').color, dockIndicatorColor(theme.colorScheme));
      expect(tester.takeException(), isNull);
      expect(tester.takeException(), isNull);
    });
  }
}
