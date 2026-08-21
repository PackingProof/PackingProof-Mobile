part of 'recordings_screen.dart';

class _HistorySummary extends StatelessWidget {
  const _HistorySummary({
    required this.total,
    required this.today,
    required this.totalBytes,
  });

  final int total;
  final int today;
  final int totalBytes;

  @override
  Widget build(BuildContext context) {
    final ({String value, String unit}) totalSize = _formatStorageSize(
      totalBytes,
    );
    return Row(
      children: <Widget>[
        _SummaryMetric(label: '本机今日', value: '$today'),
        const SizedBox(width: 10),
        _SummaryMetric(label: '本机全部', value: '$total'),
        const SizedBox(width: 10),
        _SummaryMetric(
          label: '总占用',
          value: totalSize.value,
          unit: totalSize.unit,
        ),
      ],
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({required this.label, required this.value, this.unit});

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          children: <Widget>[
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: value,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  if (unit != null)
                    TextSpan(
                      text: ' $unit',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
            ),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: colors.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _EmptyRecordings extends StatelessWidget {
  const _EmptyRecordings();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: colors.secondaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.video_library_outlined,
                size: 34,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '还没有录像',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 7),
            Text(
              '返回首页点“开始工作”，录像会自动保存在这里',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoSearchResults extends StatelessWidget {
  const _NoSearchResults();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.search_off_rounded,
            size: 42,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          const Text(
            '没有找到匹配的录像',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _RecordingThumbnail extends StatelessWidget {
  const _RecordingThumbnail({
    this.localPath,
    this.remoteUri,
    required this.remoteHeaders,
    required this.unavailable,
  });

  final Future<String?>? localPath;
  final Uri? remoteUri;
  final Map<String, String> remoteHeaders;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    Widget placeholder() => Container(
      key: const Key('recording-thumbnail'),
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(
        unavailable ? Icons.videocam_off_rounded : Icons.play_arrow_rounded,
        color: unavailable ? colors.onSurfaceVariant : colors.primary,
      ),
    );

    Widget image(String path, {bool network = false}) => ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: SizedBox(
        key: const Key('recording-thumbnail'),
        width: 56,
        height: 56,
        child: network
            ? Image.network(
                path,
                headers: remoteHeaders,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder(),
              )
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder(),
              ),
      ),
    );

    if (unavailable) return placeholder();
    if (localPath != null) {
      return FutureBuilder<String?>(
        future: localPath,
        builder: (_, snapshot) => snapshot.data?.isNotEmpty == true
            ? image(snapshot.data!)
            : placeholder(),
      );
    }
    if (remoteUri != null) return image(remoteUri.toString(), network: true);
    return placeholder();
  }
}

class _RecordingTile extends StatelessWidget {
  const _RecordingTile({
    required this.session,
    required this.managing,
    required this.selected,
    required this.onTap,
    required this.sourceLabel,
    required this.sourceIdentity,
    required this.localRecording,
    required this.backedUp,
    required this.remoteHeaders,
    this.unavailable = false,
    this.backupJob,
    this.localThumbnail,
    this.remoteThumbnail,
    this.onLongPress,
    this.hideSourceChip = false,
    this.sourceChipOnSecondaryRow = false,
  });

  final RecordingSession session;
  final bool managing;
  final bool selected;
  final VoidCallback onTap;
  final LanBackupJob? backupJob;
  final String sourceLabel;
  final String sourceIdentity;
  final bool localRecording;
  final bool unavailable;
  final bool backedUp;
  final VoidCallback? onLongPress;
  final bool hideSourceChip;
  final bool sourceChipOnSecondaryRow;
  final Future<String?>? localThumbnail;
  final Uri? remoteThumbnail;
  final Map<String, String> remoteHeaders;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Opacity(
      opacity: unavailable ? 0.52 : 1,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (managing) ...<Widget>[
            Checkbox(
              value: selected,
              onChanged: (_) => onTap(),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Material(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: <Widget>[
                          _RecordingThumbnail(
                            localPath: localThumbnail,
                            remoteUri: remoteThumbnail,
                            remoteHeaders: remoteHeaders,
                            unavailable: unavailable,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: LayoutBuilder(
                                        builder:
                                            (
                                              BuildContext context,
                                              BoxConstraints constraints,
                                            ) {
                                              const TextStyle codeStyle =
                                                  TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w800,
                                                  );
                                              return Text(
                                                fitTrackingNumber(
                                                  session.displayCode,
                                                  constraints.maxWidth,
                                                  codeStyle,
                                                  textScaler:
                                                      MediaQuery.textScalerOf(
                                                        context,
                                                      ),
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.clip,
                                                style: codeStyle,
                                              );
                                            },
                                      ),
                                    ),
                                    if (!hideSourceChip &&
                                        !sourceChipOnSecondaryRow) ...[
                                      const SizedBox(width: 8),
                                      _StatusChip(
                                        key: const Key('recording-source-chip'),
                                        label: sourceLabel,
                                        tone: sourceLabel == '电脑'
                                            ? _StatusChipTone.computer
                                            : _StatusChipTone.recordingDevice,
                                        identity: sourceIdentity,
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 7),
                                Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: Text(
                                        key: const Key(
                                          'recording-date-duration',
                                        ),
                                        '${_dateTime(session.startedAt)}  ·  ${_duration(session.duration)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: colors.onSurfaceVariant,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    if (!hideSourceChip &&
                                        sourceChipOnSecondaryRow) ...[
                                      const SizedBox(width: 8),
                                      _StatusChip(
                                        key: const Key('recording-source-chip'),
                                        label: sourceLabel,
                                        tone: sourceLabel == '电脑'
                                            ? _StatusChipTone.computer
                                            : _StatusChipTone.recordingDevice,
                                        identity: sourceIdentity,
                                      ),
                                    ],
                                    if (backedUp) ...<Widget>[
                                      const SizedBox(width: 8),
                                      const _StatusChip(
                                        key: Key('recording-backed-up-chip'),
                                        label: '已备份',
                                        tone: _StatusChipTone.backupCompleted,
                                      ),
                                    ] else if (backupJob != null &&
                                        backupJob!.state !=
                                            LanBackupJobState.completed) ...[
                                      const SizedBox(width: 8),
                                      _StatusChip(
                                        label: _backupLabel(backupJob!),
                                        tone: _backupTone(backupJob!),
                                      ),
                                    ] else if (localRecording) ...<Widget>[
                                      const SizedBox(width: 8),
                                      const _StatusChip(
                                        label: '未备份',
                                        tone: _StatusChipTone.backupPending,
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (!managing)
                            Icon(
                              Icons.chevron_right_rounded,
                              color: colors.onSurfaceVariant,
                            ),
                        ],
                      ),
                    ),
                    Positioned(
                      key: const Key('recording-operation-mode-strip'),
                      left: 0,
                      top: 12,
                      bottom: 12,
                      width: 4,
                      child: Semantics(
                        label: '${session.operationMode.label}录像',
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color:
                                session.operationMode ==
                                    RecordingOperationMode.returnGoods
                                ? const Color(0xFFFF9800)
                                : colors.primary,
                            borderRadius: const BorderRadius.horizontal(
                              right: Radius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryPagination extends StatelessWidget {
  const _HistoryPagination({
    required this.currentPage,
    required this.pageCount,
    required this.loading,
    required this.offline,
    required this.canLoadMore,
    required this.onPrevious,
    required this.onNext,
    required this.pageSize,
    required this.onPageSizeChanged,
  });

  final int currentPage;
  final int pageCount;
  final bool loading;
  final bool offline;
  final bool canLoadMore;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final int pageSize;
  final ValueChanged<int> onPageSizeChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int shownPageCount = pageCount == 0 ? 1 : pageCount;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              IconButton.outlined(
                key: const Key('recording-page-previous'),
                tooltip: '上一页',
                onPressed: loading ? null : onPrevious,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              SizedBox(
                width: 104,
                child: Text(
                  offline ? '电脑离线' : '${currentPage + 1} / $shownPageCount 页',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton.outlined(
                key: const Key('recording-page-next'),
                tooltip: offline
                    ? '电脑离线'
                    : canLoadMore && currentPage + 1 >= pageCount
                    ? '加载下一页'
                    : '下一页',
                onPressed: loading ? null : onNext,
                icon: loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Text('每页显示', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              Container(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: DropdownButton<int>(
                  key: const Key('recording-page-size-selector'),
                  value: pageSize,
                  underline: const SizedBox.shrink(),
                  dropdownColor: colors.surfaceContainerHigh,
                  iconEnabledColor: colors.onSurfaceVariant,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
                  items: const <DropdownMenuItem<int>>[
                    DropdownMenuItem<int>(value: 5, child: Text('5')),
                    DropdownMenuItem<int>(value: 10, child: Text('10')),
                    DropdownMenuItem<int>(value: 20, child: Text('20')),
                  ],
                  onChanged: (int? value) {
                    if (value != null) onPageSizeChanged(value);
                  },
                ),
              ),
              const SizedBox(width: 4),
              const Text('条', style: TextStyle(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

enum _StatusChipTone {
  neutral,
  recordingDevice,
  computer,
  backupCompleted,
  backupPending,
  backupPaused,
  backupUploading,
  error,
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    this.tone = _StatusChipTone.neutral,
    this.identity = '',
    super.key,
  });

  final String label;
  final _StatusChipTone tone;
  final String identity;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final (Color background, Color foreground) = switch (tone) {
      _StatusChipTone.recordingDevice => _recordingDeviceChipColors(
        identity,
        colors.brightness,
      ),
      _StatusChipTone.computer => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      _StatusChipTone.backupCompleted => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      _StatusChipTone.backupPending => (
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
      _StatusChipTone.backupPaused =>
        colors.brightness == Brightness.dark
            ? (const Color(0xFF4A2D0A), const Color(0xFFFFB86C))
            : (const Color(0xFFFFE8CF), const Color(0xFFA35A16)),
      _StatusChipTone.backupUploading => (
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      _StatusChipTone.error => (colors.errorContainer, colors.onErrorContainer),
      _StatusChipTone.neutral => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
    };
    return DecoratedBox(
      key: ValueKey<String>('recording-source-chip-color-$identity'),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: TextStyle(
            color: foreground,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

(Color, Color) _recordingDeviceChipColors(
  String identity,
  Brightness brightness,
) {
  int hash = 0x811C9DC5;
  for (final int unit in identity.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  hash ^= hash >> 16;
  final double hue = (hash % 360).toDouble();
  if (brightness == Brightness.dark) {
    return (
      HSLColor.fromAHSL(1, hue, 0.48, 0.24).toColor(),
      HSLColor.fromAHSL(1, hue, 0.72, 0.78).toColor(),
    );
  }
  return (
    HSLColor.fromAHSL(1, hue, 0.58, 0.91).toColor(),
    HSLColor.fromAHSL(1, hue, 0.68, 0.30).toColor(),
  );
}

String _backupLabel(LanBackupJob job) => switch (job.state) {
  LanBackupJobState.pending => '未备份',
  LanBackupJobState.uploading => '备份中 ${(job.progress * 100).round()}%',
  LanBackupJobState.paused => '等待续传',
  LanBackupJobState.completed => '已备份',
  LanBackupJobState.failed => '备份失败',
};

_StatusChipTone _backupTone(LanBackupJob job) => switch (job.state) {
  LanBackupJobState.pending => _StatusChipTone.backupPending,
  LanBackupJobState.uploading => _StatusChipTone.backupUploading,
  LanBackupJobState.paused => _StatusChipTone.backupPaused,
  LanBackupJobState.completed => _StatusChipTone.backupCompleted,
  LanBackupJobState.failed => _StatusChipTone.error,
};

String _dateTime(DateTime value) {
  return '${value.month}月${value.day}日 ${_two(value.hour)}:${_two(value.minute)}';
}

String _duration(Duration value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.inMinutes)}:${two(value.inSeconds.remainder(60))}';
}

({String value, String unit}) _formatStorageSize(int bytes) {
  const int mebibyte = 1024 * 1024;
  const int gibibyte = 1024 * mebibyte;
  if (bytes <= 0) return (value: '0', unit: 'MB');
  if (bytes < mebibyte) return (value: '<1', unit: 'MB');
  if (bytes < gibibyte) {
    final double value = bytes / mebibyte;
    return (value: value.toStringAsFixed(value < 10 ? 1 : 0), unit: 'MB');
  }
  final double value = bytes / gibibyte;
  return (value: value.toStringAsFixed(value < 10 ? 1 : 0), unit: 'GB');
}

String _two(int number) => number.toString().padLeft(2, '0');

bool _isToday(DateTime value) {
  final DateTime now = DateTime.now();
  return value.year == now.year &&
      value.month == now.month &&
      value.day == now.day;
}
