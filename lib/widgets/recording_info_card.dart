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
    this.summary = const <String>[],
    this.tags = const <String>[],
    this.source,
    this.backupLabel,
    this.backupHighlighted = false,
    this.onBackupTap,
    this.backupUploading = false,
    this.backupProgress,
    this.trailing,
    super.key,
  });

  /// 面单号；未识别时显示占位文案。
  final String code;

  /// 面单号是否可复制（未识别时没有可复制的内容）。
  final bool codeCopyable;

  /// 录像时间（已是格式化后的文案）。
  final String recordedAt;

  /// 与录像时间同一行的读数，例如 `00:45`、`12.3 MB`：都属于"这段录像多大多久"。
  final List<String> summary;

  /// 归类性质的短标签，例如 `发货`、`1080p`、`H.265`。
  final List<String> tags;

  /// 来源，例如「手机」「仓库电脑」。
  final String? source;

  /// 备份状态，例如「已备份到电脑」。
  final String? backupLabel;

  /// 备份状态是否需要一眼看到（未备份时用警示色）。
  final bool backupHighlighted;

  /// 点按备份状态行的动作，例如手动上传这条录像；为空时状态行不可点。
  final VoidCallback? onBackupTap;

  /// 是否正在上传：为 true 时备份状态行显示进度条（进度未知就是滚动加载），
  /// 不再显示点按入口。
  final bool backupUploading;

  /// 上传进度（0..1）；为空表示进度还未知，按不确定状态滚动显示。
  final double? backupProgress;

  /// 卡片底部补充入口，例如订单信息。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String trimmedSource = source?.trim() ?? '';
    final List<String> readings = <String>[
      '$recordedAt 录制',
      ...summary.where((String value) => value.trim().isNotEmpty),
    ];
    final List<String> visibleTags = tags
        .where((String value) => value.trim().isNotEmpty)
        .toList(growable: false);
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
            // 录像时间、时长、大小都是"读数"，排在同一行；归类性质的标签
            // 另起一行，避免一行里混着两种不同性质的短标签。
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final String reading in readings)
                  Text(
                    reading,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            if (visibleTags.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  for (final String tag in visibleTags)
                    _MetadataChip(text: tag),
                ],
              ),
            ],
            if (backupLabel != null && backupLabel!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              _BackupStatus(
                label: backupLabel!,
                highlighted: backupHighlighted,
                onTap: onBackupTap,
                uploading: backupUploading,
                progress: backupProgress,
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
  const _BackupStatus({
    required this.label,
    required this.highlighted,
    this.onTap,
    this.uploading = false,
    this.progress,
  });

  final String label;
  final bool highlighted;
  final VoidCallback? onTap;

  /// 上传中：这一行显示进度条，不再显示点按入口。
  final bool uploading;

  /// 上传进度（0..1）；为空时进度条按不确定状态滚动显示。
  final double? progress;

  /// 行高固定：未备份（带点按入口）、上传中（进度条）、已备份三种状态高度一致，
  /// 状态变化时卡片不会跳动。
  static const double _rowHeight = 30;
  static const double _progressBarWidth = 64;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color tone = highlighted ? colors.error : colors.primary;
    final Widget status = SizedBox(
      height: _rowHeight,
      child: Row(
        children: <Widget>[
          Icon(
            highlighted ? Icons.cloud_off_rounded : Icons.cloud_done_rounded,
            size: 16,
            color: tone,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tone,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Spacer(),
          if (uploading) ...<Widget>[
            SizedBox(
              width: _progressBarWidth,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  key: const Key('playback-backup-progress'),
                  value: progress,
                  minHeight: 4,
                  backgroundColor: colors.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
            ),
            if (progress case final double value) ...<Widget>[
              const SizedBox(width: 6),
              Text(
                '${(value * 100).round()}%',
                style: TextStyle(
                  color: colors.primary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ] else if (onTap != null) ...<Widget>[
            Text(
              '点按上传',
              style: TextStyle(
                color: colors.primary,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 16, color: colors.primary),
          ],
        ],
      ),
    );
    if (onTap == null) return status;
    return InkWell(
      key: const Key('playback-backup-upload'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: status,
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
