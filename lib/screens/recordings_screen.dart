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
part 'recordings_order_receiver_settings.dart';

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

class _RecordingsScreenState extends State<RecordingsScreen> {
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
  late List<RecordingSession> _sessions;
  late int _localRecordingBytes;
  late Set<String> _localRecordingPaths;
  late LanBackupSnapshot _backupSnapshot;
  Map<String, List<LanBackupJob>> _backupJobsByPath =
      <String, List<LanBackupJob>>{};
  late final LanBackupHostDiscovery _backupHostDiscovery;
  late final bool _ownsBackupHostDiscovery;
  LanBackupDiscoverySnapshot _backupDiscoverySnapshot =
      const LanBackupDiscoverySnapshot();
  late UnbackedRetentionPolicy _unbackedRetention;
  late BackedRetentionPolicy _backedRetention;
  final List<RemoteRecording> _remoteRecordings = <RemoteRecording>[];
  final Map<int, List<RemoteRecording>> _remotePages =
      <int, List<RemoteRecording>>{};
  final Map<int, List<RecordingSession>> _localPages =
      <int, List<RecordingSession>>{};
  final Map<int, ({RemoteRecordingStatus status, bool exists, String reason})>
  _remoteStatuses = {};
  late Set<int> _hiddenRemoteIds;
  Timer? _remoteSearchTimer;
  bool _loadingRemote = false;
  bool _remoteCacheDirty = false;
  bool _manualRefreshing = false;
  DateTime? _lastManualRefreshAt;
  int _remoteTotal = 0;
  int _remoteDeviceTotal = 0;
  int _localTotal = 0;
  bool _loadingLocal = false;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Set<String> _selectedIds = <String>{};
  final Map<String, Future<String?>> _localThumbnailFutures =
      <String, Future<String?>>{};
  String _query = '';
  bool _managing = false;
  int _historyPage = 0;
  int _remoteRequestGeneration = 0;
  int _localRequestGeneration = 0;
  RecordingSourceFilter _sourceFilter = RecordingSourceFilter.all;
  RecordingHistoryDatePreset _datePreset = RecordingHistoryDatePreset.all;
  DateTimeRange? _customDateRange;
  bool _backupDiscoveryStarted = false;
  bool _autoConnectStarted = false;
  bool _approvalRequestInFlight = false;
  LanBackupDiscoveredHost? _lastApprovalHost;

  List<RecordingSession> get _filteredSessions =>
      filterRecordingSessionsByQuery(_sessions, _query);

  bool get _hasOtherDeviceRecordings => _visibleItems.any(
    (RecordingHistoryItem item) =>
        item.remote != null && !_isRemoteFromThisDevice(item.remote!),
  );

  bool get _maxVolumeSupported =>
      widget.capabilities?.supports(PlatformCapability.alertVolumeBoost) ??
      true;

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
    _backupSnapshot = widget.backupSnapshot;
    _backupJobsByPath = _buildBackupJobsByPath(_backupSnapshot);
    _ownsBackupHostDiscovery = widget.backupHostDiscovery == null;
    _backupHostDiscovery =
        widget.backupHostDiscovery ?? LanBackupHostDiscoveryService();
    _backupDiscoverySnapshot = _backupHostDiscovery.snapshot;
    _backupHostDiscovery.addListener(_refreshBackupDiscovery);
    _unbackedRetention = widget.unbackedRetention;
    _backedRetention = widget.backedRetention;
    _hiddenRemoteIds = Set<int>.of(widget.hiddenRemoteRecordingIds);
    _applyExternalSearch(widget.externalSearchQuery);
    if (_lanBackupSupported) {
      widget.backupListenable?.addListener(_refreshBackupSnapshot);
    }
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
    widget.backupListenable?.removeListener(_refreshBackupSnapshot);
    _backupHostDiscovery.removeListener(_refreshBackupDiscovery);
    _backupHostDiscovery.cancel();
    if (_ownsBackupHostDiscovery &&
        _backupHostDiscovery is LanBackupHostDiscoveryService) {
      _backupHostDiscovery.dispose();
    }
    _remoteSearchTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _refreshBackupDiscovery() {
    if (!mounted || !_lanBackupSupported) return;
    final LanBackupDiscoverySnapshot next = _backupHostDiscovery.snapshot;
    if (!_backupDiscoverySnapshot.searching && next.searching) {
      _autoConnectStarted = false;
    }
    setState(() => _backupDiscoverySnapshot = next);
    final List<LanBackupDiscoveredHost> reachableHosts = next.hosts
        .where(
          (LanBackupDiscoveredHost host) => host.compatible && host.reachable,
        )
        .toList(growable: false);
    final LanBackupDiscoveredHost? automaticHost = reachableHosts.length == 1
        ? reachableHosts.single
        : null;
    if (!next.searching &&
        automaticHost != null &&
        widget.active &&
        widget.mode == RecordingsScreenMode.history &&
        !_autoConnectStarted &&
        _backupSnapshot.endpoint == null &&
        widget.onConnectBackupHost != null) {
      _autoConnectStarted = true;
      unawaited(_connectDiscoveredHost(automaticHost));
    }
  }

  void _startBackupHostDiscoveryIfNeeded() {
    if (!mounted ||
        !_lanBackupSupported ||
        widget.backupHostDiscovery == null ||
        !widget.active ||
        widget.mode != RecordingsScreenMode.history ||
        _backupSnapshot.endpoint != null ||
        _backupDiscoveryStarted ||
        _backupDiscoverySnapshot.searching) {
      return;
    }
    _backupDiscoveryStarted = true;
    unawaited(_backupHostDiscovery.search());
  }

  Future<void> _connectDiscoveredHost(LanBackupDiscoveredHost host) async {
    if (!host.compatible) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(host.compatibilityMessage ?? '保存主机版本过低，请更新电脑端'),
          ),
        );
      }
      return;
    }
    final Future<void> Function(
      LanBackupDiscoveredHost host,
      LanBackupPairingConfirmation? replacementConfirmation,
    )?
    connect = widget.onConnectBackupHost;
    if (connect == null) return;
    _lastApprovalHost = host;
    _autoConnectStarted = true;
    _approvalRequestInFlight = true;
    if (mounted) {
      setState(() {
        _backupSnapshot = _backupSnapshot.copyWith(
          connectionStatus: LanConnectionStatus.awaitingApproval,
          message: '已向“${host.name}”发送连接申请，请在电脑上点击“允许连接”',
        );
      });
    }
    try {
      await connect(host, null);
      _refreshBackupSnapshot();
    } on LanBackupHostMismatchException catch (error) {
      if (!mounted) return;
      _refreshBackupSnapshot();
      final bool replace =
          await showDialog<bool>(
            context: context,
            builder: (BuildContext dialogContext) => AlertDialog(
              title: const Text('更换备份电脑？'),
              content: Text(
                '当前：${error.currentEndpoint.computerName}\n'
                '新的电脑：${error.candidateEndpoint.computerName}\n\n'
                '仍有待备份录像，确认后才会向新电脑申请连接',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('继续连接'),
                ),
              ],
            ),
          ) ??
          false;
      if (replace) await connect(host, error.confirmation);
    } on Object catch (error) {
      if (!mounted) return;
      _refreshBackupSnapshot();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyBackupConnectionError(error))),
      );
    } finally {
      _approvalRequestInFlight = false;
      if (mounted) _refreshBackupSnapshot();
    }
  }

  void _cancelBackupApproval() {
    _approvalRequestInFlight = false;
    widget.onCancelBackupPairing?.call();
  }

  void _refreshBackupSnapshot() {
    if (!mounted) {
      return;
    }
    LanBackupSnapshot next =
        widget.backupSnapshotProvider?.call() ?? widget.backupSnapshot;
    if (_approvalRequestInFlight &&
        (next.connectionStatus == LanConnectionStatus.disconnected ||
            next.connectionStatus == LanConnectionStatus.connecting)) {
      next = next.copyWith(
        connectionStatus: LanConnectionStatus.awaitingApproval,
        message: _backupSnapshot.message,
      );
    }
    final Set<String> previousCompleted = _completedBackupSignatures(
      _backupSnapshot,
    );
    final Set<String> nextCompleted = _completedBackupSignatures(next);
    final bool completedChanged = nextCompleted
        .difference(previousCompleted)
        .isNotEmpty;
    final Set<String> previousDeleted = _deletedLocalPaths(_backupSnapshot);
    final Set<String> nextDeleted = _deletedLocalPaths(next);
    final bool localCleanupChanged = nextDeleted
        .difference(previousDeleted)
        .isNotEmpty;
    final bool reconnected =
        _backupSnapshot.connectionStatus != LanConnectionStatus.connected &&
        next.connectionStatus == LanConnectionStatus.connected;
    final bool endpointChanged = !_sameBackupEndpoint(
      _backupSnapshot.endpoint,
      next.endpoint,
    );
    if (localCleanupChanged) {
      _refreshLocalRecordingStats();
    }
    _backupJobsByPath = _buildBackupJobsByPath(next);
    setState(() {
      _backupSnapshot = next;
      if (completedChanged) _remoteCacheDirty = true;
      if (next.connectionStatus != LanConnectionStatus.connected) {
        _remoteRequestGeneration++;
        _loadingRemote = false;
      }
      if (endpointChanged) {
        _remoteRecordings.clear();
        _remotePages.clear();
        _remoteTotal = 0;
        _remoteDeviceTotal = 0;
        _historyPage = 0;
      }
    });
    if (reconnected) {
      unawaited(_loadRemote(reset: true, pageNumber: 1, prefetchNext: true));
    } else if (completedChanged) {
      _reloadRemoteAfterBackup();
    } else if (widget.active &&
        _backupSnapshot.connectionStatus == LanConnectionStatus.connected &&
        _remoteRecordings.isEmpty) {
      unawaited(_loadRemote(reset: true, pageNumber: 1, prefetchNext: true));
    }
  }

  bool _sameBackupEndpoint(LanBackupEndpoint? left, LanBackupEndpoint? right) {
    if (left == null || right == null) {
      return left == null && right == null;
    }
    return left.computerId == right.computerId && left.baseUri == right.baseUri;
  }

  Map<String, List<LanBackupJob>> _buildBackupJobsByPath(
    LanBackupSnapshot snapshot,
  ) {
    final Map<String, List<LanBackupJob>> jobs = <String, List<LanBackupJob>>{};
    for (final LanBackupJob job in snapshot.jobs) {
      jobs
          .putIfAbsent(
            lanBackupFileIdentity(job.filePath),
            () => <LanBackupJob>[],
          )
          .add(job);
    }
    return jobs;
  }

  Set<String> _completedBackupSignatures(LanBackupSnapshot snapshot) => snapshot
      .jobs
      .where(
        (LanBackupJob job) =>
            job.state == LanBackupJobState.completed &&
            job.remoteRecordId != null,
      )
      .map(
        (LanBackupJob job) =>
            '${job.id}:${job.destinationComputerId}:${job.remoteRecordId}',
      )
      .toSet();

  Set<String> _deletedLocalPaths(LanBackupSnapshot snapshot) => snapshot.jobs
      .where((LanBackupJob job) => job.localDeletedAt != null)
      .map((LanBackupJob job) => lanBackupFileIdentity(job.filePath))
      .toSet();

  void _reloadRemoteAfterBackup({bool force = false}) {
    if ((!_remoteCacheDirty && !force) ||
        !mounted ||
        !widget.active ||
        _loadingRemote ||
        _backupSnapshot.connectionStatus != LanConnectionStatus.connected) {
      return;
    }
    _remoteCacheDirty = false;
    unawaited(_loadRemote(reset: true, pageNumber: 1, prefetchNext: true));
  }

  Future<void> _manualRefresh() async {
    final DateTime now = DateTime.now();
    if (_manualRefreshing ||
        (_lastManualRefreshAt != null &&
            now.difference(_lastManualRefreshAt!) <
                const Duration(milliseconds: 800))) {
      return;
    }
    _lastManualRefreshAt = now;
    setState(() => _manualRefreshing = true);
    try {
      await widget.onRefreshHistory?.call();
      if (!mounted) return;
      _localRequestGeneration++;
      _loadingLocal = false;
      await _loadLocal(reset: true, pageNumber: 1, prefetchNext: true);
      if (!mounted) return;
      _remoteRequestGeneration++;
      _loadingRemote = false;
      _remoteCacheDirty = false;
      if (_backupSnapshot.connectionStatus == LanConnectionStatus.connected) {
        await _loadRemote(reset: true, pageNumber: 1, prefetchNext: true);
      }
    } finally {
      if (mounted) setState(() => _manualRefreshing = false);
    }
  }

  Future<void> _loadLocal({
    bool reset = false,
    required int pageNumber,
    bool prefetchNext = false,
    bool preservePage = false,
  }) async {
    final callback = widget.onLoadLocalRecordings;
    if (callback == null || _loadingLocal || !widget.active) return;
    final int generation = ++_localRequestGeneration;
    setState(() {
      _loadingLocal = true;
      if (reset) {
        _localPages.clear();
        _sessions.clear();
        _localTotal = 0;
        if (!preservePage) _historyPage = 0;
      }
    });
    try {
      final LocalRecordingPage result = await callback(
        page: pageNumber,
        pageSize: _historyPageSize,
        keyword: _query,
        start: _activeDateWindow?.start,
        end: _activeDateWindow?.end,
      );
      if (!mounted || generation != _localRequestGeneration) return;
      setState(() {
        _localPages[result.page] = result.data;
        _localTotal = result.total;
        _rebuildLocalRecordings();
        _refreshLocalRecordingStats();
      });
      if (prefetchNext && result.page < result.pageCount) {
        await _loadLocalPageWithoutBusy(result.page + 1, generation);
      }
    } on Object {
      // Keep already loaded rows visible if the local database is unavailable.
    } finally {
      if (mounted && generation == _localRequestGeneration) {
        setState(() => _loadingLocal = false);
      }
    }
  }

  Future<void> _loadLocalPageWithoutBusy(int pageNumber, int generation) async {
    final callback = widget.onLoadLocalRecordings;
    if (callback == null || _localPages.containsKey(pageNumber)) return;
    final LocalRecordingPage page = await callback(
      page: pageNumber,
      pageSize: _historyPageSize,
      keyword: _query,
      start: _activeDateWindow?.start,
      end: _activeDateWindow?.end,
    );
    if (!mounted || generation != _localRequestGeneration) return;
    setState(() {
      _localPages[page.page] = page.data;
      _localTotal = page.total;
      _rebuildLocalRecordings();
      _refreshLocalRecordingStats();
    });
  }

  void _rebuildLocalRecordings() {
    _sessions
      ..clear()
      ..addAll(flattenRecordingHistoryPages(_localPages));
  }

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

  Future<void> _loadRemote({
    bool reset = false,
    required int pageNumber,
    bool prefetchNext = false,
  }) async {
    if (_loadingRemote ||
        !_lanBackupSupported ||
        !widget.active ||
        widget.onLoadRemoteRecordings == null ||
        _backupSnapshot.connectionStatus != LanConnectionStatus.connected) {
      return;
    }
    final int requestGeneration = ++_remoteRequestGeneration;
    setState(() {
      _loadingRemote = true;
      if (reset) {
        _remotePages.clear();
        _remoteRecordings.clear();
        _remoteTotal = 0;
        _remoteDeviceTotal = 0;
        _historyPage = 0;
      }
    });
    try {
      final RemoteRecordingPage result = await widget.onLoadRemoteRecordings!(
        page: pageNumber,
        pageSize: _historyPageSize,
        keyword: _query,
      );
      if (!mounted || requestGeneration != _remoteRequestGeneration) return;
      setState(() {
        _remotePages[result.page] = result.data;
        _remoteTotal = result.total;
        _remoteDeviceTotal = result.deviceTotal;
        _rebuildRemoteRecordings();
      });
      await _refreshRemoteStatuses(result.data);
      if (prefetchNext && result.hasMore && mounted) {
        await _loadRemotePageWithoutBusy(result.page + 1, requestGeneration);
      }
    } on Object {
      // Connection state is updated by the backup service; cached rows stay visible.
    } finally {
      if (mounted && requestGeneration == _remoteRequestGeneration) {
        setState(() => _loadingRemote = false);
        _reloadRemoteAfterBackup();
      }
    }
  }

  Future<void> _loadRemotePageWithoutBusy(
    int pageNumber,
    int requestGeneration,
  ) async {
    if (_remotePages.containsKey(pageNumber) ||
        !_lanBackupSupported ||
        widget.onLoadRemoteRecordings == null ||
        _backupSnapshot.connectionStatus != LanConnectionStatus.connected) {
      return;
    }
    final RemoteRecordingPage page = await widget.onLoadRemoteRecordings!(
      page: pageNumber,
      pageSize: _historyPageSize,
      keyword: _query,
    );
    if (!mounted || requestGeneration != _remoteRequestGeneration) return;
    setState(() {
      _remotePages[page.page] = page.data;
      _remoteTotal = page.total;
      _remoteDeviceTotal = page.deviceTotal;
      _rebuildRemoteRecordings();
    });
    await _refreshRemoteStatuses(page.data);
  }

  void _rebuildRemoteRecordings() {
    _remoteRecordings
      ..clear()
      ..addAll(flattenRecordingHistoryPages(_remotePages));
  }

  Future<void> _refreshRemoteStatuses(List<RemoteRecording> page) async {
    final callback = widget.onLoadRemoteRecordingStatuses;
    if (callback == null) return;
    final Set<int> ids = page.map((item) => item.id).toSet()
      ..addAll(
        _backupSnapshot.jobs
            .where(
              (job) =>
                  job.destinationComputerId ==
                  _backupSnapshot.endpoint?.computerId,
            )
            .map((job) => job.remoteRecordId)
            .whereType<int>(),
      );
    if (ids.isEmpty) return;
    try {
      final statuses = await callback(ids);
      if (!mounted || statuses.isEmpty) return;
      setState(() {
        _remoteStatuses.addAll(statuses);
        for (final int pageNumber in _remotePages.keys.toList()) {
          _remotePages[pageNumber] = _remotePages[pageNumber]!
              .map((RemoteRecording item) {
                final status = statuses[item.id];
                return status == null
                    ? item
                    : item.withStatus(
                        status: status.status,
                        exists: status.exists,
                        reason: status.reason,
                      );
              })
              .toList(growable: false);
        }
        _rebuildRemoteRecordings();
      });
    } on Object {
      // The page remains usable with the availability returned by /api/videos.
    }
  }

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

  Future<String?> _localThumbnail(String filePath) => _localThumbnailFutures
      .putIfAbsent(filePath, () => _thumbnailService.generate(filePath));

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
                      localThumbnail: localAvailable
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
                      : () => setState(
                          () => _historyPage = pagination.page - 1,
                        ),
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

class _RetentionSettings extends StatelessWidget {
  const _RetentionSettings({
    required this.unbackedRetention,
    required this.backedRetention,
    required this.onUnbackedRetentionChanged,
    required this.onBackedRetentionChanged,
  });

  final UnbackedRetentionPolicy unbackedRetention;
  final BackedRetentionPolicy backedRetention;
  final ValueChanged<UnbackedRetentionPolicy> onUnbackedRetentionChanged;
  final ValueChanged<BackedRetentionPolicy> onBackedRetentionChanged;

  static const String _retentionDescription =
      '保留策略：\n'
      '· 未备份录像超过“未备份保留”天数后会被清理；选“不清除”则一直保留。\n'
      '· 已备份录像超过“备份后保留”天数后会被清理；选“不清除”则一直保留。\n'
      '· 已备份录像清理前会向电脑确认，电脑离线时暂时保留。\n'
      '空间不足时：\n'
      '· 优先清理最老的、已完成电脑校验的备份录像；\n'
      '· 不会为腾出空间删除未备份录像。\n'
      '正在上传或等待备份的录像会延后清理';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text(
                '录像清理',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              IconButton(
                key: const Key('retention-info-button'),
                tooltip: '录像清理说明',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                iconSize: 20,
                icon: const Icon(Icons.help_outline_rounded),
                onPressed: () => _showRetentionInfo(context),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _RetentionDropdowns(
            unbackedRetention: unbackedRetention,
            backedRetention: backedRetention,
            onUnbackedRetentionChanged: onUnbackedRetentionChanged,
            onBackedRetentionChanged: onBackedRetentionChanged,
          ),
        ],
      ),
    );
  }

  Future<void> _showRetentionInfo(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('录像清理说明'),
        content: const Text(_retentionDescription),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class _RetentionDropdowns extends StatelessWidget {
  const _RetentionDropdowns({
    required this.unbackedRetention,
    required this.backedRetention,
    required this.onUnbackedRetentionChanged,
    required this.onBackedRetentionChanged,
  });

  final UnbackedRetentionPolicy unbackedRetention;
  final BackedRetentionPolicy backedRetention;
  final ValueChanged<UnbackedRetentionPolicy> onUnbackedRetentionChanged;
  final ValueChanged<BackedRetentionPolicy> onBackedRetentionChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<UnbackedRetentionPolicy>(
                key: const Key('unbacked-retention-dropdown'),
                initialValue: unbackedRetention,
                decoration: const InputDecoration(
                  labelText: '未备份保留',
                  isDense: true,
                ),
                items: UnbackedRetentionPolicy.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(value.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) onUnbackedRetentionChanged(value);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<BackedRetentionPolicy>(
                key: const Key('backed-retention-dropdown'),
                initialValue: backedRetention,
                decoration: const InputDecoration(
                  labelText: '备份后保留',
                  isDense: true,
                ),
                items: BackedRetentionPolicy.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(value.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) onBackedRetentionChanged(value);
                },
              ),
            ),
          ],
        ),
        if (unbackedRetention !=
            UnbackedRetentionPolicy.keepForever) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            '超过保留时间且仍未完成电脑备份的录像将从本机永久删除',
            style: TextStyle(color: colors.error, fontSize: 11, height: 1.4),
          ),
        ],
      ],
    );
  }
}


class _SettingsCard extends StatelessWidget {
  const _SettingsCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(children: children),
    );
  }
}

class _CameraCapabilitySettings extends StatelessWidget {
  const _CameraCapabilitySettings({
    required this.mode,
    required this.statusText,
    required this.onRetry,
  });

  final CameraCapabilityMode mode;
  final String statusText;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(Icons.videocam_outlined, color: colors.primary),
        title: const Text('摄像头能力'),
        subtitle: Text(statusText),
        trailing: TextButton(
          key: const Key('retry-camera-capability-button'),
          onPressed: onRetry,
          child: const Text('重新检测'),
        ),
      ),
    );
  }
}

class _WorkModeSettings extends StatelessWidget {
  const _WorkModeSettings({required this.workMode, required this.onChanged});

  final WorkMode workMode;
  final ValueChanged<WorkMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('work-mode-settings'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '工作模式',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<WorkMode>(
              showSelectedIcon: false,
              segments: WorkMode.values
                  .map(
                    (WorkMode mode) => ButtonSegment<WorkMode>(
                      value: mode,
                      label: Text(mode.label),
                    ),
                  )
                  .toList(growable: false),
              selected: <WorkMode>{workMode},
              onSelectionChanged: (Set<WorkMode> values) {
                onChanged(values.single);
              },
            ),
          ),
          const SizedBox(height: 12),
          Text(
            workMode.description,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoCodecSettings extends StatelessWidget {
  const _VideoCodecSettings({
    required this.codec,
    this.hevcWarning,
    required this.onChanged,
  });

  final RecordingVideoCodec codec;
  final String? hevcWarning;
  final ValueChanged<RecordingVideoCodec> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('video-codec-settings'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '录像编码',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<RecordingVideoCodec>(
              showSelectedIcon: false,
              segments: RecordingVideoCodec.values
                  .map(
                    (RecordingVideoCodec value) =>
                        ButtonSegment<RecordingVideoCodec>(
                          value: value,
                          label: Text(value.label),
                        ),
                  )
                  .toList(growable: false),
              selected: <RecordingVideoCodec>{codec},
              onSelectionChanged: (Set<RecordingVideoCodec> values) {
                onChanged(values.single);
              },
            ),
          ),
          const SizedBox(height: 12),
          Text(
            codec.description,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          if (hevcWarning != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              hevcWarning!,
              style: TextStyle(color: colors.error, fontSize: 13, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecordingSpecSettings extends StatelessWidget {
  const _RecordingSpecSettings({required this.spec, required this.onChanged});

  final RecordingSpecPreset spec;
  final ValueChanged<RecordingSpecPreset> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('recording-spec-settings'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '录像规格',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<RecordingSpecPreset>(
              showSelectedIcon: false,
              segments: RecordingSpecPreset.values
                  .map(
                    (RecordingSpecPreset value) =>
                        ButtonSegment<RecordingSpecPreset>(
                          value: value,
                          label: Text(value.label),
                        ),
                  )
                  .toList(growable: false),
              selected: <RecordingSpecPreset>{spec},
              onSelectionChanged: (Set<RecordingSpecPreset> values) {
                onChanged(values.single);
              },
            ),
          ),
          const SizedBox(height: 12),
          Text(
            spec.description,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordingOrientationSettings extends StatelessWidget {
  const _RecordingOrientationSettings({
    required this.orientation,
    required this.onChanged,
  });

  final RecordingOrientation orientation;
  final ValueChanged<RecordingOrientation> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('recording-orientation-settings'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '录像方向',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<RecordingOrientation>(
              showSelectedIcon: false,
              segments: RecordingOrientation.values
                  .map(
                    (value) => ButtonSegment<RecordingOrientation>(
                      value: value,
                      label: Text(value.label),
                    ),
                  )
                  .toList(growable: false),
              selected: <RecordingOrientation>{orientation},
              onSelectionChanged: (values) => onChanged(values.single),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '水印随录像变换，成片始终位于视觉右上角并保持正向可读',
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordAudioSettings extends StatelessWidget {
  const _RecordAudioSettings({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('record-audio-settings'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '录制声音',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                Text(
                  '关闭后录像不带声音',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            key: const Key('record-audio-enabled-switch'),
            value: enabled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _MinimumBarcodeLengthSettings extends StatelessWidget {
  const _MinimumBarcodeLengthSettings({
    required this.value,
    required this.onChanged,
  });

  static const List<int> _options = <int>[
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
  ];

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int current = _options.contains(value)
        ? value
        : _options.firstWhere(
            (int candidate) => candidate >= value,
            orElse: () => _options.last,
          );
    return Padding(
      key: const Key('minimum-barcode-length-settings'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '面单条码最短长度',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                Text(
                  '低于该长度不会触发录制',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<int>(
            key: const Key('minimum-barcode-length-dropdown'),
            value: current,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: _options
                .map(
                  (int length) => DropdownMenuItem<int>(
                    value: length,
                    child: Text('$length 位'),
                  ),
                )
                .toList(growable: false),
            onChanged: (int? length) {
              if (length != null) {
                onChanged(length);
              }
            },
          ),
        ],
      ),
    );
  }
}

class _SpeechPromptSettings extends StatelessWidget {
  const _SpeechPromptSettings({
    required this.enabled,
    required this.onChanged,
    required this.onPreview,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;
  final Future<void> Function() onPreview;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('speech-prompt-settings'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '语音提示',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 5),
                Text(
                  '离线自动使用系统语音',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('speech-preview-button'),
            onPressed: enabled ? onPreview : null,
            child: const Text('试听'),
          ),
          Switch(
            key: const Key('speech-enabled-switch'),
            value: enabled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _OrderSpeechSettings extends StatelessWidget {
  const _OrderSpeechSettings({
    required this.enabled,
    required this.masterEnabled,
    required this.onChanged,
  });

  final bool enabled;
  final bool masterEnabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('order-speech-settings'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '订单播报',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                Text(
                  masterEnabled ? '播报留言、备注和退款提醒' : '请先开启语音提示',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            key: const Key('order-speech-enabled-switch'),
            value: enabled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _MaxVolumeSettings extends StatelessWidget {
  const _MaxVolumeSettings({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('max-volume-settings'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '最大音量',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 5),
                Text(
                  '工作时自动提高媒体音量',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            key: const Key('max-volume-enabled-switch'),
            value: enabled,
            onChanged: onChanged,
          ),
        ],
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
