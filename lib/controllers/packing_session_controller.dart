import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/barcode_marker.dart';
import '../models/app_settings.dart';
import '../models/backup_retention_policy.dart';
import '../models/lan_backup.dart';
import '../models/recording_session.dart';
import '../models/order_info.dart';
import '../models/recording_operation_mode.dart';
import '../models/recording_spec.dart';
import '../models/recording_video_codec.dart';
import '../models/speech_prompt.dart';
import '../models/storage_notice.dart';
import '../models/work_mode.dart';
import '../services/barcode_candidate_policy.dart';
import '../services/barcode_stability_tracker.dart';
import '../services/barcode_work_mode_policy.dart';
import '../services/camera_diagnostics_service.dart';
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

class PackingSessionController extends ChangeNotifier {
  PackingSessionController({
    SessionRepository? repository,
    SpeechPromptSink? speechService,
    MaxVolumeSink? maxVolumeService,
    LanBackupSink? lanBackupService,
    VideoWatermarkSink? videoWatermarkService,
    OrderInfoReceiverSink? orderInfoReceiver,
    DiagnosticsLogService? runtimeLog,
    CameraDiagnosticsService? cameraDiagnostics,
  }) : _repository = repository ?? SessionRepository(),
       _speechService = speechService ?? SpeechPromptService(),
       _maxVolumeService = maxVolumeService ?? MaxVolumeService(),
       _videoWatermarkService =
           videoWatermarkService ?? VideoWatermarkService(),
       _orderInfoReceiver = orderInfoReceiver ?? OrderInfoReceiverService(),
       _barcodeScanner = BarcodeScanner(
         formats: const <BarcodeFormat>[BarcodeFormat.all],
       ) {
    _runtimeLog = runtimeLog ?? DiagnosticsLogService();
    _cameraDiagnostics = cameraDiagnostics ?? CameraDiagnosticsService();
    _lanBackupService =
        lanBackupService ??
        LanBackupService(
          logEvent: (String kind, Map<String, Object?> extra) =>
              _runtimeLog.log(kind: kind, extra: extra),
        );
  }

  static const Duration analysisInterval = Duration(milliseconds: 200);
  static const Duration transitionSettleDelay = Duration(milliseconds: 120);
  static const Duration initialModeAnnouncementDelay =
      Duration(milliseconds: 250);
  static const int recordingFps = 30;

  final SessionRepository _repository;
  final SpeechPromptSink _speechService;
  final MaxVolumeSink _maxVolumeService;
  late final LanBackupSink _lanBackupService;
  final VideoWatermarkSink _videoWatermarkService;
  final OrderInfoReceiverSink _orderInfoReceiver;
  final BarcodeScanner _barcodeScanner;
  final BarcodeStabilityTracker _stabilityTracker = BarcodeStabilityTracker();
  final RecordingTimeline _timeline = RecordingTimeline();
  final InitialRecordingPromptPolicy _initialPromptPolicy =
      InitialRecordingPromptPolicy();
  late final CameraDiagnosticsService _cameraDiagnostics;
  late final DiagnosticsLogService _runtimeLog;
  Future<void> _cameraInitializeTail = Future<void>.value();
  bool _appStartLogged = false;

  CameraController? _cameraController;
  ContinuousCameraService? _nativeCamera;
  ContinuousCameraInitialization? _nativeInitialization;
  List<NativeCameraLens> _backCameraLenses = const <NativeCameraLens>[];
  PackingSessionPhase _phase = PackingSessionPhase.initializing;
  List<RecordingSession> _sessions = <RecordingSession>[];
  DateTime _lastAnalysisAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _elapsedTimer;
  Timer? _feedbackTimer;
  Timer? _scanWarningTimer;
  Timer? _cameraNoticeTimer;
  Timer? _rejectedBarcodeTimer;
  Timer? _initialPromptTimer;
  Timer? _pairingFeedbackTimer;
  Timer? _storageMonitorTimer;
  Timer? _diagnosticsTimer;
  Duration _elapsed = Duration.zero;
  BarcodeMarker? _lastMarker;
  String _candidateCode = '';
  WorkMode _workMode = WorkMode.continuousScan;
  RecordingOperationMode _operationMode = RecordingOperationMode.shipping;
  bool _speechEnabled = true;
  bool _orderSpeechEnabled = true;
  bool _maxVolumeEnabled = true;
  bool _recordAudioEnabled = true;
  bool _nativeRecordingFallback = false;
  RecordingVideoCodec _preferredVideoCodec = RecordingVideoCodec.hevc;
  RecordingSpecPreset _recordingSpec = RecordingSpecPreset.hd1080p30;
  int _minimumBarcodeLength = AppSettings.defaultMinimumBarcodeLength;
  int _historyPageSize = AppSettings.defaultHistoryPageSize;
  UnbackedRetentionPolicy _unbackedRetention = UnbackedRetentionPolicy.days30;
  BackedRetentionPolicy _backedRetention = BackedRetentionPolicy.days7;
  bool _appIsActive = true;
  String? _errorMessage;
  String? _scanWarningMessage;
  String? _storageWarningMessage;
  String? _cameraNotice;
  String? _rejectedBarcodeMessage;
  String _lastRejectedBarcodeCode = '';
  DateTime? _lastRejectedBarcodeAt;
  bool _processingFrame = false;
  bool _handlingBarcode = false;
  bool _disposed = false;
  bool _pairingScanActive = false;
  bool _historyScanActive = false;
  bool _pairingBusy = false;
  int _pairingAttemptRevision = 0;
  bool _backupListenerAttached = false;
  bool _orderReceiverListenerAttached = false;
  final Set<String> _handledDeletedBackupJobs = <String>{};
  String? _pairingMessage;
  String? _historyScanResult;
  String? _recordingId;
  String? _activeSegmentId;
  int _segmentIndex = 1;
  bool _torchEnabled = false;
  bool _workActive = false;
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
  bool _storageCheckRunning = false;
  int _queuedStorageNoticePriority = -1;
  StorageNotice? _storageNoticeToShow;
  int _storageNoticeRevision = 0;
  bool _storageStopRequested = false;

  CameraController? get cameraController => _cameraController;
  int? get nativeTextureId => _nativeInitialization?.textureId;
  Size? get nativePreviewSize => _nativeInitialization?.portraitPreviewSize;
  PackingSessionPhase get phase => _phase;
  List<RecordingSession> get sessions =>
      List<RecordingSession>.unmodifiable(_sessions);
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
  UnbackedRetentionPolicy get unbackedRetention => _unbackedRetention;
  BackedRetentionPolicy get backedRetention => _backedRetention;
  bool get recordAudioEnabled => _recordAudioEnabled;
  RecordingVideoCodec get preferredVideoCodec => _preferredVideoCodec;
  RecordingSpecPreset get recordingSpec => _recordingSpec;
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
  bool get flashAvailable => Platform.isAndroid
      ? _nativeInitialization?.flashAvailable == true
      : _cameraController?.value.isInitialized == true;
  bool get torchEnabled => _torchEnabled;
  bool get cameraSwitchAvailable =>
      Platform.isAndroid &&
      _nativeInitialization?.canSwitchCamera == true &&
      !_pairingScanActive &&
      !_historyScanActive;
  List<NativeCameraLens> get backCameraLenses => _backCameraLenses;
  bool get multiBackCameraAvailable => _backCameraLenses.length >= 2;
  String? get activeCameraId => _nativeInitialization?.cameraId;
  bool get frontCameraActive =>
      Platform.isAndroid && _nativeInitialization?.isFrontCamera == true;
  String? get historyScanResult => _historyScanResult;
  String? get errorMessage => _errorMessage;

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
      _storageWarningMessage ?? _cameraNotice ?? _scanWarningMessage;
  String? get rejectedBarcodeMessage => _rejectedBarcodeMessage;
  int get storageNoticeRevision => _storageNoticeRevision;
  bool get isRecording => _phase == PackingSessionPhase.recording;
  bool get isWorking => _workActive;
  RecordingOperationMode get operationMode => _operationMode;
  Set<int> get hiddenRemoteRecordingIds =>
      Set<int>.unmodifiable(_hiddenRemoteRecordingIds);
  bool get isBusy =>
      _phase == PackingSessionPhase.initializing ||
      _phase == PackingSessionPhase.starting ||
      _phase == PackingSessionPhase.saving;
  bool get isCameraReady =>
      (Platform.isAndroid
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
    final Future<void> next = _cameraInitializeTail.then(
      (_) => _initializeCamera(force: force),
    );
    _cameraInitializeTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _initializeCamera({required bool force}) async {
    if (_disposed || (!force && isCameraReady)) {
      return;
    }
    _setPhase(PackingSessionPhase.initializing);
    _errorMessage = null;

    try {
      await _repository.initialize();
      await _reloadRecentSessions();
      final AppSettings settings = await _repository.loadSettings();
      _workMode = settings.workMode;
      _speechEnabled = settings.speechEnabled;
      _orderSpeechEnabled = settings.orderSpeechEnabled;
      _maxVolumeEnabled = settings.maxVolumeEnabled;
      _unbackedRetention = settings.unbackedRetention;
      _backedRetention = settings.backedRetention;
      _recordAudioEnabled = settings.recordAudioEnabled;
      _nativeRecordingFallback = settings.nativeRecordingFallback;
      _preferredVideoCodec = settings.preferredVideoCodec;
      _recordingSpec = settings.recordingSpec;
      _minimumBarcodeLength = settings.minimumBarcodeLength;
      _historyPageSize = settings.historyPageSize;
      _hiddenRemoteRecordingIds = Set<int>.of(
        settings.hiddenRemoteRecordingIds,
      );
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
      } on Object {
        // Backup is optional and must never hold camera startup indefinitely.
      }
      await _pruneDeletedBackupSessions(notify: false);
      if (_lanBackupService.snapshot.autoEnabled) {
        unawaited(_backupAllRepositorySessions('app_start'));
      } else {
        unawaited(_registerRepositorySessionsForRetention());
      }
      await _speechService.setEnabled(_speechEnabled);
      if (!_orderReceiverListenerAttached) {
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
          // Order push can be retried from settings after recording is ready.
        }
      }
      if (Platform.isAndroid) {
        final ContinuousCameraService nativeCamera = ContinuousCameraService();
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
        await nativeCamera.ensurePermissions(recordAudio: _recordAudioEnabled);
        _nativeInitialization = await nativeCamera
            .initialize(
              videoCodec: _preferredVideoCodec,
              recordingSpec: _recordingSpec,
              fallbackRecording: _nativeRecordingFallback,
            )
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () => throw TimeoutException('摄像头初始化超过 15 秒'),
            );
        final String? codecFallbackReason =
            _nativeInitialization?.codecFallbackReason;
        if (codecFallbackReason != null) {
          developer.log(
            _codecFallbackMessage(codecFallbackReason),
            name: 'PackingProof.Codec',
          );
          unawaited(_runtimeLog.log(
            kind: 'codec_fallback',
            extra: <String, Object?>{
              'reason': codecFallbackReason,
              'videoMime': _nativeInitialization?.videoMime,
            },
          ));
        }
        await _refreshBackCameraLenses();
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
        imageFormatGroup: Platform.isAndroid
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
    }
  }

  Future<void> retryInitialize() async {
    unawaited(_cameraDiagnostics.recordEvent(kind: 'retry_initialize'));
    await _disposeCamera();
    await initialize(force: true);
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

  void _handleNativeRecordingFallback(Map<Object?, Object?> info) {
    unawaited(
      _cameraDiagnostics.recordEvent(
        kind: 'recording_fallback',
        extra: info.cast<String, Object?>(),
      ),
    );
    final String mode = '${info['mode'] ?? ''}';
    final String phase = '${info['phase'] ?? ''}';
    if (mode == 'encoder_analysis' && !_nativeRecordingFallback) {
      _nativeRecordingFallback = true;
      unawaited(_repository.saveNativeRecordingFallback(true));
    }
    _showCameraNotice(
      mode == 'encoder_analysis'
          ? (phase == 'stall_during_recording'
                ? '当前设备录像时画面会暂停，已切换兼容模式，请停止后重新开始工作'
                : '当前设备录像时预览画面暂停，识别与录制正常')
          : '已切换录像兼容模式',
    );
  }

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
    if (!Platform.isAndroid || _diagnosticsTimer != null) return;
    _diagnosticsTimer = Timer.periodic(
      CameraDiagnosticsService.heartbeatInterval,
      (_) => unawaited(_captureCameraDiagnosticsSnapshot('heartbeat')),
    );
  }

  Future<void> _captureCameraDiagnosticsSnapshot(String trigger) async {
    if (!Platform.isAndroid || _disposed || _nativeCamera == null) return;
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
      if (Platform.isAndroid) {
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
    try {
      if (_torchEnabled) {
        await _nativeCamera!.setTorchEnabled(false);
        _torchEnabled = false;
      }
      _errorMessage = null;
      _setPhase(PackingSessionPhase.initializing);
      _nativeInitialization = await _nativeCamera!.switchCamera();
      await _refreshBackCameraLenses();
      _setPhase(PackingSessionPhase.ready);
      unawaited(_captureCameraDiagnosticsSnapshot('switch_camera'));
    } on Object {
      await _disposeCamera();
      await initialize();
      if (!_disposed) {
        _errorMessage = '摄像头切换失败，已恢复后置摄像头';
        notifyListeners();
      }
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
    try {
      if (_torchEnabled) {
        await nativeCamera.setTorchEnabled(false);
        _torchEnabled = false;
      }
      _errorMessage = null;
      _setPhase(PackingSessionPhase.initializing);
      _nativeInitialization = await nativeCamera.switchToCamera(cameraId);
      await _refreshBackCameraLenses();
      _setPhase(PackingSessionPhase.ready);
      unawaited(_captureCameraDiagnosticsSnapshot('switch_lens'));
    } on Object {
      await _disposeCamera();
      await initialize();
      if (!_disposed) {
        _errorMessage = '摄像头切换失败，已恢复默认后置摄像头';
        notifyListeners();
      }
    }
  }

  Future<void> _refreshBackCameraLenses() async {
    final ContinuousCameraService? nativeCamera = _nativeCamera;
    if (nativeCamera == null) return;
    try {
      _backCameraLenses = await nativeCamera.listCameras();
    } on Object {
      _backCameraLenses = const <NativeCameraLens>[];
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> startWork() async {
    final CameraController? camera = _cameraController;
    final bool cameraUnavailable = Platform.isAndroid
        ? _nativeInitialization == null
        : camera == null || !camera.value.isInitialized;
    if (cameraUnavailable || isBusy || isWorking) {
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
        },
      ),
    );
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
    _beginInitialPromptFlow();

    try {
      await WakelockPlus.enable();
      await _setNativeWorkScanEnabled(true);
      unawaited(_captureCameraDiagnosticsSnapshot('start_work'));
      _workActive = true;
      _startStorageMonitor();
      await _orderInfoReceiver.setBackgroundKeepAlive(false);
      _elapsed = Duration.zero;
      _setPhase(PackingSessionPhase.waitingForBarcode);
      _scheduleInitialModeAnnouncement();
    } on CameraException catch (error) {
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

  Future<RecordingSession?> stopWork() async {
    if (!isWorking) {
      return null;
    }
    final bool silentStorageStop = _storageStopRequested;
    final CameraController? camera = _cameraController;
    final DateTime? startedAt = _timeline.recordingStartedAt;
    final bool recordingUnavailable = Platform.isAndroid
        ? _nativeCamera == null
        : camera == null || !camera.value.isRecordingVideo;
    if (startedAt == null) {
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
      return null;
    }
    _cancelInitialPromptFlow();
    await _setNativeWorkScanEnabled(false);

    _setPhase(PackingSessionPhase.saving);
    await WidgetsBinding.instance.endOfFrame;

    try {
      final List<RecordingSession> savedSessions = Platform.isAndroid
          ? await _finishNativeRecording()
          : await _finishRecording();
      unawaited(_captureCameraDiagnosticsSnapshot('stop_work'));
      _candidateCode = '';
      _stabilityTracker.reset();
      _workActive = false;
      _stopStorageMonitor();
      await WakelockPlus.disable();
      await _endMaxVolumeSession();
      await Future<void>.delayed(transitionSettleDelay);
      _setPhase(PackingSessionPhase.ready);
      _speechService.resetIncidents();
      if (!silentStorageStop) {
        _speechService.enqueue(SpeechPrompt.recordingStopped);
      }
      _setActiveOrderInfo(null, announce: false);
      await _releaseStorageNoticeAfterWork();
      return savedSessions.isEmpty ? null : savedSessions.last;
    } on Object catch (error) {
      _timeline.reset();
      _workActive = false;
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

  StorageNotice? takeStorageNoticeForDisplay() {
    final StorageNotice? notice = _storageNoticeToShow;
    _storageNoticeToShow = null;
    return notice;
  }

  void _startStorageMonitor() {
    _storageMonitorTimer?.cancel();
    _storageMonitorTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_checkAndHandleStorage(allowStop: true)),
    );
  }

  void _stopStorageMonitor() {
    _storageMonitorTimer?.cancel();
    _storageMonitorTimer = null;
  }

  Future<StorageSpaceResult> _checkAndHandleStorage({
    required bool allowStop,
  }) async {
    if (_storageCheckRunning || _disposed) {
      return const StorageSpaceResult(
        availableBytes: 1 << 62,
        availableBytesBefore: 1 << 62,
        freedBytes: 0,
        deletedCount: 0,
        warning: false,
        insufficient: false,
      );
    }
    _storageCheckRunning = true;
    try {
      final StorageSpaceResult result = await _lanBackupService
          .checkAndReclaimStorage();
      if (result.deletedCount > 0) {
        final String message =
            '存储空间不足，已提前清理 ${result.deletedCount} 个已备份录像，'
            '释放 ${_formatStorageBytes(result.freedBytes)}。建议缩短本机保留时间';
        await _queueStorageNotice(
          StorageNotice(
            severity: StorageNoticeSeverity.reclaimed,
            message: message,
          ),
        );
        _storageWarningMessage = '空间不足，已清理已备份录像';
      } else if (result.warning) {
        await _queueStorageNotice(
          const StorageNotice(
            severity: StorageNoticeSeverity.warning,
            message: '手机剩余空间不足 3GB，建议连接电脑备份或缩短本机录像保留时间',
          ),
        );
        _storageWarningMessage = '手机存储空间不足 3GB';
      }
      if (result.insufficient) {
        await _queueStorageNotice(
          const StorageNotice(
            severity: StorageNoticeSeverity.stopped,
            message: '已备份录像不足以释放空间，录像已停止。请清理手机空间或连接电脑完成备份',
          ),
        );
        _storageWarningMessage = '存储空间不足 2GB，正在停止录像';
        notifyListeners();
        if (allowStop && isWorking && !isBusy) {
          _storageStopRequested = true;
          try {
            await stopWork();
          } finally {
            _storageStopRequested = false;
          }
        }
      } else if (!_disposed) {
        notifyListeners();
      }
      return result;
    } on Object {
      return const StorageSpaceResult(
        availableBytes: 1 << 62,
        availableBytesBefore: 1 << 62,
        freedBytes: 0,
        deletedCount: 0,
        warning: false,
        insufficient: false,
      );
    } finally {
      _storageCheckRunning = false;
    }
  }

  Future<void> _queueStorageNotice(StorageNotice notice) async {
    if (notice.priority <= _queuedStorageNoticePriority) return;
    _queuedStorageNoticePriority = notice.priority;
    await _repository.queueStorageNotice(notice);
  }

  Future<void> _handleNativeStorageCritical() async {
    unawaited(_cameraDiagnostics.recordEvent(kind: 'storage_critical'));
    await _checkAndHandleStorage(allowStop: false);
    await _queueStorageNotice(
      const StorageNotice(
        severity: StorageNoticeSeverity.stopped,
        message: '存储空间不足导致录像写入失败，当前录像已停止。请清理手机空间或连接电脑完成备份',
      ),
    );
    _storageWarningMessage = '存储空间不足，正在停止录像';
    if (!_disposed) notifyListeners();
    if (!isWorking || isBusy) return;
    _storageStopRequested = true;
    try {
      await stopWork();
    } finally {
      _storageStopRequested = false;
    }
  }

  Future<void> _releaseStorageNoticeAfterWork() async {
    final StorageNotice? notice = await _repository.takeStorageNoticeAfterWork(
      DateTime.now(),
    );
    _storageWarningMessage = null;
    if (notice == null || _disposed) return;
    _storageNoticeToShow = notice;
    _storageNoticeRevision++;
    notifyListeners();
  }

  static String _formatStorageBytes(int bytes) {
    final double gigabytes = bytes / (1024 * 1024 * 1024);
    if (gigabytes >= 1) return '${gigabytes.toStringAsFixed(1)}GB';
    return '${(bytes / (1024 * 1024)).round()}MB';
  }

  Future<void> setWorkMode(WorkMode mode) async {
    if (_workMode == mode || isWorking || isBusy) {
      return;
    }
    _workMode = mode;
    notifyListeners();
    await _repository.saveWorkMode(mode);
  }

  void setOperationMode(RecordingOperationMode mode) {
    if (_operationMode == mode || isWorking || isBusy) {
      return;
    }
    _operationMode = mode;
    notifyListeners();
  }

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
    if (Platform.isAndroid && _phase != PackingSessionPhase.saving) {
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
    if (Platform.isAndroid && _phase != PackingSessionPhase.saving) {
      // 编码器在相机初始化时创建，切换规格后必须重建相机才会生效；
      // 若正在工作，先安全结束当前工作（正在录的片段会正常保存）。
      if (isWorking) {
        await stopWork();
      }
      await retryInitialize();
    }
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

  Future<void> setLanBackupAutoEnabled(bool enabled) async {
    await _lanBackupService.setAutoEnabled(enabled);
    await _repository.saveLanBackupAutoEnabled(enabled);
    if (enabled) {
      await _backupAllRepositorySessions('auto_toggle_enabled');
    }
  }

  Future<void> setBackupRetention({
    required UnbackedRetentionPolicy unbacked,
    required BackedRetentionPolicy backed,
  }) async {
    _unbackedRetention = unbacked;
    _backedRetention = backed;
    notifyListeners();
    await _lanBackupService.setRetentionPolicies(
      unbacked: unbacked,
      backed: backed,
    );
    await _repository.saveBackupRetention(unbacked: unbacked, backed: backed);
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

  Future<void> backupAllSessions() => _backupAllRepositorySessions('manual');

  Future<LocalRecordingPage> loadLocalRecordings({
    required int page,
    required int pageSize,
    String keyword = '',
  }) => _repository.querySessions(
    page: page,
    pageSize: pageSize,
    keyword: keyword,
  );

  Future<void> disconnectBackup() => _lanBackupService.disconnect();

  Future<NetworkDiagnostics?> fetchNetworkDiagnostics() =>
      _lanBackupService.getNetworkDiagnostics();

  Future<void> retryBackupConnection() async {
    final bool connected = await _lanBackupService.retryConnection();
    if (connected && _lanBackupService.snapshot.autoEnabled) {
      await _backupAllRepositorySessions('connection_restored');
    }
  }

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

  Map<String, String> get remotePlaybackHeaders =>
      _lanBackupService.playbackHeaders;

  RemoteVideoClipSink? createRemoteVideoClipService(Uri remoteUri) =>
      _lanBackupService.createRemoteVideoClipService(remoteUri);

  Future<void> previewSpeech() => _speechService.preview();

  Future<void> _startRecording() async {
    if (Platform.isAndroid) {
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
    unawaited(_watermarkAndBackup(savedPath, session));
    _elapsed = stopped.endedAt.difference(_timeline.recordingStartedAt!);
    _timeline.reset();
    _recordingId = null;
    _activeSegmentId = null;
    return <RecordingSession>[session];
  }

  Future<void> _watermarkAndBackup(
    String savedPath,
    RecordingSession session,
  ) async {
    final String trackingNumber = _firstTrackingNumber(<RecordingSession>[
      session,
    ]);
    try {
      final String watermarkedPath = await _videoWatermarkService.apply(
        inputPath: savedPath,
        startedAt: session.startedAt,
        trackingNumber: trackingNumber,
        // 相机可能因设备不支持偏好编码而回退，水印必须跟随实际录制的编码。
        videoCodec: recordingVideoCodecFromMime(
          _nativeInitialization?.videoMime,
          fallback: _preferredVideoCodec,
        ),
      );
      final String finalPath = await _repository.finalizeVideo(
        sourcePath: watermarkedPath,
        sessionId: session.id,
        startedAt: session.startedAt,
        trackingNumber: trackingNumber,
        operationMode: session.operationMode,
      );
      final RecordingSession finalized = finalPath == session.filePath
          ? session
          : _sessionWithPath(session, finalPath);
      if (finalized.filePath != session.filePath) {
        _sessions = await _repository.updateSession(finalized);
        await _repository.deleteFileIfUnreferenced(savedPath);
      }
      await _enqueueBackupIfNeeded(finalPath, <RecordingSession>[finalized]);
    } on Object {
      // The original recording is already safely indexed. A failed watermark
      // must not keep the work button blocked or discard the video.
      if (await File(savedPath).exists()) {
        await _enqueueBackupIfNeeded(savedPath, <RecordingSession>[session]);
      }
    }
    if (!_disposed) notifyListeners();
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
    await _lanBackupService.refresh();
    await _orderInfoReceiver.setBackgroundKeepAlive(false);
    if (isWorking) {
      await _beginMaxVolumeIfNeeded();
    }
    final bool needsInitialization = Platform.isAndroid
        ? _nativeInitialization == null
        : _cameraController?.value.isInitialized != true;
    if (needsInitialization && _phase != PackingSessionPhase.saving) {
      await initialize();
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
    if (!Platform.isAndroid) return;
    try {
      await _nativeCamera?.setPreviewActive(active);
    } on Object {
      // Preview power tuning must never block navigation or recording.
    }
  }

  Future<void> _setNativeWorkScanEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;
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
    notifyListeners();
  }

  Future<void> deleteSessions(Set<String> sessionIds) async {
    _sessions = await _repository.deleteSessions(sessionIds);
    notifyListeners();
  }

  Future<void> hideRemoteRecordings(Set<int> ids) async {
    if (ids.isEmpty) return;
    _hiddenRemoteRecordingIds = <int>{..._hiddenRemoteRecordingIds, ...ids};
    await _repository.saveHiddenRemoteRecordingIds(_hiddenRemoteRecordingIds);
    notifyListeners();
  }

  void _processNativeBarcodeFrame(List<NativeBarcodeCandidate> candidates) {
    if (_historyScanActive) {
      NativeBarcodeCandidate? match;
      for (final NativeBarcodeCandidate candidate in candidates) {
        if (BarcodeCandidatePolicy.isValid(candidate.value)) {
          match = candidate;
          break;
        }
      }
      if (match != null) {
        _historyScanResult = BarcodeCandidatePolicy.normalize(match.value);
        _historyScanActive = false;
        unawaited(_nativeCamera?.setPairingScanEnabled(false));
        notifyListeners();
      }
      return;
    }
    if (_pairingScanActive) {
      if (!_pairingBusy) {
        for (final NativeBarcodeCandidate candidate in candidates) {
          unawaited(_tryPairComputer(candidate.value));
          break;
        }
      }
      return;
    }
    if (!isWorking || isBusy || _handlingBarcode) {
      return;
    }
    final List<RejectedBarcodeCandidate> rejectedCandidates = candidates
        .map(
          (NativeBarcodeCandidate candidate) => RejectedBarcodeCandidate(
            value: candidate.value,
            area: candidate.area.toDouble(),
            format: candidate.format,
          ),
        )
        .toList(growable: false);
    String? validCode;
    int largestArea = -1;
    for (final NativeBarcodeCandidate candidate in candidates) {
      if (BarcodeCandidatePolicy.isValidForWorkScan(
            candidate.value,
            format: candidate.format,
            minimumLength: _minimumBarcodeLength,
          ) &&
          candidate.area > largestArea) {
        largestArea = candidate.area;
        validCode = BarcodeCandidatePolicy.normalize(candidate.value);
      }
    }
    final DateTime now = DateTime.now();
    final RejectedBarcodeDecision? rejected = RejectedBarcodePolicy.decide(
      candidates: rejectedCandidates,
      minimumLength: _minimumBarcodeLength,
      now: now,
      lastCode: _lastRejectedBarcodeCode,
      lastShownAt: _lastRejectedBarcodeAt,
    );
    if (rejected != null) {
      _showRejectedBarcodeNotice(rejected, now);
    }
    final BarcodeObservation observation = _stabilityTracker.observe(
      validCode,
      now,
    );
    if (observation.confirmedCode.isNotEmpty) {
      _candidateCode = '';
      unawaited(_handleConfirmedBarcode(observation.confirmedCode, now));
    } else if (observation.candidateCode != _candidateCode) {
      _candidateCode = observation.candidateCode;
      notifyListeners();
    }
  }

  Future<void> _processFrame(CameraImage image) async {
    if (_processingFrame || !isWorking || isBusy || _handlingBarcode) {
      return;
    }
    final DateTime now = DateTime.now();
    if (now.difference(_lastAnalysisAt) < analysisInterval) {
      return;
    }
    _lastAnalysisAt = now;
    _processingFrame = true;

    try {
      final InputImageRotation? rotation = _inputImageRotation(
        _cameraController!.description,
        _cameraController!.value.deviceOrientation,
      );
      if (rotation == null) {
        return;
      }
      final InputImage? inputImage = _toInputImage(image, rotation: rotation);
      if (inputImage == null) {
        return;
      }
      List<Barcode> barcodes = await _barcodeScanner.processImage(inputImage);
      if (barcodes.isEmpty && Platform.isAndroid) {
        final InputImage? croppedInput = _toCroppedInputImage(
          image,
          rotation: rotation,
        );
        if (croppedInput != null) {
          barcodes = await _barcodeScanner.processImage(croppedInput);
        }
      }
      final List<RejectedBarcodeCandidate> rejectedCandidates = barcodes
          .map(
            (Barcode barcode) => RejectedBarcodeCandidate(
              value: barcode.rawValue ?? '',
              area:
                  barcode.boundingBox.width.abs() *
                  barcode.boundingBox.height.abs(),
              format: barcode.format.name,
            ),
          )
          .toList(growable: false);
      String? validCode;
      double largestArea = -1;
      for (final Barcode barcode in barcodes) {
        if (BarcodeCandidatePolicy.isValidForWorkScan(
          barcode.rawValue,
          format: barcode.format.name,
          minimumLength: _minimumBarcodeLength,
        )) {
          final double area =
              barcode.boundingBox.width.abs() *
              barcode.boundingBox.height.abs();
          if (area > largestArea) {
            largestArea = area;
            validCode = BarcodeCandidatePolicy.normalize(barcode.rawValue);
          }
        }
      }

      final RejectedBarcodeDecision? rejected = RejectedBarcodePolicy.decide(
        candidates: rejectedCandidates,
        minimumLength: _minimumBarcodeLength,
        now: now,
        lastCode: _lastRejectedBarcodeCode,
        lastShownAt: _lastRejectedBarcodeAt,
      );
      if (rejected != null) {
        _showRejectedBarcodeNotice(rejected, now);
      }
      final BarcodeObservation observation = _stabilityTracker.observe(
        validCode,
        now,
      );
      if (observation.confirmedCode.isNotEmpty) {
        _candidateCode = '';
        unawaited(_handleConfirmedBarcode(observation.confirmedCode, now));
      } else if (observation.candidateCode != _candidateCode) {
        _candidateCode = observation.candidateCode;
        notifyListeners();
      }
    } on Object {
      // A malformed analysis frame should not interrupt recording.
    } finally {
      _processingFrame = false;
    }
  }

  InputImage? _toInputImage(
    CameraImage image, {
    required InputImageRotation rotation,
  }) {
    if (image.planes.length != 1) {
      return null;
    }

    final Plane plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: Platform.isAndroid
            ? InputImageFormat.nv21
            : InputImageFormat.bgra8888,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  InputImage? _toCroppedInputImage(
    CameraImage image, {
    required InputImageRotation rotation,
  }) {
    if (image.planes.length != 1) {
      return null;
    }
    final Plane plane = image.planes.first;
    final Nv21CropResult? crop = cropNv21Center(
      bytes: plane.bytes,
      width: image.width,
      height: image.height,
      bytesPerRow: plane.bytesPerRow,
    );
    if (crop == null) {
      return null;
    }
    return InputImage.fromBytes(
      bytes: crop.bytes,
      metadata: InputImageMetadata(
        size: Size(crop.width.toDouble(), crop.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: crop.width,
      ),
    );
  }

  InputImageRotation? _inputImageRotation(
    CameraDescription camera,
    DeviceOrientation orientation,
  ) {
    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    }

    const Map<DeviceOrientation, int> compensations = <DeviceOrientation, int>{
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270,
    };
    final int? compensation = compensations[orientation];
    if (compensation == null) {
      return null;
    }
    final int rotation = camera.lensDirection == CameraLensDirection.front
        ? (camera.sensorOrientation + compensation) % 360
        : (camera.sensorOrientation - compensation + 360) % 360;
    return InputImageRotationValue.fromRawValue(rotation);
  }

  Future<void> _handleConfirmedBarcode(String code, DateTime now) async {
    if (_handlingBarcode || !isWorking || isBusy) {
      return;
    }
    if (!isRecording || !_timeline.isActive) {
      _handlingBarcode = true;
      try {
        final bool duplicate = await _hasRecentTrackingNumber(code);
        final OrderInfo? orderInfo = await _orderInfoReceiver.lookup(code);
        _setActiveOrderInfo(orderInfo, announce: false);
        await _startRecording();
        _bindCurrentCode(code, _timeline.segmentStartedAt ?? now);
        if (duplicate) _showDuplicateOrderWarning(code);
        _announceOrderInfo(orderInfo);
      } on Object catch (error) {
        _timeline.reset();
        _errorMessage = '无法开始录像，请重新对准面单\n$error';
        _setPhase(PackingSessionPhase.waitingForBarcode);
        _speechService.enqueue(
          SpeechPrompt.recordingFailed,
          incidentKey: SpeechPrompt.recordingFailed.name,
        );
      } finally {
        _handlingBarcode = false;
      }
      return;
    }
    final BarcodeWorkAction action = BarcodeWorkModePolicy.decide(
      mode: _workMode,
      currentCode: _timeline.currentCode,
      scannedCode: code,
    );
    switch (action) {
      case BarcodeWorkAction.bindCurrentVideo:
        _bindCurrentCode(code, now);
        return;
      case BarcodeWorkAction.ignore:
        _candidateCode = '';
        notifyListeners();
        return;
      case BarcodeWorkAction.stopVideo:
        _handlingBarcode = true;
        try {
          await _saveCurrentVideoAndWait();
        } finally {
          _handlingBarcode = false;
        }
        return;
      case BarcodeWorkAction.startNextVideo:
        _handlingBarcode = true;
        try {
          final bool duplicate = await _hasRecentTrackingNumber(code);
          final OrderInfo? nextOrderInfo = await _orderInfoReceiver.lookup(
            code,
          );
          bool announced = false;
          void announceSegmentStarted(BarcodeMarker marker) {
            announced = true;
            _speechService.resolveIncident(SpeechPrompt.segmentSaveFailed.name);
            _speechService.enqueue(SpeechPrompt.recordingStarted);
            _showMarkerFeedback(marker);
          }

          final BarcodeMarker? marker = Platform.isAndroid
              ? await _splitNativeRecording(
                  code,
                  nextOrderInfo: nextOrderInfo,
                  onSegmentStarted: announceSegmentStarted,
                )
              : _startNextTimelineSegment(code, now);
          if (marker != null && !announced) {
            _setActiveOrderInfo(nextOrderInfo, announce: false);
            announceSegmentStarted(marker);
          }
          if (marker != null) {
            if (duplicate) _showDuplicateOrderWarning(code);
            _announceOrderInfo(nextOrderInfo);
          }
        } on Object catch (error) {
          _errorMessage = '录像分段保存失败\n$error';
          _speechService.enqueue(
            SpeechPrompt.segmentSaveFailed,
            incidentKey: SpeechPrompt.segmentSaveFailed.name,
          );
          if (!_disposed) {
            notifyListeners();
          }
        } finally {
          _handlingBarcode = false;
        }
        return;
    }
  }

  Future<RecordingSession?> _saveCurrentVideoAndWait() async {
    if (!isWorking || !isRecording || !_timeline.isActive) {
      return null;
    }
    _cancelInitialPromptFlow();
    _setPhase(PackingSessionPhase.saving);
    await WidgetsBinding.instance.endOfFrame;
    try {
      final List<RecordingSession> savedSessions = Platform.isAndroid
          ? await _finishNativeRecording()
          : await _finishRecording();
      _candidateCode = '';
      _elapsed = Duration.zero;
      await Future<void>.delayed(transitionSettleDelay);
      _setPhase(PackingSessionPhase.waitingForBarcode);
      _speechService.resetIncidents();
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
    unawaited(_watermarkAndBackup(savedPath, completed));
    _activeSegmentId = nextId;
    _segmentIndex = nextIndex;
    return transition.marker;
  }

  BarcodeMarker? _startNextTimelineSegment(String code, DateTime boundaryAt) {
    final RecordingSegmentTransition? transition = _timeline.startNext(
      code,
      boundaryAt,
    );
    if (transition != null) {
      _resetSegmentElapsed();
    }
    return transition?.marker;
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

  static String _firstTrackingNumber(List<RecordingSession> sessions) {
    for (final RecordingSession session in sessions) {
      if (session.markers.isNotEmpty && session.markers.first.code.isNotEmpty) {
        return session.markers.first.code;
      }
    }
    return '';
  }

  static RecordingSession _sessionWithPath(
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

  void _setActiveOrderInfo(OrderInfo? value, {required bool announce}) {
    _activeOrderInfo = value;
    if (value == null) _lastAnnouncedOrderSignature = '';
    if (!_disposed) notifyListeners();
    if (announce) _announceOrderInfo(value);
  }

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

  void _bindCurrentCode(String code, DateTime now) {
    final BarcodeMarker? marker = _timeline.bindCode(code, now);
    if (marker == null) {
      return;
    }
    _announceInitialRecordingStarted();
    _showMarkerFeedback(marker);
  }

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

  Future<void> _enqueueBackupIfNeeded(
    String filePath,
    List<RecordingSession> sessions,
  ) async {
    try {
      await _lanBackupService.enqueueFinalizedFile(filePath, sessions);
    } on Object catch (error) {
      // A saved local recording must never fail because its backup is offline.
      unawaited(
        _runtimeLog.log(
          kind: 'backup_enqueue_failed',
          extra: <String, Object?>{
            'filePath': filePath,
            'sessionCount': sessions.length,
            'autoEnabled': _lanBackupService.snapshot.autoEnabled,
            'error': error.toString(),
          },
        ),
      );
    }
  }

  void _handleBackupChanged() {
    final List<LanBackupJob> newlyDeletedJobs = _lanBackupService.snapshot.jobs
        .where((LanBackupJob job) => job.localDeletedAt != null)
        .where(
          (LanBackupJob job) => !_handledDeletedBackupJobs.contains(job.id),
        )
        .toList(growable: false);
    if (newlyDeletedJobs.isNotEmpty) {
      _handledDeletedBackupJobs.addAll(
        newlyDeletedJobs.map((LanBackupJob job) => job.id),
      );
      unawaited(_recordDeletedBackupJobs(newlyDeletedJobs));
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> _recordDeletedBackupJobs(List<LanBackupJob> jobs) async {
    for (final LanBackupJob job in jobs) {
      try {
        await _repository.recordAutomaticCleanup(
          eventId: job.id,
          filePath: job.filePath,
          fileSizeBytes: job.totalBytes,
          deletedAt: job.localDeletedAt!,
          reason:
              job.cleanupReason ??
              (job.backupCompletedAt == null ? '未备份录像保留策略清理' : '已备份录像保留策略清理'),
        );
      } on Object {
        _handledDeletedBackupJobs.remove(job.id);
      }
    }
    await _pruneDeletedBackupSessions();
  }

  Future<void> _reloadRecentSessions() async {
    _sessions = (await _repository.querySessions(page: 1, pageSize: 50)).data;
  }

  Future<void> _backupAllRepositorySessions(String reason) async {
    unawaited(
      _runtimeLog.log(
        kind: 'backup_all',
        extra: <String, Object?>{'reason': reason},
      ),
    );
    await _forEachRepositoryBackupBatch(_lanBackupService.backupAll);
  }

  Future<void> _registerRepositorySessionsForRetention() =>
      _forEachRepositoryBackupBatch(_registerSessionsForRetention);

  Future<void> _forEachRepositoryBackupBatch(
    Future<void> Function(List<RecordingSession> sessions) action,
  ) async {
    var page = 1;
    while (!_disposed) {
      final List<RecordingSession> sessions = await _repository.loadBackupBatch(
        page: page,
      );
      if (sessions.isEmpty) return;
      await action(sessions);
      page++;
    }
  }

  Future<void> _registerSessionsForRetention(
    List<RecordingSession> sessions,
  ) async {
    final Map<String, List<RecordingSession>> grouped =
        <String, List<RecordingSession>>{};
    for (final RecordingSession session in sessions) {
      if (!File(session.filePath).existsSync()) continue;
      grouped
          .putIfAbsent(session.filePath, () => <RecordingSession>[])
          .add(session);
    }
    for (final MapEntry<String, List<RecordingSession>> entry
        in grouped.entries) {
      await _lanBackupService.enqueueFinalizedFile(entry.key, entry.value);
    }
  }

  Future<void> _pruneDeletedBackupSessions({bool notify = true}) async {
    final List<LanBackupJob> deletedBackupJobs = _lanBackupService.snapshot.jobs
        .where(
          (LanBackupJob job) =>
              job.state == LanBackupJobState.completed &&
              job.localDeletedAt != null,
        )
        .toList(growable: false);
    final Set<String> backedPaths = _sessions
        .where(
          (RecordingSession session) => deletedBackupJobs.any(
            (LanBackupJob job) =>
                isSameLanBackupFile(job.filePath, session.filePath),
          ),
        )
        .map((RecordingSession session) => session.filePath)
        .toSet();
    _sessions = await _repository.pruneMissingSessions(
      retainedMissingPaths: backedPaths,
    );
    if (notify && !_disposed) notifyListeners();
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
      final SpeechPrompt? prompt =
          _initialPromptPolicy.onModeAnnouncementElapsed();
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

  void _showDuplicateOrderWarning(String trackingNumber) {
    _scanWarningMessage = '警告：重复单号，请确认';
    _scanWarningTimer?.cancel();
    _scanWarningTimer = Timer(const Duration(seconds: 3), () {
      if (_disposed) return;
      _scanWarningMessage = null;
      notifyListeners();
    });
    _speechService.enqueue(
      SpeechPrompt.duplicateOrderWarning,
      incidentKey: 'duplicate-order-number:$trackingNumber',
    );
    notifyListeners();
  }

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

  void _setPhase(PackingSessionPhase value) {
    _phase = value;
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> _disposeCamera() async {
    _cancelInitialPromptFlow();
    if (Platform.isAndroid) {
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

  String _sessionId(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    String three(int number) => number.toString().padLeft(3, '0');
    return '${value.year}${two(value.month)}${two(value.day)}_'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}_'
        '${three(value.millisecond)}';
  }

  @override
  void dispose() {
    _disposed = true;
    _clearPendingComputerReplacement();
    _elapsedTimer?.cancel();
    _feedbackTimer?.cancel();
    _scanWarningTimer?.cancel();
    _cameraNoticeTimer?.cancel();
    _rejectedBarcodeTimer?.cancel();
    _storageMonitorTimer?.cancel();
    _diagnosticsTimer?.cancel();
    unawaited(WakelockPlus.disable());
    final CameraController? camera = _cameraController;
    if (camera != null) {
      unawaited(camera.dispose());
    }
    final ContinuousCameraService? nativeCamera = _nativeCamera;
    if (nativeCamera != null) {
      unawaited(nativeCamera.dispose());
    }
    unawaited(_barcodeScanner.close());
    unawaited(_speechService.dispose());
    unawaited(_maxVolumeService.dispose());
    if (_backupListenerAttached) {
      _lanBackupService.removeListener(_handleBackupChanged);
    }
    if (_orderReceiverListenerAttached) {
      _orderInfoReceiver.removeListener(_handleOrderReceiverChanged);
    }
    unawaited(_orderInfoSubscription?.cancel());
    unawaited(_orderInfoReceiver.dispose());
    unawaited(_lanBackupService.dispose());
    unawaited(_repository.dispose());
    super.dispose();
  }
}

bool _looksLikeComputerPairingQr(String value) {
  final String normalized = value.trim().toLowerCase();
  return normalized.startsWith('http://') || normalized.startsWith('https://');
}
