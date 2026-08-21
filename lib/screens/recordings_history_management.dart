part of 'recordings_screen.dart';

mixin _RecordingsHistoryManagement on _RecordingsHistoryDataCoordinator {
  final Set<String> _selectedIds = <String>{};
  bool _managing = false;

  List<RecordingHistoryItem> get _visibleItems;

  void _enterManaging({RecordingSession? keepVisible}) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _managing = true;
      _selectedIds.clear();
      if (keepVisible != null) {
        final int index = _visibleItems.indexWhere(
          (item) => item.session.id == keepVisible.id,
        );
        if (index >= 0) {
          _historyPage = index ~/ _historyPageSize;
        }
      }
    });
    widget.onManagingChanged?.call(true);
  }

  void _exitManaging() {
    setState(() {
      _managing = false;
      _selectedIds.clear();
    });
    widget.onManagingChanged?.call(false);
  }

  void _toggleManaging() {
    if (_managing) {
      _exitManaging();
    } else {
      _enterManaging();
    }
  }

  void _handleRecordingLongPress(
    RecordingHistoryItem item,
    RecordingSession session,
  ) {
    if (!_managing) {
      _enterManaging(keepVisible: session);
    }
    _toggleSelection(session.id);
  }

  void _toggleSelection(String id) {
    setState(() {
      if (!_selectedIds.add(id)) {
        _selectedIds.remove(id);
      }
    });
  }

  void _toggleSelectAllCurrentPage(List<RecordingSession> currentPageSessions) {
    final Set<String> pageIds = currentPageSessions
        .map((RecordingSession item) => item.id)
        .toSet();
    setState(() {
      if (_selectedIds.containsAll(pageIds) && pageIds.isNotEmpty) {
        _selectedIds.removeAll(pageIds);
      } else {
        _selectedIds.addAll(pageIds);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) {
      return;
    }
    final Set<String> localIds = _selectedIds
        .where(
          (String id) =>
              _sessions.any((RecordingSession session) => session.id == id),
        )
        .toSet();
    if (localIds.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('电脑录像仅支持复制单号，无法删除')));
      return;
    }
    final bool mixedSelection = localIds.length < _selectedIds.length;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => TwoButtonConfirmDialog(
        title: '删除 ${localIds.length} 段录像？',
        message: mixedSelection
            ? '仅删除本机录像，电脑录像不会删除'
            : '应用会按保留策略自动清理录像，一般无需手动删除。删除后无法恢复',
        confirmLabel: '仍要删除',
        dangerous: true,
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final Set<String> ids = localIds;
    try {
      await widget.onDeleteSessions(ids);
    } on Object {
      // broad-catch: 删除适配器错误类型不统一，统一保留列表并提示重试。
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('删除失败，请稍后重试')));
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _sessions.removeWhere((RecordingSession item) => ids.contains(item.id));
      _refreshLocalRecordingStats();
      _selectedIds.clear();
      _managing = false;
    });
    widget.onManagingChanged?.call(false);
  }

  Future<void> _copySelectedTrackingNumbers() async {
    if (_selectedIds.isEmpty) return;
    final List<String> codes = <String>[];
    final Set<String> seen = <String>{};
    int duplicateRows = 0;
    for (final RecordingHistoryItem item in _visibleItems) {
      if (!_selectedIds.contains(item.session.id)) continue;
      final String code = item.session.displayCode;
      if (code.isEmpty || code == RecordingSession.unrecognizedLabel) continue;
      if (!seen.add(code)) {
        duplicateRows++;
        continue;
      }
      codes.add(code);
    }
    if (codes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('所选记录没有可复制的单号')));
      return;
    }
    await Clipboard.setData(ClipboardData(text: codes.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          duplicateRows > 0
              ? '已复制 ${codes.length} 个唯一单号（重复 $duplicateRows 行）'
              : '已复制 ${codes.length} 个单号',
        ),
      ),
    );
  }
}
