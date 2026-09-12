import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 底栏面板底色：半透明配合背景模糊，让摄像头画面和列表透出一点，
/// 同时保留足够不透明度维持文字对比度。
Color dockSurfaceColor(ColorScheme colors) {
  return colors.brightness == Brightness.dark
      ? colors.surfaceContainerHighest.withValues(alpha: 0.76)
      : Colors.white.withValues(alpha: 0.76);
}

/// 选中胶囊的底色：强调色的浅色调。这里必须是不透明色——面板本身已经半透明，
/// 胶囊再透明的话，底色会随摄像头画面漂移，强调色文字的对比度会掉到 3:1 以下。
Color dockIndicatorColor(ColorScheme colors) {
  final bool dark = colors.brightness == Brightness.dark;
  return Color.alphaBlend(
    colors.primary.withValues(alpha: dark ? 0.16 : 0.14),
    dark ? colors.surfaceContainerHighest : Colors.white,
  );
}

/// One entry of [DockNavigationBar].
class DockDestination {
  const DockDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// 底栏选中态：图标和文字一起被胶囊高亮包住，三个入口的形状完全一致，
/// 不再给单个入口加圆形底衬。
class DockNavigationBar extends StatelessWidget {
  const DockNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.destinations,
    this.height = 64,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<DockDestination> destinations;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        children: <Widget>[
          for (int index = 0; index < destinations.length; index++)
            Expanded(
              child: _DockNavigationItem(
                destination: destinations[index],
                selected: index == selectedIndex,
                onTap: () => onSelected(index),
              ),
            ),
        ],
      ),
    );
  }
}

class _DockNavigationItem extends StatelessWidget {
  const _DockNavigationItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final DockDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // 选中项的图标和文字都用强调色，未选中保持中性。
    final Color foreground = selected
        ? colors.primary
        : colors.onSurfaceVariant;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: ShapeDecoration(
              shape: const StadiumBorder(),
              color: selected ? dockIndicatorColor(colors) : Colors.transparent,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 24,
                  color: foreground,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.1,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact navigation surface with the system gesture area outside its shape.
class FloatingDock extends StatelessWidget {
  const FloatingDock({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Align(
        heightFactor: 1,
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 304),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              boxShadow: [
                BoxShadow(
                  color: colors.shadow.withValues(alpha: dark ? 0.2 : 0.08),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
                BoxShadow(
                  color: colors.shadow.withValues(alpha: dark ? 0.4 : 0.16),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            // 半透明面板需要先裁剪出自身形状，模糊才只作用在面板范围内。
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Material(
                  color: dockSurfaceColor(colors),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(32),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: dark ? 0.14 : 0.8),
                      width: 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: MediaQuery.removePadding(
                    context: context,
                    removeBottom: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
