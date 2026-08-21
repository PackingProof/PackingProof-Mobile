part of 'recordings_screen.dart';

class _OrderReceiverSettings extends StatelessWidget {
  const _OrderReceiverSettings({
    required this.snapshot,
    this.onRetry,
    this.speechEnabled,
    this.speechMasterEnabled = true,
    this.onSpeechChanged,
  });

  final OrderInfoReceiverSnapshot snapshot;
  final Future<void> Function()? onRetry;
  final bool? speechEnabled;
  final bool speechMasterEnabled;
  final ValueChanged<bool>? onSpeechChanged;

  bool get _hasSpeech => speechEnabled != null && onSpeechChanged != null;

  @override
  Widget build(BuildContext context) {
    final bool ready = snapshot.running && snapshot.url.isNotEmpty;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      key: const Key('order-receiver-settings'),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_hasSpeech) ...<Widget>[
            _OrderSpeechSettings(
              enabled: speechEnabled!,
              masterEnabled: speechMasterEnabled,
              onChanged: onSpeechChanged!,
            ),
            Divider(height: 1, thickness: 1, color: colors.outlineVariant),
          ],
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        '订单接收',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: ready
                            ? colors.secondaryContainer
                            : colors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        ready ? '接收中' : '未启动',
                        style: TextStyle(
                          color: ready
                              ? colors.primary
                              : colors.onSurfaceVariant,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  ready
                      ? snapshot.url
                      : snapshot.errorMessage.isEmpty
                      ? '请连接局域网 Wi-Fi 后重试'
                      : snapshot.errorMessage,
                  key: const Key('order-receiver-address'),
                  style: TextStyle(
                    color: ready ? colors.primary : colors.onSurfaceVariant,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '在油猴脚本中将监控地址设为以上地址',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: ready
                            ? () async {
                                await Clipboard.setData(
                                  ClipboardData(text: snapshot.url),
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('接收地址已复制')),
                                );
                              }
                            : null,
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('复制地址'),
                      ),
                    ),
                    if (!ready && onRetry != null) ...<Widget>[
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('重试'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
