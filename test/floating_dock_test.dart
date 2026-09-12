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

      // A raised panel stays at least as bright as the page; shadows define its edge.
      expect(
        material.color!.computeLuminance(),
        greaterThanOrEqualTo(theme.scaffoldBackgroundColor.computeLuminance()),
      );
      expect(
        contrast(material.color!, theme.colorScheme.onSurface),
        greaterThan(4.5),
      );
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
      expect(rect.bottom, 640 - (bottom == 0 ? 8 : bottom));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('选中项的胶囊高亮同时包住图标与文字', (tester) async {
    // 窄屏也要放得下三个带文字的胶囊。
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ThemeData theme = PackingProofTheme.light();
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
    expect(
      decorationFor('录制').color,
      theme.colorScheme.secondaryContainer,
    );
    expect(decorationFor('历史').color, Colors.transparent);
    expect(decorationFor('设置').color, Colors.transparent);
    for (final label in ['历史', '录制', '设置']) {
      expect(decorationFor(label).shape, isA<StadiumBorder>());
    }

    // 高亮覆盖图标与文字整体，而不是只套住图标。
    final Rect pill = tester.getRect(
      find.ancestor(
        of: find.text('录制'),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final Rect icon = tester.getRect(find.byIcon(Icons.videocam_rounded));
    final Rect label = tester.getRect(find.text('录制'));
    expect(pill.left, lessThan(icon.left));
    expect(pill.right, greaterThan(label.right));

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(decorationFor('设置').color, theme.colorScheme.secondaryContainer);
    expect(tester.takeException(), isNull);
  });
}
