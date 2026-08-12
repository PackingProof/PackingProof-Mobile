import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_build_config.dart';
import '../controllers/packing_session_controller.dart';
import '../models/barcode_marker.dart';
import '../models/recording_operation_mode.dart';
import '../models/work_mode.dart';
import '../models/order_info.dart';
import '../models/storage_notice.dart';
import '../models/lan_backup.dart';
import '../services/preview_cover_transform.dart';
import '../services/lan_backup_discovery_service.dart';
import '../services/lan_backup_host_file_cache.dart';
import '../services/session_repository.dart';
import '../services/speech_prompt_service.dart';
import '../widgets/order_info_sheet.dart';
import 'recordings_screen.dart';

@visibleForTesting
bool shouldSuspendPackingSession(AppLifecycleState state) {
  return state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;
}

enum PackingBackAction {
  cancelPairing,
  cancelHistoryScan,
  keepWorking,
  showHome,
  armExit,
  exitApp,
}

@visibleForTesting
PackingBackAction resolvePackingBackAction({
  required bool pairingActive,
  required bool pairingMessageVisible,
  required bool historyScanActive,
  required bool workInProgress,
  required int selectedTab,
  required DateTime now,
  DateTime? exitArmedAt,
}) {
  if (pairingActive || pairingMessageVisible) {
    return PackingBackAction.cancelPairing;
  }
  if (historyScanActive) return PackingBackAction.cancelHistoryScan;
  if (workInProgress) return PackingBackAction.keepWorking;
  if (selectedTab != 1) return PackingBackAction.showHome;
  if (exitArmedAt != null) {
    final Duration elapsed = now.difference(exitArmedAt);
    if (!elapsed.isNegative && elapsed <= const Duration(seconds: 2)) {
      return PackingBackAction.exitApp;
    }
  }
  return PackingBackAction.armExit;
}

@visibleForTesting
bool shouldBlockTabSwitch({
  required bool workInProgress,
  required bool busy,
  required int from,
  required int to,
}) => (workInProgress || busy) && to != 1;

@visibleForTesting
bool shouldHideMainBottomNavigation({
  required bool pairingScanActive,
  required bool working,
}) => pairingScanActive || working;

@visibleForTesting
Future<void> showComputerPairingFailureDialog(
  BuildContext context,
  String message,
) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('连接电脑失败'),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

@visibleForTesting
Future<bool> showComputerReplacementDialog(
  BuildContext context,
  ComputerReplacementPrompt prompt,
) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('更换备份电脑？'),
          content: Text(
            '当前：${prompt.currentComputer}\n新的电脑：${prompt.newComputer}\n\n更换后，后续录像将备份到新的电脑',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('继续绑定'),
            ),
          ],
        ),
      ) ??
      false;
}

const String mobileAppDownloadUrl =
    'https://gitee.com/PackingProof/PackingProof-Mobile/releases/latest';

@visibleForTesting
Future<void> showMobileAppUpdateNotice(
  BuildContext context,
  MobileAppUpdateNotice notice, {
  Future<bool> Function(Uri uri)? openUrl,
}) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentMaterialBanner();
  final ScaffoldFeatureController<MaterialBanner, MaterialBannerClosedReason>
  controller = messenger.showMaterialBanner(
    MaterialBanner(
      leading: const Icon(Icons.system_update_rounded),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            '手机 App 更新',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            notice.message.isEmpty
                ? '当前 APP 版本过低，需要更新\n'
                      '电脑端要求使用 ${notice.minimumVersion} 或更高版本\n'
                      '暂不更新时仍可继续识别面单和录像'
                : notice.updateRequired
                ? '${notice.message}\n最低兼容版本：${notice.minimumVersion}\n'
                      '暂不更新时仍可继续识别面单和录像'
                : '${notice.message}\n最新版本：${notice.latestVersion}\n'
                      '暂不更新时仍可继续识别面单和录像',
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: messenger.hideCurrentMaterialBanner,
          child: const Text('稍后'),
        ),
        TextButton(
          onPressed: () {
            messenger.hideCurrentMaterialBanner();
            final Uri uri = Uri.parse(mobileAppDownloadUrl);
            unawaited(
              (openUrl ??
                      (Uri value) => launchUrl(
                        value,
                        mode: LaunchMode.externalApplication,
                      ))
                  .call(uri),
            );
          },
          child: const Text('打开下载页面'),
        ),
      ],
    ),
  );
  return controller.closed.then<void>((_) {});
}

class PackingHomeScreen extends StatefulWidget {
  const PackingHomeScreen({
    this.repository,
    this.buildConfig = AppBuildConfig.environment,
    super.key,
  });

  final SessionRepository? repository;
  final AppBuildConfig buildConfig;

  @override
  State<PackingHomeScreen> createState() => _PackingHomeScreenState();
}

class _PackingHomeScreenState extends State<PackingHomeScreen>
    with WidgetsBindingObserver {
  late final PackingSessionController _controller;
  late final LanBackupHostDiscoveryService _backupHostDiscovery;
  int _selectedTab = 1;
  String _historySearchQuery = '';
  bool _historyManaging = false;
  int _handledPairingSuccessRevision = 0;
  int _handledPairingFailureRevision = 0;
  int _handledPairingReplacementRevision = 0;
  String _handledMobileUpdateSignature = '';
  bool _mobileUpdateNoticeScheduled = false;
  int _handledStorageNoticeRevision = 0;
  int _transientReturnTab = 1;
  DateTime? _exitArmedAt;
  Timer? _watermarkClock;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = PackingSessionController(
      repository: widget.repository,
      speechService: SpeechPromptService(),
    );
    _backupHostDiscovery = LanBackupHostDiscoveryService(
      cache: LanBackupHostFileCache(),
    );
    _watermarkClock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _selectedTab == 1) setState(() {});
    });
    unawaited(_controller.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_resumeSession());
    } else if (shouldSuspendPackingSession(state)) {
      unawaited(_controller.handleInactive());
    }
  }

  Future<void> _resumeSession() async {
    await _controller.handleResumed();
    await _controller.setPreviewActive(_selectedTab == 1);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _watermarkClock?.cancel();
    _controller.dispose();
    _backupHostDiscovery.dispose();
    super.dispose();
  }

  Future<void> _toggleWork() async {
    _resetExitIntent();
    if (_controller.isWorking) {
      await _controller.stopWork();
      return;
    }
    await _controller.startWork();
  }

  void _selectTab(int value) {
    if (shouldBlockTabSwitch(
      workInProgress: _controller.isWorking,
      busy: _controller.isBusy,
      from: _selectedTab,
      to: value,
    )) {
      _resetExitIntent();
      _showBackMessage('工作进行中，请先结束工作');
      return;
    }
    _resetExitIntent();
    setState(() => _selectedTab = value);
    unawaited(_controller.setPreviewActive(value == 1));
    if (value == 0) unawaited(_controller.refreshSessions());
  }

  void _beginComputerPairing() {
    _resetExitIntent();
    setState(() {
      _transientReturnTab = _selectedTab;
      _selectedTab = 1;
    });
    unawaited(_controller.setPreviewActive(true));
    _controller.beginComputerPairing();
  }

  void _beginHistorySearchScan() {
    _resetExitIntent();
    setState(() {
      _transientReturnTab = _selectedTab;
      _selectedTab = 1;
    });
    unawaited(_controller.setPreviewActive(true));
    _controller.beginHistoryBarcodeScan();
  }

  void _cancelComputerPairingAndReturn() {
    _controller.cancelComputerPairing();
    _returnFromTransientScan();
  }

  void _cancelHistoryScanAndReturn() {
    _controller.cancelHistoryBarcodeScan();
    _returnFromTransientScan();
  }

  void _returnFromTransientScan() {
    final int targetTab = _transientReturnTab;
    _resetExitIntent();
    setState(() {
      _selectedTab = targetTab;
      _transientReturnTab = 1;
    });
    unawaited(_controller.setPreviewActive(targetTab == 1));
    if (targetTab == 0) unawaited(_controller.refreshSessions());
  }

  Future<void> _returnToHistoryAndShowPairingFailure(String message) async {
    setState(() {
      _selectedTab = 0;
      _transientReturnTab = 1;
    });
    _resetExitIntent();
    await _controller.setPreviewActive(false);
    await _controller.refreshSessions();
    if (!mounted) return;
    await showComputerPairingFailureDialog(context, message);
  }

  Future<void> _returnToHistoryAndConfirmComputerReplacement(
    ComputerReplacementPrompt prompt,
  ) async {
    setState(() {
      _selectedTab = 0;
      _transientReturnTab = 1;
    });
    _resetExitIntent();
    await _controller.setPreviewActive(false);
    await _controller.refreshSessions();
    if (!mounted) return;
    final bool confirmed = await showComputerReplacementDialog(context, prompt);
    if (!mounted) return;
    if (confirmed) {
      await _controller.confirmPendingComputerReplacement();
    } else {
      _controller.cancelPendingComputerReplacement();
    }
  }

  void _resetExitIntent() {
    _exitArmedAt = null;
  }

  void _showBackMessage(String message) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  void _handleSystemBack() {
    if (_historyManaging) {
      return;
    }
    final DateTime now = DateTime.now();
    final PackingBackAction action = resolvePackingBackAction(
      pairingActive: _controller.pairingScanActive,
      pairingMessageVisible:
          _controller.pairingMessage != null && _transientReturnTab != 1,
      historyScanActive: _controller.historyScanActive,
      workInProgress:
          _controller.isWorking ||
          _controller.phase == PackingSessionPhase.starting ||
          _controller.phase == PackingSessionPhase.saving,
      selectedTab: _selectedTab,
      now: now,
      exitArmedAt: _exitArmedAt,
    );
    switch (action) {
      case PackingBackAction.cancelPairing:
        _cancelComputerPairingAndReturn();
        return;
      case PackingBackAction.cancelHistoryScan:
        _cancelHistoryScanAndReturn();
        return;
      case PackingBackAction.keepWorking:
        _resetExitIntent();
        _showBackMessage('工作进行中，请先结束工作');
        return;
      case PackingBackAction.showHome:
        _selectTab(1);
        return;
      case PackingBackAction.armExit:
        _exitArmedAt = now;
        _showBackMessage('再按一次返回退出应用');
        return;
      case PackingBackAction.exitApp:
        _resetExitIntent();
        unawaited(SystemNavigator.pop());
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, Widget? child) {
        final int pairingSuccessRevision = _controller.pairingSuccessRevision;
        if (pairingSuccessRevision > _handledPairingSuccessRevision) {
          _handledPairingSuccessRevision = pairingSuccessRevision;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _selectedTab = 0;
              _transientReturnTab = 1;
            });
            _resetExitIntent();
            unawaited(_controller.setPreviewActive(false));
          });
        }
        final int pairingFailureRevision = _controller.pairingFailureRevision;
        if (pairingFailureRevision > _handledPairingFailureRevision) {
          _handledPairingFailureRevision = pairingFailureRevision;
          final String? message = _controller.takePairingFailureForDisplay();
          if (message != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              unawaited(_returnToHistoryAndShowPairingFailure(message));
            });
          }
        }
        final int pairingReplacementRevision =
            _controller.pairingReplacementRevision;
        if (pairingReplacementRevision > _handledPairingReplacementRevision) {
          _handledPairingReplacementRevision = pairingReplacementRevision;
          final ComputerReplacementPrompt? prompt = _controller
              .takeComputerReplacementPrompt();
          if (prompt != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              unawaited(_returnToHistoryAndConfirmComputerReplacement(prompt));
            });
          }
        }
        final int storageNoticeRevision = _controller.storageNoticeRevision;
        if (storageNoticeRevision > _handledStorageNoticeRevision) {
          _handledStorageNoticeRevision = storageNoticeRevision;
          final StorageNotice? notice = _controller
              .takeStorageNoticeForDisplay();
          if (notice != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _controller.isWorking) return;
              unawaited(_showStorageNotice(notice));
            });
          }
        }
        final MobileAppUpdateNotice? mobileAppUpdate =
            _controller.backupSnapshot.mobileAppUpdate;
        if (mobileAppUpdate != null &&
            mobileAppUpdate.signature != _handledMobileUpdateSignature &&
            !_mobileUpdateNoticeScheduled) {
          _mobileUpdateNoticeScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            unawaited(
              _controller
                  .reserveMobileUpdatePrompt()
                  .then<void>((bool allowed) async {
                    if (!context.mounted || !allowed) return;
                    _handledMobileUpdateSignature = mobileAppUpdate.signature;
                    await showMobileAppUpdateNotice(context, mobileAppUpdate);
                  })
                  .whenComplete(() => _mobileUpdateNoticeScheduled = false),
            );
          });
        }
        final String? scanned = _controller.historyScanResult;
        if (scanned != null) {
          _controller.clearHistoryScanResult();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _historySearchQuery = scanned;
              _selectedTab = 0;
              _transientReturnTab = 1;
            });
            _resetExitIntent();
          });
        }
        return PopScope<Object?>(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (!didPop) _handleSystemBack();
          },
          child: Scaffold(
            body: IndexedStack(
              index: _selectedTab,
              children: <Widget>[
                _buildRecordingsScreen(RecordingsScreenMode.history),
                PackingHomeView(
                  cameraController: _controller.cameraController,
                  nativeTextureId: _controller.nativeTextureId,
                  nativePreviewSize: _controller.nativePreviewSize,
                  phase: _controller.phase,
                  elapsed: _controller.elapsed,
                  lastMarker: _controller.lastMarker,
                  candidateCode: _controller.candidateCode,
                  currentCode: _controller.currentCode,
                  orderInfo: _controller.activeOrderInfo,
                  workMode: _controller.workMode,
                  operationMode: _controller.operationMode,
                  errorMessage: _controller.errorMessage,
                  scanWarningMessage: _controller.scanWarningMessage,
                  rejectedBarcodeMessage: _controller.rejectedBarcodeMessage,
                  pairingScanActive: _controller.pairingScanActive,
                  pairingMessage: _controller.pairingMessage,
                  historyScanActive: _controller.historyScanActive,
                  flashAvailable: _controller.flashAvailable,
                  torchEnabled: _controller.torchEnabled,
                  cameraSwitchAvailable: _controller.cameraSwitchAvailable,
                  frontCameraActive: _controller.frontCameraActive,
                  onPairingCancel: _cancelComputerPairingAndReturn,
                  onHistoryScanCancel: _cancelHistoryScanAndReturn,
                  onTorchPressed: _controller.toggleTorch,
                  onCameraSwitchPressed: _controller.switchCamera,
                  onOperationModeChanged: _controller.setOperationMode,
                  onPrimaryPressed: _toggleWork,
                  onRetryPressed: _controller.retryInitialize,
                ),
                _buildRecordingsScreen(RecordingsScreenMode.settings),
              ],
            ),
            bottomNavigationBar:
                shouldHideMainBottomNavigation(
                  pairingScanActive: _controller.pairingScanActive,
                  working: _controller.isWorking,
                )
                ? null
                : _PackingBottomNavigation(
                    selectedIndex: _selectedTab,
                    onSelected: _selectTab,
                  ),
          ),
        );
      },
    );
  }

  Future<void> _showStorageNotice(StorageNotice notice) => showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('手机存储空间提醒'),
      content: Text(notice.message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  Widget _buildRecordingsScreen(RecordingsScreenMode mode) {
    return RecordingsScreen(
      mode: mode,
      embedded: true,
      active: mode == RecordingsScreenMode.history
          ? _selectedTab == 0
          : _selectedTab == 2,
      focusBackupRevision: mode == RecordingsScreenMode.history
          ? _controller.pairingSuccessRevision
          : 0,
      externalSearchQuery: mode == RecordingsScreenMode.history
          ? _historySearchQuery
          : '',
      sessions: _controller.sessions,
      workMode: _controller.workMode,
      speechEnabled: _controller.speechEnabled,
      orderSpeechEnabled: _controller.orderSpeechEnabled,
      orderReceiverSnapshot: _controller.orderReceiverSnapshot,
      maxVolumeEnabled: _controller.maxVolumeEnabled,
      recordAudioEnabled: _controller.recordAudioEnabled,
      preferredVideoCodec: _controller.preferredVideoCodec,
      recordingSpec: _controller.recordingSpec,
      minimumBarcodeLength: _controller.minimumBarcodeLength,
      historyPageSize: _controller.historyPageSize,
      unbackedRetention: _controller.unbackedRetention,
      backedRetention: _controller.backedRetention,
      backupSnapshot: _controller.backupSnapshot,
      backupListenable: _controller,
      backupSnapshotProvider: () => _controller.backupSnapshot,
      onWorkModeChanged: _controller.setWorkMode,
      onSpeechEnabledChanged: _controller.setSpeechEnabled,
      onOrderSpeechEnabledChanged: _controller.setOrderSpeechEnabled,
      onRetryOrderReceiver: _controller.retryOrderReceiver,
      onMaxVolumeEnabledChanged: _controller.setMaxVolumeEnabled,
      onRecordAudioEnabledChanged: _controller.setRecordAudioEnabled,
      onPreferredVideoCodecChanged: _controller.setPreferredVideoCodec,
      onRecordingSpecChanged: _controller.setRecordingSpec,
      onMinimumBarcodeLengthChanged: _controller.setMinimumBarcodeLength,
      onHistoryPageSizeChanged: _controller.setHistoryPageSize,
      onAutoBackupChanged: _controller.setLanBackupAutoEnabled,
      onBackupRetentionChanged: _controller.setBackupRetention,
      onBackupNow: _controller.backupAllSessions,
      onDisconnectBackup: _controller.disconnectBackup,
      onRetryConnection: _controller.retryBackupConnection,
      onRetryBackup: _controller.retryBackup,
      onRefreshHistory: _controller.refreshSessions,
      onManagingChanged: (bool managing) {
        if (mounted) setState(() => _historyManaging = managing);
      },
      onLoadRemoteRecordings: _controller.fetchRemoteRecordings,
      onLoadLocalRecordings: _controller.loadLocalRecordings,
      onLoadRemoteRecordingStatuses: _controller.fetchRemoteRecordingStatuses,
      remotePlaybackHeaders: _controller.remotePlaybackHeaders,
      remoteClipServiceFactory: _controller.createRemoteVideoClipService,
      onNetworkDiagnostics: _controller.fetchNetworkDiagnostics,
      onConnectComputer: _beginComputerPairing,
      onCancelBackupPairing: _controller.cancelComputerPairing,
      onConnectBackupHost: (host, confirmation) =>
          _controller.connectBackupHost(
            host.baseUri,
            replacementConfirmation: confirmation,
          ),
      backupHostDiscovery: _backupHostDiscovery,
      onScanSearch: _beginHistorySearchScan,
      onSpeechPreview: _controller.previewSpeech,
      onSessionUpdated: _controller.updateSession,
      onDeleteSessions: _controller.deleteSessions,
      hiddenRemoteRecordingIds: _controller.hiddenRemoteRecordingIds,
      onHideRemoteRecordings: _controller.hideRemoteRecordings,
    );
  }
}

class _PackingBottomNavigation extends StatelessWidget {
  const _PackingBottomNavigation({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return NavigationBar(
      key: const Key('main-bottom-navigation'),
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelected,
      height: 72,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: <NavigationDestination>[
        const NavigationDestination(
          icon: Icon(Icons.history_rounded),
          selectedIcon: Icon(Icons.history_rounded),
          label: '历史',
        ),
        NavigationDestination(
          icon: CircleAvatar(
            radius: 22,
            backgroundColor: colors.secondaryContainer,
            child: Icon(
              Icons.videocam_rounded,
              color: colors.onSecondaryContainer,
            ),
          ),
          selectedIcon: CircleAvatar(
            radius: 22,
            backgroundColor: colors.primary,
            child: Icon(Icons.videocam_rounded, color: colors.onPrimary),
          ),
          label: '录制',
        ),
        const NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings_rounded),
          label: '设置',
        ),
      ],
    );
  }
}

class PackingHomeView extends StatelessWidget {
  const PackingHomeView({
    required this.phase,
    required this.elapsed,
    required this.onPrimaryPressed,
    required this.onRetryPressed,
    this.cameraController,
    this.nativeTextureId,
    this.nativePreviewSize,
    this.lastMarker,
    this.candidateCode = '',
    this.currentCode = '',
    this.orderInfo,
    this.workMode = WorkMode.continuousScan,
    this.operationMode = RecordingOperationMode.shipping,
    this.errorMessage,
    this.scanWarningMessage,
    this.rejectedBarcodeMessage,
    this.pairingScanActive = false,
    this.pairingMessage,
    this.historyScanActive = false,
    this.flashAvailable = false,
    this.torchEnabled = false,
    this.cameraSwitchAvailable = false,
    this.frontCameraActive = false,
    this.onPairingCancel,
    this.onHistoryScanCancel,
    this.onTorchPressed,
    this.onCameraSwitchPressed,
    this.onOperationModeChanged,
    this.previewOverride,
    this.watermarkTimestamp,
    super.key,
  });

  final CameraController? cameraController;
  final int? nativeTextureId;
  final Size? nativePreviewSize;
  final PackingSessionPhase phase;
  final Duration elapsed;
  final BarcodeMarker? lastMarker;
  final String candidateCode;
  final String currentCode;
  final OrderInfo? orderInfo;
  final WorkMode workMode;
  final RecordingOperationMode operationMode;
  final String? errorMessage;
  final String? scanWarningMessage;
  final String? rejectedBarcodeMessage;
  final bool pairingScanActive;
  final String? pairingMessage;
  final bool historyScanActive;
  final bool flashAvailable;
  final bool torchEnabled;
  final bool cameraSwitchAvailable;
  final bool frontCameraActive;
  final VoidCallback? onPairingCancel;
  final VoidCallback? onHistoryScanCancel;
  final VoidCallback? onTorchPressed;
  final VoidCallback? onCameraSwitchPressed;
  final ValueChanged<RecordingOperationMode>? onOperationModeChanged;
  final VoidCallback onPrimaryPressed;
  final VoidCallback onRetryPressed;
  final Widget? previewOverride;
  final DateTime? watermarkTimestamp;

  static const double workingBottomGap = 40;

  bool get _isRecording => phase == PackingSessionPhase.recording;
  bool get _isWorking =>
      phase == PackingSessionPhase.waitingForBarcode ||
      phase == PackingSessionPhase.starting ||
      phase == PackingSessionPhase.recording ||
      phase == PackingSessionPhase.saving;
  bool get _isBusy =>
      phase == PackingSessionPhase.initializing ||
      phase == PackingSessionPhase.starting ||
      phase == PackingSessionPhase.saving;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double bottomInset = MediaQuery.paddingOf(context).bottom;
            final double bottomGap = _isWorking
                ? PackingHomeView.workingBottomGap
                : 0;
            final double minimumPanelHeight = _isWorking
                ? (constraints.maxHeight * 0.14).clamp(112.0, 122.0)
                : (constraints.maxHeight * 0.18).clamp(136.0, 156.0);
            final double previewAspectRatio = _portraitPreviewAspectRatio;
            final double cameraHeight =
                (constraints.maxWidth / previewAspectRatio).clamp(
                  0.0,
                  constraints.maxHeight,
                );
            final double panelTop =
                constraints.maxHeight -
                bottomInset -
                bottomGap -
                minimumPanelHeight;
            final double panelHeight = minimumPanelHeight;
            final double cameraPanelOverlap = (cameraHeight - panelTop).clamp(
              0.0,
              cameraHeight,
            );
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Positioned(
                  key: const Key('camera-preview-viewport'),
                  left: 0,
                  right: 0,
                  top: 0,
                  height: cameraHeight,
                  child: _CameraArea(this, bottomOcclusion: cameraPanelOverlap),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: bottomInset + bottomGap),
                    child: _ControlPanel(view: this, height: panelHeight),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  double get _portraitPreviewAspectRatio {
    final Size? sourceSize =
        nativePreviewSize ??
        (cameraController?.value.isInitialized == true
            ? cameraController?.value.previewSize
            : null);
    if (sourceSize == null || sourceSize.width <= 0 || sourceSize.height <= 0) {
      return 9 / 16;
    }
    return sourceSize.width <= sourceSize.height
        ? sourceSize.width / sourceSize.height
        : sourceSize.height / sourceSize.width;
  }
}

class _CameraArea extends StatelessWidget {
  const _CameraArea(this.view, {required this.bottomOcclusion});

  final PackingHomeView view;
  final double bottomOcclusion;

  @override
  Widget build(BuildContext context) {
    final double lowerOverlayInset = bottomOcclusion + 18;
    Widget preview;
    final CameraController? camera = view.cameraController;
    if (view.previewOverride != null) {
      preview = view.previewOverride!;
    } else if (view.nativeTextureId != null && view.nativePreviewSize != null) {
      preview = NativeCameraPreviewCover(
        textureId: view.nativeTextureId!,
        sourceSize: view.nativePreviewSize!,
      );
    } else if (camera?.value.isInitialized == true) {
      preview = CameraPreviewCover(
        controller: camera!,
        mirrored: view.frontCameraActive,
      );
    } else {
      preview = Center(
        child: Image.asset(
          'assets/images/app-icon.png',
          key: const Key('camera-loading-app-icon'),
          width: 96,
          height: 96,
          fit: BoxFit.contain,
        ),
      );
    }

    return ColoredBox(
      key: const Key('camera-preview-backing'),
      color: Theme.of(context).colorScheme.surface,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(child: preview),
          Positioned(
            key: const Key('camera-watermark-position'),
            top: view._isRecording ? 68 : 22,
            right: view.flashAvailable ? 72 : 18,
            child: _CameraWatermarkPreview(
              timestamp: view.watermarkTimestamp ?? DateTime.now(),
              trackingNumber: view.currentCode,
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            top: 64,
            bottom: lowerOverlayInset + 2,
            child: const SizedBox(
              key: Key('scan-guide'),
              child: CustomPaint(painter: _ScanGuidePainter()),
            ),
          ),
          if (!view.pairingScanActive && !view.historyScanActive)
            Positioned(
              left: 0,
              right: 0,
              bottom: lowerOverlayInset,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: _OperationModePills(
                  mode: view.operationMode,
                  working: view._isWorking,
                  enabled: !view._isBusy,
                  onChanged: view.onOperationModeChanged,
                ),
              ),
            ),
          if (view._isRecording)
            Positioned(
              left: 0,
              right: 0,
              top: 20,
              child: Align(
                alignment: Alignment.topCenter,
                child: _RecordingDurationPill(elapsed: view.elapsed),
              ),
            ),
          if (view.scanWarningMessage != null)
            Positioned(
              left: 18,
              right: 18,
              bottom: lowerOverlayInset + 54,
              child: _ScanWarningToast(message: view.scanWarningMessage!),
            )
          else if (view.lastMarker != null)
            Positioned(
              left: 20,
              right: 20,
              bottom: lowerOverlayInset + 54,
              child: _RecognitionToast(marker: view.lastMarker!),
            )
          else if (view.candidateCode.isNotEmpty)
            Positioned(
              left: 20,
              right: 20,
              bottom: lowerOverlayInset + 54,
              child: Text(
                '正在确认 · ${view.candidateCode}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  shadows: <Shadow>[
                    Shadow(color: Color(0x88000000), blurRadius: 8),
                  ],
                ),
              ),
            ),
          if (view.rejectedBarcodeMessage != null)
            Positioned(
              left: 18,
              right: 18,
              bottom: lowerOverlayInset + 118,
              child: Align(
                alignment: Alignment.bottomRight,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: _ScanWarningToast(
                    key: const Key('rejected-barcode-toast'),
                    message: view.rejectedBarcodeMessage!,
                  ),
                ),
              ),
            ),
          if (view.pairingScanActive || view.pairingMessage != null)
            Positioned(
              left: 20,
              right: 20,
              top: 88,
              child: _ComputerPairingBanner(
                message: view.pairingMessage ?? '扫描电脑二维码',
                onCancel: view.onPairingCancel,
              ),
            ),
          if (view.historyScanActive)
            Positioned(
              left: 20,
              right: 20,
              top: 24,
              child: _ComputerPairingBanner(
                message: '对准条码，识别后自动筛选历史记录',
                onCancel: view.onHistoryScanCancel,
              ),
            ),
          if (view.flashAvailable &&
              !view.pairingScanActive &&
              !view.historyScanActive)
            Positioned(
              right: 18,
              top: 20,
              child: Material(
                color: const Color(0x99000000),
                shape: const CircleBorder(),
                child: IconButton(
                  key: const Key('torch-button'),
                  tooltip: view.torchEnabled ? '关闭闪光灯' : '打开闪光灯',
                  onPressed: view.onTorchPressed,
                  color: view.torchEnabled
                      ? const Color(0xFFFFD54F)
                      : Colors.white,
                  icon: Icon(
                    view.torchEnabled
                        ? Icons.flash_on_rounded
                        : Icons.flash_off_rounded,
                  ),
                ),
              ),
            ),
          if (view.cameraSwitchAvailable &&
              !view._isWorking &&
              !view._isBusy &&
              !view.pairingScanActive &&
              !view.historyScanActive)
            Positioned(
              left: 18,
              top: 20,
              child: Material(
                color: const Color(0x99000000),
                shape: const CircleBorder(),
                child: IconButton(
                  key: const Key('switch-camera-button'),
                  tooltip: view.frontCameraActive ? '切换到后置摄像头' : '切换到前置摄像头',
                  onPressed: view.onCameraSwitchPressed,
                  color: Colors.white,
                  icon: const Icon(Icons.cameraswitch_rounded),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _OperationModePills extends StatelessWidget {
  const _OperationModePills({
    required this.mode,
    required this.working,
    required this.enabled,
    required this.onChanged,
  });

  final RecordingOperationMode mode;
  final bool working;
  final bool enabled;
  final ValueChanged<RecordingOperationMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    final List<RecordingOperationMode> modes = working
        ? <RecordingOperationMode>[mode]
        : RecordingOperationMode.values;
    return Semantics(
      container: true,
      label: '当前${mode.label}模式',
      child: Material(
        key: const Key('recording-operation-mode-pills'),
        color: const Color(0xB3000000),
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: modes
              .map(
                (RecordingOperationMode value) => _OperationModePill(
                  mode: value,
                  selected: value == mode,
                  enabled: enabled && !working && onChanged != null,
                  onPressed: () => onChanged?.call(value),
                ),
              )
              .toList(growable: false),
        ),
      ),
    );
  }
}

class _OperationModePill extends StatelessWidget {
  const _OperationModePill({
    required this.mode,
    required this.selected,
    required this.enabled,
    required this.onPressed,
  });

  final RecordingOperationMode mode;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bool returning = mode == RecordingOperationMode.returnGoods;
    final Color accent = returning
        ? const Color(0xFFFFA726)
        : const Color(0xFF42A5F5);
    return InkWell(
      key: Key('operation-mode-${mode.storageValue}-pill'),
      onTap: enabled ? onPressed : null,
      child: Ink(
        color: selected ? accent : Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 96, minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  returning
                      ? Icons.keyboard_return_rounded
                      : Icons.local_shipping_rounded,
                  size: 18,
                  color: Colors.white,
                ),
                const SizedBox(width: 7),
                Text(
                  mode.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CameraWatermarkPreview extends StatelessWidget {
  const _CameraWatermarkPreview({
    required this.timestamp,
    required this.trackingNumber,
  });

  final DateTime timestamp;
  final String trackingNumber;

  @override
  Widget build(BuildContext context) {
    final String text = <String>[
      _watermarkTimestamp(timestamp),
      if (trackingNumber.isNotEmpty) 'Order:$trackingNumber',
    ].join('\n');
    const TextStyle baseStyle = TextStyle(
      fontSize: 12,
      height: 1.25,
      fontWeight: FontWeight.w700,
    );

    return Semantics(
      label: '录像水印',
      child: SizedBox(
        key: const Key('camera-watermark-preview'),
        width: 250,
        child: Stack(
          alignment: Alignment.topRight,
          children: <Widget>[
            Text(
              text,
              key: const Key('camera-watermark-outline'),
              textAlign: TextAlign.right,
              style: baseStyle.copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 3
                  ..strokeJoin = StrokeJoin.round
                  ..color = Colors.black,
              ),
            ),
            Text(
              text,
              key: const Key('camera-watermark-fill'),
              textAlign: TextAlign.right,
              style: baseStyle.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComputerPairingBanner extends StatelessWidget {
  const _ComputerPairingBanner({required this.message, this.onCancel});

  final String message;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onCancel == null
          ? const Color(0xF0087454)
          : const Color(0xE6000000),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: <Widget>[
            const Icon(Icons.qr_code_scanner_rounded, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (onCancel != null)
              TextButton(
                onPressed: onCancel,
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('取消'),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecordingDurationPill extends StatelessWidget {
  const _RecordingDurationPill({required this.elapsed});

  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('recording-duration-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xB8000000),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Color(0xFFFF453A),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _duration(elapsed),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class NativeCameraPreviewCover extends StatelessWidget {
  const NativeCameraPreviewCover({
    required this.textureId,
    required this.sourceSize,
    super.key,
  });

  final int textureId;
  final Size sourceSize;

  @override
  Widget build(BuildContext context) {
    final Widget viewport = RepaintBoundary(
      child: _PreviewCoverViewport(
        sourceSize: sourceSize,
        previewKey: const Key('native-camera-preview-natural-size'),
        child: Texture(textureId: textureId, filterQuality: FilterQuality.low),
      ),
    );
    return Transform(
      key: const Key('native-camera-preview-mirror'),
      alignment: Alignment.center,
      // Camera2 already mirrors the front preview stream on Android. Applying
      // another Flutter transform would turn it back into a non-mirrored view.
      transform: Matrix4.identity(),
      child: viewport,
    );
  }
}

class _ScanGuidePainter extends CustomPainter {
  const _ScanGuidePainter();

  @override
  void paint(Canvas canvas, Size size) {
    const double inset = 1;
    const double cornerLength = 28;
    final Paint paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.92)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final Path path = Path()
      ..moveTo(inset, inset + cornerLength)
      ..lineTo(inset, inset)
      ..lineTo(inset + cornerLength, inset)
      ..moveTo(size.width - inset - cornerLength, inset)
      ..lineTo(size.width - inset, inset)
      ..lineTo(size.width - inset, inset + cornerLength)
      ..moveTo(size.width - inset, size.height - inset - cornerLength)
      ..lineTo(size.width - inset, size.height - inset)
      ..lineTo(size.width - inset - cornerLength, size.height - inset)
      ..moveTo(inset + cornerLength, size.height - inset)
      ..lineTo(inset, size.height - inset)
      ..lineTo(inset, size.height - inset - cornerLength);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ScanGuidePainter oldDelegate) => false;
}

class CameraPreviewCover extends StatelessWidget {
  const CameraPreviewCover({
    required this.controller,
    this.mirrored = false,
    super.key,
  });

  final CameraController controller;
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    return Transform(
      key: const Key('flutter-camera-preview-mirror'),
      alignment: Alignment.center,
      transform: mirrored ? Matrix4.rotationY(math.pi) : Matrix4.identity(),
      child: CameraPreviewCoverLayout(
        cameraValue: controller,
        preview: controller.buildPreview(),
      ),
    );
  }
}

class CameraPreviewCoverLayout extends StatelessWidget {
  const CameraPreviewCoverLayout({
    required this.cameraValue,
    required this.preview,
    super.key,
  });

  final ValueListenable<CameraValue> cameraValue;
  final Widget preview;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CameraValue>(
      valueListenable: cameraValue,
      builder: (BuildContext context, CameraValue value, Widget? child) {
        if (!value.isInitialized || value.previewSize == null) {
          return const SizedBox.expand();
        }

        final Size previewSize = value.previewSize!;
        final Size portraitSize = previewSize.width > previewSize.height
            ? Size(previewSize.height, previewSize.width)
            : previewSize;
        return _PreviewCoverViewport(
          sourceSize: portraitSize,
          previewKey: const Key('camera-preview-natural-size'),
          child: child!,
        );
      },
      child: preview,
    );
  }
}

class _PreviewCoverViewport extends StatelessWidget {
  const _PreviewCoverViewport({
    required this.sourceSize,
    required this.previewKey,
    required this.child,
  });

  final Size sourceSize;
  final Key previewKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final PreviewCoverTransform transform = PreviewCoverTransform.contain(
          sourceSize: sourceSize,
          canvasSize: Size(constraints.maxWidth, constraints.maxHeight),
        );
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: <Widget>[
              Positioned.fromRect(
                rect: transform.sourceDestinationRect,
                child: SizedBox(key: previewKey, child: child),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RecognitionToast extends StatelessWidget {
  const _RecognitionToast({required this.marker});

  final BarcodeMarker marker;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xEB087454),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.check_circle_rounded, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '已识别面单，当前录像已绑定',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  marker.code,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFD8F3E9),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanWarningToast extends StatelessWidget {
  const _ScanWarningToast({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('scan-warning-toast'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xEBB3261E),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x44000000),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.warning_amber_rounded, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlPanel extends StatelessWidget {
  const _ControlPanel({required this.view, required this.height});

  final PackingHomeView view;
  final double height;

  @override
  Widget build(BuildContext context) {
    final bool isError = view.phase == PackingSessionPhase.error;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color secondaryText = colors.brightness == Brightness.dark
        ? colors.onSurfaceVariant
        : const Color(0xFF767D7A);
    return PhysicalShape(
      key: const Key('recording-control-panel'),
      clipper: const _ShallowUpwardArcClipper(),
      color: colors.surface.withValues(alpha: 0.66),
      shadowColor: const Color(0x44000000),
      elevation: 10,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            view._isWorking ? 10 : 17,
            24,
            view._isWorking ? 6 : 8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (view._isWorking) ...<Widget>[
                Text(
                  view.currentCode.isEmpty ? '等待面单' : view.currentCode,
                  key: const Key('current-shipping-code'),
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 1),
                GestureDetector(
                  key: const Key('active-order-summary'),
                  onTap: view.orderInfo == null
                      ? null
                      : () => showOrderInfoSheet(context, view.orderInfo!),
                  child: Text(
                    view.orderInfo?.summary ?? _recordingHint(view),
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: view.orderInfo?.hasRefundWarning == true
                          ? colors.error
                          : secondaryText,
                      fontSize: 12,
                      height: 1.25,
                      fontWeight: view.orderInfo == null
                          ? FontWeight.normal
                          : FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
              ] else ...<Widget>[
                Text(
                  view.historyScanActive
                      ? '扫描条码以搜索历史记录'
                      : view.pairingScanActive
                      ? '正在连接电脑'
                      : isError
                      ? (view.errorMessage ?? '请重新检查摄像头权限')
                      : '对准面单条码',
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: secondaryText,
                    fontSize: 14,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              _PrimaryWorkButton(view: view, isError: isError),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShallowUpwardArcClipper extends CustomClipper<Path> {
  const _ShallowUpwardArcClipper();

  @override
  Path getClip(Size size) => Path()
    ..moveTo(0, 12)
    ..cubicTo(size.width * 0.24, 12, size.width * 0.34, 0, size.width * 0.5, 0)
    ..cubicTo(size.width * 0.66, 0, size.width * 0.76, 12, size.width, 12)
    ..lineTo(size.width, size.height)
    ..lineTo(0, size.height)
    ..close();

  @override
  bool shouldReclip(_ShallowUpwardArcClipper oldClipper) => false;
}

class _PrimaryWorkButton extends StatefulWidget {
  const _PrimaryWorkButton({required this.view, required this.isError});

  final PackingHomeView view;
  final bool isError;

  @override
  State<_PrimaryWorkButton> createState() => _PrimaryWorkButtonState();
}

class _PrimaryWorkButtonState extends State<_PrimaryWorkButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _syncShimmer();
  }

  @override
  void didUpdateWidget(_PrimaryWorkButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.view._isWorking != widget.view._isWorking) {
      _syncShimmer();
    }
  }

  void _syncShimmer() {
    if (widget.view._isWorking) {
      _shimmerController.repeat();
    } else {
      _shimmerController.stop();
      _shimmerController.value = 0;
    }
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PackingHomeView view = widget.view;
    return FilledButton(
      key: const Key('primary-work-button'),
      onPressed:
          view._isBusy || view.pairingScanActive || view.historyScanActive
          ? null
          : widget.isError
          ? view.onRetryPressed
          : view.onPrimaryPressed,
      style: view._isWorking
          ? FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD92D20),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(54),
            )
          : null,
      child: SizedBox(
        width: double.infinity,
        height: 24,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: <Widget>[
            if (view._isWorking)
              Positioned(
                key: const Key('recording-button-shimmer'),
                left: -24,
                right: -24,
                top: -17,
                bottom: -17,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: AnimatedBuilder(
                    animation: _shimmerController,
                    builder: (BuildContext context, Widget? child) {
                      return CustomPaint(
                        painter: _RecordingButtonShimmerPainter(
                          Curves.easeInOutQuad.transform(
                            _shimmerController.value,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (view._isBusy)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2.4,
                    ),
                  )
                else
                  Icon(
                    widget.isError
                        ? Icons.refresh_rounded
                        : view._isWorking
                        ? Icons.stop_circle_outlined
                        : Icons.videocam_outlined,
                  ),
                const SizedBox(width: 8),
                Text(
                  view.phase == PackingSessionPhase.initializing
                      ? '正在准备摄像头'
                      : view.phase == PackingSessionPhase.starting
                      ? '正在启动录像'
                      : view.phase == PackingSessionPhase.saving
                      ? '正在保存录像'
                      : widget.isError
                      ? '重新检查'
                      : view._isWorking
                      ? '结束工作'
                      : '开始工作',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingButtonShimmerPainter extends CustomPainter {
  const _RecordingButtonShimmerPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final double bandWidth = size.width * 0.55;
    final double left = -bandWidth + progress * (size.width + bandWidth * 2);
    final Rect band = Rect.fromLTWH(left, 0, bandWidth, size.height);
    final Paint paint = Paint()
      ..shader = const LinearGradient(
        colors: <Color>[
          Colors.transparent,
          Color(0x10FFFFFF),
          Color(0x78FFFFFF),
          Color(0x10FFFFFF),
          Colors.transparent,
        ],
        stops: <double>[0, 0.3, 0.5, 0.7, 1],
      ).createShader(band);
    canvas.drawRect(band, paint);
  }

  @override
  bool shouldRepaint(_RecordingButtonShimmerPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

String _recordingHint(PackingHomeView view) {
  if (view.currentCode.isEmpty) {
    return '识别面单后自动开始录像';
  }
  return switch (view.workMode) {
    WorkMode.continuousScan => '扫描下一张面单自动分段',
    WorkMode.sameCodeStop => '再次扫描相同面单后结束',
  };
}

String _duration(Duration value) {
  String two(int number) => number.toString().padLeft(2, '0');
  final int hours = value.inHours;
  final int minutes = value.inMinutes.remainder(60);
  final int seconds = value.inSeconds.remainder(60);
  return hours > 0
      ? '${two(hours)}:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

String _watermarkTimestamp(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}/${two(value.month)}/${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}
