import 'package:flutter/material.dart';

/// 输入框统一使用 Flutter 自带的选择菜单。
///
/// Material 的 [SearchBar] 在 iOS 16 及以上默认返回 `SystemContextMenu`，
/// 也就是走引擎的 `showSystemContextMenu` → UIKit `UIEditMenuInteraction`。
/// 这条链在 UIKit 内部抛异常时会把 App 直接中止（崩溃点
/// `UIKitCore: 0x196a14000 + 3561892`，与更早的 `0x18d01f000 + 3563616`
/// 是同一条调用链），应用侧既拦不住也修不了。
///
/// 统一回落到 Flutter 自己的选择菜单：复制、粘贴、全选照常可用，但不再
/// 依赖系统编辑菜单的实现。
Widget buildFlutterTextSelectionMenu(
  BuildContext context,
  EditableTextState editableTextState,
) {
  return AdaptiveTextSelectionToolbar.editableText(
    editableTextState: editableTextState,
  );
}
