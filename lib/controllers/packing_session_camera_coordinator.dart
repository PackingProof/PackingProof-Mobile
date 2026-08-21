part of 'packing_session_controller.dart';

/// 协调摄像头初始化、能力判定、镜头身份与运行诊断。
mixin _PackingSessionCameraCoordinator on _PackingSessionOrderCoordinator {
  PackingSessionPhase get _phase;
  set _speechEnabled(bool value);
  set _workMode(WorkMode value);
  set _maxVolumeEnabled(bool value);
  bool get _recordAudioEnabled;
  set _recordAudioEnabled(bool value);
  set _preferredVideoCodec(RecordingVideoCodec value);
  RecordingSpecPreset get _recordingSpec;
  set _recordingSpec(RecordingSpecPreset value);
  set _recordingOrientation(RecordingOrientation value);
  set _historyPageSize(int value);
  set _hiddenRemoteRecordingIds(Set<int> value);
  set _nativeCamera(ContinuousCameraService? value);
  @override
  ContinuousCameraInitialization? get _nativeInitialization;
  set _nativeInitialization(ContinuousCameraInitialization? value);
  set _cameraController(CameraController? value);
  bool get _supportsCameraCapabilityNegotiation;
  bool get isCameraReady;
  @override
  bool get isWorking;
  @override
  bool get isBusy;
  set _cameraNotice(String? value);

  Future<void> _reloadRecentSessions();
  Future<void> _initializeBackgroundServices(AppSettings settings);
  Future<void> _disposeCamera();
  void _setCameraError(CameraException error);
  void _speakErrorMessage(String message);

  Future<void> _cameraInitializeTail = Future<void>.value();
  int _pendingCameraInitializations = 0;
  bool _appStartLogged = false;
  List<NativeCameraLens> _backCameraLenses = const <NativeCameraLens>[];
  Timer? _cameraNoticeTimer;
  Timer? _diagnosticsTimer;
  bool _nativeRecordingFallback = false;
  @override
  CameraCapabilityMode _capabilityMode = CameraCapabilityMode.unverified;
  Map<String, Object?>? _capabilityState;
  bool _capabilityProbeRunning = false;
  String? _capabilityProbeMessage;
  String? _capabilityNoticeMessage;

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
        fps: PackingSessionController.recordingFps,
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
      // broad-catch: Repository, speech, and plugin initialization can throw
      // non-camera errors; record them and keep the controller in error state.
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

  Future<void> retryInitialize() async {
    unawaited(_cameraDiagnostics.recordEvent(kind: 'retry_initialize'));
    await _disposeCamera();
    await initialize(force: true);
  }

  /// 设置页「重新检测」：仅空闲时可用，探测期间阻塞开始工作。
  Future<void> retryCapabilityProbe() async {
    if (_disposed ||
        !_supportsNativeCamera ||
        !_supportsCameraCapabilityNegotiation ||
        _nativeCamera == null) {
      return;
    }
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
    if (_disposed ||
        !_supportsNativeCamera ||
        !_supportsCameraCapabilityNegotiation ||
        _nativeCamera == null) {
      return;
    }
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
      // broad-catch: Platform-channel and malformed probe responses are
      // infrastructure failures, not evidence that the camera is unsupported.
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
        // broad-catch: Native mode handoff is best-effort here; the unverified
        // state deliberately keeps the regular camera path available.
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
      // broad-catch: A rejected native mode must downgrade the persisted
      // decision to unverified instead of blocking work with a stale mode.
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
      // broad-catch: Session stage is optional diagnostic context; an empty
      // value still allows the recording-fallback suspicion to be persisted.
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
      // broad-catch: Heartbeat diagnostics are observational only; recording
      // must continue and the periodic timer will retry on its next interval.
    }
  }

  Future<void> _refreshBackCameraLenses() async {
    final ContinuousCameraService? nativeCamera = _nativeCamera;
    if (nativeCamera == null) return;
    try {
      final List<NativeCameraLens> lenses = await nativeCamera.listCameras();
      _backCameraLenses = scannableBackLenses(lenses);
    } on Object {
      // broad-catch: Failed lens enumeration hides optional switch targets;
      // the already initialized default camera remains usable.
      _backCameraLenses = const <NativeCameraLens>[];
    }
    if (!_disposed) {
      notifyListeners();
    }
  }
}
