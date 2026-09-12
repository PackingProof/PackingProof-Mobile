import 'package:flutter/material.dart';

class TwoButtonConfirmDialog extends StatelessWidget {
  const TwoButtonConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.cancelLabel = '取消',
    this.dangerous = false,
    super.key,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool dangerous;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    const ButtonStyle sharedButtonStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size.fromHeight(48)),
      padding: WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.zero),
      textStyle: WidgetStatePropertyAll<TextStyle>(
        TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
    );
    return AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: SingleChildScrollView(child: Text(message)),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      actions: <Widget>[
        Row(
          key: const Key('confirm-dialog-button-row'),
          children: <Widget>[
            Expanded(
              child: FilledButton(
                key: const Key('confirm-dialog-cancel'),
                style: sharedButtonStyle.copyWith(
                  backgroundColor: WidgetStatePropertyAll<Color?>(
                    colors.surfaceContainerHigh,
                  ),
                  foregroundColor: WidgetStatePropertyAll<Color?>(
                    colors.onSurface,
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(cancelLabel),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                key: const Key('confirm-dialog-confirm'),
                style: sharedButtonStyle.copyWith(
                  backgroundColor: WidgetStatePropertyAll<Color?>(
                    dangerous ? colors.error : colors.primary,
                  ),
                  foregroundColor: WidgetStatePropertyAll<Color?>(
                    dangerous ? colors.onError : colors.onPrimary,
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(confirmLabel),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
