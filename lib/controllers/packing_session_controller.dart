// ignore_for_file: annotate_overrides

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app/app_build_config.dart';
import '../models/barcode_marker.dart';
import '../models/app_settings.dart';
import '../models/backup_retention_policy.dart';
import '../models/lan_backup.dart';
import '../models/recording_session.dart';
import '../models/order_info.dart';
import '../models/recording_operation_mode.dart';
import '../models/recording_spec.dart';
import '../models/recording_video_codec.dart';
import '../models/recording_orientation.dart';
import '../models/speech_prompt.dart';
import '../models/storage_notice.dart';
import '../models/work_mode.dart';
import '../platform/platform_capabilities.dart';
import '../platform/platform_container.dart';
import '../services/barcode_candidate_policy.dart';
import '../services/barcode_recognized_beep_policy.dart';
import '../services/barcode_stability_tracker.dart';
import '../services/barcode_work_mode_policy.dart';
import '../services/camera_diagnostics_service.dart';
import '../services/camera_capability_policy.dart';
import '../services/camera_lens_policy.dart';
import '../services/continuous_camera_service.dart';
import '../services/diagnostics_log_service.dart';
import '../services/initial_recording_prompt_policy.dart';
import '../services/lan_backup_service.dart';
import '../services/max_volume_service.dart';
import '../services/order_info_receiver_service.dart';
import '../services/rejected_barcode_policy.dart';
import '../services/remote_video_clip_service.dart';
import '../services/nv21_center_crop.dart';
import '../services/recording_timeline.dart';
import '../services/recording_database.dart';
import '../services/session_repository.dart';
import '../services/speech_prompt_service.dart';
import '../services/jd_barcode_policy.dart';
import '../services/video_watermark_service.dart';

part 'packing_session_app_support.dart';
part 'packing_session_backup_coordinator.dart';
part 'packing_session_barcode_coordinator.dart';
part 'packing_session_camera_coordinator.dart';
part 'packing_session_order_coordinator.dart';
part 'packing_session_pairing_coordinator.dart';
part 'packing_session_settings_coordinator.dart';
part 'packing_session_storage_coordinator.dart';
part 'packing_session_watermark_coordinator.dart';
part 'packing_session_watermark_helpers.dart';

enum PackingSessionPhase {
  initializing,
  ready,
  waitingForBarcode,
  starting,
  recording,
  saving,
  error,
}

class PackingSessionController extends ChangeNotifier
    with
        _PackingSessionAppSupport,
        _PackingSessionBackupCoordinator,
        _PackingSessionStorageCoordinator,
        _PackingSessionWatermarkCoordinator,
        _PackingSessionBarcodeCoordinator,
        _PackingSessionOrderCoordinator,
        _PackingSessionPairingCoordinator,
        _PackingSessionSettingsCoordinator,
        _PackingSessionCameraCoordinator {
  PackingSessionController({
    SessionRepository? repository,
    SpeechPromptSink? speechService,
    MaxVolumeSink? maxVolumeService,
    LanBackupSink? lanBackupService,
    VideoWatermarkSink? videoWatermarkService,
    OrderInfoReceiverSink? orderInfoReceiver,
    DiagnosticsLogService? runtimeLog,
    CameraDiagnosticsService? cameraDiagnostics,
    PlatformCapabilities? capabilities,
    ContinuousCameraService? cameraService,
    ContinuousCameraService Function()? cameraServiceFactory,
    Future<PackageInfo> Function()? packageInfoLoader,
    // Named parameters cannot use a private initializing formal.
    // ignore: prefer_initializing_formals
    AppBuildConfig buildConfig = AppBuildConfig.environment,
  }) : _repository =
           repository ??
           SessionRepository(
             availableRecordingStorageBytes: AppContainer.forCurrentPlatform()
                 .backup
                 .availableRecordingStorageBytes,
           ),
       _speechService = speechService ?? SpeechPromptService(),
       _maxVolumeService = maxVolumeService ?? MaxVolumeService(),
       _videoWatermarkService =
           videoWatermarkService ?? VideoWatermarkService(),
       _orderInfoReceiver = orderInfoReceiver ?? OrderInfoReceiverService(),
       _capabilities =
           capabilities ?? AppContainer.forCurrentPlatform().capabilities,
       _nativeCamera = cameraService,
       _cameraServiceFactory =
           cameraServiceFactory ?? ContinuousCameraService.new,
       _packageInfoLoader = packageInfoLoader ?? PackageInfo.fromPlatform,
       // ignore: prefer_initializing_formals
       _buildConfig = buildConfig,
       _barcodeScanner = BarcodeScanner(
         formats: const <BarcodeFormat>[BarcodeFormat.all],
       ) {
    _runtimeLog =
        runtimeLog ??
        DiagnosticsLogService(runtimeMetadataLoader: _loadRuntimeMetadata);
    _cameraDiagnostics = cameraDiagnostics ?? CameraDiagnosticsService();
    _lanBackupService =
        lanBackupService ??
        LanBackupService(
          platform: AppContainer.forCurrentPlatform().backup,
          logEvent: (String kind, Map<String, Object?> extra) =>
              _runtimeLog.log(kind: kind, extra: extra),
        );
  }

  static const Duration analysisInterval = Duration(milliseconds: 200);
  static const Duration transitionSettleDelay = Duration(milliseconds: 120);
  static const Duration initialModeAnnouncementDelay = Duration(
    milliseconds: 250,
  );
  static const Duration _shutdownOperationTimeout = Duration(milliseconds: 400);
  static const int recordingFps = 30;

  @override
  Duration get _analysisInterval => analysisInterval;

  @override
  final SessionRepository _repository;
  @override
  final SpeechPromptSink _speechService;
  final MaxVolumeSink _maxVolumeService;
  @override
  late final LanBackupSink _lanBackupService;
  @override
  final VideoWatermarkSink _videoWatermarkService;
  final PlatformCapabilities _capabilities;
  @override
  final OrderInfoReceiverSink _orderInfoReceiver;
  @override
  final BarcodeScanner _barcodeScanner;
  final Future<PackageInfo> Function() _packageInfoLoader;
  final AppBuildConfig _buildConfig;
  @override
  final RecordingTimeline _timeline = RecordingTimeline();
  final InitialRecordingPromptPolicy _initialPromptPolicy =
      InitialRecordingPromptPolicy();
  @override
  late final CameraDiagnosticsService _cameraDiagnostics;
  @override
  late final DiagnosticsLogService _runtimeLog;
  Future<Map<String, Object?>>? _runtimeMetadataFuture;
  Future<void> _previewStateTail = Future<void>.value();
  int _pendingPreviewTransitions = 0;
  final Set<Future<void>> _backgroundTasks = <Future<void>>{};
  Future<void>? _shutdownFuture;
  bool _shutdownAbandonedStop = false;
  PlatformCapabilities get capabilities => _capabilities;

  @override
  CameraController? _cameraController;
  @override
  ContinuousCameraService? _nativeCamera;
  @override
  final ContinuousCameraService Function() _cameraServiceFactory;
  @override
  ContinuousCameraInitialization? _nativeInitialization;
  @override
  PackingSessionPhase _phase = PackingSessionPhase.initializing;
  // 条码候选和相机状态会频繁通知首页；仅在内容变化时复制不可变快照，
  // 避免每次通知都为两个离屏录像页重新分配集合。
  List<RecordingSession> _sessionItems = <RecordingSession>[];
  List<RecordingSession> _sessionSnapshot = const <RecordingSession>[];
  LocalRecordingStatistics _localRecordingStatistics =
      const LocalRecordingStatistics();
  Timer? _elapsedTimer;
  Timer? _feedbackTimer;
  Timer? _rejectedBarcodeTimer;
  Timer? _initialPromptTimer;
  Duration _elapsed = Duration.zero;
  final ValueNotifier<Duration> _elapsedListenable = ValueNotifier<Duration>(
    Duration.zero,
  );
  BarcodeMarker? _lastMarker;
  @override
  UnbackedRetentionPolicy _unbackedRetention = UnbackedRetentionPolicy.days30;
  @override
  BackedRetentionPolicy _backedRetention = BackedRetentionPolicy.days7;
  @override
  UnbackedRetentionPolicy _returnUnbackedRetention =
      UnbackedRetentionPolicy.days3;
  @override
  BackedRetentionPolicy _returnBackedRetention = BackedRetentionPolicy.days1;
  bool _appIsActive = true;
  @override
  String? _errorMessage;
  @override
  String? _cameraNotice;
  String? _rejectedBarcodeMessage;
  @override
  bool _disposed = false;
  bool _backupListenerAttached = false;
  bool _backgroundServicesInitialized = false;
  String? _recordingId;
  String? _activeSegmentId;
  int _segmentIndex = 1;
  bool _torchEnabled = false;
  bool _workActive = false;
  int _operationGeneration = 0;
  Set<int> _hiddenRemoteRecordingIdItems = <int>{};
  Set<int> _hiddenRemoteRecordingIdSnapshot = const <int>{};

  @override
  List<RecordingSession> get _sessions => _sessionItems;

  @override
  set _sessions(List<RecordingSession> value) {
    _sessionItems = value;
    _sessionSnapshot = List<RecordingSession>.unmodifiable(value);
  }

  Set<int> get _hiddenRemoteRecordingIds => _hiddenRemoteRecordingIdItems;

  @override
  set _hiddenRemoteRecordingIds(Set<int> value) {
    _hiddenRemoteRecordingIdItems = value;
    _hiddenRemoteRecordingIdSnapshot = Set<int>.unmodifiable(value);
  }

  LanBackupSnapshot get backupSnapshot => _lanBackupService.snapshot;
  bool get historyScanActive => _historyScanActive;
  bool get flashAvailable => _supportsNativeCamera
      ? _nativeInitialization?.flashAvailable == true
      : _cameraController?.value.isInitialized == true;
  bool get torchEnabled => _torchEnabled;
  bool get cameraSwitchAvailable =>
      _supportsNativeCamera &&
      _nativeInitialization?.canSwitchCamera == true &&
      !_pairingScanActive &&
      !_historyScanActive;
  List<NativeCameraLens> get backCameraLenses => _backCameraLenses;
  bool get multiBackCameraAvailable => _backCameraLenses.length >= 2;
  @override
  bool get _supportsNativeCamera =>
      _capabilities.supports(PlatformCapability.continuousCameraRecording);
  @override
  bool get _supportsCameraCapabilityNegotiation =>
      _capabilities.supports(PlatformCapability.cameraCapabilityNegotiation);
  String? get activeCameraId => _nativeInitialization?.cameraId;
  bool get frontCameraActive =>
      _supportsNativeCamera && _nativeInitialization?.isFrontCamera == true;
  String? get historyScanResult => _historyScanResult;
  String? get errorMessage => _errorMessage;

  /// 探测完成后的一次性能力说明（取走即消费）。
  String? takeCapabilityNoticeForDisplay() {
    final String? message = _capabilityNoticeMessage;
    _capabilityNoticeMessage = null;
    return message;
  }

  String? get scanWarningMessage =>
      _storageWarningMessage ?? _scanWarningMessage;
  String? get cameraNotice => _cameraNotice;
  String? get rejectedBarcodeMessage => _rejectedBarcodeMessage;
  int get storageNoticeRevision => _storageNoticeRevision;
  @override
  bool get isRecording => _phase == PackingSessionPhase.recording;
  @override
  bool get isWorking => _workActive;
  RecordingOperationMode get operationMode => _operationMode;
  Set<int> get hiddenRemoteRecordingIds => _hiddenRemoteRecordingIdSnapshot;
  @override
  bool get isBusy =>
      _phase == PackingSessionPhase.initializing ||
      _phase == PackingSessionPhase.starting ||
      _phase == PackingSessionPhase.saving;
  @override
  bool get isCameraReady =>
      (_supportsNativeCamera
          ? _nativeInitialization != null
          : _cameraController?.value.isInitialized == true) &&
      _phase != PackingSessionPhase.error;

  @override
  Future<void> _initializeBackgroundServices(AppSettings settings) async {
    if (_disposed || _backgroundServicesInitialized) return;
    try {
      await _logAppUpgradeIfNeeded(settings);
    } on Object {
      // Runtime metadata is diagnostic and must not delay camera availability.
    }
    await _resumePendingWatermarks();
    if (_capabilities.supports(PlatformCapability.lanBackup)) {
      if (!_backupListenerAttached) {
        _lanBackupService.addListener(_handleBackupChanged);
        _backupListenerAttached = true;
      }
      try {
        await _lanBackupService
            .initialize(
              autoEnabled: settings.lanBackupAutoEnabled,
              unbackedRetention: settings.unbackedRetention,
              backedRetention: settings.backedRetention,
              returnUnbackedRetention: settings.returnUnbackedRetention,
              returnBackedRetention: settings.returnBackedRetention,
            )
            .timeout(const Duration(seconds: 8));
      } on Object catch (error) {
        // 备份服务初始化失败不影响摄像头；记录原因，服务侧看门狗会自愈重试。
        unawaited(
          _runtimeLog.log(
            kind: 'backup_service_init_failed',
            extra: <String, Object?>{'error': error.toString()},
          ),
        );
      }
      if (_disposed) return;
      try {
        await _drainCleanupEvents();
      } on Object {
        // Local history remains available even when optional cleanup cannot run.
      }
      if (_lanBackupService.snapshot.autoEnabled) {
        _scheduleAutomaticBackupBootstrap('app_start');
      } else {
        _runInBackground(_registerRepositorySessionsForRetention());
      }
    }
    if (_capabilities.supports(PlatformCapability.orderInfoReceiver)) {
      await _initializeOrderReceiverBinding();
    }
    _backgroundServicesInitialized = true;
    if (!_disposed) notifyListeners();
  }

  Future<void> toggleTorch() async {
    if (!flashAvailable || isBusy) return;
    final bool enabled = !_torchEnabled;
    try {
      if (_supportsNativeCamera) {
        final bool ok = await _nativeCamera!.setTorchEnabled(enabled);
        if (enabled && !ok) {
          // 硬件拒绝点亮：_torchEnabled 本来就是 false，提示后保持关闭。
          _showCameraNotice('闪光灯暂时不可用');
          if (!_disposed) notifyListeners();
          return;
        }
      } else {
        await _cameraController!.setFlashMode(
          enabled ? FlashMode.torch : FlashMode.off,
        );
      }
      // 原生关闭接口返回 false 是正常状态，成功后一律以请求值更新 UI。
      _torchEnabled = enabled;
      notifyListeners();
    } on Object {
      _torchEnabled = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> switchCamera() async {
    if (!cameraSwitchAvailable || isBusy || isWorking) return;
    final Stopwatch stopwatch = Stopwatch()..start();
    bool usedFallback = false;
    try {
      if (_torchEnabled) {
        await _nativeCamera!.setTorchEnabled(false);
        _torchEnabled = false;
      }
      _errorMessage = null;
      _setPhase(PackingSessionPhase.initializing);
      _nativeInitialization = await _nativeCamera!.switchCamera();
      await _refreshBackCameraLenses();
      await _resolveCameraCapability();
      if (_phase == PackingSessionPhase.error) return;
      _setPhase(PackingSessionPhase.ready);
      unawaited(_captureCameraDiagnosticsSnapshot('switch_camera'));
    } on Object {
      usedFallback = true;
      await _disposeCamera();
      await initialize();
      if (!_disposed) {
        _errorMessage = '摄像头切换失败，已恢复后置摄像头';
        notifyListeners();
      }
    } finally {
      stopwatch.stop();
      unawaited(
        _runtimeLog.log(
          kind: 'camera_switch_timing',
          extra: <String, Object?>{
            'target': 'oppositeFacing',
            'cameraId': activeCameraId,
            'durationMs': stopwatch.elapsedMilliseconds,
            'usedFallback': usedFallback,
            'ready': isCameraReady,
          },
        ),
      );
    }
  }

  Future<void> switchToCamera(String cameraId) async {
    final ContinuousCameraService? nativeCamera = _nativeCamera;
    if (nativeCamera == null ||
        isBusy ||
        isWorking ||
        !_backCameraLenses.any(
          (NativeCameraLens lens) => lens.cameraId == cameraId,
        )) {
      return;
    }
    final Stopwatch stopwatch = Stopwatch()..start();
    bool usedFallback = false;
    try {
      if (_torchEnabled) {
        await nativeCamera.setTorchEnabled(false);
        _torchEnabled = false;
      }
      _errorMessage = null;
      _setPhase(PackingSessionPhase.initializing);
      _nativeInitialization = await nativeCamera.switchToCamera(cameraId);
      await _refreshBackCameraLenses();
      await _resolveCameraCapability();
      if (_phase == PackingSessionPhase.error) return;
      _setPhase(PackingSessionPhase.ready);
      unawaited(_captureCameraDiagnosticsSnapshot('switch_lens'));
    } on Object {
      usedFallback = true;
      await _disposeCamera();
      await initialize();
      if (!_disposed) {
        _errorMessage = '摄像头切换失败，已恢复默认后置摄像头';
        notifyListeners();
      }
    } finally {
      stopwatch.stop();
      unawaited(
        _runtimeLog.log(
          kind: 'camera_switch_timing',
          extra: <String, Object?>{
            'target': 'cameraId',
            'requestedCameraId': cameraId,
            'cameraId': activeCameraId,
            'durationMs': stopwatch.elapsedMilliseconds,
            'usedFallback': usedFallback,
            'ready': isCameraReady,
          },
        ),
      );
    }
  }

  @override
  Future<void> startWork() async {
    final int generation = ++_operationGeneration;
    final CameraController? camera = _cameraController;
    final bool cameraUnavailable = _supportsNativeCamera
        ? _nativeInitialization == null
        : camera == null || !camera.value.isInitialized;
    if (cameraUnavailable || isBusy || isWorking) {
      unawaited(
        _runtimeLog.log(
          kind: 'start_work_skipped',
          extra: <String, Object?>{
            'generation': generation,
            'cameraUnavailable': cameraUnavailable,
            'isBusy': isBusy,
            'isWorking': isWorking,
            'phase': _phase.name,
            'nativeInitialized': _nativeInitialization != null,
          },
        ),
      );
      return;
    }
    await _repository.pauseSharedFileMigration();
    final _PackingOperationTiming timing = _PackingOperationTiming();
    String timingOutcome = 'error';
    try {
      unawaited(
        _runtimeLog.log(
          kind: 'start_work',
          extra: <String, Object?>{
            'recordAudio': _recordAudioEnabled,
            'recordingSpec': _recordingSpec.storageValue,
            'videoCodec': _preferredVideoCodec.storageValue,
            'nativeRecordingFallback': _nativeRecordingFallback,
            'capabilityMode': _capabilityMode.wireValue,
          },
        ),
      );
      _alternatingLastCompletedCode = null;
      _alternatingNoCodeSince = null;
      _queuedStorageNoticePriority = -1;
      _storageWarningMessage = null;
      final StorageSpaceResult storage = await timing.measure(
        'storageReclaim',
        _reclaimStorage,
      );
      if (storage.insufficient) {
        timingOutcome = 'insufficient_storage';
        _errorMessage = storage.insufficientMessage;
        notifyListeners();
        await _resumeSharedFileMigrationIfIdle();
        return;
      }

      await timing.measure('maxVolumeBegin', _beginMaxVolumeIfNeeded);
      await timing.measure('maxVolumeBoost', _boostMaxVolumeIfNeeded);

      _errorMessage = null;
      _lastMarker = null;
      _candidateCode = '';
      _timeline.reset();
      _activeOrderInfo = null;
      _lastAnnouncedOrderSignature = '';
      _stabilityTracker.reset();
      _speechService.resetIncidents();
      if (_speechService case final SpeechPromptService speech) {
        await timing.measure(
          'fixedSpeechPrewarm',
          speech.prepareDuplicateOrderWarning,
        );
      }
      _beginInitialPromptFlow();

      await timing.measure('wakelock', WakelockPlus.enable);
      await timing.measure('preview', () => setPreviewActive(true));
      await timing.measure('workScan', () => _setNativeWorkScanEnabled(true));
      unawaited(_captureCameraDiagnosticsSnapshot('start_work'));
      _workActive = true;
      _startStorageMonitor();
      await timing.measure(
        'orderReceiver',
        () => _orderInfoReceiver.setBackgroundKeepAlive(false),
      );
      _setElapsed(Duration.zero);
      _setPhase(PackingSessionPhase.waitingForBarcode);
      timingOutcome = 'success';
      unawaited(
        _runtimeLog.log(
          kind: 'start_work_done',
          extra: <String, Object?>{'generation': generation},
        ),
      );
      _scheduleInitialModeAnnouncement();
    } on CameraException catch (error) {
      timingOutcome = 'camera_error';
      unawaited(
        _runtimeLog.log(
          kind: 'start_work_error',
          extra: <String, Object?>{
            'generation': generation,
            'type': 'camera',
            'error': '$error',
          },
        ),
      );
      await _setNativeWorkScanEnabled(false);
      _cancelInitialPromptFlow();
      _workActive = false;
      _stopStorageMonitor();
      _activeOrderInfo = null;
      _timeline.reset();
      await WakelockPlus.disable();
      await _endMaxVolumeSession();
      _setCameraError(error);
      await _resumeSharedFileMigrationIfIdle();
    } on Object catch (error) {
      timingOutcome = 'error';
      unawaited(
        _runtimeLog.log(
          kind: 'start_work_error',
          extra: <String, Object?>{
            'generation': generation,
            'type': 'unknown',
            'error': '$error',
          },
        ),
      );
      await _setNativeWorkScanEnabled(false);
      _cancelInitialPromptFlow();
      _workActive = false;
      _stopStorageMonitor();
      _activeOrderInfo = null;
      _timeline.reset();
      await WakelockPlus.disable();
      await _endMaxVolumeSession();
      _errorMessage = '无法开始录像，请重新检查摄像头\n$error';
      _setPhase(PackingSessionPhase.error);
      _speakErrorMessage(error.toString());
      await _resumeSharedFileMigrationIfIdle();
    } finally {
      unawaited(
        _runtimeLog.log(
          kind: 'start_work_stage_timing',
          extra: timing.finish(outcome: timingOutcome),
        ),
      );
    }
  }

  @override
  Future<RecordingSession?> stopWork() async {
    final int generation = ++_operationGeneration;
    if (!isWorking) {
      unawaited(
        _runtimeLog.log(
          kind: 'stop_work_skipped',
          extra: <String, Object?>{
            'generation': generation,
            'reason': 'not_working',
          },
        ),
      );
      await _resumeSharedFileMigrationIfIdle();
      return null;
    }
    final bool silentStorageStop = _storageStopRequested;
    final CameraController? camera = _cameraController;
    final DateTime? startedAt = _timeline.recordingStartedAt;
    final bool recordingUnavailable = _supportsNativeCamera
        ? _nativeCamera == null
        : camera == null || !camera.value.isRecordingVideo;
    if (startedAt == null) {
      unawaited(
        _runtimeLog.log(
          kind: 'stop_work_skipped',
          extra: <String, Object?>{
            'generation': generation,
            'reason': 'no_recording',
          },
        ),
      );
      _cancelInitialPromptFlow();
      await _setNativeWorkScanEnabled(false);
      _workActive = false;
      _stopStorageMonitor();
      _candidateCode = '';
      _setActiveOrderInfo(null, announce: false);
      _stabilityTracker.reset();
      await WakelockPlus.disable();
      await _endMaxVolumeSession();
      _setPhase(PackingSessionPhase.ready);
      await _releaseStorageNoticeAfterWork();
      await _resumeSharedFileMigrationIfIdle();
      return null;
    }
    if (recordingUnavailable) {
      unawaited(
        _runtimeLog.log(
          kind: 'stop_work_skipped',
          extra: <String, Object?>{
            'generation': generation,
            'reason': 'recording_unavailable',
          },
        ),
      );
      return null;
    }
    _cancelInitialPromptFlow();
    await _setNativeWorkScanEnabled(false);

    _setPhase(PackingSessionPhase.saving);
    await WidgetsBinding.instance.endOfFrame;

    try {
      final List<RecordingSession> savedSessions = _supportsNativeCamera
          ? await _finishNativeRecording()
          : await _finishRecording();
      unawaited(_captureCameraDiagnosticsSnapshot('stop_work'));
      _candidateCode = '';
      _stabilityTracker.reset();
      _workActive = false;
      _alternatingLastCompletedCode = null;
      _alternatingNoCodeSince = null;
      _stopStorageMonitor();
      await WakelockPlus.disable();
      await _endMaxVolumeSession();
      await Future<void>.delayed(transitionSettleDelay);
      _setPhase(PackingSessionPhase.ready);
      await _speechService.clear();
      if (!silentStorageStop) {
        _speechService.enqueue(SpeechPrompt.recordingStopped);
      }
      unawaited(
        _runtimeLog.log(
          kind: 'stop_work_done',
          extra: <String, Object?>{
            'generation': generation,
            'savedCount': savedSessions.length,
          },
        ),
      );
      _setActiveOrderInfo(null, announce: false);
      await _releaseStorageNoticeAfterWork();
      await _resumeSharedFileMigrationIfIdle();
      return savedSessions.isEmpty ? null : savedSessions.last;
    } on Object catch (error) {
      unawaited(
        _runtimeLog.log(
          kind: 'stop_work_error',
          extra: <String, Object?>{'generation': generation, 'error': '$error'},
        ),
      );
      _timeline.reset();
      _workActive = false;
      _alternatingLastCompletedCode = null;
      _alternatingNoCodeSince = null;
      _stopStorageMonitor();
      await WakelockPlus.disable();
      await _endMaxVolumeSession();
      _errorMessage = '录像保存失败，请保留应用并重试\n$error';
      _setPhase(PackingSessionPhase.error);
      if (!silentStorageStop) {
        _speakErrorMessage(error.toString());
      }
      await _resumeSharedFileMigrationIfIdle();
      return null;
    }
  }

  @override
  Future<void> _resumeSharedFileMigrationIfIdle() async {
    if (_disposed || isWorking) return;
    try {
      await _repository.resumeSharedFileMigration();
    } on Object catch (error, stackTrace) {
      developer.log(
        'PackingSessionController failed to resume shared file migration',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 轮换模式：完成当前订单的录像并回到扫码，工作会话继续。
  ///
  /// 只复用录像 finalize 链（原生 stopWork + 入库/水印/备份），
  /// 不复用「结束工作」的 controller 收尾：Wakelock、最大音量会话、
  /// 存储监控与 _workActive 都保持不变。
  Future<void> finishCurrentOrder() async {
    if (!canFinishCurrentOrder || _nativeCamera == null) return;
    final String completedCode = _timeline.currentCode;
    _cancelInitialPromptFlow();
    _setPhase(PackingSessionPhase.saving);
    await WidgetsBinding.instance.endOfFrame;
    try {
      final List<RecordingSession> saved = await _finishNativeRecording();
      unawaited(_captureCameraDiagnosticsSnapshot('finish_order'));
      _alternatingLastCompletedCode = completedCode.isEmpty
          ? null
          : completedCode;
      _alternatingNoCodeSince = null;
      _lastMarker = null;
      _candidateCode = '';
      _setElapsed(Duration.zero);
      _setActiveOrderInfo(null, announce: false);
      _setPhase(PackingSessionPhase.waitingForBarcode);
      await _speechService.clear();
      _speechService.enqueue(SpeechPrompt.recordingStopped);
      if (saved.isNotEmpty) {
        _showCameraNotice('本单已完成，请扫描下一张面单');
      }
      notifyListeners();
    } on Object catch (error) {
      _timeline.reset();
      _errorMessage = '本单录像保存失败，请保留应用并重试\n$error';
      _setPhase(PackingSessionPhase.error);
      _speakErrorMessage(error.toString());
    }
  }

  Future<void> _startRecording(String trackingNumber) async {
    if (_supportsNativeCamera) {
      await _startNativeRecording(trackingNumber);
      return;
    }
    final CameraController? camera = _cameraController;
    if (camera == null || !camera.value.isInitialized) {
      throw CameraException('CameraNotReady', '摄像头尚未准备完成');
    }

    final DateTime startedAt = DateTime.now();
    _timeline.start(startedAt);
    _setElapsed(Duration.zero);
    _setPhase(PackingSessionPhase.starting);
    await WidgetsBinding.instance.endOfFrame;
    await camera.lockCaptureOrientation(DeviceOrientation.portraitUp);
    await camera.startVideoRecording(
      onAvailable: _processFrame,
      enablePersistentRecording: true,
    );
    try {
      await camera.setFocusMode(FocusMode.auto);
      await camera.setFocusPoint(const Offset(0.5, 0.52));
      await camera.setExposurePoint(const Offset(0.5, 0.52));
    } on CameraException {
      // Some devices keep continuous autofocus without exposing focus points.
    }
    await Future<void>.delayed(transitionSettleDelay);
    _setPhase(PackingSessionPhase.recording);
    _startElapsedTimer();
  }

  Future<void> _startNativeRecording(String trackingNumber) async {
    final ContinuousCameraService? camera = _nativeCamera;
    if (camera == null || _nativeInitialization == null) {
      throw StateError('摄像头尚未准备完成');
    }
    final _PackingOperationTiming timing = _PackingOperationTiming();
    String timingOutcome = 'error';
    try {
      _setPhase(PackingSessionPhase.starting);
      await timing.measure(
        'endOfFrame',
        () => WidgetsBinding.instance.endOfFrame,
      );
      final String recordingId = _sessionId(DateTime.now());
      final String path = await timing.measure(
        'recordingPath',
        () => _repository.recordingPath(recordingId),
      );
      final NativeRecordingStart started = await timing.measure(
        'nativeStart',
        () => camera.startWork(
          path,
          recordAudio: _recordAudioEnabled,
          trackingNumber: trackingNumber,
        ),
      );
      unawaited(_captureCameraDiagnosticsSnapshot('native_start'));
      _recordingId = recordingId;
      _activeSegmentId = recordingId;
      _segmentIndex = 1;
      _timeline.start(started.startedAt);
      _setElapsed(Duration.zero);
      _setPhase(PackingSessionPhase.recording);
      _startElapsedTimer();
      timingOutcome = 'success';
    } finally {
      unawaited(
        _runtimeLog.log(
          kind: 'native_recording_timing',
          extra: <String, Object?>{
            'operation': 'start',
            ...timing.finish(outcome: timingOutcome),
          },
        ),
      );
    }
  }

  Future<List<RecordingSession>> _finishRecording() async {
    final CameraController camera = _cameraController!;
    final DateTime startedAt = _timeline.recordingStartedAt!;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    final XFile captured = await camera.stopVideoRecording();
    final DateTime endedAt = DateTime.now();
    final String sessionId = _sessionId(startedAt);
    final List<RecordingSession> drafts = _timeline.buildSessions(
      endedAt: endedAt,
      filePath: captured.path,
      recordingId: sessionId,
      operationMode: _operationMode,
      videoCodec: _videoCodecFromMime(_nativeInitialization?.videoMime),
    );
    final String savedPath = await _repository.finalizeVideo(
      sourcePath: captured.path,
      sessionId: sessionId,
      startedAt: startedAt,
      trackingNumber: _firstTrackingNumber(drafts),
      operationMode: _operationMode,
    );
    final List<RecordingSession> sessions = drafts
        .map(
          (RecordingSession draft) =>
              _sessionWithPath(draft, savedPath, orderInfo: _activeOrderInfo),
        )
        .toList(growable: false);
    _sessions = await _repository.addSessions(sessions);
    await _enqueueBackupIfNeeded(savedPath, sessions);
    _setElapsed(endedAt.difference(startedAt));
    _timeline.reset();
    return sessions;
  }

  Future<List<RecordingSession>> _finishNativeRecording() async {
    final ContinuousCameraService camera = _nativeCamera!;
    final String segmentId = _activeSegmentId!;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    final NativeRecordingStop stopped = await camera.stopWork();
    if (_shutdownAbandonedStop) {
      throw StateError('控制器已关闭，忽略迟到的原生停录结果');
    }
    final RecordingSegmentDraft? draft = _timeline.finish(stopped.endedAt);
    if (draft == null) {
      throw StateError('找不到当前录像片段');
    }
    final String savedPath = await _repository.finalizeVideo(
      sourcePath: stopped.path,
      sessionId: segmentId,
      startedAt: draft.startedAt,
      trackingNumber: draft.markers.isEmpty ? '' : draft.markers.first.code,
      operationMode: _operationMode,
    );
    final RecordingSession session =
        _standaloneSession(
          id: segmentId,
          path: savedPath,
          draft: draft,
        ).copyWith(
          watermarkStatus: nativeWatermarkStatus(stopped.watermarkDisposition),
        );
    _sessions = await _repository.addSession(session);
    if (nativeWatermarkNeedsPostProcess(stopped.watermarkDisposition)) {
      await _resumePendingWatermarks();
    } else {
      _runInBackground(
        _enqueueBackupIfNeeded(savedPath, <RecordingSession>[session]),
      );
    }
    _setElapsed(stopped.endedAt.difference(_timeline.recordingStartedAt!));
    _timeline.reset();
    _recordingId = null;
    _activeSegmentId = null;
    return <RecordingSession>[session];
  }

  void _startElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final DateTime? startedAt = _timeline.segmentStartedAt;
      if (startedAt == null || _disposed) {
        return;
      }
      _setElapsed(DateTime.now().difference(startedAt));
    });
  }

  void _setElapsed(Duration value) {
    _elapsed = value;
    _elapsedListenable.value = value;
  }

  Future<void> handleInactive() async {
    _appIsActive = false;
    final bool keepOrderReceiver = isWorking;
    await _orderInfoReceiver.setBackgroundKeepAlive(keepOrderReceiver);
    if (isWorking) {
      await stopWork();
    }
    if (_phase != PackingSessionPhase.saving) {
      await _disposeCamera();
    }
    await _endMaxVolumeSession();
  }

  Future<void> handleResumed() async {
    _appIsActive = true;
    final bool needsInitialization = _supportsNativeCamera
        ? _nativeInitialization == null
        : _cameraController?.value.isInitialized != true;
    if (needsInitialization && _phase != PackingSessionPhase.saving) {
      await initialize();
    }
    await _resumePendingWatermarks();
    await _orderInfoReceiver.setBackgroundKeepAlive(false);
    unawaited(_lanBackupService.refresh());
    if (isWorking) {
      await _beginMaxVolumeIfNeeded();
    }
  }

  @override
  Future<void> _beginMaxVolumeIfNeeded() async {
    if (!_maxVolumeEnabled || !_appIsActive) {
      return;
    }
    try {
      await _maxVolumeService.beginSession();
    } on Object {
      // Volume convenience must never block the camera workflow.
    }
  }

  Future<void> setPreviewActive(bool active) async {
    if (!_supportsNativeCamera) return;
    _pendingPreviewTransitions++;
    final Future<void> next = _previewStateTail.then((_) async {
      try {
        await _nativeCamera?.setPreviewActive(active);
      } on Object {
        // Preview power tuning must never block navigation or recording.
      }
    });
    final Future<void> tracked = next.whenComplete(
      () => _pendingPreviewTransitions--,
    );
    _previewStateTail = tracked;
    await tracked;
  }

  Future<void> _setNativeWorkScanEnabled(bool enabled) async {
    if (!_supportsNativeCamera) return;
    try {
      await _nativeCamera?.setWorkScanEnabled(enabled);
    } on Object {
      if (enabled) rethrow;
    }
  }

  Future<void> _endMaxVolumeSession() async {
    try {
      await _maxVolumeService.endSession();
    } on Object {
      // Android may already have released the activity during shutdown.
    }
  }

  @override
  Future<void> _disableMaxVolume() async {
    try {
      await _maxVolumeService.disable();
    } on Object {
      // Volume convenience must never block settings persistence.
    }
  }

  Future<void> _boostMaxVolumeIfNeeded() async {
    if (!_maxVolumeEnabled || !_appIsActive) {
      return;
    }
    try {
      await _maxVolumeService.boost();
    } on Object {
      // Volume convenience must never block recording startup.
    }
  }

  Future<void> refreshSessions() async {
    await _lanBackupService.refresh();
    await _reloadRecentSessions();
    notifyListeners();
  }

  Future<void> updateSession(RecordingSession session) async {
    _sessions = await _repository.updateSession(session);
    await _refreshLocalStatistics();
    notifyListeners();
  }

  Future<RecordingSession> prepareSessionFileForPlayback(String sessionId) =>
      _repository.prepareSessionFileForAccess(sessionId);

  Future<void> deleteSessions(Set<String> sessionIds) async {
    _sessions = await _repository.deleteSessions(sessionIds);
    await _refreshLocalStatistics();
    notifyListeners();
  }

  Future<void> hideRemoteRecordings(Set<int> ids) async {
    if (ids.isEmpty) return;
    _hiddenRemoteRecordingIds = <int>{..._hiddenRemoteRecordingIds, ...ids};
    await _repository.saveHiddenRemoteRecordingIds(_hiddenRemoteRecordingIds);
    notifyListeners();
  }

  @visibleForTesting
  void handleNativeRecordingFallbackForTesting(
    Map<Object?, Object?> info, {
    bool persist = true,
  }) {
    _handleNativeRecordingFallback(info, persist: persist);
  }

  @visibleForTesting
  void resetRecordingTimelineForTesting() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _timeline.reset();
    _setActiveOrderInfo(null, announce: false);
  }

  @override
  Future<RecordingSession?> _saveCurrentVideoAndWait() async {
    if (!isWorking || !isRecording || !_timeline.isActive) {
      return null;
    }
    _cancelInitialPromptFlow();
    _setPhase(PackingSessionPhase.saving);
    await WidgetsBinding.instance.endOfFrame;
    try {
      final List<RecordingSession> savedSessions = _supportsNativeCamera
          ? await _finishNativeRecording()
          : await _finishRecording();
      _candidateCode = '';
      _setElapsed(Duration.zero);
      await Future<void>.delayed(transitionSettleDelay);
      _setPhase(PackingSessionPhase.waitingForBarcode);
      await _speechService.clear();
      _speechService.enqueue(SpeechPrompt.recordingStopped);
      _setActiveOrderInfo(null, announce: false);
      return savedSessions.isEmpty ? null : savedSessions.last;
    } on Object catch (error) {
      _timeline.reset();
      _workActive = false;
      await WakelockPlus.disable();
      await _endMaxVolumeSession();
      _errorMessage = '录像保存失败，请保留应用并重试\n$error';
      _setPhase(PackingSessionPhase.error);
      _speakErrorMessage(error.toString());
      return null;
    }
  }

  @override
  Future<BarcodeMarker?> _splitNativeRecording(
    String code, {
    required void Function(BarcodeMarker marker) onSegmentStarted,
  }) async {
    final ContinuousCameraService? camera = _nativeCamera;
    final String? recordingId = _recordingId;
    final String? completedId = _activeSegmentId;
    if (camera == null || recordingId == null || completedId == null) {
      return null;
    }
    if (!isWorking || !await _ensureStorageForSegment()) return null;
    final _PackingOperationTiming timing = _PackingOperationTiming();
    String timingOutcome = 'error';
    try {
      final int nextIndex = _segmentIndex + 1;
      final OrderInfo? completedOrderInfo = _activeOrderInfo;
      final String nextId =
          '${recordingId}_${nextIndex.toString().padLeft(3, '0')}';
      final String nextPath = await timing.measure(
        'recordingPath',
        () => _repository.recordingPath(nextId),
      );
      final NativeRecordingSplit split = await timing.measure(
        'nativeSplit',
        () => _splitNativeWithStorageRecovery(camera, nextPath, code),
      );
      unawaited(_captureCameraDiagnosticsSnapshot('native_split'));
      final RecordingSegmentTransition? transition = _timeline.startNext(
        code,
        split.boundaryAt,
      );
      if (transition == null) {
        throw StateError('录像时间线无法开始下一段');
      }
      _activeSegmentId = nextId;
      _segmentIndex = nextIndex;
      if (_isCurrentSegmentCode(code)) {
        _setActiveOrderInfo(null, announce: false);
        _resetSegmentElapsed();
        onSegmentStarted(transition.marker);
      }
      final String savedPath = await timing.measure(
        'finalizeVideo',
        () => _repository.finalizeVideo(
          sourcePath: split.completedPath,
          sessionId: completedId,
          startedAt: transition.completed.startedAt,
          trackingNumber: transition.completed.markers.isEmpty
              ? ''
              : transition.completed.markers.first.code,
          operationMode: _operationMode,
        ),
      );
      final RecordingSession completed =
          _standaloneSession(
            id: completedId,
            path: savedPath,
            draft: transition.completed,
            orderInfo: completedOrderInfo,
          ).copyWith(
            watermarkStatus: nativeWatermarkStatus(split.watermarkDisposition),
          );
      _sessions = await timing.measure(
        'persistSession',
        () => _repository.addSession(completed),
      );
      if (nativeWatermarkNeedsPostProcess(split.watermarkDisposition)) {
        await timing.measure('watermarkRecovery', _resumePendingWatermarks);
      } else {
        _runInBackground(
          _enqueueBackupIfNeeded(savedPath, <RecordingSession>[completed]),
        );
      }
      timingOutcome = 'success';
      return transition.marker;
    } finally {
      unawaited(
        _runtimeLog.log(
          kind: 'native_recording_timing',
          extra: <String, Object?>{
            'operation': 'split',
            ...timing.finish(outcome: timingOutcome),
          },
        ),
      );
    }
  }

  @override
  Future<BarcodeMarker?> _splitCameraRecording(
    String code, {
    required OrderInfo? nextOrderInfo,
    required void Function(BarcodeMarker marker) onSegmentStarted,
  }) async {
    final CameraController? camera = _cameraController;
    if (camera == null ||
        !camera.value.isRecordingVideo ||
        !_timeline.isActive) {
      return null;
    }
    final DateTime boundaryAt = DateTime.now();
    final RecordingSegmentTransition? transition = _timeline.startNext(
      code,
      boundaryAt,
    );
    if (transition == null) return null;

    try {
      final XFile captured = await camera.stopVideoRecording();
      final DateTime endedAt = DateTime.now();
      final String completedId = _sessionId(transition.completed.startedAt);
      final String savedPath = await _repository.finalizeVideo(
        sourcePath: captured.path,
        sessionId: completedId,
        startedAt: transition.completed.startedAt,
        trackingNumber: transition.completed.markers.isEmpty
            ? ''
            : transition.completed.markers.first.code,
        operationMode: _operationMode,
      );
      final RecordingSession completed = _standaloneSession(
        id: completedId,
        path: savedPath,
        draft: RecordingSegmentDraft(
          startedAt: transition.completed.startedAt,
          endedAt: endedAt,
          markers: transition.completed.markers,
        ),
        orderInfo: _activeOrderInfo,
      );
      _sessions = await _repository.addSession(completed);
      await _resumePendingWatermarks();

      _timeline.reset();
      _timeline.start(boundaryAt);
      await camera.startVideoRecording(
        onAvailable: _processFrame,
        enablePersistentRecording: true,
      );
      _resetSegmentElapsed();
      _setPhase(PackingSessionPhase.recording);
      onSegmentStarted(transition.marker);
      return transition.marker;
    } on Object catch (error) {
      _timeline.reset();
      _workActive = false;
      await WakelockPlus.disable();
      await _endMaxVolumeSession();
      _errorMessage = '录像分段保存失败\n$error';
      _setPhase(PackingSessionPhase.error);
      _speechService.enqueue(SpeechPrompt.segmentSaveFailed);
      if (!_disposed) notifyListeners();
      return null;
    }
  }

  void _resetSegmentElapsed() {
    _setElapsed(Duration.zero);
    notifyListeners();
  }

  RecordingSession _standaloneSession({
    required String id,
    required String path,
    required RecordingSegmentDraft draft,
    OrderInfo? orderInfo,
  }) {
    return RecordingSession(
      id: id,
      filePath: path,
      startedAt: draft.startedAt,
      endedAt: draft.endedAt,
      markers: List<BarcodeMarker>.unmodifiable(draft.markers),
      orderInfo: orderInfo ?? _activeOrderInfo,
      operationMode: _operationMode,
      recordingOrientation: _recordingOrientation,
      videoCodec: _videoCodecFromMime(_nativeInitialization?.videoMime),
      watermarkStatus: WatermarkProcessingStatus.pending,
    );
  }

  @override
  String _firstTrackingNumber(List<RecordingSession> sessions) {
    for (final RecordingSession session in sessions) {
      if (session.markers.isNotEmpty && session.markers.first.code.isNotEmpty) {
        return session.markers.first.code;
      }
    }
    return '';
  }

  RecordingSession _sessionWithPath(
    RecordingSession session,
    String filePath, {
    OrderInfo? orderInfo,
  }) => RecordingSession(
    id: session.id,
    filePath: filePath,
    startedAt: session.startedAt,
    endedAt: session.endedAt,
    markers: session.markers,
    mediaStart: session.mediaStart,
    mediaEnd: session.mediaEnd,
    orderInfo: orderInfo ?? session.orderInfo,
    operationMode: session.operationMode,
    recordingOrientation: session.recordingOrientation,
    videoCodec: session.videoCodec,
    watermarkStatus: session.watermarkStatus,
    watermarkAttemptCount: session.watermarkAttemptCount,
  );

  @override
  void _bindCurrentCode(String code, DateTime now) {
    final BarcodeMarker? marker = _timeline.bindCode(code, now);
    if (marker == null) {
      return;
    }
    _announceInitialRecordingStarted();
    _showMarkerFeedback(marker);
  }

  @override
  Future<void> _reloadRecentSessions() async {
    _sessions = await _repository.loadRecentSessionMetadata();
    await _refreshLocalStatistics();
  }

  @override
  Future<void> _refreshLocalStatistics() async {
    try {
      _localRecordingStatistics = await _repository
          .loadLocalRecordingStatistics();
    } on Object {
      // Statistics must never block history or recording operations.
    }
  }

  void _showMarkerFeedback(BarcodeMarker marker) {
    _lastMarker = marker;
    _candidateCode = '';
    _feedbackTimer?.cancel();
    _pairingFeedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(seconds: 3), () {
      if (_disposed) {
        return;
      }
      _lastMarker = null;
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  void _showRejectedBarcodeNotice(
    RejectedBarcodeDecision decision,
    DateTime now,
  ) {
    _rejectedBarcodeMessage = decision.message;
    _lastRejectedBarcodeCode = decision.code;
    _lastRejectedBarcodeAt = now;
    _rejectedBarcodeTimer?.cancel();
    _rejectedBarcodeTimer = Timer(const Duration(seconds: 4), () {
      if (_disposed) return;
      _rejectedBarcodeMessage = null;
      _speechService.resolveIncident('invalid-order-number');
      notifyListeners();
    });
    _speechService.enqueue(
      SpeechPrompt.invalidTrackingNumber,
      incidentKey: 'invalid-order-number',
    );
    notifyListeners();
  }

  @override
  void _setCameraError(CameraException error) {
    _errorMessage = switch (error.code) {
      'CameraAccessDenied' ||
      'CameraAccessDeniedWithoutPrompt' => '需要摄像头权限才能识别面单和录像\n请允许权限后重试',
      'CameraAccessRestricted' => '系统限制了摄像头访问，请检查设备设置',
      'AudioAccessDenied' ||
      'AudioAccessDeniedWithoutPrompt' => '需要麦克风权限才能录制声音\n请允许权限后重试',
      'AudioAccessRestricted' => '系统限制了麦克风访问，请检查设备设置',
      'NoCamera' => '没有检测到可用摄像头',
      _ => '摄像头暂时不可用，请重试\n${error.description ?? error.code}',
    };
    _setPhase(PackingSessionPhase.error);
    _speakErrorMessage('${error.code} ${error.description ?? ''}');
  }

  @override
  void _speakErrorMessage(String message) {
    final String normalized = message.toLowerCase();
    if (normalized.contains('未准备') ||
        normalized.contains('摄像头初始化') ||
        normalized.contains('摄像头打开') ||
        normalized.contains('camera_not_ready')) {
      return;
    }
    final SpeechPrompt prompt;
    if (normalized.contains('permission') ||
        normalized.contains('权限') ||
        normalized.contains('accessdenied') ||
        normalized.contains('accessrestricted')) {
      prompt = SpeechPrompt.permissionRequired;
    } else if (normalized.contains('没有检测到') ||
        normalized.contains('nocamera')) {
      prompt = SpeechPrompt.cameraNotFound;
    } else if (normalized.contains('断开')) {
      prompt = SpeechPrompt.cameraDisconnected;
    } else if (normalized.contains('声音') || normalized.contains('麦克风')) {
      prompt = SpeechPrompt.audioRecordingFailed;
    } else if (normalized.contains('分段')) {
      prompt = SpeechPrompt.segmentSaveFailed;
    } else if (normalized.contains('文件创建')) {
      prompt = SpeechPrompt.videoFileCreateFailed;
    } else if (normalized.contains('保存')) {
      prompt = SpeechPrompt.recordingSaveFailed;
    } else if (normalized.contains('视频编码器')) {
      prompt = SpeechPrompt.recordingFailed;
    } else {
      prompt = SpeechPrompt.recordingFailed;
    }
    _speechService.enqueue(prompt, incidentKey: prompt.name);
  }

  @override
  void _setPhase(PackingSessionPhase value) {
    _phase = value;
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  Future<void> _disposeCamera() async {
    _cancelInitialPromptFlow();
    if (_supportsNativeCamera) {
      final ContinuousCameraService? nativeCamera = _nativeCamera;
      _nativeCamera = null;
      _nativeInitialization = null;
      _backCameraLenses = const <NativeCameraLens>[];
      _torchEnabled = false;
      if (nativeCamera != null) {
        await nativeCamera.dispose();
      }
      if (!_disposed && _phase != PackingSessionPhase.error) {
        _phase = PackingSessionPhase.initializing;
        notifyListeners();
      }
      return;
    }
    final CameraController? camera = _cameraController;
    _cameraController = null;
    _torchEnabled = false;
    if (camera != null) {
      await camera.dispose();
    }
    if (!_disposed && _phase != PackingSessionPhase.error) {
      _phase = PackingSessionPhase.initializing;
      notifyListeners();
    }
  }

  @override
  void _runInBackground(Future<void> task) {
    _backgroundTasks.add(task);
    unawaited(
      task
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              developer.log(
                'PackingSessionController background task failed',
                error: error,
                stackTrace: stackTrace,
              );
            },
          )
          .whenComplete(() => _backgroundTasks.remove(task)),
    );
  }

  Future<void> _drainBackgroundTasksForShutdown() async {
    final List<Future<void>> pending = _backgroundTasks.toList(growable: false);
    if (pending.isEmpty) return;
    try {
      await Future.wait<void>(
        pending.map(
          (Future<void> task) => task.catchError((Object _, StackTrace _) {}),
        ),
      ).timeout(_shutdownOperationTimeout);
    } on TimeoutException {
      developer.log(
        'PackingSessionController stopped waiting for background tasks during shutdown',
      );
    } finally {
      _backgroundTasks.removeAll(pending);
    }
  }

  Future<bool> _awaitShutdownOperation<T>(
    String operation,
    Future<T> task,
  ) async {
    try {
      await task.timeout(_shutdownOperationTimeout);
      return true;
    } on TimeoutException catch (error, stackTrace) {
      developer.log(
        'PackingSessionController stopped waiting for $operation during shutdown',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    } on Object catch (error, stackTrace) {
      developer.log(
        'PackingSessionController failed $operation during shutdown',
        error: error,
        stackTrace: stackTrace,
      );
      return true;
    }
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    _disposed = true;
    await _repository.pauseSharedFileMigration();
    _stopStorageMonitor();
    await _cancelWatermarkForShutdown();
    final Future<void>? storageStop = _storageStopFuture;
    if (storageStop != null) {
      final bool stopped = await _awaitShutdownOperation<void>(
        'for storage stop',
        storageStop,
      );
      _shutdownAbandonedStop = !stopped;
    }
    if (isWorking && !_storageStopRequested) {
      final bool stopped = await _awaitShutdownOperation<RecordingSession?>(
        'to stop active recording',
        stopWork(),
      );
      _shutdownAbandonedStop = !stopped;
    }
    _clearPendingComputerReplacement();
    _elapsedTimer?.cancel();
    _feedbackTimer?.cancel();
    _scanWarningTimer?.cancel();
    _cameraNoticeTimer?.cancel();
    _rejectedBarcodeTimer?.cancel();
    _initialPromptTimer?.cancel();
    _pairingFeedbackTimer?.cancel();
    _storageMonitorTimer?.cancel();
    _diagnosticsTimer?.cancel();
    _pendingDiagnosticsTrigger = null;
    if (_backupListenerAttached) {
      _lanBackupService.removeListener(_handleBackupChanged);
      _backupListenerAttached = false;
    }
    _detachOrderReceiverBinding();

    final CameraController? camera = _cameraController;
    _cameraController = null;
    final ContinuousCameraService? nativeCamera = _nativeCamera;
    _nativeCamera = null;
    _nativeInitialization = null;

    if (_pendingCameraInitializations > 0) {
      await _cameraInitializeTail.catchError((Object _, StackTrace _) {});
    }
    if (_pendingPreviewTransitions > 0) {
      await _previewStateTail.catchError((Object _, StackTrace _) {});
    }
    await _drainBackgroundTasksForShutdown();

    Future<void> cleanup(
      String component,
      Future<void> Function() operation,
    ) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        developer.log(
          'PackingSessionController failed to close $component',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    await Future.wait<void>(<Future<void>>[
      cleanup('wakelock', WakelockPlus.disable),
      if (camera != null) cleanup('camera', camera.dispose),
      if (nativeCamera != null) cleanup('nativeCamera', nativeCamera.dispose),
      cleanup('barcodeScanner', _barcodeScanner.close),
      cleanup('speechService', _speechService.dispose),
      cleanup('maxVolumeService', _maxVolumeService.dispose),
      if (_orderInfoSubscription != null)
        cleanup('orderInfoSubscription', _orderInfoSubscription!.cancel),
      cleanup('orderInfoReceiver', _orderInfoReceiver.dispose),
      cleanup('lanBackupService', _lanBackupService.dispose),
    ]);
    _orderInfoSubscription = null;
    await _awaitShutdownOperation<void>(
      'to close repository',
      cleanup('repository', _repository.dispose),
    );
    await _awaitShutdownOperation<void>(
      'to flush diagnostics',
      Future.wait<void>(<Future<void>>[
        _runtimeLog.flush(),
        _cameraDiagnostics.flush(),
      ]),
    );
  }

  String _sessionId(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    String three(int number) => number.toString().padLeft(3, '0');
    return '${value.year}${two(value.month)}${two(value.day)}_'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}_'
        '${three(value.millisecond)}';
  }

  @override
  void dispose() {
    unawaited(shutdown().whenComplete(_elapsedListenable.dispose));
    super.dispose();
  }
}
