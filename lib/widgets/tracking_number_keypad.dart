import 'package:flutter/material.dart';

/// 应用内单号键盘。
///
/// 接上扫码枪或外接键盘后，Android 和 iOS 都会抑制系统软键盘，`TextInput.show`
/// 变成空调用，用户就没法手动补录单号。这块面板不依赖系统输入法，按键直接改写
/// 输入框内容。
///
/// 键位沿用 QWERTY 顺序，上面再加一排数字；按键集合对应单号规则
/// `^[A-Z0-9-]{8,40}$`：数字、大写字母和连字符。
class TrackingNumberKeypad extends StatelessWidget {
  const TrackingNumberKeypad({
    super.key,
    required this.onInsert,
    required this.onBackspace,
    required this.onClear,
    this.hint,
  });

  final ValueChanged<String> onInsert;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final String? hint;

  static const List<String> _digits = <String>[
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '0',
  ];
  static const List<String> _topRow = <String>[
    'Q',
    'W',
    'E',
    'R',
    'T',
    'Y',
    'U',
    'I',
    'O',
    'P',
  ];
  static const List<String> _homeRow = <String>[
    'A',
    'S',
    'D',
    'F',
    'G',
    'H',
    'J',
    'K',
    'L',
    '-',
  ];
  static const List<String> _bottomRow = <String>[
    'Z',
    'X',
    'C',
    'V',
    'B',
    'N',
    'M',
  ];

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // 按键不参与焦点，否则点一下就把光标从输入框里抢走了。
    return ExcludeFocus(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                hint!,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          for (final List<String> row in <List<String>>[
            _digits,
            _topRow,
            _homeRow,
          ])
            _KeyRow(
              children: <Widget>[
                for (final String key in row)
                  _KeypadKey(label: key, onTap: () => onInsert(key)),
              ],
            ),
          _KeyRow(
            children: <Widget>[
              _KeypadKey(
                key: const Key('keypad-clear-button'),
                label: '清空',
                flex: 2,
                emphasized: true,
                fontSize: 14,
                onTap: onClear,
              ),
              for (final String key in _bottomRow)
                _KeypadKey(label: key, onTap: () => onInsert(key)),
              _KeypadKey(
                key: const Key('keypad-backspace-button'),
                label: '⌫',
                flex: 2,
                emphasized: true,
                onTap: onBackspace,
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
      padding: const EdgeInsets.only(top: 6),
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
    this.fontSize = 17,
  });

  final String label;
  final VoidCallback onTap;
  final int flex;
  final bool emphasized;
  final double fontSize;

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
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 46,
              child: Center(
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
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
