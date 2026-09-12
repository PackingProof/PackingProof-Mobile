import 'package:flutter/material.dart';

/// 应用内单号键盘。
///
/// 接上扫码枪或外接键盘后，Android 和 iOS 都会抑制系统软键盘，`TextInput.show`
/// 变成空调用，用户就没法手动补录单号。这块面板不依赖系统输入法，按键直接改写
/// 输入框内容。
///
/// 布局对齐手机系统键盘的习惯：字母页五排（数字行 + 三排 QWERTY + 功能行），
/// `123` 切到九宫格数字页。按键集合对应单号规则 `^[A-Z0-9-]{8,40}$`。
class TrackingNumberKeypad extends StatefulWidget {
  const TrackingNumberKeypad({
    super.key,
    required this.onInsert,
    required this.onBackspace,
    required this.onClear,
    this.onSubmit,
    this.hint,
  });

  final ValueChanged<String> onInsert;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback? onSubmit;
  final String? hint;

  @override
  State<TrackingNumberKeypad> createState() => _TrackingNumberKeypadState();
}

class _TrackingNumberKeypadState extends State<TrackingNumberKeypad> {
  static const List<List<String>> _letterRows = <List<String>>[
    <String>['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    <String>['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
    <String>['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
    <String>['Z', 'X', 'C', 'V', 'B', 'N', 'M'],
  ];
  static const List<List<String>> _digitRows = <List<String>>[
    <String>['1', '2', '3'],
    <String>['4', '5', '6'],
    <String>['7', '8', '9'],
  ];

  bool _numeric = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // 按键不参与焦点，否则点一下就把光标从输入框里抢走了。
    return ExcludeFocus(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                widget.hint!,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          if (_numeric) ..._buildDigitRows() else ..._buildLetterRows(),
        ],
      ),
    );
  }

  /// 字母页共五排：数字行 + 三排 QWERTY + 功能行，退格跟在 Z 排行尾。
  List<Widget> _buildLetterRows() {
    return <Widget>[
      for (final List<String> row in _letterRows)
        _KeyRow(
          children: <Widget>[
            // 第二、三排比第一排短，两侧留半个键的余量，保持系统键盘的错落感。
            if (row.length < 10) const Spacer(),
            for (final String key in row)
              _KeypadKey(
                label: key,
                flex: 2,
                onTap: () => widget.onInsert(key),
              ),
            if (row.length == 7) _backspaceKey(flex: 4),
            if (row.length < 10) const Spacer(),
          ],
        ),
      _KeyRow(
        children: <Widget>[
          _modeKey(flex: 4),
          _KeypadKey(label: '-', flex: 4, onTap: () => widget.onInsert('-')),
          _clearKey(flex: 6),
          if (widget.onSubmit != null) _submitKey(flex: 6),
        ],
      ),
    ];
  }

  /// 数字页：九宫格 + 右侧功能列，退格同样落在第三排。
  List<Widget> _buildDigitRows() {
    return <Widget>[
      _KeyRow(
        children: <Widget>[
          for (final String key in _digitRows[0])
            _KeypadKey(label: key, onTap: () => widget.onInsert(key)),
          _clearKey(),
        ],
      ),
      _KeyRow(
        children: <Widget>[
          for (final String key in _digitRows[1])
            _KeypadKey(label: key, onTap: () => widget.onInsert(key)),
          _KeypadKey(label: '-', onTap: () => widget.onInsert('-')),
        ],
      ),
      _KeyRow(
        children: <Widget>[
          for (final String key in _digitRows[2])
            _KeypadKey(label: key, onTap: () => widget.onInsert(key)),
          _backspaceKey(),
        ],
      ),
      _KeyRow(
        children: <Widget>[
          _modeKey(),
          _KeypadKey(label: '0', flex: 2, onTap: () => widget.onInsert('0')),
          if (widget.onSubmit != null) _submitKey(),
        ],
      ),
    ];
  }

  Widget _modeKey({int flex = 1}) => _KeypadKey(
    key: const Key('keypad-mode-button'),
    label: _numeric ? 'ABC' : '123',
    flex: flex,
    fontSize: 14,
    tone: _KeyTone.function,
    onTap: () => setState(() => _numeric = !_numeric),
  );

  Widget _clearKey({int flex = 1}) => _KeypadKey(
    key: const Key('keypad-clear-button'),
    label: '清空',
    flex: flex,
    fontSize: 14,
    tone: _KeyTone.function,
    onTap: widget.onClear,
  );

  Widget _submitKey({int flex = 1}) => _KeypadKey(
    key: const Key('keypad-submit-button'),
    label: '✓',
    flex: flex,
    tone: _KeyTone.primary,
    onTap: widget.onSubmit!,
  );

  Widget _backspaceKey({int flex = 1}) => _KeypadKey(
    key: const Key('keypad-backspace-button'),
    label: '⌫',
    flex: flex,
    tone: _KeyTone.function,
    onTap: widget.onBackspace,
  );
}

enum _KeyTone { normal, function, primary }

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
    this.tone = _KeyTone.normal,
    this.fontSize = 17,
  });

  final String label;
  final VoidCallback onTap;
  final int flex;
  final _KeyTone tone;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color background = switch (tone) {
      _KeyTone.normal => colors.surfaceContainerHighest,
      _KeyTone.function => colors.secondaryContainer,
      _KeyTone.primary => colors.primary,
    };
    final Color foreground = switch (tone) {
      _KeyTone.normal => colors.onSurface,
      _KeyTone.function => colors.onSecondaryContainer,
      _KeyTone.primary => colors.onPrimary,
    };
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          color: background,
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
                    color: foreground,
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
