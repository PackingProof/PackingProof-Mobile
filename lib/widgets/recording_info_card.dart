import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 录像信息卡片。
///
/// 排版原则：能用位置和形态表达的信息就不再写标注——面单号用大号等宽字放在
/// 顶部，录像时间自带「录制」字样，时长 / 大小 / 来源用一行小标签并列，
/// 备份状态单独一行。
class RecordingInfoCard extends StatelessWidget {
  const RecordingInfoCard({
    required this.code,
    required this.codeCopyable,
    required this.recordedAt,
    required this.metadata,
    this.source,
    this.backupLabel,
    this.backupHighlighted = false,
    this.trailing,
    super.key,
  });

  /// 面单号；未识别时显示占位文案。
  final String code;

  /// 面单号是否可复制（未识别时没有可复制的内容）。
  final bool codeCopyable;

  /// 录像时间（已是格式化后的文案）。
  final String recordedAt;

  /// 与时长、大小并列的短标签，例如 `00:45`、`12.3 MB`。
  final List<String> metadata;

  /// 来源，例如「手机」「仓库电脑」。
  final String? source;

  /// 备份状态，例如「已备份到电脑」。
  final String? backupLabel;

  /// 备份状态是否需要一眼看到（未备份时用警示色）。
  final bool backupHighlighted;

  /// 卡片底部补充入口，例如订单信息。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String trimmedSource = source?.trim() ?? '';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: codeCopyable
                      ? _CopyableCode(code: code)
                      : Text(
                          code,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
                if (trimmedSource.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 10),
                  _SourceBadge(source: trimmedSource),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '$recordedAt 录制',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (metadata.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  for (final String item in metadata) _MetadataChip(text: item),
                ],
              ),
            ],
            if (backupLabel != null && backupLabel!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              _BackupStatus(
                label: backupLabel!,
                highlighted: backupHighlighted,
              ),
            ],
            if (trailing != null) ...<Widget>[
              const SizedBox(height: 10),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 面单号：点按复制，右侧给出复制提示。
class _CopyableCode extends StatelessWidget {
  const _CopyableCode({required this.code});

  final String code;

  Future<void> _copy(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: code));
    messenger.showSnackBar(const SnackBar(content: Text('面单号已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return InkWell(
      key: const Key('playback-copy-code'),
      onTap: () => _copy(context),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: <Widget>[
            Flexible(
              child: Text(
                code,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurface,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.copy_rounded, size: 15, color: colors.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          source,
          style: TextStyle(
            color: colors.onPrimaryContainer,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _MetadataChip extends StatelessWidget {
  const _MetadataChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(
          text,
          style: TextStyle(
            color: colors.onSurfaceVariant,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _BackupStatus extends StatelessWidget {
  const _BackupStatus({required this.label, required this.highlighted});

  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color tone = highlighted ? colors.error : colors.primary;
    return Row(
      children: <Widget>[
        Icon(
          highlighted ? Icons.cloud_off_rounded : Icons.cloud_done_rounded,
          size: 16,
          color: tone,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: tone,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// 录像分辨率文案：按视频实际短边归类（4K 取 2160 档）。
String formatRecordingResolution(Size? videoSize) {
  if (videoSize == null) return '';
  final double width = videoSize.width;
  final double height = videoSize.height;
  if (width <= 0 || height <= 0) return '';
  final double shorterSide = width < height ? width : height;
  if (shorterSide >= 2160) return '4K';
  if (shorterSide >= 1080) return '1080p';
  if (shorterSide >= 720) return '720p';
  if (shorterSide >= 480) return '480p';
  return '${shorterSide.round()}p';
}

/// 编码文案：h265 显示 H.265，其余按 h264 显示 H.264。
String formatRecordingCodec(String codec) {
  final String normalized = codec.trim().toLowerCase();
  if (normalized.contains('hevc') || normalized.contains('h265')) {
    return 'H.265';
  }
  if (normalized.contains('avc') || normalized.contains('h264')) {
    return 'H.264';
  }
  return '';
}

/// 录像时间：同一年只显示月日与时分，跨年补上年份。
String formatRecordingTime(DateTime value, {DateTime? now}) {
  final DateTime reference = now ?? DateTime.now();
  final String clock = '${_two(value.hour)}:${_two(value.minute)}';
  if (value.year == reference.year) {
    return '${value.month}月${value.day}日 $clock';
  }
  return '${value.year}年${value.month}月${value.day}日 $clock';
}

/// 录像时长：不足一小时用 `分:秒`，超过则补小时。
String formatRecordingDuration(Duration value) {
  final int totalSeconds = value.inSeconds < 0 ? 0 : value.inSeconds;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = totalSeconds.remainder(3600) ~/ 60;
  final int seconds = totalSeconds.remainder(60);
  if (hours > 0) {
    return '$hours:${_two(minutes)}:${_two(seconds)}';
  }
  return '${_two(minutes)}:${_two(seconds)}';
}

/// 文件大小：不足 1 MB 显示 KB，超过 1 GB 显示 GB。
String formatRecordingSize(int bytes) {
  const int kilobyte = 1024;
  const int mebibyte = 1024 * kilobyte;
  const int gibibyte = 1024 * mebibyte;
  if (bytes <= 0) return '未知';
  if (bytes < kilobyte) return '$bytes B';
  if (bytes < mebibyte) {
    return '${(bytes / kilobyte).toStringAsFixed(0)} KB';
  }
  if (bytes < gibibyte) {
    final double value = bytes / mebibyte;
    return '${value.toStringAsFixed(value < 10 ? 1 : 0)} MB';
  }
  final double value = bytes / gibibyte;
  return '${value.toStringAsFixed(value < 10 ? 2 : 1)} GB';
}

String _two(int value) => value.toString().padLeft(2, '0');
