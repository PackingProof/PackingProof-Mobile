part of 'recordings_screen.dart';

mixin _RecordingsHistoryManagement on _RecordingsHistoryDataCoordinator {
  final Set<String> _selectedIds = <String>{};
  final Set<String> _selectedLocalIds = <String>{};
  final Map<String, String> _selectedTrackingNumbers = <String, String>{};
  bool _managing = false;
  bool _sharingSelection = false;

  List<RecordingHistoryItem> get _visibleItems;

  void _enterManaging({RecordingSession? keepVisible}) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _managing = true;
      _selectedIds.clear();
      _selectedLocalIds.clear();
      _selectedTrackingNumbers.clear();
      if (keepVisible != null) {
        final int index = _visibleItems.indexWhere(
          (item) => item.session.id == keepVisible.id,
        );
        if (index >= 0) {
          final int firstLoadedPage = _localPages.isEmpty
              ? 0
              : _localPages.keys.reduce((int a, int b) => a < b ? a : b) - 1;
          _historyPage = firstLoadedPage + index ~/ _historyPageSize;
        }
      }
    });
    widget.onManagingChanged?.call(true);
  }

  void _exitManaging() {
    setState(() {
      _managing = false;
      _selectedIds.clear();
      _selectedLocalIds.clear();
      _selectedTrackingNumbers.clear();
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
      if (_selectedIds.add(id)) {
        RecordingHistoryItem? selected;
        for (final RecordingHistoryItem item in _visibleItems) {
          if (item.session.id == id) {
            selected = item;
            break;
          }
        }
        if (selected != null) {
          _selectedTrackingNumbers[id] = selected.session.displayCode;
        }
        if (_sessions.any((RecordingSession session) => session.id == id)) {
          _selectedLocalIds.add(id);
        }
      } else {
        _selectedIds.remove(id);
        _selectedLocalIds.remove(id);
        _selectedTrackingNumbers.remove(id);
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
        _selectedLocalIds.removeAll(pageIds);
        for (final String id in pageIds) {
          _selectedTrackingNumbers.remove(id);
        }
      } else {
        _selectedIds.addAll(pageIds);
        for (final RecordingSession session in currentPageSessions) {
          _selectedTrackingNumbers[session.id] = session.displayCode;
          if (_sessions.any(
            (RecordingSession local) => local.id == session.id,
          )) {
            _selectedLocalIds.add(session.id);
          }
        }
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) {
      return;
    }
    final Set<String> localIds = Set<String>.of(_selectedLocalIds);
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
      _selectedLocalIds.clear();
      _selectedTrackingNumbers.clear();
      _managing = false;
    });
    widget.onManagingChanged?.call(false);
  }

  Future<void> _copySelectedTrackingNumbers() async {
    if (_selectedIds.isEmpty) return;
    final List<String> codes = <String>[];
    final Set<String> seen = <String>{};
    int duplicateRows = 0;
    for (final String id in _selectedIds) {
      final String code = _selectedTrackingNumbers[id] ?? '';
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

  /// 批量分享/保存所选录像：电脑上、本机缺失的文件跳过并在结果里说明。
  Future<void> _shareSelected() async {
    if (_selectedIds.isEmpty || _sharingSelection) return;
    final List<RecordingSession> sessions = _sessions
        .where(
          (RecordingSession session) => _selectedLocalIds.contains(session.id),
        )
        .toList(growable: false);
    if (sessions.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('电脑上的录像不在本机，无法分享或保存')));
      return;
    }
    final bool canSaveToGallery = AppContainer.forCurrentPlatform().capabilities
        .supports(PlatformCapability.saveVideoToGallery);
    final ShareOption? option = await showShareOptionsSheet(
      context,
      canSaveToGallery: canSaveToGallery,
    );
    if (option == null || !mounted) return;
    final bool saveToGallery = option == ShareOption.gallery;
    setState(() {
      _sharingSelection = true;
    });
    try {
      final VideoShareService shareService = VideoShareService();
      final List<File> files = <File>[];
      int prepareFailed = 0;
      for (final RecordingSession session in sessions) {
        try {
          final File source = File(session.filePath);
          if (!await source.exists()) {
            prepareFailed++;
            continue;
          }
          files.add(
            await shareService.prepareForSharing(
              source,
              fileName: shareFileName(session),
            ),
          );
        } on Object {
          prepareFailed++;
        }
      }
      if (!mounted) return;
      final String skippedNote = _shareSkipNote(
        skippedRemote: _selectedIds.length - sessions.length,
        failed: prepareFailed,
      );
      if (files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(skippedNote.isEmpty ? '没有可分享的录像' : skippedNote),
          ),
        );
        return;
      }
      if (saveToGallery) {
        final SystemMediaPresenter presenter =
            AppContainer.forCurrentPlatform().systemMediaPresenter;
        int saved = 0;
        int saveFailed = 0;
        for (final File file in files) {
          try {
            await presenter.saveVideoToGallery(file.path);
            saved++;
          } on Object {
            saveFailed++;
          }
        }
        if (!mounted) return;
        final String note = _shareSkipNote(
          skippedRemote: _selectedIds.length - sessions.length,
          failed: saveFailed,
          failedLabel: '保存失败',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saved == 0
                  ? (note.isEmpty ? '保存到相册失败' : note)
                  : '已保存 $saved 段录像到相册${note.isEmpty ? '' : '（$note）'}',
            ),
          ),
        );
        return;
      }
      if (skippedNote.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(skippedNote)));
      }
      await SharePlus.instance.share(
        ShareParams(
          title: files.length == 1 ? '分享录像' : '分享 ${files.length} 段录像',
          files: files
              .map((File file) => XFile(file.path, mimeType: 'video/mp4'))
              .toList(growable: false),
        ),
      );
    } on Object catch (error) {
      unawaited(
        DiagnosticsLogService().log(
          kind: saveToGallery ? 'gallery_save_failed' : 'share_failed',
          extra: <String, Object?>{
            'source': 'manage',
            'count': sessions.length,
            'error': error.toString(),
          },
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${saveToGallery ? '保存' : '分享'}失败，请稍后重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _sharingSelection = false;
        });
      }
    }
  }

  String _shareSkipNote({
    required int skippedRemote,
    required int failed,
    String failedLabel = '准备失败',
  }) {
    return <String>[
      if (skippedRemote > 0) '跳过电脑上的 $skippedRemote 条',
      if (failed > 0) '$failed 段$failedLabel',
    ].join('，');
  }
}
