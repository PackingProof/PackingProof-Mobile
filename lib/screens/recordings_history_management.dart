part of 'recordings_screen.dart';

mixin _RecordingsHistoryManagement on _RecordingsHistoryDataCoordinator {
  final Set<String> _selectedIds = <String>{};
  final Set<String> _selectedLocalIds = <String>{};
  /// 勾选时就把录像来源记下来：翻页会回收更旧的页，靠 id 再去列表里
  /// 反查可能已经查不到，分享/删除都依赖这份快照。
  final Map<String, RecordingHistoryItem> _selectedItems =
      <String, RecordingHistoryItem>{};
  bool _managing = false;
  bool _sharingSelection = false;
  String? _shareProgressLabel;

  List<RecordingHistoryItem> get _visibleItems;

  void _enterManaging({RecordingSession? keepVisible}) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _managing = true;
      _selectedIds.clear();
      _selectedLocalIds.clear();
      _selectedItems.clear();
      _shareProgressLabel = null;
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
      _selectedItems.clear();
      _shareProgressLabel = null;
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
          _selectedItems[id] = selected;
        }
        if (_sessions.any((RecordingSession session) => session.id == id)) {
          _selectedLocalIds.add(id);
        }
      } else {
        _selectedIds.remove(id);
        _selectedLocalIds.remove(id);
        _selectedItems.remove(id);
      }
    });
  }

  void _toggleSelectAllCurrentPage(List<RecordingHistoryItem> currentPageItems) {
    final Set<String> pageIds = currentPageItems
        .map((RecordingHistoryItem item) => item.session.id)
        .toSet();
    setState(() {
      if (_selectedIds.containsAll(pageIds) && pageIds.isNotEmpty) {
        _selectedIds.removeAll(pageIds);
        _selectedLocalIds.removeAll(pageIds);
        for (final String id in pageIds) {
          _selectedItems.remove(id);
        }
      } else {
        for (final RecordingHistoryItem item in currentPageItems) {
          final RecordingSession session = item.session;
          _selectedIds.add(session.id);
          _selectedItems[session.id] = item;
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
      _selectedItems.clear();
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
      final String code = _selectedItems[id]?.session.displayCode ?? '';
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

  /// 批量分享/保存所选录像：本机原片直接用；只在电脑上的先下载再处理，
  /// 下载失败或电脑离线的条目跳过并在结果里说明。
  Future<void> _shareSelected() async {
    if (_selectedIds.isEmpty || _sharingSelection) return;
    final List<RecordingHistoryItem> items = <RecordingHistoryItem>[];
    int staleRows = 0;
    for (final String id in _selectedIds) {
      final RecordingHistoryItem? item = _selectedItems[id];
      if (item == null) {
        staleRows++;
        continue;
      }
      items.add(item);
    }
    if (items.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('所选录像不在本机，无法分享或保存')));
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
      _shareProgressLabel = null;
    });
    try {
      final VideoShareService shareService = VideoShareService();
      final List<File> files = <File>[];
      int missingLocal = 0;
      int downloadFailed = 0;
      int offline = 0;
      final int remoteCount = items
          .where((RecordingHistoryItem item) => item.remote != null)
          .length;
      int remoteDone = 0;
      for (final RecordingHistoryItem item in items) {
        final RecordingSession session = item.session;
        File? source;
        final String? localPath = item.local?.filePath;
        if (localPath != null && localPath.isNotEmpty) {
          final File local = File(localPath);
          if (!await local.exists()) {
            missingLocal++;
            continue;
          }
          source = local;
        } else if (item.remote != null) {
          final int index = remoteDone + 1;
          _setShareProgress('下载 $index/$remoteCount');
          try {
            source = await _downloadRemoteRecording(
              item.remote!,
              shareService: shareService,
              onProgress: (double progress) => _setShareProgress(
                '下载 $index/$remoteCount ${(progress * 100).round()}%',
              ),
            );
          } on _RemoteRecordingUnavailable {
            offline++;
            continue;
          } on Object {
            downloadFailed++;
            continue;
          } finally {
            remoteDone++;
          }
        } else {
          missingLocal++;
          continue;
        }
        try {
          files.add(
            await shareService.prepareForSharing(
              source,
              fileName: shareFileName(session),
            ),
          );
        } on Object {
          downloadFailed++;
        }
      }
      if (!mounted) return;
      final String skippedNote = _shareSkipNote(
        staleRows: staleRows,
        missingLocal: missingLocal,
        offline: offline,
        failed: downloadFailed,
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
          _setShareProgress('保存 ${saved + saveFailed + 1}/${files.length}');
          try {
            await presenter.saveVideoToGallery(file.path);
            saved++;
          } on Object {
            saveFailed++;
          }
        }
        if (!mounted) return;
        final String note = _shareSkipNote(
          staleRows: staleRows,
          missingLocal: missingLocal,
          offline: offline,
          failed: saveFailed,
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
            'count': items.length,
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
          _shareProgressLabel = null;
        });
      }
    }
  }

  void _setShareProgress(String label) {
    if (_shareProgressLabel == label || !mounted) return;
    setState(() {
      _shareProgressLabel = label;
    });
  }

  /// 下载电脑上的录像；电脑离线或配对失效时抛 [_RemoteRecordingUnavailable]。
  Future<File> _downloadRemoteRecording(
    RemoteRecording remote, {
    required VideoShareService shareService,
    void Function(double progress)? onProgress,
  }) async {
    final Future<Uri?> Function(Uri remoteUri)? resolver =
        widget.onResolveRemoteUri;
    final Uri? resolved = resolver == null
        ? remote.playUri
        : await resolver(remote.playUri);
    if (resolved == null) throw const _RemoteRecordingUnavailable();
    final RemoteVideoClipSink? sink = widget.remoteClipServiceFactory?.call(
      resolved,
    );
    if (sink != null) {
      return sink.download(resolved, onProgress: onProgress);
    }
    return shareService.prepare(
      sourcePath: '',
      remoteUri: resolved,
      remoteHeaders: widget.remotePlaybackHeaders,
      mediaStart: Duration.zero,
      mediaEnd: remote.duration,
      sourceDuration: remote.duration,
      onProgress: (double progress, String _) => onProgress?.call(progress),
    );
  }

  String _shareSkipNote({
    required int staleRows,
    required int missingLocal,
    required int offline,
    required int failed,
  }) {
    return <String>[
      if (staleRows > 0) '跳过已不在列表的 $staleRows 条',
      if (missingLocal > 0) '本机文件缺失 $missingLocal 条',
      if (offline > 0) '电脑离线 $offline 条',
      if (failed > 0) '失败 $failed 条',
    ].join('，');
  }
}

/// 电脑录像当前拿不到（电脑离线或配对失效）。
class _RemoteRecordingUnavailable implements Exception {
  const _RemoteRecordingUnavailable();
}
