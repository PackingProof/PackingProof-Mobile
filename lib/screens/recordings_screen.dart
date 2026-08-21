import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_settings.dart';
import '../models/backup_retention_policy.dart';
import '../models/lan_backup.dart';
import '../models/recording_video_codec.dart';
import '../models/recording_operation_mode.dart';
import '../models/recording_session.dart';
import '../models/recording_spec.dart';
import '../models/recording_orientation.dart';
import '../services/order_info_receiver_service.dart';
import '../services/lan_backup_discovery_service.dart';
import '../services/lan_backup_service.dart';
import '../models/work_mode.dart';
import '../platform/platform_capabilities.dart';
import '../widgets/about_settings.dart';
import '../widgets/two_button_confirm_dialog.dart';
import '../services/recording_thumbnail_service.dart';
import '../services/camera_capability_policy.dart';
import '../services/recording_database.dart';
import '../services/remote_playback_compat.dart';
import '../services/remote_video_clip_service.dart';
import '../services/system_video_player_service.dart';
import 'recordings_history_filter.dart';
import 'recordings_history_pagination.dart';
import 'video_playback_screen.dart';

export 'recordings_history_filter.dart' show RecordingSourceFilter;

part 'recordings_computer_backup_settings.dart';
part 'recordings_backup_coordinator.dart';
part 'recordings_device_settings.dart';
part 'recordings_history_data_coordinator.dart';
part 'recordings_history_management.dart';
part 'recordings_order_receiver_settings.dart';
part 'recordings_history_widgets.dart';

enum RecordingsScreenMode { history, settings }

@visibleForTesting
String recordingsHistoryTitle(String deviceName, String ipAddress) {
  final String name = deviceName.trim().isEmpty ? '设备' : deviceName.trim();
  final String ip = ipAddress.trim();
  return ip.isEmpty ? name : '$name · $ip';
}

@visibleForTesting
String fitTrackingNumber(
  String value,
  double maxWidth,
  TextStyle style, {
  TextScaler textScaler = TextScaler.noScaling,
}) {
  const int tailLength = 4;
  final TextPainter painter = TextPainter(
    textDirection: TextDirection.ltr,
    maxLines: 1,
    textScaler: textScaler,
  );
  double measure(String text) {
    painter.text = TextSpan(text: text, style: style);
    painter.layout();
    return painter.width;
  }

  if (measure(value) <= maxWidth) {
    return value;
  }
  final String tail = value.length <= tailLength
      ? value
      : value.substring(value.length - tailLength);
  int low = 0;
  int high = value.length - tail.length;
  int best = 0;
  while (low <= high) {
    final int mid = (low + high) ~/ 2;
    if (measure('${value.substring(0, mid)}…$tail') <= maxWidth) {
      best = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  final String withEllipsis = best > 0
      ? '${value.substring(0, best)}…$tail'
      : '…$tail';
  if (measure(withEllipsis) <= maxWidth) {
    return withEllipsis;
  }
  int tailChars = tail.length;
  while (tailChars > 1 &&
      measure(tail.substring(tail.length - tailChars)) > maxWidth) {
    tailChars--;
  }
  return tail.substring(tail.length - tailChars);
}

@visibleForTesting
String friendlyBackupConnectionError(Object error) {
  if (error is LanBackupConnectionException ||
      error is LanBackupHostUpgradeRequiredException ||
      error is LanBackupClientUpgradeRequiredException ||
      error is LanBackupNotHostException ||
      error is LanBackupUnsupportedException) {
    return error.toString();
  }
  return '暂时无法连接保存主机，请稍后再试';
}

@visibleForTesting
String? recordingWatermarkPlaybackBlockMessage(
  RecordingSession session, {
  required bool localAvailable,
}) {
  if (!localAvailable ||
      session.watermarkStatus == WatermarkProcessingStatus.completed) {
    return null;
  }
  return session.watermarkStatus == WatermarkProcessingStatus.pending
      ? '水印处理中，完成后即可播放'
      : '水印处理失败，原片已安全保留';
}

class _RecordingsHistoryTitle extends StatelessWidget {
  const _RecordingsHistoryTitle({
    required this.deviceName,
    required this.ipAddress,
  });

  final String deviceName;
  final String ipAddress;

  @override
  Widget build(BuildContext context) {
    final String name = deviceName.trim().isEmpty ? '设备' : deviceName.trim();
    final String ip = ipAddress.trim();
    return Semantics(
      label: recordingsHistoryTitle(name, ip),
      child: Row(
        children: <Widget>[
          Flexible(
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (ip.isNotEmpty)
            Text(
              ' · $ip',
              key: const Key('recordings-history-ip'),
              maxLines: 1,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
            ),
        ],
      ),
    );
  }
}

class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({
    required this.sessions,
    required this.workMode,
    required this.speechEnabled,
    this.orderSpeechEnabled = true,
    this.orderReceiverSnapshot = const OrderInfoReceiverSnapshot(),
    required this.maxVolumeEnabled,
    this.recordAudioEnabled = true,
    this.preferredVideoCodec = RecordingVideoCodec.hevc,
    this.recordingSpec = RecordingSpecPreset.hd1080p30,
    this.recordingOrientation = RecordingOrientation.portrait,
    this.minimumBarcodeLength = AppSettings.defaultMinimumBarcodeLength,
    this.historyPageSize = AppSettings.defaultHistoryPageSize,
    required this.onWorkModeChanged,
    required this.onSpeechEnabledChanged,
    this.onOrderSpeechEnabledChanged,
    this.onRetryOrderReceiver,
    required this.onMaxVolumeEnabledChanged,
    this.onRecordAudioEnabledChanged,
    this.onPreferredVideoCodecChanged,
    this.onRecordingSpecChanged,
    this.onRecordingOrientationChanged,
    this.onMinimumBarcodeLengthChanged,
    this.onHistoryPageSizeChanged,
    required this.onSpeechPreview,
    required this.onSessionUpdated,
    required this.onDeleteSessions,
    this.backupSnapshot = const LanBackupSnapshot(),
    this.backupListenable,
    this.backupSnapshotProvider,
    this.onAutoBackupChanged,
    this.onBackupNow,
    this.onDisconnectBackup,
    this.onRetryConnection,
    this.onRetryBackup,
    this.onRefreshHistory,
    this.onManagingChanged,
    this.capabilityMode,
    this.capabilityStatusText,
    this.capabilityProbedAtMs = 0,
    this.showCameraCapabilityCard = false,
    this.onRetryCapabilityProbe,
    this.unbackedRetention = UnbackedRetentionPolicy.days30,
    this.backedRetention = BackedRetentionPolicy.days7,
    this.onBackupRetentionChanged,
    this.onLoadRemoteRecordings,
    this.onLoadLocalRecordings,
    this.onLoadRemoteRecordingStatuses,
    this.onResolveRemoteUri,
    this.hiddenRemoteRecordingIds = const <int>{},
    this.onHideRemoteRecordings,
    this.remotePlaybackHeaders = const <String, String>{},
    this.remoteClipServiceFactory,
    this.onNetworkDiagnostics,
    this.mode = RecordingsScreenMode.history,
    this.embedded = false,
    this.onConnectComputer,
    this.onCancelBackupPairing,
    this.onConnectBackupHost,
    this.backupHostDiscovery,
    this.onScanSearch,
    this.externalSearchQuery = '',
    this.active = true,
    this.focusBackupRevision = 0,
    this.capabilities,
    this.recordingStatistics,
    super.key,
  });

  final List<RecordingSession> sessions;
  final WorkMode workMode;
  final bool speechEnabled;
  final bool orderSpeechEnabled;
  final OrderInfoReceiverSnapshot orderReceiverSnapshot;
  final bool maxVolumeEnabled;
  final bool recordAudioEnabled;
  final RecordingVideoCodec preferredVideoCodec;
  final RecordingSpecPreset recordingSpec;
  final RecordingOrientation recordingOrientation;
  final int minimumBarcodeLength;
  final int historyPageSize;
  final ValueChanged<int>? onHistoryPageSizeChanged;
  final Future<void> Function(WorkMode mode) onWorkModeChanged;
  final Future<void> Function(bool enabled) onSpeechEnabledChanged;
  final Future<void> Function(bool enabled)? onOrderSpeechEnabledChanged;
  final Future<void> Function()? onRetryOrderReceiver;
  final Future<void> Function(bool enabled) onMaxVolumeEnabledChanged;
  final Future<void> Function(bool enabled)? onRecordAudioEnabledChanged;
  final Future<void> Function(RecordingVideoCodec codec)?
  onPreferredVideoCodecChanged;
  final Future<void> Function(RecordingSpecPreset spec)? onRecordingSpecChanged;
  final Future<void> Function(RecordingOrientation orientation)?
  onRecordingOrientationChanged;
  final Future<void> Function(int value)? onMinimumBarcodeLengthChanged;
  final Future<void> Function() onSpeechPreview;
  final Future<void> Function(RecordingSession session) onSessionUpdated;
  final Future<void> Function(Set<String> sessionIds) onDeleteSessions;
  final LanBackupSnapshot backupSnapshot;
  final Listenable? backupListenable;
  final LanBackupSnapshot Function()? backupSnapshotProvider;
  final Future<void> Function(bool enabled)? onAutoBackupChanged;
  final Future<void> Function()? onBackupNow;
  final Future<void> Function()? onDisconnectBackup;
  final Future<void> Function()? onRetryConnection;
  final Future<void> Function(String jobId)? onRetryBackup;
  final Future<void> Function()? onRefreshHistory;
  final ValueChanged<bool>? onManagingChanged;
  final CameraCapabilityMode? capabilityMode;
  final String? capabilityStatusText;
  final int capabilityProbedAtMs;
  final bool showCameraCapabilityCard;
  final VoidCallback? onRetryCapabilityProbe;
  final UnbackedRetentionPolicy unbackedRetention;
  final BackedRetentionPolicy backedRetention;
  final Future<void> Function({
    required UnbackedRetentionPolicy unbacked,
    required BackedRetentionPolicy backed,
  })?
  onBackupRetentionChanged;
  final Future<RemoteRecordingPage> Function({
    required int page,
    required int pageSize,
    String keyword,
  })?
  onLoadRemoteRecordings;
  final Future<LocalRecordingPage> Function({
    required int page,
    required int pageSize,
    String keyword,
    DateTime? start,
    DateTime? end,
  })?
  onLoadLocalRecordings;
  final Future<
    Map<int, ({RemoteRecordingStatus status, bool exists, String reason})>
  >
  Function(Iterable<int> ids)?
  onLoadRemoteRecordingStatuses;
  final Future<Uri?> Function(Uri remoteUri)? onResolveRemoteUri;
  final Set<int> hiddenRemoteRecordingIds;
  final Future<void> Function(Set<int> ids)? onHideRemoteRecordings;
  final Map<String, String> remotePlaybackHeaders;
  final RemoteVideoClipSink? Function(Uri remoteUri)? remoteClipServiceFactory;
  final Future<NetworkDiagnostics?> Function()? onNetworkDiagnostics;
  final RecordingsScreenMode mode;
  final bool embedded;
  final VoidCallback? onConnectComputer;
  final VoidCallback? onCancelBackupPairing;
  final Future<void> Function(
    LanBackupDiscoveredHost host,
    LanBackupPairingConfirmation? replacementConfirmation,
  )?
  onConnectBackupHost;
  final LanBackupHostDiscovery? backupHostDiscovery;
  final VoidCallback? onScanSearch;
  final String externalSearchQuery;
  final bool active;
  final int focusBackupRevision;
  final PlatformCapabilities? capabilities;
  final LocalRecordingStatistics? recordingStatistics;

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen>
    with
        _RecordingsBackupCoordinator,
        _RecordingsHistoryDataCoordinator,
        _RecordingsHistoryManagement {
  @override
  int _historyPageSize = 5;
  static final RecordingThumbnailService _thumbnailService =
      RecordingThumbnailService();

  late WorkMode _workMode;
  late bool _speechEnabled;
  late bool _orderSpeechEnabled;
  late bool _maxVolumeEnabled;
  late bool _recordAudioEnabled;
  late RecordingVideoCodec _preferredVideoCodec;
  late RecordingSpecPreset _recordingSpec;
  late RecordingOrientation _recordingOrientation;
  late int _minimumBarcodeLength;
  VideoDecodeSupport? _deviceDecodeSupport;
  @override
  late List<RecordingSession> _sessions;
  late int _localRecordingBytes;
  late Set<String> _localRecordingPaths;
  late UnbackedRetentionPolicy _unbackedRetention;
  late BackedRetentionPolicy _backedRetention;
  late Set<int> _hiddenRemoteIds;
  Timer? _remoteSearchTimer;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Map<String, Future<String?>> _localThumbnailFutures =
      <String, Future<String?>>{};
  @override
  String _query = '';
  RecordingSourceFilter _sourceFilter = RecordingSourceFilter.all;
  RecordingHistoryDatePreset _datePreset = RecordingHistoryDatePreset.all;
  DateTimeRange? _customDateRange;

  List<RecordingSession> get _filteredSessions =>
      filterRecordingSessionsByQuery(_sessions, _query);

  bool get _hasOtherDeviceRecordings => _visibleItems.any(
    (RecordingHistoryItem item) =>
        item.remote != null && !_isRemoteFromThisDevice(item.remote!),
  );

  bool get _maxVolumeSupported =>
      widget.capabilities?.supports(PlatformCapability.alertVolumeBoost) ??
      true;

  @override
  bool get _lanBackupSupported =>
      widget.capabilities?.supports(PlatformCapability.lanBackup) ?? true;

  bool get _orderReceiverSupported =>
      widget.capabilities?.supports(PlatformCapability.orderInfoReceiver) ??
      true;

  bool get _systemVideoPlayerSupported =>
      widget.capabilities?.supports(PlatformCapability.systemVideoPlayer) ??
      true;

  @override
  void initState() {
    super.initState();
    _workMode = widget.workMode;
    _speechEnabled = widget.speechEnabled;
    _orderSpeechEnabled = widget.orderSpeechEnabled;
    _maxVolumeEnabled = widget.maxVolumeEnabled;
    _recordAudioEnabled = widget.recordAudioEnabled;
    _preferredVideoCodec = widget.preferredVideoCodec;
    _recordingSpec = widget.recordingSpec;
    _recordingOrientation = widget.recordingOrientation;
    _minimumBarcodeLength = widget.minimumBarcodeLength;
    _historyPageSize = widget.historyPageSize;
    if (_systemVideoPlayerSupported) {
      unawaited(_loadDeviceDecodeSupport());
    }
    _sessions = List<RecordingSession>.of(widget.sessions);
    _refreshLocalRecordingStats();
    _initializeBackupCoordinator();
    _unbackedRetention = widget.unbackedRetention;
    _backedRetention = widget.backedRetention;
    _hiddenRemoteIds = Set<int>.of(widget.hiddenRemoteRecordingIds);
    _applyExternalSearch(widget.externalSearchQuery);
    _attachBackupSnapshotListener();
    if (widget.mode == RecordingsScreenMode.history && widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_loadLocal(reset: true, pageNumber: 1, prefetchNext: true));
        unawaited(_loadRemote(reset: true, pageNumber: 1, prefetchNext: true));
        _startBackupHostDiscoveryIfNeeded();
      });
    }
  }

  Future<void> _loadDeviceDecodeSupport() async {
    final VideoDecodeSupport? support = await SystemVideoPlayerService()
        .getVideoDecodeSupport();
    if (!mounted) return;
    setState(() => _deviceDecodeSupport = support);
  }

  @override
  void didUpdateWidget(covariant RecordingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool sessionsChanged = !_sameSessionSnapshot(
      oldWidget.sessions,
      widget.sessions,
    );
    if (sessionsChanged && widget.onLoadLocalRecordings == null) {
      _sessions = List<RecordingSession>.of(widget.sessions);
      _refreshLocalRecordingStats();
    } else if (sessionsChanged && widget.active) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(
          _loadLocal(
            reset: true,
            pageNumber: 1,
            prefetchNext: true,
            preservePage: true,
          ),
        ),
      );
    }
    _workMode = widget.workMode;
    _speechEnabled = widget.speechEnabled;
    _orderSpeechEnabled = widget.orderSpeechEnabled;
    _maxVolumeEnabled = widget.maxVolumeEnabled;
    _recordAudioEnabled = widget.recordAudioEnabled;
    _preferredVideoCodec = widget.preferredVideoCodec;
    _recordingSpec = widget.recordingSpec;
    _recordingOrientation = widget.recordingOrientation;
    _minimumBarcodeLength = widget.minimumBarcodeLength;
    _historyPageSize = widget.historyPageSize;
    _unbackedRetention = widget.unbackedRetention;
    _backedRetention = widget.backedRetention;
    _hiddenRemoteIds.addAll(widget.hiddenRemoteRecordingIds);
    if (oldWidget.focusBackupRevision != widget.focusBackupRevision &&
        widget.focusBackupRevision > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          unawaited(
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
            ),
          );
        }
      });
    }
    if (!oldWidget.active &&
        widget.active &&
        (_remoteRecordings.isEmpty || _remoteCacheDirty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_loadLocal(reset: true, pageNumber: 1, prefetchNext: true));
        _reloadRemoteAfterBackup(force: _remoteRecordings.isEmpty);
        _startBackupHostDiscoveryIfNeeded();
      });
    }
    if (oldWidget.externalSearchQuery != widget.externalSearchQuery &&
        widget.externalSearchQuery.isNotEmpty) {
      _applyExternalSearch(widget.externalSearchQuery);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_loadLocal(reset: true, pageNumber: 1, prefetchNext: true));
        unawaited(_loadRemote(reset: true, pageNumber: 1, prefetchNext: true));
      });
    }
  }

  void _applyExternalSearch(String value) {
    if (value.isEmpty) return;
    _query = value;
    _searchController.text = value;
    _searchController.selection = TextSelection.collapsed(offset: value.length);
  }

  @override
  void dispose() {
    _disposeBackupCoordinator();
    _remoteSearchTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  List<RecordingHistoryItem> get _visibleItems =>
      buildVisibleRecordingHistoryItems(
        localSessions: _filteredSessions,
        remoteRecordings: _remoteRecordings,
        hiddenRemoteIds: _hiddenRemoteIds,
        localRecordingPaths: _localRecordingPaths,
        sourceFilter: _sourceFilter,
        dateWindow: _activeDateWindow,
        isRemoteFromThisDevice: _isRemoteFromThisDevice,
        isLocalBackedUp: (RecordingSession local) =>
            _backupJobsByPath[lanBackupFileIdentity(local.filePath)]?.any(
              _isJobConfirmedAvailable,
            ) ==
            true,
      );

  Future<void> _confirmDeleteComputer() async {
    final LanBackupEndpoint? endpoint = _backupSnapshot.endpoint;
    if (endpoint == null || widget.onDisconnectBackup == null) return;
    final bool? continueDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => const TwoButtonConfirmDialog(
        title: '删除这台电脑？',
        message: '将删除保存主机连接并停止当前备份。手机中的录像不会被删除',
        confirmLabel: '继续',
      ),
    );
    if (continueDelete != true || !mounted) return;
    final String identity = endpoint.computerName.isEmpty
        ? endpoint.displayAddress
        : '${endpoint.computerName}\n${endpoint.displayAddress}';
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => TwoButtonConfirmDialog(
        title: '再次确认删除',
        message: '确定删除以下电脑？\n\n$identity',
        confirmLabel: '确认删除',
        dangerous: true,
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onDisconnectBackup!();
    if (!mounted) return;
    await _backupHostDiscovery.forgetHost(
      nodeId: endpoint.computerId,
      address: endpoint.displayAddress,
    );
    if (!mounted) return;
    setState(() {
      _remoteRequestGeneration++;
      _loadingRemote = false;
      _remoteRecordings.clear();
      _remotePages.clear();
      _remoteTotal = 0;
      _remoteDeviceTotal = 0;
      _historyPage = 0;
    });
  }

  void _onSearchChanged(String value) {
    setState(() {
      _query = value;
      _historyPage = 0;
    });
    _remoteSearchTimer?.cancel();
    _remoteSearchTimer = Timer(const Duration(milliseconds: 300), () {
      _localRequestGeneration++;
      _loadingLocal = false;
      unawaited(_loadLocal(reset: true, pageNumber: 1, prefetchNext: true));
      unawaited(_loadRemote(reset: true, pageNumber: 1, prefetchNext: true));
    });
  }

  Future<void> _setWorkMode(WorkMode mode) async {
    if (_workMode == mode) {
      return;
    }
    setState(() => _workMode = mode);
    await widget.onWorkModeChanged(mode);
  }

  Future<void> _setSpeechEnabled(bool enabled) async {
    if (_speechEnabled == enabled) {
      return;
    }
    setState(() => _speechEnabled = enabled);
    await widget.onSpeechEnabledChanged(enabled);
  }

  Future<void> _setOrderSpeechEnabled(bool enabled) async {
    if (_orderSpeechEnabled == enabled) return;
    setState(() => _orderSpeechEnabled = enabled);
    await widget.onOrderSpeechEnabledChanged?.call(enabled);
  }

  Future<void> _setMaxVolumeEnabled(bool enabled) async {
    if (_maxVolumeEnabled == enabled) {
      return;
    }
    setState(() => _maxVolumeEnabled = enabled);
    await widget.onMaxVolumeEnabledChanged(enabled);
  }

  Future<void> _setRecordAudioEnabled(bool enabled) async {
    if (_recordAudioEnabled == enabled) {
      return;
    }
    setState(() => _recordAudioEnabled = enabled);
    await widget.onRecordAudioEnabledChanged?.call(enabled);
  }

  Future<void> _setPreferredVideoCodec(RecordingVideoCodec codec) async {
    if (_preferredVideoCodec == codec) {
      return;
    }
    setState(() => _preferredVideoCodec = codec);
    await widget.onPreferredVideoCodecChanged?.call(codec);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('录像编码已切换，新录像将使用所选编码')));
    }
  }

  Future<void> _setRecordingSpec(RecordingSpecPreset spec) async {
    if (_recordingSpec == spec) {
      return;
    }
    setState(() => _recordingSpec = spec);
    await widget.onRecordingSpecChanged?.call(spec);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('录像规格已切换，新录像将使用所选规格')));
    }
  }

  Future<void> _setRecordingOrientation(
    RecordingOrientation orientation,
  ) async {
    if (_recordingOrientation == orientation) return;
    setState(() => _recordingOrientation = orientation);
    await widget.onRecordingOrientationChanged?.call(orientation);
  }

  Future<void> _setMinimumBarcodeLength(int value) async {
    if (_minimumBarcodeLength == value) {
      return;
    }
    setState(() => _minimumBarcodeLength = value);
    await widget.onMinimumBarcodeLengthChanged?.call(value);
  }

  Future<void> _setUnbackedRetention(UnbackedRetentionPolicy value) async {
    setState(() => _unbackedRetention = value);
    await widget.onBackupRetentionChanged?.call(
      unbacked: value,
      backed: _backedRetention,
    );
  }

  Future<void> _setBackedRetention(BackedRetentionPolicy value) async {
    if (value == BackedRetentionPolicy.immediately) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => const TwoButtonConfirmDialog(
          title: '备份后立即清除？',
          message: '录像成功备份到电脑后，将自动删除手机中的本机文件。电脑离线时仍可查看录像记录，但无法播放远程视频',
          confirmLabel: '确认',
          dangerous: true,
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _backedRetention = value);
    await widget.onBackupRetentionChanged?.call(
      unbacked: _unbackedRetention,
      backed: value,
    );
  }

  Future<void> _updateSession(RecordingSession updated) async {
    await widget.onSessionUpdated(updated);
    if (!mounted) {
      return;
    }
    setState(() {
      final int index = _sessions.indexWhere(
        (RecordingSession item) => item.id == updated.id,
      );
      if (index >= 0) {
        _sessions[index] = updated;
        _sessions.sort(
          (RecordingSession a, RecordingSession b) =>
              b.startedAt.compareTo(a.startedAt),
        );
        _refreshLocalRecordingStats();
      }
    });
  }

  Future<String?> _localThumbnail(String filePath) => _localThumbnailFutures
      .putIfAbsent(filePath, () => _thumbnailService.generate(filePath));

  Future<void> _pasteSearch() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String value = data?.text?.trim() ?? '';
    if (!mounted || value.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('剪贴板里没有可用文本')));
      }
      return;
    }
    _searchController.text = value;
    _searchController.selection = TextSelection.collapsed(offset: value.length);
    _onSearchChanged(value);
  }

  Future<void> _showSourceFilter() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    final RecordingSourceFilter? value =
        await showModalBottomSheet<RecordingSourceFilter>(
          context: context,
          showDragHandle: true,
          builder: (BuildContext context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: RecordingSourceFilter.values
                  .map(
                    (filter) => ListTile(
                      leading: Icon(
                        filter == _sourceFilter
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                        color: filter == _sourceFilter
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(recordingHistorySourceFilterLabel(filter)),
                      onTap: () => Navigator.of(context).pop(filter),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        );
    if (value != null && mounted) {
      setState(() {
        _sourceFilter = value;
        _historyPage = 0;
      });
    }
  }

  @override
  RecordingHistoryDateWindow? get _activeDateWindow =>
      recordingHistoryDateWindow(
        preset: _datePreset,
        now: DateTime.now(),
        customStart: _customDateRange?.start,
        customEnd: _customDateRange?.end,
      );

  String get _dateFilterLabel => recordingHistoryDateFilterLabel(
    preset: _datePreset,
    customStart: _customDateRange?.start,
    customEnd: _customDateRange?.end,
  );

  Future<void> _showDateFilter() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    final RecordingHistoryDatePreset? value =
        await showModalBottomSheet<RecordingHistoryDatePreset>(
          context: context,
          showDragHandle: true,
          builder: (BuildContext context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: RecordingHistoryDatePreset.values
                  .map(
                    (preset) => ListTile(
                      leading: Icon(
                        preset == _datePreset
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                        color: preset == _datePreset
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(
                        recordingHistoryDatePresetOptionLabel(preset),
                      ),
                      onTap: () => Navigator.of(context).pop(preset),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        );
    if (value == null || !mounted) return;
    if (value == RecordingHistoryDatePreset.custom) {
      final DateTimeRange? picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime.now(),
        initialDateRange: _customDateRange,
      );
      if (picked == null || !mounted) return;
      setState(() {
        _datePreset = RecordingHistoryDatePreset.custom;
        _customDateRange = picked;
        _historyPage = 0;
      });
      _reloadLocalAfterFilterChange();
      return;
    }
    setState(() {
      _datePreset = value;
      _historyPage = 0;
    });
    _reloadLocalAfterFilterChange();
  }

  void _reloadLocalAfterFilterChange() {
    _localRequestGeneration++;
    _loadingLocal = false;
    unawaited(_loadLocal(reset: true, pageNumber: 1, prefetchNext: true));
  }

  Future<void> _showNextHistoryPage(int pageCount) async {
    final RecordingHistoryNextPagePlan? plan = recordingHistoryNextPagePlan(
      currentPage: _historyPage,
      pageCount: pageCount,
    );
    if (plan == null) return;
    if (!_remotePages.containsKey(plan.dataPage) &&
        _backupSnapshot.connectionStatus == LanConnectionStatus.connected) {
      await _loadRemote(pageNumber: plan.dataPage);
    }
    if (!_localPages.containsKey(plan.dataPage)) {
      await _loadLocal(pageNumber: plan.dataPage);
    }
    if (!mounted) return;
    setState(() => _historyPage = plan.historyPage);
    if (shouldPrefetchRecordingHistoryPage(
          page: plan.prefetchPage,
          total: _remoteTotal,
          pageSize: _historyPageSize,
          loadedPages: _remotePages.keys,
        ) &&
        _backupSnapshot.connectionStatus == LanConnectionStatus.connected) {
      unawaited(_loadRemote(pageNumber: plan.prefetchPage));
    }
    if (shouldPrefetchRecordingHistoryPage(
      page: plan.prefetchPage,
      total: _localTotal,
      pageSize: _historyPageSize,
      loadedPages: _localPages.keys,
    )) {
      unawaited(_loadLocal(pageNumber: plan.prefetchPage));
    }
  }

  void _setHistoryPageSize(int pageSize) {
    if (pageSize == _historyPageSize) return;
    _localRequestGeneration++;
    _remoteRequestGeneration++;
    setState(() {
      _historyPageSize = pageSize;
      _loadingLocal = false;
      _loadingRemote = false;
      _localPages.clear();
      _remotePages.clear();
      _sessions.clear();
      _remoteRecordings.clear();
      _localTotal = 0;
      _remoteTotal = 0;
      _remoteDeviceTotal = 0;
      _historyPage = 0;
    });
    unawaited(_loadLocal(reset: true, pageNumber: 1, prefetchNext: true));
    unawaited(_loadRemote(reset: true, pageNumber: 1, prefetchNext: true));
    widget.onHistoryPageSizeChanged?.call(pageSize);
  }

  @override
  Widget build(BuildContext context) {
    final List<RecordingHistoryItem> visibleItems = _visibleItems;
    final List<RecordingSession> filteredSessions = _filteredSessions;
    final int localCount = filteredSessions
        .where((session) => _localRecordingPaths.contains(session.filePath))
        .length;
    final int localLogicalCount = widget.onLoadLocalRecordings == null
        ? filteredSessions.length
        : _localTotal;
    final bool hasOtherDeviceRecordings = _hasOtherDeviceRecordings;
    final List<RecordingSession> existingLocalSessions = _existingLocalSessions;
    final Set<String> confirmedBackupPaths = _backupSnapshot.jobs
        .where(_isJobConfirmedAvailable)
        .map((LanBackupJob job) => lanBackupFileIdentity(job.filePath))
        .toSet();
    final bool allLocalFilesBackedUp = _localRecordingPaths
        .map(lanBackupFileIdentity)
        .every(confirmedBackupPaths.contains);
    final int remainingBackupCount = _localRecordingPaths
        .map(lanBackupFileIdentity)
        .where((String path) => !confirmedBackupPaths.contains(path))
        .length;
    final RecordingHistoryPagination<RecordingHistoryItem> pagination =
        buildRecordingHistoryPagination(
          sourceFilter: _sourceFilter,
          localCount: widget.onLoadLocalRecordings == null
              ? localCount
              : _localTotal,
          localLogicalCount: localLogicalCount,
          remoteTotal: _remoteTotal,
          remoteDeviceTotal: _remoteDeviceTotal,
          visibleItems: visibleItems,
          requestedPage: _historyPage,
          pageSize: _historyPageSize,
        );
    final List<RecordingSession> currentPageSessions = pagination.items
        .map((item) => item.session)
        .toList(growable: false);
    final bool historyMode = widget.mode == RecordingsScreenMode.history;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return PopScope<Object?>(
      canPop: !_managing,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _managing) {
          _exitManaging();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !widget.embedded,
          title: _managing
              ? Text('已选 ${_selectedIds.length} 项')
              : historyMode
              ? _RecordingsHistoryTitle(
                  deviceName: _backupSnapshot.deviceName,
                  ipAddress: widget.orderReceiverSnapshot.ipAddress,
                )
              : const Text('设置'),
          actions: <Widget>[
            if (_managing)
              TextButton(
                key: const Key('finish-managing-appbar-button'),
                onPressed: _toggleManaging,
                child: const Text('完成'),
              ),
          ],
        ),
        body: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
          children: <Widget>[
            if (!historyMode) ...<Widget>[
              _SettingsCard(
                key: const Key('work-settings-card'),
                children: <Widget>[
                  _WorkModeSettings(
                    workMode: _workMode,
                    onChanged: _setWorkMode,
                  ),
                  if (widget.onMinimumBarcodeLengthChanged != null) ...<Widget>[
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: colors.outlineVariant,
                    ),
                    _MinimumBarcodeLengthSettings(
                      value: _minimumBarcodeLength,
                      onChanged: _setMinimumBarcodeLength,
                    ),
                  ],
                ],
              ),
              if (widget.showCameraCapabilityCard &&
                  widget.capabilities?.supports(
                        PlatformCapability.cameraCapabilityNegotiation,
                      ) !=
                      false &&
                  widget.capabilityMode != null) ...<Widget>[
                const SizedBox(height: 12),
                _SettingsCard(
                  key: const Key('camera-capability-settings-card'),
                  children: <Widget>[
                    _CameraCapabilitySettings(
                      mode: widget.capabilityMode!,
                      statusText: widget.capabilityStatusText ?? '',
                      onRetry: widget.onRetryCapabilityProbe,
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              _SettingsCard(
                key: const Key('recording-settings-card'),
                children: <Widget>[
                  _RetentionSettings(
                    unbackedRetention: _unbackedRetention,
                    backedRetention: _backedRetention,
                    onUnbackedRetentionChanged: _setUnbackedRetention,
                    onBackedRetentionChanged: _setBackedRetention,
                  ),
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: colors.outlineVariant,
                  ),
                  _VideoCodecSettings(
                    codec: _preferredVideoCodec,
                    hevcWarning: _deviceDecodeSupport == null
                        ? null
                        : (!_deviceDecodeSupport!.hasHevcDecoder
                              ? '当前设备不支持播放 H.265，新录像将自动使用 H.264'
                              : null),
                    onChanged: _setPreferredVideoCodec,
                  ),
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: colors.outlineVariant,
                  ),
                  _RecordingSpecSettings(
                    spec: _recordingSpec,
                    onChanged: _setRecordingSpec,
                  ),
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: colors.outlineVariant,
                  ),
                  _RecordingOrientationSettings(
                    orientation: _recordingOrientation,
                    onChanged: (value) {
                      unawaited(_setRecordingOrientation(value));
                    },
                  ),
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: colors.outlineVariant,
                  ),
                  _RecordAudioSettings(
                    enabled: _recordAudioEnabled,
                    onChanged: _setRecordAudioEnabled,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _SettingsCard(
                key: const Key('voice-settings-card'),
                children: <Widget>[
                  _SpeechPromptSettings(
                    enabled: _speechEnabled,
                    onChanged: _setSpeechEnabled,
                    onPreview: widget.onSpeechPreview,
                  ),
                  if (_maxVolumeSupported) ...<Widget>[
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: colors.outlineVariant,
                    ),
                    _MaxVolumeSettings(
                      enabled: _maxVolumeEnabled,
                      onChanged: _setMaxVolumeEnabled,
                    ),
                  ],
                ],
              ),
              if (_orderReceiverSupported) ...<Widget>[
                const SizedBox(height: 12),
                _OrderReceiverSettings(
                  snapshot: widget.orderReceiverSnapshot,
                  onRetry: widget.onRetryOrderReceiver,
                  speechEnabled: _orderSpeechEnabled,
                  speechMasterEnabled: _speechEnabled,
                  onSpeechChanged: _setOrderSpeechEnabled,
                ),
              ],
              const SizedBox(height: 12),
              const AboutSettings(),
            ] else ...<Widget>[
              if (!_managing) ...<Widget>[
                _HistorySummary(
                  total:
                      widget.recordingStatistics?.total ??
                      existingLocalSessions.length,
                  today:
                      widget.recordingStatistics?.today ??
                      existingLocalSessions
                          .where((item) => _isToday(item.startedAt))
                          .length,
                  totalBytes:
                      widget.recordingStatistics?.totalBytes ??
                      _localRecordingBytes,
                ),
                if (_lanBackupSupported) ...<Widget>[
                  const SizedBox(height: 12),
                  _ComputerBackupSettings(
                    snapshot: _backupSnapshot,
                    allBackedUp: allLocalFilesBackedUp,
                    remainingBackupCount: remainingBackupCount,
                    onConnect:
                        widget.onConnectComputer ??
                        () => Navigator.of(context).pop(true),
                    onAutoChanged: widget.onAutoBackupChanged,
                    onBackupNow: widget.onBackupNow,
                    onDisconnect: _confirmDeleteComputer,
                    onRetryConnection: widget.onRetryConnection,
                    onRetry: widget.onRetryBackup,
                    discovery: _backupDiscoverySnapshot,
                    onSearchHosts: () {
                      _autoConnectStarted = false;
                      return _backupHostDiscovery.search();
                    },
                    onSelectHost: _connectDiscoveredHost,
                    onRequestApproval: _lastApprovalHost != null
                        ? () => _connectDiscoveredHost(_lastApprovalHost!)
                        : _backupSnapshot.endpoint == null
                        ? null
                        : () => _connectDiscoveredHost(
                            LanBackupDiscoveredHost(
                              nodeId: _backupSnapshot.endpoint!.computerId,
                              name: _backupSnapshot.endpoint!.computerName,
                              address: _backupSnapshot.endpoint!.displayAddress,
                            ),
                          ),
                    onCancelApproval: _cancelBackupApproval,
                    unbackedRetention: _unbackedRetention,
                    backedRetention: _backedRetention,
                    onUnbackedRetentionChanged: _setUnbackedRetention,
                    onBackedRetentionChanged: _setBackedRetention,
                    showRetention: false,
                  ),
                ],
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 12, 2, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Text(
                          '录像记录',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (_backupSnapshot.connectionStatus ==
                            LanConnectionStatus.connected)
                          IconButton(
                            key: const Key('refresh-recordings-button'),
                            tooltip: '刷新录像记录',
                            onPressed: _manualRefreshing
                                ? null
                                : _manualRefresh,
                            icon: _manualRefreshing
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded),
                          ),
                        const Spacer(),
                        if (!_managing && visibleItems.isNotEmpty)
                          TextButton(
                            key: const Key('manage-recordings-button'),
                            onPressed: _toggleManaging,
                            child: const Text('管理'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SearchBar(
                      key: const Key('recording-search'),
                      controller: _searchController,
                      hintText: '搜索面单号或日期',
                      leading: const Icon(Icons.search_rounded),
                      trailing: <Widget>[
                        IconButton(
                          key: const Key('scan-search-button'),
                          tooltip: '扫描条码搜索',
                          onPressed: widget.onScanSearch,
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                        ),
                        IconButton(
                          key: const Key('paste-search-button'),
                          tooltip: '粘贴搜索内容',
                          onPressed: _pasteSearch,
                          icon: const Icon(Icons.content_paste_rounded),
                        ),
                        if (_query.isNotEmpty)
                          IconButton(
                            tooltip: '清除搜索',
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _query = '';
                                _historyPage = 0;
                              });
                              unawaited(
                                _loadRemote(
                                  reset: true,
                                  pageNumber: 1,
                                  prefetchNext: true,
                                ),
                              );
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                      ],
                      onChanged: _onSearchChanged,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        FilterChip(
                          key: const Key('recording-source-filter'),
                          avatar: const Icon(
                            Icons.filter_alt_rounded,
                            size: 18,
                          ),
                          label: Text(
                            recordingHistorySourceFilterLabel(_sourceFilter),
                          ),
                          selected: _sourceFilter != RecordingSourceFilter.all,
                          showCheckmark: false,
                          onSelected: (_) => _showSourceFilter(),
                        ),
                        FilterChip(
                          key: const Key('recording-date-filter'),
                          avatar: const Icon(
                            Icons.calendar_month_rounded,
                            size: 18,
                          ),
                          label: Text(_dateFilterLabel),
                          selected:
                              _datePreset != RecordingHistoryDatePreset.all,
                          showCheckmark: false,
                          onSelected: (_) => _showDateFilter(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_sessions.isEmpty && _remoteRecordings.isEmpty)
                const SizedBox(height: 280, child: _EmptyRecordings())
              else if (visibleItems.isEmpty)
                const SizedBox(height: 220, child: _NoSearchResults())
              else
                ...List<Widget>.generate(pagination.items.length, (int index) {
                  final RecordingHistoryItem item = pagination.items[index];
                  final RecordingSession session = item.session;
                  final bool localAvailable =
                      item.local != null &&
                      _localRecordingPaths.contains(item.local!.filePath);
                  final List<LanBackupJob> matchingBackupJobs =
                      item.local == null
                      ? const <LanBackupJob>[]
                      : _backupJobsByPath[lanBackupFileIdentity(
                              item.local!.filePath,
                            )] ??
                            const <LanBackupJob>[];
                  final bool remoteAvailable =
                      item.remote != null &&
                      item.remote!.status == RemoteRecordingStatus.available &&
                      item.remote!.exists;
                  final LanBackupJob? completedBackupJob = matchingBackupJobs
                      .where(_isJobKnownAvailable)
                      .firstOrNull;
                  final LanBackupJob? backupJob =
                      completedBackupJob ?? matchingBackupJobs.firstOrNull;
                  final bool unavailable =
                      !localAvailable &&
                      !remoteAvailable &&
                      completedBackupJob == null;
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: index == pagination.items.length - 1 ? 0 : 10,
                    ),
                    child: _RecordingTile(
                      session: session,
                      backupJob: backupJob,
                      managing: _managing,
                      unavailable: unavailable,
                      sourceLabel: _recordingSourceLabel(item),
                      sourceIdentity: _recordingSourceIdentity(item),
                      localRecording: item.local != null && localAvailable,
                      backedUp:
                          (remoteAvailable &&
                              _isRemoteFromThisDevice(item.remote!)) ||
                          completedBackupJob != null,
                      localThumbnail:
                          localAvailable &&
                              session.watermarkStatus ==
                                  WatermarkProcessingStatus.completed
                          ? _localThumbnail(session.filePath)
                          : null,
                      remoteThumbnail: item.remote?.thumbnailUri,
                      remoteHeaders: widget.remotePlaybackHeaders,
                      selected: _selectedIds.contains(session.id),
                      onLongPress: () =>
                          _handleRecordingLongPress(item, session),
                      hideSourceChip: !hasOtherDeviceRecordings,
                      sourceChipOnSecondaryRow: _managing && item.local == null,
                      onTap: () async {
                        if (_managing) {
                          _toggleSelection(session.id);
                          return;
                        }
                        FocusManager.instance.primaryFocus?.unfocus();
                        final String? watermarkBlockMessage =
                            recordingWatermarkPlaybackBlockMessage(
                              session,
                              localAvailable:
                                  item.local != null && localAvailable,
                            );
                        if (watermarkBlockMessage != null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(watermarkBlockMessage)),
                          );
                          return;
                        }
                        if (unavailable) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('录像已清理或文件不存在，无法播放')),
                          );
                          return;
                        }
                        Uri? resolvedRemoteUri;
                        if (!localAvailable &&
                            remoteAvailable &&
                            item.remote != null) {
                          final Future<Uri?> Function(Uri remoteUri)? resolver =
                              widget.onResolveRemoteUri;
                          final Uri? currentRemoteUri = resolver == null
                              ? item.remote!.playUri
                              : await resolver(item.remote!.playUri);
                          if (!context.mounted) return;
                          if (currentRemoteUri == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('保存主机暂时离线，请稍后重试')),
                            );
                            return;
                          }
                          final VideoDecodeSupport? decodeSupport =
                              await SystemVideoPlayerService()
                                  .getVideoDecodeSupport();
                          resolvedRemoteUri =
                              RemotePlaybackCompat.resolvePlaybackUri(
                                currentRemoteUri,
                                decodeSupport: decodeSupport,
                                videoCodec: item.remote!.videoCodec,
                              );
                        }
                        if (!context.mounted) return;
                        final bool?
                        deleted = await Navigator.of(context).push<bool>(
                          MaterialPageRoute<bool>(
                            builder: (BuildContext context) =>
                                VideoPlaybackScreen(
                                  session: session,
                                  onSessionUpdated: _updateSession,
                                  onDelete: item.local == null
                                      ? null
                                      : () => widget.onDeleteSessions(<String>{
                                          item.local!.id,
                                        }),
                                  remoteUri: localAvailable
                                      ? null
                                      : remoteAvailable
                                      ? resolvedRemoteUri
                                      : null,
                                  remoteVideoId: localAvailable
                                      ? null
                                      : remoteAvailable
                                      ? item.remote?.id
                                      : null,
                                  remoteHeaders: widget.remotePlaybackHeaders,
                                  backedUpOffline: completedBackupJob != null,
                                  remoteClipService: localAvailable
                                      ? null
                                      : item.remote == null
                                      ? null
                                      : widget.remoteClipServiceFactory?.call(
                                          resolvedRemoteUri!,
                                        ),
                                  networkDiagnosticsLoader:
                                      widget.onNetworkDiagnostics,
                                ),
                          ),
                        );
                        if (deleted == true && mounted && item.local != null) {
                          final Set<int> hiddenIds = <int>{
                            if (item.remote != null) item.remote!.id,
                            if (backupJob?.remoteRecordId case final int id) id,
                          };
                          setState(() {
                            _hiddenRemoteIds.addAll(hiddenIds);
                            _sessions.removeWhere(
                              (RecordingSession value) =>
                                  value.id == item.local!.id,
                            );
                            _refreshLocalRecordingStats();
                          });
                          await widget.onHideRemoteRecordings?.call(hiddenIds);
                        }
                      },
                    ),
                  );
                }),
              if (pagination.pageCount > 1)
                _HistoryPagination(
                  currentPage: pagination.page,
                  pageCount: pagination.pageCount,
                  loading: _loadingRemote || _loadingLocal,
                  offline:
                      _backupSnapshot.connected &&
                      _backupSnapshot.connectionStatus !=
                          LanConnectionStatus.connected,
                  canLoadMore: pagination.page + 1 < pagination.pageCount,
                  onPrevious: pagination.page == 0
                      ? null
                      : () =>
                            setState(() => _historyPage = pagination.page - 1),
                  onNext: pagination.page + 1 < pagination.pageCount
                      ? () => _showNextHistoryPage(pagination.pageCount)
                      : null,
                  pageSize: _historyPageSize,
                  onPageSizeChanged: _setHistoryPageSize,
                ),
            ],
          ],
        ),
        bottomNavigationBar: _managing
            ? SafeArea(
                child: Container(
                  key: const Key('manage-bottom-bar'),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    border: Border(
                      top: BorderSide(color: colors.outlineVariant),
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          if (currentPageSessions.isNotEmpty)
                            OutlinedButton(
                              key: const Key('select-all-recordings-button'),
                              onPressed: () => _toggleSelectAllCurrentPage(
                                currentPageSessions,
                              ),
                              child: Text(
                                _selectedIds.containsAll(
                                      currentPageSessions.map(
                                        (RecordingSession item) => item.id,
                                      ),
                                    )
                                    ? '取消全选'
                                    : '全选本页',
                              ),
                            ),
                          const Spacer(),
                          FilledButton.tonalIcon(
                            key: const Key('finish-managing-button'),
                            onPressed: _toggleManaging,
                            // 全局 FilledButton 主题把最小宽度设为通栏
                            // Size.fromHeight(58)，在 Row 的无界宽度约束下会把
                            // 按钮撑成无限宽导致布局异常，这里显式收回宽度。
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(64, 58),
                            ),
                            icon: const Icon(Icons.check_rounded, size: 18),
                            label: const Text('完成'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: FilledButton.tonalIcon(
                              key: const Key('copy-selected-tracking-numbers'),
                              onPressed: _selectedIds.isEmpty
                                  ? null
                                  : _copySelectedTrackingNumbers,
                              icon: const Icon(Icons.copy_rounded),
                              label: const Text('复制单号'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              key: const Key('delete-selected-recordings'),
                              onPressed: _selectedIds.isEmpty
                                  ? null
                                  : _deleteSelected,
                              style: FilledButton.styleFrom(
                                backgroundColor: colors.error,
                                foregroundColor: colors.onError,
                              ),
                              icon: const Icon(Icons.delete_outline_rounded),
                              label: const Text('删除'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }

  @override
  void _refreshLocalRecordingStats() {
    final ({int bytes, Set<String> paths}) summary =
        _measureLocalRecordingStats(_sessions);
    _localRecordingBytes = summary.bytes;
    _localRecordingPaths = summary.paths;
  }

  List<RecordingSession> get _existingLocalSessions => _sessions
      .where(
        (RecordingSession session) =>
            session.filePath.isNotEmpty &&
            _localRecordingPaths.contains(session.filePath),
      )
      .toList(growable: false);

  static ({int bytes, Set<String> paths}) _measureLocalRecordingStats(
    Iterable<RecordingSession> sessions,
  ) {
    int total = 0;
    final Set<String> candidates = sessions
        .map((RecordingSession session) => session.filePath)
        .where((String path) => path.isNotEmpty)
        .toSet();
    final Set<String> existingPaths = <String>{};
    for (final String path in candidates) {
      try {
        final File file = File(path);
        if (file.existsSync()) {
          existingPaths.add(path);
          total += file.lengthSync();
        }
      } on FileSystemException {
        // A file may be removed by the retention worker while this page opens.
      }
    }
    return (bytes: total, paths: existingPaths);
  }

  bool _isJobConfirmedAvailable(LanBackupJob job) {
    final String currentComputerId = _backupSnapshot.endpoint?.computerId ?? '';
    if (currentComputerId.isEmpty ||
        job.destinationComputerId != currentComputerId) {
      return false;
    }
    return _isJobKnownAvailable(job);
  }

  bool _isRemoteFromThisDevice(RemoteRecording recording) {
    final String deviceId = _backupSnapshot.deviceId.trim();
    return deviceId.isNotEmpty && recording.sourceDeviceId == deviceId;
  }

  String _recordingSourceLabel(RecordingHistoryItem item) {
    final RemoteRecording? remote = item.remote;
    if (remote != null) {
      if (remote.sourceType.toLowerCase() != 'external') {
        final String computerName = remote.sourceDeviceName.trim();
        if (computerName.isNotEmpty) return computerName;
        final String pairedComputerName =
            _backupSnapshot.endpoint?.computerName.trim() ?? '';
        if (pairedComputerName.isNotEmpty) return pairedComputerName;
        return '电脑';
      }
      final String remoteName = remote.sourceDeviceName.trim();
      if (remoteName.isNotEmpty) return remoteName;
    }
    final String currentDeviceName = _backupSnapshot.deviceName.trim();
    if (item.local != null ||
        (remote != null && _isRemoteFromThisDevice(remote))) {
      return currentDeviceName.isEmpty ? '手机' : currentDeviceName;
    }
    return '手机';
  }

  String _recordingSourceIdentity(RecordingHistoryItem item) {
    final RemoteRecording? remote = item.remote;
    if (remote != null) {
      if (remote.sourceType.toLowerCase() != 'external') return 'computer';
      final String remoteDeviceId = remote.sourceDeviceId.trim();
      if (remoteDeviceId.isNotEmpty) return remoteDeviceId;
      final String remoteDeviceName = remote.sourceDeviceName.trim();
      if (remoteDeviceName.isNotEmpty) return remoteDeviceName;
    }
    final String currentDeviceId = _backupSnapshot.deviceId.trim();
    if (currentDeviceId.isNotEmpty) return currentDeviceId;
    final String currentDeviceName = _backupSnapshot.deviceName.trim();
    return currentDeviceName.isEmpty ? 'mobile' : currentDeviceName;
  }

  bool _isJobKnownAvailable(LanBackupJob job) {
    final int? remoteRecordId = job.remoteRecordId;
    if (job.state != LanBackupJobState.completed || remoteRecordId == null) {
      return false;
    }
    final status = _remoteStatuses[remoteRecordId];
    return status == null ||
        (status.status == RemoteRecordingStatus.available && status.exists);
  }
}

bool _sameSessionSnapshot(
  List<RecordingSession> first,
  List<RecordingSession> second,
) {
  if (identical(first, second)) return true;
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    final RecordingSession left = first[index];
    final RecordingSession right = second[index];
    if (left.id != right.id ||
        left.filePath != right.filePath ||
        left.startedAt != right.startedAt ||
        left.endedAt != right.endedAt ||
        left.mediaStart != right.mediaStart ||
        left.mediaEnd != right.mediaEnd) {
      return false;
    }
  }
  return true;
}
