import 'package:flutter/material.dart';

/// 应用内单号键盘。
///
/// 接上扫码枪或外接键盘后，Android 和 iOS 都会抑制系统软键盘，`TextInput.show`
/// 变成空调用，用户就没法手动补录单号。这块面板不依赖系统输入法，按键直接改写
/// 输入框内容。
///
/// 按键集合对应单号规则 `^[A-Z0-9-]{8,40}$`：数字、大写字母和连字符。
class TrackingNumberKeypad extends StatefulWidget {
  const TrackingNumberKeypad({
    super.key,
    required this.onInsert,
    required this.onBackspace,
    required this.onClear,
    this.onHide,
  });

  final ValueChanged<String> onInsert;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback? onHide;

  @override
  State<TrackingNumberKeypad> createState() => _TrackingNumberKeypadState();
}

class _TrackingNumberKeypadState extends State<TrackingNumberKeypad> {
  static const List<List<String>> _digitRows = <List<String>>[
    <String>['1', '2', '3', '4', '5'],
    <String>['6', '7', '8', '9', '0'],
  ];
  static const List<List<String>> _letterRows = <List<String>>[
    <String>['A', 'B', 'C', 'D', 'E', 'F', 'G'],
    <String>['H', 'I', 'J', 'K', 'L', 'M', 'N'],
    <String>['O', 'P', 'Q', 'R', 'S', 'T', 'U'],
    <String>['V', 'W', 'X', 'Y', 'Z'],
  ];

  bool _letters = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // 按键不参与焦点，否则点一下就把光标从输入框里抢走了。
    return ExcludeFocus(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '外接设备占用了系统键盘，可用下方键盘输入',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              if (widget.onHide != null)
                IconButton(
                  key: const Key('keypad-hide-button'),
                  tooltip: '收起键盘',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.keyboard_hide_rounded, size: 20),
                  onPressed: widget.onHide,
                ),
            ],
          ),
          for (final List<String> row in _letters ? _letterRows : _digitRows)
            _KeyRow(
              children: <Widget>[
                for (final String key in row)
                  _KeypadKey(label: key, onTap: () => widget.onInsert(key)),
              ],
            ),
          _KeyRow(
            children: <Widget>[
              _KeypadKey(
                key: const Key('keypad-mode-button'),
                label: _letters ? '123' : 'ABC',
                emphasized: true,
                flex: 2,
                onTap: () => setState(() => _letters = !_letters),
              ),
              _KeypadKey(label: '-', onTap: () => widget.onInsert('-')),
              _KeypadKey(
                key: const Key('keypad-clear-button'),
                label: '清空',
                flex: 2,
                onTap: widget.onClear,
              ),
              _KeypadKey(
                key: const Key('keypad-backspace-button'),
                label: '⌫',
                emphasized: true,
                flex: 2,
                onTap: widget.onBackspace,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: children),
    );
  }
}

class _KeypadKey extends StatelessWidget {
  const _KeypadKey({
    super.key,
    required this.label,
    required this.onTap,
    this.flex = 1,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback onTap;
  final int flex;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          color: emphasized
              ? colors.secondaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 40,
              child: Center(
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: emphasized
                        ? colors.onSecondaryContainer
                        : colors.onSurface,
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
