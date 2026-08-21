import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:camera/camera.dart';
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
import '../services/video_watermark_service.dart';

part 'packing_session_backup_coordinator.dart';
part 'packing_session_barcode_coordinator.dart';
part 'packing_session_storage_coordinator.dart';
part 'packing_session_watermark_coordinator.dart';

enum PackingSessionPhase {
  initializing,
  ready,
  waitingForBarcode,
  starting,
  recording,
  saving,
  error,
}

class ComputerReplacementPrompt {
  const ComputerReplacementPrompt({
    required this.currentComputer,
    required this.newComputer,
  });

  final String currentComputer;
  final String newComputer;
}

String _codecFallbackMessage(String reason) => switch (reason) {
  'no_hevc_decoder' => '本机不支持 H.265 解码，新录像已改用 H.264',
  _ => '录像编码自动回退：$reason',
};

class PackingSessionController extends ChangeNotifier
    with
        _PackingSessionBackupCoordinator,
        _PackingSessionStorageCoordinator,
        _PackingSessionWatermarkCoordinator,
        _PackingSessionBarcodeCoordinator {
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
    Future<PackageInfo> Function()? packageInfoLoader,
    // Named parameters cannot use a private initializing formal.
    // ignore: prefer_initializing_formals
    AppBuildConfig buildConfig = AppBuildConfig.environment,
  }) : _repository = repository ?? SessionRepository(),
       _speechService = speechService ?? SpeechPromptService(),
       _maxVolumeService = maxVolumeService ?? MaxVolumeService(),
       _videoWatermarkService =
           videoWatermarkService ?? VideoWatermarkService(),
       _orderInfoReceiver = orderInfoReceiver ?? OrderInfoReceiverService(),
       _capabilities =
           capabilities ?? AppContainer.forCurrentPlatform().capabilities,
       _nativeCamera = cameraService,
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
  Future<void> _cameraInitializeTail = Future<void>.value();
  Future<void> _previewStateTail = Future<void>.value();
  int _pendingCameraInitializations = 0;
  int _pendingPreviewTransitions = 0;
  final Set<Future<void>> _backgroundTasks = <Future<void>>{};
  Future<void>? _shutdownFuture;
  bool _appStartLogged = false;

  PlatformCapabilities get capabilities => _capabilities;

  @override
  CameraController? _cameraController;
  @override
  ContinuousCameraService? _nativeCamera;
  @override
  ContinuousCameraInitialization? _nativeInitialization;
  List<NativeCameraLens> _backCameraLenses = const <NativeCameraLens>[];
  PackingSessionPhase _phase = PackingSessionPhase.initializing;
  @override
  List<RecordingSession> _sessions = <RecordingSession>[];
  LocalRecordingStatistics _localRecordingStatistics =
      const LocalRecordingStatistics();
  Timer? _elapsedTimer;
  Timer? _feedbackTimer;
  Timer? _scanWarningTimer;
  Timer? _cameraNoticeTimer;
  Timer? _rejectedBarcodeTimer;
  Timer? _initialPromptTimer;
  Timer? _pairingFeedbackTimer;
  Timer? _diagnosticsTimer;
  Duration _elapsed = Duration.zero;
  BarcodeMarker? _lastMarker;
  @override
  WorkMode _workMode = WorkMode.continuousScan;
  @override
  RecordingOperationMode _operationMode = RecordingOperationMode.shipping;
  bool _speechEnabled = true;
  bool _orderSpeechEnabled = true;
  bool _maxVolumeEnabled = true;
  bool _recordAudioEnabled = true;
  bool _nativeRecordingFallback = false;
  @override
  CameraCapabilityMode _capabilityMode = CameraCapabilityMode.unverified;
  Map<String, Object?>? _capabilityState;
  bool _capabilityProbeRunning = false;
  String? _capabilityProbeMessage;
  String? _capabilityNoticeMessage;
  @override
  RecordingVideoCodec _preferredVideoCodec = RecordingVideoCodec.hevc;
  RecordingSpecPreset _recordingSpec = RecordingSpecPreset.hd1080p30;
  @override
  RecordingOrientation _recordingOrientation = RecordingOrientation.portrait;
  int _historyPageSize = AppSettings.defaultHistoryPageSize;
  @override
  UnbackedRetentionPolicy _unbackedRetention = UnbackedRetentionPolicy.days30;
  @override
  BackedRetentionPolicy _backedRetention = BackedRetentionPolicy.days7;
  bool _appIsActive = true;
  @override
  String? _errorMessage;
  String? _scanWarningMessage;
  String? _cameraNotice;
  String? _rejectedBarcodeMessage;
  @override
  bool _disposed = false;
  int _pairingAttemptRevision = 0;
  bool _backupListenerAttached = false;
  bool _orderReceiverListenerAttached = false;
  bool _backgroundServicesInitialized = false;
  String? _pairingMessage;
  String? _recordingId;
  String? _activeSegmentId;
  int _segmentIndex = 1;
  bool _torchEnabled = false;
  bool _workActive = false;
  int _operationGeneration = 0;
  int _pairingSuccessRevision = 0;
  int _pairingFailureRevision = 0;
  String? _pairingFailureMessage;
  int _pairingReplacementRevision = 0;
  ComputerReplacementPrompt? _pairingReplacementPrompt;
  String? _pendingReplacementQr;
  LanBackupPairingConfirmation? _pendingReplacementConfirmation;
  Set<int> _hiddenRemoteRecordingIds = <int>{};
  StreamSubscription<OrderInfo>? _orderInfoSubscription;
  OrderInfo? _activeOrderInfo;
  String _lastAnnouncedOrderSignature = '';

  CameraController? get cameraController => _cameraController;
  int? get nativeTextureId => _nativeInitialization?.textureId;
  Size? get nativePreviewSize => _nativeInitialization?.portraitPreviewSize;
  PackingSessionPhase get phase => _phase;
  List<RecordingSession> get sessions =>
      List<RecordingSession>.unmodifiable(_sessions);
  LocalRecordingStatistics get localRecordingStatistics =>
      _localRecordingStatistics;
  Duration get elapsed => _elapsed;
  BarcodeMarker? get lastMarker => _lastMarker;
  String get candidateCode => _candidateCode;
  String get currentCode => _timeline.currentCode;
  WorkMode get workMode => _workMode;
  bool get speechEnabled => _speechEnabled;
  bool get orderSpeechEnabled => _orderSpeechEnabled;
  OrderInfo? get activeOrderInfo => _activeOrderInfo;
  OrderInfoReceiverSnapshot get orderReceiverSnapshot =>
      _orderInfoReceiver.snapshot;
  bool get maxVolumeEnabled => _maxVolumeEnabled;
  CameraCapabilityMode get capabilityMode => _capabilityMode;
  bool get capabilityProbeRunning => _capabilityProbeRunning;
  String? get capabilityProbeMessage => _capabilityProbeMessage;
  bool get showCameraCapabilityCard =>
      (_capabilityMode != CameraCapabilityMode.unverified &&
          _capabilityMode != CameraCapabilityMode.full) ||
      _nativeRecordingFallback;
  bool get alternatingRecording =>
      _capabilityMode == CameraCapabilityMode.alternating && isRecording;
  bool get canFinishCurrentOrder =>
      alternatingRecording && !isBusy && _nativeCamera != null;
  String get capabilityStatusText {
    final String base =
        '${_capabilityMode.label}：${_capabilityMode.description}';
    if (_capabilityMode == CameraCapabilityMode.unverified) {
      final String? reason = _capabilityState?['probeErrorReason'] as String?;
      if (reason != null && reason.trim().isNotEmpty) {
        return '$_capabilityMode.label（${reason.trim()}）';
      }
    }
    return base;
  }

  int get capabilityProbedAtMs =>
      (_capabilityState?['probedAtMs'] as num?)?.toInt() ??
      (_capabilityState?['lastProbeErrorAtMs'] as num?)?.toInt() ??
      0;
  UnbackedRetentionPolicy get unbackedRetention => _unbackedRetention;
  BackedRetentionPolicy get backedRetention => _backedRetention;
  bool get recordAudioEnabled => _recordAudioEnabled;
  RecordingVideoCodec get preferredVideoCodec => _preferredVideoCodec;
  RecordingSpecPreset get recordingSpec => _recordingSpec;
  RecordingOrientation get recordingOrientation => _recordingOrientation;
  int get minimumBarcodeLength => _minimumBarcodeLength;
  int get historyPageSize => _historyPageSize;
  LanBackupSnapshot get backupSnapshot => _lanBackupService.snapshot;
  bool get pairingScanActive => _pairingScanActive;
  int get pairingSuccessRevision => _pairingSuccessRevision;
  int get pairingFailureRevision => _pairingFailureRevision;
  int get pairingReplacementRevision => _pairingReplacementRevision;
  String? get pairingMessage => _pairingMessage;

  Future<void> connectBackupHost(
    Uri baseUri, {
    LanBackupPairingConfirmation? replacementConfirmation,
  }) async {
    await _lanBackupService.connectToHost(
      baseUri,
      replacementConfirmation: replacementConfirmation,
    );
    _pairingSuccessRevision++;
    notifyListeners();
  }

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

  String? takePairingFailureForDisplay() {
    final String? message = _pairingFailureMessage;
    _pairingFailureMessage = null;
    return message;
  }

  ComputerReplacementPrompt? takeComputerReplacementPrompt() {
    final ComputerReplacementPrompt? prompt = _pairingReplacementPrompt;
    _pairingReplacementPrompt = null;
    return prompt;
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
  Set<int> get hiddenRemoteRecordingIds =>
      Set<int>.unmodifiable(_hiddenRemoteRecordingIds);
  @override
  bool get isBusy =>
      _phase == PackingSessionPhase.initializing ||
      _phase == PackingSessionPhase.starting ||
      _phase == PackingSessionPhase.saving;
  bool get isCameraReady =>
      (_supportsNativeCamera
          ? _nativeInitialization != null
          : _cameraController?.value.isInitialized == true) &&
      _phase != PackingSessionPhase.error;

  Future<bool> reserveMobileUpdatePrompt() =>
      _repository.tryReserveMobileUpdatePrompt(DateTime.now());

  Future<void> initialize({bool force = false}) {
    if (!_appStartLogged) {
      _appStartLogged = true;
      unawaited(_runtimeLog.log(kind: 'app_start'));
    }
    _startCameraDiagnosticsTimer();
    _pendingCameraInitializations++;
    final Future<void> next = _cameraInitializeTail.then(
      (_) => _initializeCamera(force: force),
    );
    final Future<void> tracked = next.whenComplete(
      () => _pendingCameraInitializations--,
    );
    _cameraInitializeTail = tracked.catchError((Object _) {});
    return tracked;
  }

  Future<void> _initializeCamera({required bool force}) async {
    if (_disposed || (!force && isCameraReady)) {
      return;
    }
    final Stopwatch totalStopwatch = Stopwatch()..start();
    final Map<String, int> stageDurationsMs = <String, int>{};
    AppSettings? loadedSettings;
    _setPhase(PackingSessionPhase.initializing);
    _errorMessage = null;

    try {
      await _measureCameraPreparationStage(
        stageDurationsMs,
        'repository',
        _repository.initialize,
      );
      await _measureCameraPreparationStage(
        stageDurationsMs,
        'recentSessions',
        _reloadRecentSessions,
      );
      final AppSettings settings = await _measureCameraPreparationStage(
        stageDurationsMs,
        'settings',
        _repository.loadSettings,
      );
      loadedSettings = settings;
      _workMode = settings.workMode;
      _operationMode = settings.operationMode;
      _speechEnabled = settings.speechEnabled;
      _orderSpeechEnabled = settings.orderSpeechEnabled;
      _maxVolumeEnabled = settings.maxVolumeEnabled;
      _unbackedRetention = settings.unbackedRetention;
      _backedRetention = settings.backedRetention;
      _recordAudioEnabled = settings.recordAudioEnabled;
      _nativeRecordingFallback = settings.nativeRecordingFallback;
      _capabilityState = settings.cameraCapabilityState;
      _preferredVideoCodec = settings.preferredVideoCodec;
      _recordingSpec = settings.recordingSpec;
      _recordingOrientation = settings.recordingOrientation;
      _minimumBarcodeLength = settings.minimumBarcodeLength;
      _historyPageSize = settings.historyPageSize;
      _hiddenRemoteRecordingIds = Set<int>.of(
        settings.hiddenRemoteRecordingIds,
      );
      await _measureCameraPreparationStage(
        stageDurationsMs,
        'speech',
        () => _speechService.setEnabled(_speechEnabled),
      );
      if (_supportsNativeCamera) {
        final ContinuousCameraService nativeCamera =
            _nativeCamera ?? ContinuousCameraService();
        nativeCamera.onBarcodeFrame = _processNativeBarcodeFrame;
        nativeCamera.onError = (String message) {
          _errorMessage = message;
          _speakErrorMessage(message);
          unawaited(
            _cameraDiagnostics.recordEvent(
              kind: 'native_error',
              extra: <String, Object?>{'message': message},
            ),
          );
          if (!_disposed) {
            notifyListeners();
          }
        };
        nativeCamera.onStorageCritical = () {
          unawaited(_handleNativeStorageCritical());
        };
        nativeCamera.onProbeFinished = _handleNativeProbeFinished;
        nativeCamera.onRecordingFallback = _handleNativeRecordingFallback;
        _nativeCamera = nativeCamera;
        final bool nativePermissionsGranted =
            await _measureCameraPreparationStage(
              stageDurationsMs,
              'permissions',
              () => nativeCamera.ensurePermissions(
                recordAudio: _recordAudioEnabled,
              ),
            );
        if (!nativePermissionsGranted) {
          throw PlatformException(
            code: 'permission_denied',
            message: '需要摄像头和麦克风权限才能工作',
          );
        }
        _nativeInitialization = await _measureCameraPreparationStage(
          stageDurationsMs,
          'nativeCamera',
          () => nativeCamera
              .initialize(
                videoCodec: _preferredVideoCodec,
                recordingSpec: _recordingSpec,
                recordingOrientation: _recordingOrientation,
                capabilityMode: _provisionalCapabilityMode().wireValue,
              )
              .timeout(
                const Duration(seconds: 15),
                onTimeout: () => throw TimeoutException('摄像头初始化超过 15 秒'),
              ),
        );
        final String? codecFallbackReason =
            _nativeInitialization?.codecFallbackReason;
        if (codecFallbackReason != null) {
          developer.log(
            _codecFallbackMessage(codecFallbackReason),
            name: 'PackingProof.Codec',
          );
          unawaited(
            _runtimeLog.log(
              kind: 'codec_fallback',
              extra: <String, Object?>{
                'reason': codecFallbackReason,
                'videoMime': _nativeInitialization?.videoMime,
              },
            ),
          );
        }
        await _measureCameraPreparationStage(
          stageDurationsMs,
          'cameraLenses',
          _refreshBackCameraLenses,
        );
        await _measureCameraPreparationStage(
          stageDurationsMs,
          'capabilityCache',
          _resolveCameraCapability,
        );
        if (_phase == PackingSessionPhase.error) {
          return;
        }
        _speechService.resetIncidents();
        _setPhase(PackingSessionPhase.ready);
        return;
      }
      final List<CameraDescription> cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('NoCamera', '没有检测到可用摄像头');
      }
      final CameraDescription selected = cameras.firstWhere(
        (CameraDescription camera) =>
            camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final CameraController controller = CameraController(
        selected,
        ResolutionPreset.veryHigh,
        enableAudio: _recordAudioEnabled,
        fps: recordingFps,
        imageFormatGroup: _supportsNativeCamera
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      _cameraController = controller;
      await controller.initialize().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('摄像头初始化超过 15 秒'),
      );
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      try {
        await controller.setFlashMode(FlashMode.off);
      } on CameraException {
        // Some tablets and emulators expose a camera without a controllable flash.
      }
      _setPhase(PackingSessionPhase.ready);
      _speechService.resetIncidents();
    } on PlatformException catch (error) {
      _recordInitFailure(error.code, error.message ?? '');
      _errorMessage = error.code == 'permission_denied'
          ? '需要摄像头${_recordAudioEnabled ? '和麦克风' : ''}权限才能工作\n请允许权限后重试'
          : '摄像头初始化失败，请重试\n${error.message ?? error.code}';
      _setPhase(PackingSessionPhase.error);
    } on CameraException catch (error) {
      _recordInitFailure(error.code, error.description ?? '');
      _setCameraError(error);
    } on Object catch (error) {
      _recordInitFailure('unknown', '$error');
      _errorMessage = '摄像头初始化失败，请重试\n$error';
      _setPhase(PackingSessionPhase.error);
    } finally {
      final bool cameraReadyBeforeBackgroundServices = isCameraReady;
      if (loadedSettings != null) {
        await _measureCameraPreparationStage(
          stageDurationsMs,
          'backgroundServices',
          () => _initializeBackgroundServices(loadedSettings!),
        );
      }
      totalStopwatch.stop();
      await _runtimeLog.log(
        kind: 'camera_prepare_timing',
        extra: <String, Object?>{
          'force': force,
          'phase': _phase.name,
          'readyBeforeBackgroundServices': cameraReadyBeforeBackgroundServices,
          'totalMs': totalStopwatch.elapsedMilliseconds,
          'stagesMs': stageDurationsMs,
        },
      );
    }
  }

  Future<T> _measureCameraPreparationStage<T>(
    Map<String, int> durations,
    String stage,
    Future<T> Function() action,
  ) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      return await action();
    } finally {
      stopwatch.stop();
      durations[stage] = stopwatch.elapsedMilliseconds;
    }
  }

  Future<void> _initializeBackgroundServices(AppSettings settings) async {
    if (_disposed || _backgroundServicesInitialized) return;
    try {
      await _logAppUpgradeIfNeeded(settings);
    } on Object {
      // Runtime metadata is diagnostic and must not delay camera availability.
    }
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
        await _pruneDeletedBackupSessions(notify: false);
      } on Object {
        // Local history remains available even when optional cleanup cannot run.
      }
      if (_lanBackupService.snapshot.autoEnabled) {
        _runInBackground(_backupAllRepositorySessions('app_start'));
      } else {
        _runInBackground(_registerRepositorySessionsForRetention());
      }
    }
    if (_capabilities.supports(PlatformCapability.orderInfoReceiver) &&
        !_orderReceiverListenerAttached) {
      _orderInfoReceiver.addListener(_handleOrderReceiverChanged);
      _orderReceiverListenerAttached = true;
      _orderInfoSubscription = _orderInfoReceiver.received.listen(
        _handleReceivedOrderInfo,
      );
      try {
        await _orderInfoReceiver.initialize().timeout(
          const Duration(seconds: 8),
        );
      } on Object {
        // Order push can be retried from settings after the camera is ready.
      }
    }
    _backgroundServicesInitialized = true;
    if (!_disposed) notifyListeners();
  }

  Future<void> retryInitialize() async {
    unawaited(_cameraDiagnostics.recordEvent(kind: 'retry_initialize'));
    await _disposeCamera();
    await initialize(force: true);
  }

  /// 设置页「重新检测」：仅空闲时可用，探测期间阻塞开始工作。
  Future<void> retryCapabilityProbe() async {
    if (_disposed || !_supportsNativeCamera || _nativeCamera == null) return;
    if (isWorking || isBusy || _capabilityProbeRunning) return;
    _errorMessage = null;
    _setPhase(PackingSessionPhase.initializing);
    _capabilityProbeMessage = '正在重新检测摄像头能力';
    notifyListeners();
    final Map<String, Object?> identity = await _currentCameraIdentity();
    await _runCapabilityProbe(
      identity.isEmpty ? const <String, Object?>{} : identity,
      message: '正在重新检测摄像头能力',
    );
    if (_disposed) return;
    if (_phase != PackingSessionPhase.error) {
      _setPhase(PackingSessionPhase.ready);
    }
    notifyListeners();
  }

  void _handleNativeProbeFinished(Map<Object?, Object?> results) {
    unawaited(
      _cameraDiagnostics.recordEvent(
        kind: 'probe_finished',
        extra: results.cast<String, Object?>(),
      ),
    );
    unawaited(_captureCameraDiagnosticsSnapshot('probe_finished'));
  }

  void _recordInitFailure(String code, String message) {
    unawaited(
      _cameraDiagnostics.recordEvent(
        kind: 'init_failed',
        extra: <String, Object?>{'code': code, 'message': message},
      ),
    );
  }

  Future<Map<String, Object?>> _loadRuntimeMetadata() {
    final Future<Map<String, Object?>>? existing = _runtimeMetadataFuture;
    if (existing != null) {
      return existing;
    }
    final Future<Map<String, Object?>> loaded = _loadRuntimeMetadataNow();
    _runtimeMetadataFuture = loaded;
    return loaded;
  }

  Future<Map<String, Object?>> _loadRuntimeMetadataNow() async {
    String? appVersion;
    int? appBuildNumber;
    try {
      final PackageInfo info = await _packageInfoLoader();
      appVersion = info.version;
      appBuildNumber = int.tryParse(info.buildNumber);
    } on Object {
      // 版本信息失败时仍返回稳定的空字段，不能阻塞相机初始化。
    }
    return <String, Object?>{
      'appVersion': appVersion,
      'appBuildNumber': appBuildNumber,
      'buildRevision': _buildConfig.buildRevision.isEmpty
          ? null
          : _buildConfig.buildRevision,
      'buildTimestamp': _buildConfig.buildTimestamp.isEmpty
          ? null
          : _buildConfig.buildTimestamp,
    };
  }

  String _buildIdentity(Map<String, Object?> metadata) {
    final String version = '${metadata['appVersion'] ?? ''}';
    if (version.isEmpty) {
      return '';
    }
    final Object? buildNumber = metadata['appBuildNumber'];
    final String revision = '${metadata['buildRevision'] ?? ''}';
    final String timestamp = '${metadata['buildTimestamp'] ?? ''}';
    final String discriminator = revision.isNotEmpty ? revision : timestamp;
    return '$version|${buildNumber ?? ''}|$discriminator';
  }

  Future<void> _logAppUpgradeIfNeeded(AppSettings settings) async {
    final Map<String, Object?> metadata = await _loadRuntimeMetadata();
    final String version = '${metadata['appVersion'] ?? ''}';
    final int buildNumber = (metadata['appBuildNumber'] as num?)?.toInt() ?? 0;
    if (version.isEmpty) {
      return;
    }
    final String buildIdentity = _buildIdentity(metadata);
    final bool hasHistory =
        settings.lastLoggedAppVersion.isNotEmpty ||
        settings.lastLoggedBuildIdentity.isNotEmpty;
    final bool changed =
        hasHistory &&
        (settings.lastLoggedAppVersion != version ||
            settings.lastLoggedAppBuildNumber != buildNumber ||
            settings.lastLoggedBuildIdentity != buildIdentity);
    if (changed) {
      await _runtimeLog.log(
        kind: 'app_upgrade',
        extra: <String, Object?>{
          'previousVersion': settings.lastLoggedAppVersion,
          'previousBuildNumber': settings.lastLoggedAppBuildNumber,
          'previousBuildIdentity': settings.lastLoggedBuildIdentity,
          'currentVersion': version,
          'currentBuildNumber': buildNumber,
          'currentBuildIdentity': buildIdentity,
        },
      );
    }
    await _repository.saveLastLoggedAppIdentity(
      version: version,
      buildNumber: buildNumber,
      buildIdentity: buildIdentity,
    );
  }

  void _handleNativeRecordingFallback(
    Map<Object?, Object?> info, {
    bool persist = true,
  }) {
    if (persist) {
      unawaited(
        _cameraDiagnostics.recordEvent(
          kind: 'recording_fallback',
          extra: info.cast<String, Object?>(),
        ),
      );
    }
    final String mode = '${info['mode'] ?? ''}';
    if (mode == 'encoder_analysis') {
      _capabilityMode = CameraCapabilityMode.encoderAnalysis;
      if (persist && !_nativeRecordingFallback) {
        _nativeRecordingFallback = true;
        _runInBackground(_repository.saveNativeRecordingFallback(true));
      }
      if (persist) {
        _runInBackground(_recordCapabilitySuspicion(info));
      }
    }
    notifyListeners();
    _showCameraNotice(
      mode == 'encoder_analysis' ? '受硬件限制，录像时预览画面会暂停，扫码和录像不受影响' : '已切换录像兼容模式',
    );
  }

  CameraCapabilityMode _provisionalCapabilityMode() {
    if (_capabilityMode != CameraCapabilityMode.unverified &&
        _capabilityMode != CameraCapabilityMode.unsupported) {
      return _capabilityMode;
    }
    return _nativeRecordingFallback
        ? CameraCapabilityMode.encoderAnalysis
        : CameraCapabilityMode.unverified;
  }

  Future<void> _resolveCameraCapability() async {
    if (_disposed || !_supportsNativeCamera || _nativeCamera == null) return;
    final Map<String, Object?> identity = await _currentCameraIdentity();
    if (identity.isEmpty) return;
    final Map<String, Object?>? cached = _capabilityState;
    final Map<String, Object?>? cachedIdentity = _identityMap(
      cached?['identity'],
    );
    final bool cacheValid =
        _identityMatches(cachedIdentity, identity) &&
        _capabilityState?['stale'] != true;
    if (cacheValid) {
      final CameraCapabilityMode mode = CameraCapabilityMode.fromWire(
        cached?['mode'],
      );
      if (mode != CameraCapabilityMode.unverified &&
          mode != CameraCapabilityMode.unsupported) {
        _capabilityMode = mode;
        await _nativeCamera!.setCapabilityMode(mode.wireValue);
        return;
      }
      if (mode == CameraCapabilityMode.unsupported) {
        _capabilityMode = mode;
        _errorMessage = '此设备无法同时提供预览和识别，暂时无法进行打包录像';
        _setPhase(PackingSessionPhase.error);
        return;
      }
    }
    // 0.5.21 回归修复：首次启动不再自动阻塞式探测并持久化模式。
    // 保留手动“重新检测”入口；平时按旧版逻辑先尝试完整三路，
    // 只有真正发生停摆时才由原生 recordingFallback 降级。
  }

  Future<Map<String, Object?>> _currentCameraIdentity() async {
    final ContinuousCameraService? camera = _nativeCamera;
    if (camera == null) return const <String, Object?>{};
    final CameraDiagnosticsSnapshot? snapshot = await camera.getDiagnostics();
    if (snapshot == null) return const <String, Object?>{};
    final Map<String, Object?> cameraState = snapshot.camera;
    final String videoMime = '${cameraState['videoMime'] ?? ''}';
    return <String, Object?>{
      'cameraId': '${cameraState['cameraId'] ?? ''}',
      'videoSize':
          '${cameraState['videoWidth'] ?? 0}x${cameraState['videoHeight'] ?? 0}',
      'analysisSize':
          '${cameraState['analysisWidth'] ?? 0}x${cameraState['analysisHeight'] ?? 0}',
      'codec': videoMime.toLowerCase().contains('avc') ? 'h264' : 'hevc',
      'spec': '${cameraState['recordingSpec'] ?? _recordingSpec.storageValue}',
      'probeSchemaVersion': CameraCapabilityPolicy.probeSchemaVersion,
      'cameraPipelineVersion': CameraCapabilityPolicy.cameraPipelineVersion,
    };
  }

  Map<String, Object?>? _identityMap(Object? value) {
    if (value is! Map) return null;
    return Map<String, Object?>.from(value);
  }

  bool _identityMatches(
    Map<String, Object?>? cached,
    Map<String, Object?> current,
  ) {
    if (cached == null) return false;
    for (final String key in current.keys) {
      if ('${cached[key]}' != '${current[key]}') return false;
    }
    return true;
  }

  Future<void> _runCapabilityProbe(
    Map<String, Object?> identity, {
    String message = '正在检测摄像头能力',
  }) async {
    if (_capabilityProbeRunning) return;
    _capabilityProbeRunning = true;
    _capabilityProbeMessage = message;
    notifyListeners();
    final Stopwatch stopwatch = Stopwatch()..start();
    final Map<String, List<CameraProbePhase>> results =
        <String, List<CameraProbePhase>>{};
    String? infraReason;
    Map<String, Object?>? probedIdentity = identity;
    try {
      for (final String sequence in CameraCapabilityPolicy.sequenceOrder) {
        final int remaining = 30000 - stopwatch.elapsedMilliseconds;
        if (remaining < 10000) {
          infraReason = '检测时间预算不足';
          break;
        }
        final int budgetMs = remaining.clamp(10000, 25000);
        final Map<Object?, Object?>? raw = await _nativeCamera!.probeSequence(
          sequence,
          budgetMs: budgetMs,
        );
        if (raw == null) {
          infraReason = '原生探针没有返回结果';
          break;
        }
        probedIdentity = _identityMap(raw['identity']) ?? probedIdentity;
        final String status = '${raw['status'] ?? 'error'}';
        if (status == 'error' || status == 'budget_exceeded') {
          infraReason = '${raw['probeErrorReason'] ?? status}';
          break;
        }
        final List<Object?> phaseList = List<Object?>.from(
          raw['phases'] as List? ?? const <Object?>[],
        );
        final List<CameraProbePhase> phases = phaseList
            .map(
              (Object? item) => CameraProbePhase.fromMap(
                Map<Object?, Object?>.from(item! as Map),
              ),
            )
            .toList(growable: false);
        results[sequence] = phases;
        final CameraSequenceVerdict verdict =
            CameraCapabilityPolicy.evaluateSequence(
              sequence,
              phases,
              fps: _recordingSpec.fps,
            );
        if (verdict == CameraSequenceVerdict.errorInfra) {
          infraReason = '$sequence 探测阶段发生异常';
          break;
        }
        if (verdict == CameraSequenceVerdict.passed) break;
      }
    } on Object catch (error) {
      infraReason = '$error';
    } finally {
      _capabilityProbeRunning = false;
      _capabilityProbeMessage = null;
    }
    final CameraCapabilityDecision decision = infraReason != null
        ? CameraCapabilityDecision.unverified(infraReason)
        : CameraCapabilityPolicy.decide(results, fps: _recordingSpec.fps);
    await _applyCapabilityDecision(
      decision,
      identity: probedIdentity,
      phases: <Map<String, Object?>>[
        for (final String sequence in results.keys)
          <String, Object?>{
            'sequence': sequence,
            'phases': results[sequence]!
                .map(
                  (CameraProbePhase phase) => <String, Object?>{
                    'phase': phase.phase,
                    'candidate': phase.candidate,
                    'outcome': phase.outcome,
                    'detail': phase.detail,
                    'previewFrames': phase.previewFrames,
                    'analysisFrames': phase.analysisFrames,
                    'encoderBuffers': phase.encoderBuffers,
                    'durationMs': phase.durationMs,
                  },
                )
                .toList(growable: false),
          },
      ],
    );
  }

  Future<void> _applyCapabilityDecision(
    CameraCapabilityDecision decision, {
    required Map<String, Object?>? identity,
    required List<Map<String, Object?>> phases,
  }) async {
    if (decision.mode == CameraCapabilityMode.unverified) {
      _capabilityMode = _nativeRecordingFallback
          ? CameraCapabilityMode.encoderAnalysis
          : CameraCapabilityMode.unverified;
      try {
        await _nativeCamera?.setCapabilityMode(_capabilityMode.wireValue);
      } on Object {
        // 下发失败不影响回退到常规路径。
      }
      final Map<String, Object?> state = <String, Object?>{
        'mode': CameraCapabilityMode.unverified.wireValue,
        'identity': identity,
        'lastProbeErrorAtMs': DateTime.now().millisecondsSinceEpoch,
        'probeErrorReason': decision.infraReason ?? '未知错误',
        'probePhases': phases,
      };
      _capabilityState = state;
      await _repository.saveCameraCapabilityState(state);
      unawaited(
        _cameraDiagnostics.recordEvent(
          kind: 'probe_infra_error',
          extra: <String, Object?>{
            'reason': decision.infraReason ?? '',
            'phases': phases,
          },
        ),
      );
      notifyListeners();
      return;
    }
    _capabilityMode = decision.mode;
    try {
      await _nativeCamera?.setCapabilityMode(decision.mode.wireValue);
    } on Object {
      // 模式下发失败时继续沿用常规路径，不阻塞工作。
      _capabilityMode = CameraCapabilityMode.unverified;
    }
    final Map<String, Object?> state = <String, Object?>{
      'mode': _capabilityMode.wireValue,
      'identity': identity,
      'probedAtMs': DateTime.now().millisecondsSinceEpoch,
      'probePhases': phases,
    };
    _capabilityState = state;
    await _repository.saveCameraCapabilityState(state);
    unawaited(
      _cameraDiagnostics.recordEvent(
        kind: 'capability_probed',
        extra: <String, Object?>{
          'mode': _capabilityMode.wireValue,
          'identity': identity ?? const <String, Object?>{},
        },
      ),
    );
    if (decision.mode == CameraCapabilityMode.unsupported) {
      _errorMessage = '此设备无法同时提供预览和识别，暂时无法进行打包录像';
      _setPhase(PackingSessionPhase.error);
    } else if (decision.mode != CameraCapabilityMode.full) {
      _capabilityNoticeMessage =
          '该设备无法同时预览、识别和录像，已启用${decision.mode.label}：${decision.mode.description}';
    }
    notifyListeners();
  }

  Future<void> _recordCapabilitySuspicion(Map<Object?, Object?> info) async {
    final String cameraId = _nativeInitialization?.cameraId ?? '';
    String sessionConfigStage = '';
    try {
      final CameraDiagnosticsSnapshot? snapshot = await _nativeCamera
          ?.getDiagnostics();
      sessionConfigStage = '${snapshot?.camera['sessionConfigStage'] ?? ''}';
    } on Object {
      // 诊断失败不影响降级安全网。
    }
    final String key = <String>[
      cameraId,
      _capabilityMode.wireValue,
      sessionConfigStage,
      '${info['phase'] ?? ''}',
      '${info['mode'] ?? ''}',
    ].join('|');
    final Map<String, Object?>? state = _capabilityState;
    final List<Object?> existing = List<Object?>.from(
      state?['suspicions'] as List? ?? const <Object?>[],
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<Map<String, Object?>> suspicions = existing
        .map((Object? item) => Map<String, Object?>.from(item! as Map))
        .where(
          (Map<String, Object?> item) =>
              (item['key'] == key) &&
              now - ((item['atMs'] as num?)?.toInt() ?? 0) <
                  const Duration(hours: 24).inMilliseconds,
        )
        .toList(growable: true);
    suspicions.add(<String, Object?>{'key': key, 'atMs': now});
    final bool thresholdReached = suspicions.length >= 2;
    final Map<String, Object?> updated = <String, Object?>{
      ...?_capabilityState,
      'suspicions': suspicions,
      if (thresholdReached) 'stale': true,
    };
    _capabilityState = updated;
    _runInBackground(_repository.saveCameraCapabilityState(updated));
    if (thresholdReached) {
      unawaited(
        _cameraDiagnostics.recordEvent(
          kind: 'capability_suspicion_threshold',
          extra: <String, Object?>{'key': key},
        ),
      );
    }
  }

  @override
  void _showCameraNotice(String message) {
    _cameraNotice = message;
    _cameraNoticeTimer?.cancel();
    _cameraNoticeTimer = Timer(const Duration(seconds: 5), () {
      _cameraNotice = null;
      if (!_disposed) {
        notifyListeners();
      }
    });
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _startCameraDiagnosticsTimer() {
    if (!_supportsNativeCamera || _diagnosticsTimer != null) return;
    _diagnosticsTimer = Timer.periodic(
      CameraDiagnosticsService.heartbeatInterval,
      (_) => unawaited(_captureCameraDiagnosticsSnapshot('heartbeat')),
    );
  }

  Future<void> _captureCameraDiagnosticsSnapshot(String trigger) async {
    if (!_supportsNativeCamera || _disposed || _nativeCamera == null) return;
    try {
      final CameraDiagnosticsSnapshot? snapshot = await _nativeCamera!
          .getDiagnostics();
      if (snapshot == null) return;
      await _cameraDiagnostics.recordSnapshot(
        trigger: trigger,
        snapshot: snapshot,
      );
    } on Object {
      // 诊断轮询绝不能阻塞或中断相机工作流。
    }
  }

  Future<void> toggleTorch() async {
    if (!flashAvailable || isBusy) return;
    final bool enabled = !_torchEnabled;
    try {
      if (_supportsNativeCamera) {
        _torchEnabled = await _nativeCamera!.setTorchEnabled(enabled);
      } else {
        await _cameraController!.setFlashMode(
          enabled ? FlashMode.torch : FlashMode.off,
        );
        _torchEnabled = enabled;
      }
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

  Future<void> _refreshBackCameraLenses() async {
    final ContinuousCameraService? nativeCamera = _nativeCamera;
    if (nativeCamera == null) return;
    try {
      final List<NativeCameraLens> lenses = await nativeCamera.listCameras();
      _backCameraLenses = scannableBackLenses(lenses);
    } on Object {
      _backCameraLenses = const <NativeCameraLens>[];
    }
    if (!_disposed) {
      notifyListeners();
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
    final StorageSpaceResult storage = await _checkAndHandleStorage(
      allowStop: false,
    );
    if (storage.insufficient) {
      _errorMessage = '存储空间不足 2GB，请清理空间或连接电脑完成录像备份';
      notifyListeners();
      return;
    }

    await _beginMaxVolumeIfNeeded();
    await _boostMaxVolumeIfNeeded();

    _errorMessage = null;
    _lastMarker = null;
    _candidateCode = '';
    _timeline.reset();
    _activeOrderInfo = null;
    _lastAnnouncedOrderSignature = '';
    _stabilityTracker.reset();
    _speechService.resetIncidents();
    if (_speechService case final SpeechPromptService speech) {
      await speech.prepareDuplicateOrderWarning();
    }
    _beginInitialPromptFlow();

    try {
      await WakelockPlus.enable();
      await setPreviewActive(true);
      await _setNativeWorkScanEnabled(true);
      unawaited(_captureCameraDiagnosticsSnapshot('start_work'));
      _workActive = true;
      _startStorageMonitor();
      await _orderInfoReceiver.setBackgroundKeepAlive(false);
      _elapsed = Duration.zero;
      _setPhase(PackingSessionPhase.waitingForBarcode);
      unawaited(
        _runtimeLog.log(
          kind: 'start_work_done',
          extra: <String, Object?>{'generation': generation},
        ),
      );
      _scheduleInitialModeAnnouncement();
    } on CameraException catch (error) {
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
    } on Object catch (error) {
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
      return null;
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
      _elapsed = Duration.zero;
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

  Future<void> setWorkMode(WorkMode mode) async {
    if (_workMode == mode || isWorking || isBusy) {
      return;
    }
    _workMode = mode;
    notifyListeners();
    await _repository.saveWorkMode(mode);
  }

  Future<void> setOperationMode(RecordingOperationMode mode) async {
    if (_operationMode == mode || isWorking || isBusy) {
      return;
    }
    _operationMode = mode;
    notifyListeners();
    _speechService.enqueue(_speechForOperationMode(mode));
    await _repository.saveOperationMode(mode);
  }

  SpeechPrompt _speechForOperationMode(RecordingOperationMode mode) =>
      mode == RecordingOperationMode.returnGoods
      ? SpeechPrompt.returnMode
      : SpeechPrompt.shippingMode;

  Future<void> setSpeechEnabled(bool enabled) async {
    if (_speechEnabled == enabled) {
      return;
    }
    _speechEnabled = enabled;
    notifyListeners();
    await _speechService.setEnabled(enabled);
    await _repository.saveSpeechEnabled(enabled);
  }

  Future<void> setOrderSpeechEnabled(bool enabled) async {
    if (_orderSpeechEnabled == enabled) return;
    _orderSpeechEnabled = enabled;
    notifyListeners();
    await _repository.saveOrderSpeechEnabled(enabled);
  }

  Future<void> retryOrderReceiver() => _orderInfoReceiver.retry();

  Future<void> setMaxVolumeEnabled(bool enabled) async {
    if (_maxVolumeEnabled == enabled) {
      return;
    }
    _maxVolumeEnabled = enabled;
    notifyListeners();
    if (enabled) {
      if (isWorking) {
        await _beginMaxVolumeIfNeeded();
      }
    } else {
      await _disableMaxVolume();
    }
    await _repository.saveMaxVolumeEnabled(enabled);
  }

  Future<void> setRecordAudioEnabled(bool enabled) async {
    if (_recordAudioEnabled == enabled) {
      return;
    }
    _recordAudioEnabled = enabled;
    notifyListeners();
    if (enabled) {
      unawaited(_requestRecordingAudioPermission());
    }
    await _repository.saveRecordAudioEnabled(enabled);
  }

  Future<void> setPreferredVideoCodec(RecordingVideoCodec codec) async {
    if (_preferredVideoCodec == codec) {
      return;
    }
    _preferredVideoCodec = codec;
    notifyListeners();
    await _repository.savePreferredVideoCodec(codec);
    if (_supportsNativeCamera && _phase != PackingSessionPhase.saving) {
      // 编码器在相机初始化时创建，切换后必须重建相机才会生效；
      // 若正在工作，先安全结束当前工作（正在录的片段会正常保存）。
      if (isWorking) {
        await stopWork();
      }
      await retryInitialize();
    }
  }

  Future<void> setRecordingSpec(RecordingSpecPreset spec) async {
    if (_recordingSpec == spec) {
      return;
    }
    _recordingSpec = spec;
    notifyListeners();
    await _repository.saveRecordingSpec(spec);
    if (_supportsNativeCamera && _phase != PackingSessionPhase.saving) {
      // 编码器在相机初始化时创建，切换规格后必须重建相机才会生效；
      // 若正在工作，先安全结束当前工作（正在录的片段会正常保存）。
      if (isWorking) {
        await stopWork();
      }
      await retryInitialize();
    }
  }

  Future<void> setRecordingOrientation(RecordingOrientation orientation) async {
    if (_recordingOrientation == orientation) return;
    _recordingOrientation = orientation;
    notifyListeners();
    await _repository.saveRecordingOrientation(orientation);
    if (_supportsNativeCamera && !isWorking) await retryInitialize();
  }

  Future<void> setMinimumBarcodeLength(int value) async {
    final int normalized = AppSettings.normalizeBarcodeLength(value);
    if (_minimumBarcodeLength == normalized) {
      return;
    }
    _minimumBarcodeLength = normalized;
    notifyListeners();
    await _repository.saveMinimumBarcodeLength(normalized);
  }

  Future<void> setHistoryPageSize(int value) async {
    final int normalized = AppSettings.normalizeHistoryPageSize(value);
    if (_historyPageSize == normalized) {
      return;
    }
    _historyPageSize = normalized;
    notifyListeners();
    await _repository.saveHistoryPageSize(normalized);
  }

  Future<void> _requestRecordingAudioPermission() async {
    try {
      await _nativeCamera?.ensurePermissions(recordAudio: true);
    } on Object {
      // 未授权麦克风时，开始录像阶段会给出明确提示。
    }
  }

  void beginComputerPairing() {
    if (isWorking || isBusy) {
      return;
    }
    _pairingAttemptRevision++;
    _clearPendingComputerReplacement();
    _pairingScanActive = true;
    _pairingMessage = '将电脑上的二维码放入框内';
    _stabilityTracker.reset();
    unawaited(_nativeCamera?.setPairingScanEnabled(true));
    notifyListeners();
  }

  void cancelComputerPairing() {
    _pairingFeedbackTimer?.cancel();
    _pairingAttemptRevision++;
    _pairingScanActive = false;
    _pairingMessage = null;
    _clearPendingComputerReplacement();
    _lanBackupService.cancelPairing();
    unawaited(_nativeCamera?.setPairingScanEnabled(false));
    notifyListeners();
  }

  void beginHistoryBarcodeScan() {
    if (isWorking || isBusy) return;
    _historyScanResult = null;
    _historyScanActive = true;
    _stabilityTracker.reset();
    unawaited(_nativeCamera?.setPairingScanEnabled(true));
    notifyListeners();
  }

  void cancelHistoryBarcodeScan() {
    _historyScanActive = false;
    unawaited(_nativeCamera?.setPairingScanEnabled(false));
    notifyListeners();
  }

  void clearHistoryScanResult() => _historyScanResult = null;

  Future<LocalRecordingPage> loadLocalRecordings({
    required int page,
    required int pageSize,
    String keyword = '',
    DateTime? start,
    DateTime? end,
  }) => _repository.querySessions(
    page: page,
    pageSize: pageSize,
    keyword: keyword,
    start: start,
    end: end,
  );

  Future<void> disconnectBackup() => _lanBackupService.disconnect();

  Future<NetworkDiagnostics?> fetchNetworkDiagnostics() =>
      _lanBackupService.getNetworkDiagnostics();

  Future<void> retryBackup(String jobId) => _lanBackupService.retry(jobId);

  Future<RemoteRecordingPage> fetchRemoteRecordings({
    required int page,
    required int pageSize,
    String keyword = '',
  }) => _lanBackupService.fetchRemoteRecordings(
    page: page,
    pageSize: pageSize,
    keyword: keyword,
  );

  Future<Map<int, ({RemoteRecordingStatus status, bool exists, String reason})>>
  fetchRemoteRecordingStatuses(Iterable<int> ids) =>
      _lanBackupService.fetchRemoteRecordingStatuses(ids);

  Future<Uri?> resolveRemoteRecordingUri(Uri remoteUri) =>
      _lanBackupService.resolveRemoteUri(remoteUri);

  Map<String, String> get remotePlaybackHeaders =>
      _lanBackupService.playbackHeaders;

  RemoteVideoClipSink? createRemoteVideoClipService(Uri remoteUri) =>
      _lanBackupService.createRemoteVideoClipService(remoteUri);

  Future<void> previewSpeech() => _speechService.preview();

  @override
  Future<void> _startRecording() async {
    if (_supportsNativeCamera) {
      await _startNativeRecording();
      return;
    }
    final CameraController? camera = _cameraController;
    if (camera == null || !camera.value.isInitialized) {
      throw CameraException('CameraNotReady', '摄像头尚未准备完成');
    }

    final DateTime startedAt = DateTime.now();
    _timeline.start(startedAt);
    _elapsed = Duration.zero;
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

  Future<void> _startNativeRecording() async {
    final ContinuousCameraService? camera = _nativeCamera;
    if (camera == null || _nativeInitialization == null) {
      throw StateError('摄像头尚未准备完成');
    }
    _setPhase(PackingSessionPhase.starting);
    await WidgetsBinding.instance.endOfFrame;
    final String recordingId = _sessionId(DateTime.now());
    final String path = await _repository.recordingPath(recordingId);
    final NativeRecordingStart started = await camera.startWork(
      path,
      recordAudio: _recordAudioEnabled,
    );
    _recordingId = recordingId;
    _activeSegmentId = recordingId;
    _segmentIndex = 1;
    _timeline.start(started.startedAt);
    _elapsed = Duration.zero;
    _setPhase(PackingSessionPhase.recording);
    _startElapsedTimer();
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
    _elapsed = endedAt.difference(startedAt);
    _timeline.reset();
    return sessions;
  }

  Future<List<RecordingSession>> _finishNativeRecording() async {
    final ContinuousCameraService camera = _nativeCamera!;
    final String segmentId = _activeSegmentId!;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    final NativeRecordingStop stopped = await camera.stopWork();
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
    final RecordingSession session = _standaloneSession(
      id: segmentId,
      path: savedPath,
      draft: draft,
    );
    _sessions = await _repository.addSession(session);
    _runInBackground(_watermarkAndBackup(savedPath, session));
    _elapsed = stopped.endedAt.difference(_timeline.recordingStartedAt!);
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
      _elapsed = DateTime.now().difference(startedAt);
      notifyListeners();
    });
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
    await _orderInfoReceiver.setBackgroundKeepAlive(false);
    unawaited(_lanBackupService.refresh());
    if (isWorking) {
      await _beginMaxVolumeIfNeeded();
    }
  }

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
      _elapsed = Duration.zero;
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
    required OrderInfo? nextOrderInfo,
    required void Function(BarcodeMarker marker) onSegmentStarted,
  }) async {
    final ContinuousCameraService? camera = _nativeCamera;
    final String? recordingId = _recordingId;
    final String? completedId = _activeSegmentId;
    if (camera == null || recordingId == null || completedId == null) {
      return null;
    }
    final StorageSpaceResult storage = await _checkAndHandleStorage(
      allowStop: true,
    );
    if (storage.insufficient || !isWorking) return null;
    final int nextIndex = _segmentIndex + 1;
    final OrderInfo? completedOrderInfo = _activeOrderInfo;
    final String nextId =
        '${recordingId}_${nextIndex.toString().padLeft(3, '0')}';
    final String nextPath = await _repository.recordingPath(nextId);
    final NativeRecordingSplit split = await camera.split(nextPath);
    final RecordingSegmentTransition? transition = _timeline.startNext(
      code,
      split.boundaryAt,
    );
    if (transition == null) {
      throw StateError('录像时间线无法开始下一段');
    }
    _setActiveOrderInfo(nextOrderInfo, announce: false);
    _resetSegmentElapsed();
    onSegmentStarted(transition.marker);
    final String savedPath = await _repository.finalizeVideo(
      sourcePath: split.completedPath,
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
      draft: transition.completed,
      orderInfo: completedOrderInfo,
    );
    _sessions = await _repository.addSession(completed);
    _runInBackground(_watermarkAndBackup(savedPath, completed));
    _activeSegmentId = nextId;
    _segmentIndex = nextIndex;
    return transition.marker;
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
      _runInBackground(_watermarkAndBackup(savedPath, completed));

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
    _elapsed = Duration.zero;
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

  @override
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
  );

  void _handleOrderReceiverChanged() {
    if (!_disposed) notifyListeners();
  }

  void _handleReceivedOrderInfo(OrderInfo info) {
    if (_disposed) return;
    if (info.isTest) {
      _speechService.enqueue(SpeechPrompt.testOrderReceived);
      return;
    }
    if (_timeline.currentCode.isEmpty ||
        info.trackingNumber != _timeline.currentCode.trim().toUpperCase()) {
      return;
    }
    _setActiveOrderInfo(info, announce: false);
    _announceOrderInfo(info);
  }

  @override
  void _setActiveOrderInfo(OrderInfo? value, {required bool announce}) {
    _activeOrderInfo = value;
    if (value == null) _lastAnnouncedOrderSignature = '';
    if (!_disposed) notifyListeners();
    if (announce) _announceOrderInfo(value);
  }

  @override
  void _announceOrderInfo(OrderInfo? info) {
    if (!_speechEnabled || !_orderSpeechEnabled || info == null) return;
    final String signature = info.announcementSignature;
    if (signature == _lastAnnouncedOrderSignature) return;
    _lastAnnouncedOrderSignature = signature;
    if (_speechService case final DynamicSpeechPromptSink speech) {
      for (final message in info.speechMessages) {
        speech.enqueueText(
          message.text,
          priority: message.warning
              ? SpeechPromptPriority.warning
              : SpeechPromptPriority.normal,
          incidentKey: message.warning
              ? 'order-refund:${info.trackingNumber}:${info.orderId}:${info.refundStatus}'
              : null,
          playRemarkTone: !message.warning,
          playIndustrialAlarm: message.warning,
        );
      }
    }
  }

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
  Future<void> _tryPairComputer(String value) async {
    if (_pairingBusy || !_pairingScanActive) {
      return;
    }
    final int revision = _pairingAttemptRevision;
    _pairingBusy = true;
    final bool isComputerQr = _looksLikeComputerPairingQr(value);
    if (isComputerQr) {
      _pairingMessage = '已识别电脑二维码，正在连接…';
      notifyListeners();
    }
    try {
      await _lanBackupService.pair(value);
      if (revision != _pairingAttemptRevision || !_pairingScanActive) return;
      await _completePairingSuccess(revision);
    } on LanBackupHostMismatchException catch (error) {
      if (revision != _pairingAttemptRevision) return;
      await _queueComputerReplacement(value, error);
    } on FormatException catch (error) {
      if (revision != _pairingAttemptRevision) return;
      if (isComputerQr) {
        await _completePairingFailure(error.message.toString());
      }
      // Ordinary waybill barcodes remain silent while waiting for a computer QR.
    } on Object catch (error) {
      if (revision != _pairingAttemptRevision) return;
      await _completePairingFailure(
        error.toString().replaceFirst('Exception: ', ''),
      );
    } finally {
      _pairingBusy = false;
    }
  }

  Future<void> confirmPendingComputerReplacement() async {
    final String? qrValue = _pendingReplacementQr;
    final LanBackupPairingConfirmation? confirmation =
        _pendingReplacementConfirmation;
    if (_pairingBusy || qrValue == null || confirmation == null) return;
    final int revision = _pairingAttemptRevision;
    _pairingBusy = true;
    _pairingMessage = '正在确认新的备份电脑…';
    notifyListeners();
    try {
      await _lanBackupService.pair(
        qrValue,
        replacementConfirmation: confirmation,
      );
      if (revision != _pairingAttemptRevision) return;
      await _completePairingSuccess(revision);
    } on LanBackupHostMismatchException catch (error) {
      if (revision != _pairingAttemptRevision) return;
      await _queueComputerReplacement(qrValue, error);
    } on FormatException catch (error) {
      if (revision != _pairingAttemptRevision) return;
      await _completePairingFailure(error.message.toString());
    } on Object catch (error) {
      if (revision != _pairingAttemptRevision) return;
      await _completePairingFailure(
        error.toString().replaceFirst('Exception: ', ''),
      );
    } finally {
      _pairingBusy = false;
    }
  }

  void cancelPendingComputerReplacement() {
    _clearPendingComputerReplacement();
    _pairingMessage = null;
    notifyListeners();
  }

  Future<void> _queueComputerReplacement(
    String qrValue,
    LanBackupHostMismatchException error,
  ) async {
    _pairingScanActive = false;
    _pairingMessage = null;
    _pendingReplacementQr = qrValue;
    _pendingReplacementConfirmation = error.confirmation;
    _pairingReplacementPrompt = ComputerReplacementPrompt(
      currentComputer: _endpointDisplayName(error.currentEndpoint),
      newComputer: _endpointDisplayName(error.candidateEndpoint),
    );
    _pairingReplacementRevision++;
    try {
      await _nativeCamera?.setPairingScanEnabled(false);
    } on Object {
      // The confirmation prompt must still be shown when camera teardown fails.
    }
    notifyListeners();
  }

  Future<void> _completePairingSuccess(int revision) async {
    if (revision != _pairingAttemptRevision) return;
    _clearPendingComputerReplacement();
    _pairingScanActive = false;
    _pairingSuccessRevision++;
    await _nativeCamera?.setPairingScanEnabled(false);
    final LanBackupEndpoint? endpoint = _lanBackupService.snapshot.endpoint;
    _pairingMessage = endpoint == null
        ? '电脑连接成功'
        : '电脑连接成功 · ${endpoint.computerName} · ${endpoint.displayAddress}';
    _pairingFeedbackTimer?.cancel();
    _pairingFeedbackTimer = Timer(const Duration(seconds: 3), () {
      if (_disposed) return;
      _pairingMessage = null;
      notifyListeners();
    });
    await _backupAllRepositorySessions('pairing_completed');
    notifyListeners();
  }

  void _clearPendingComputerReplacement() {
    _pendingReplacementQr = null;
    _pendingReplacementConfirmation = null;
    _pairingReplacementPrompt = null;
  }

  static String _endpointDisplayName(LanBackupEndpoint endpoint) {
    final String name = endpoint.computerName.trim();
    return name.isNotEmpty ? name : endpoint.displayAddress;
  }

  Future<void> _completePairingFailure(String message) async {
    _pairingScanActive = false;
    _pairingMessage = null;
    _clearPendingComputerReplacement();
    _pairingFailureMessage = message;
    _pairingFailureRevision++;
    try {
      await _nativeCamera?.setPairingScanEnabled(false);
    } on Object {
      // Returning to history and showing the actionable error must still proceed.
    }
    notifyListeners();
  }

  Future<void> _reloadRecentSessions() async {
    _sessions = (await _repository.querySessions(page: 1, pageSize: 50)).data;
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

  void _beginInitialPromptFlow() {
    _initialPromptTimer?.cancel();
    _initialPromptTimer = null;
    _initialPromptPolicy.beginWork(_operationMode);
  }

  void _scheduleInitialModeAnnouncement() {
    _initialPromptTimer?.cancel();
    _initialPromptTimer = Timer(initialModeAnnouncementDelay, () {
      _initialPromptTimer = null;
      if (_disposed || !isWorking || isRecording) {
        return;
      }
      final SpeechPrompt? prompt = _initialPromptPolicy
          .onModeAnnouncementElapsed();
      if (prompt != null) {
        _speechService.enqueue(prompt);
      }
    });
  }

  void _announceInitialRecordingStarted() {
    _initialPromptTimer?.cancel();
    _initialPromptTimer = null;
    final SpeechPrompt? prompt = _initialPromptPolicy.onFirstLabelRecognized();
    _speechService.enqueue(prompt ?? SpeechPrompt.recordingStarted);
  }

  void _cancelInitialPromptFlow() {
    _initialPromptTimer?.cancel();
    _initialPromptTimer = null;
    _initialPromptPolicy.cancel();
  }

  @override
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
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  void _showDuplicateOrderWarning(String trackingNumber) {
    final String incidentKey = 'duplicate-order-number:$trackingNumber';
    _scanWarningMessage = '警告：重复单号，请确认';
    _scanWarningTimer?.cancel();
    _scanWarningTimer = Timer(const Duration(seconds: 3), () {
      if (_disposed) return;
      _scanWarningMessage = null;
      _speechService.resolveIncident(incidentKey);
      notifyListeners();
    });
    _speechService.enqueue(
      SpeechPrompt.duplicateOrderWarning,
      incidentKey: incidentKey,
    );
    notifyListeners();
  }

  @override
  Future<bool> _hasRecentTrackingNumber(String trackingNumber) async {
    try {
      return await _repository.hasRecentTrackingNumber(trackingNumber);
    } on Object {
      // Duplicate-order assistance must never prevent recording from starting.
      return false;
    }
  }

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

  Future<void> _drainBackgroundTasks() async {
    while (_backgroundTasks.isNotEmpty) {
      final List<Future<void>> pending = _backgroundTasks.toList(
        growable: false,
      );
      await Future.wait<void>(
        pending.map(
          (Future<void> task) => task.catchError((Object _, StackTrace _) {}),
        ),
      );
      _backgroundTasks.removeAll(pending);
    }
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    _disposed = true;
    if (isWorking) {
      try {
        await stopWork();
      } on Object catch (error, stackTrace) {
        developer.log(
          'PackingSessionController failed to stop active recording during shutdown',
          error: error,
          stackTrace: stackTrace,
        );
      }
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
    if (_backupListenerAttached) {
      _lanBackupService.removeListener(_handleBackupChanged);
      _backupListenerAttached = false;
    }
    if (_orderReceiverListenerAttached) {
      _orderInfoReceiver.removeListener(_handleOrderReceiverChanged);
      _orderReceiverListenerAttached = false;
    }

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
    await _drainBackgroundTasks();

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
    await cleanup('repository', _repository.dispose);
    await Future.wait<void>(<Future<void>>[
      _runtimeLog.flush(),
      _cameraDiagnostics.flush(),
    ]);
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
    unawaited(shutdown());
    super.dispose();
  }
}

bool _looksLikeComputerPairingQr(String value) {
  final String normalized = value.trim().toLowerCase();
  return normalized.startsWith('http://') || normalized.startsWith('https://');
}

/// 备份触发原因是否要求强制重启已有上传任务：只有用户手动“立即备份”需要，
/// 启动恢复、连接恢复等场景由原生状态机裁决，避免每次启动全量重启上传。
