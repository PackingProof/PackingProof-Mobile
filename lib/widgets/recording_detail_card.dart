import 'package:flutter/material.dart';

/// 一条录像事实：标签与取值。
class RecordingDetail {
  const RecordingDetail(this.label, this.value, {this.emphasized = false});

  final String label;
  final String value;

  /// 取值使用正文强调色，用于备份状态这类需要一眼看到的行。
  final bool emphasized;
}

/// 录像详情卡片：来源、时间、时长、大小、备份状态等项目。
///
/// 播放页此前只显示视频与按钮，页面显得空；把录像事实集中在这里展示。
class RecordingDetailCard extends StatelessWidget {
  const RecordingDetailCard({required this.details, this.trailing, super.key});

  final List<RecordingDetail> details;

  /// 卡片底部的补充入口，例如订单信息。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    if (details.isEmpty && trailing == null) {
      return const SizedBox.shrink();
    }
    final ColorScheme colors = Theme.of(context).colorScheme;
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
            for (final RecordingDetail detail in details) ...<Widget>[
              _RecordingDetailRow(
                label: detail.label,
                value: detail.value,
                emphasized: detail.emphasized,
              ),
              if (detail != details.last) const SizedBox(height: 10),
            ],
            if (trailing != null) ...<Widget>[
              if (details.isNotEmpty) const SizedBox(height: 12),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _RecordingDetailRow extends StatelessWidget {
  const _RecordingDetailRow({
    required this.label,
    required this.value,
    required this.emphasized,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 60,
          child: Text(
            label,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: emphasized ? colors.primary : colors.onSurface,
              fontSize: 14,
              fontWeight: emphasized ? FontWeight.w800 : FontWeight.w600,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// 录像时间：`9月13日 19:19`，跨年时补上年份。
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
