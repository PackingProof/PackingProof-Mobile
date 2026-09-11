part of 'packing_session_controller.dart';

/// 低频业务边界计时，只在一次操作结束时输出聚合结果。
///
/// 阶段名称由调用点使用固定字面量传入；payload 不接收路径、单号或错误文本，
/// 避免性能诊断意外收集业务数据。
class _PackingOperationTiming {
  _PackingOperationTiming() : _total = Stopwatch()..start();

  final Stopwatch _total;
  final Map<String, int> _stagesMs = <String, int>{};

  Future<T> measure<T>(String stage, Future<T> Function() action) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      return await action();
    } finally {
      stopwatch.stop();
      _stagesMs[stage] = stopwatch.elapsedMilliseconds;
    }
  }

  Map<String, Object?> finish({required String outcome}) {
    _total.stop();
    return <String, Object?>{
      'outcome': outcome,
      'totalMs': _total.elapsedMilliseconds,
      'stagesMs': Map<String, int>.unmodifiable(_stagesMs),
    };
  }
}

String _codecFallbackMessage(String reason) => switch (reason) {
  'no_hevc_decoder' => '本机不支持 H.265 解码，新录像已改用 H.264',
  'hevc_encoder_unavailable' => '本机 H.265 编码器不可用，新录像已改用 H.264',
  _ => '录像编码自动回退：$reason',
};

String _videoCodecFromMime(String? mime) => switch (mime?.toLowerCase()) {
  'video/hevc' || 'video/h265' => 'h265',
  'video/avc' || 'video/h264' => 'h264',
  _ => '',
};

mixin _PackingSessionAppSupport on ChangeNotifier {
  SessionRepository get _repository;
  Future<Map<String, Object?>>? get _runtimeMetadataFuture;
  set _runtimeMetadataFuture(Future<Map<String, Object?>>? value);
  Future<PackageInfo> Function() get _packageInfoLoader;
  AppBuildConfig get _buildConfig;
  DiagnosticsLogService get _runtimeLog;
  LanBackupSink get _lanBackupService;
  ContinuousCameraService? get _nativeCamera;
  bool get isWorking;
  bool get isBusy;
  bool get isRecording;
  bool get _disposed;
  set _historyScanResult(String? value);
  set _historyScanActive(bool value);
  BarcodeStabilityTracker get _stabilityTracker;
  Timer? get _initialPromptTimer;
  set _initialPromptTimer(Timer? value);
  InitialRecordingPromptPolicy get _initialPromptPolicy;
  RecordingOperationMode get _operationMode;
  SpeechPromptSink get _speechService;
  CameraController? get _cameraController;
  ContinuousCameraInitialization? get _nativeInitialization;
  PackingSessionPhase get _phase;
  List<RecordingSession> get _sessionSnapshot;
  LocalRecordingStatistics get _localRecordingStatistics;
  Duration get _elapsed;
  ValueNotifier<Duration> get _elapsedListenable;
  BarcodeMarker? get _lastMarker;
  String get _candidateCode;
  RecordingTimeline get _timeline;
  WorkMode get _workMode;
  bool get _speechEnabled;
  bool get _maxVolumeEnabled;
  CameraCapabilityMode get _capabilityMode;
  bool get _capabilityProbeRunning;
  String? get _capabilityProbeMessage;
  bool get _supportsCameraCapabilityNegotiation;
  bool get _nativeRecordingFallback;
  Map<String, Object?>? get _capabilityState;
  UnbackedRetentionPolicy get _unbackedRetention;
  BackedRetentionPolicy get _backedRetention;
  UnbackedRetentionPolicy get _returnUnbackedRetention;
  BackedRetentionPolicy get _returnBackedRetention;
  bool get _recordAudioEnabled;
  RecordingVideoCodec get _preferredVideoCodec;
  RecordingSpecPreset get _recordingSpec;
  List<RecordingSpecPreset> get _availableRecordingSpecs;
  RecordingOrientation get _recordingOrientation;
  int get _minimumBarcodeLength;
  int get _historyPageSize;
  Future<bool> reserveMobileUpdatePrompt() =>
      _repository.tryReserveMobileUpdatePrompt(DateTime.now());
  CameraController? get cameraController => _cameraController;
  int? get nativeTextureId => _nativeInitialization?.textureId;
  Size? get nativePreviewSize => _nativeInitialization?.portraitPreviewSize;
  PackingSessionPhase get phase => _phase;
  List<RecordingSession> get sessions => _sessionSnapshot;
  LocalRecordingStatistics get localRecordingStatistics =>
      _localRecordingStatistics;
  Duration get elapsed => _elapsed;
  ValueListenable<Duration> get elapsedListenable => _elapsedListenable;
  BarcodeMarker? get lastMarker => _lastMarker;
  String get candidateCode => _candidateCode;
  String get currentCode => _timeline.currentCode;
  WorkMode get workMode => _workMode;
  bool get speechEnabled => _speechEnabled;
  bool get maxVolumeEnabled => _maxVolumeEnabled;
  CameraCapabilityMode get capabilityMode => _capabilityMode;
  bool get capabilityProbeRunning => _capabilityProbeRunning;
  String? get capabilityProbeMessage => _capabilityProbeMessage;
  bool get showCameraCapabilityCard =>
      _supportsCameraCapabilityNegotiation &&
      ((_capabilityMode != CameraCapabilityMode.unverified &&
              _capabilityMode != CameraCapabilityMode.full) ||
          _nativeRecordingFallback);
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
  UnbackedRetentionPolicy get returnUnbackedRetention => _returnUnbackedRetention;
  BackedRetentionPolicy get returnBackedRetention => _returnBackedRetention;
  bool get recordAudioEnabled => _recordAudioEnabled;
  RecordingVideoCodec get preferredVideoCodec => _preferredVideoCodec;
  RecordingSpecPreset get recordingSpec => _recordingSpec;
  List<RecordingSpecPreset> get availableRecordingSpecs =>
      _availableRecordingSpecs;
  RecordingOrientation get recordingOrientation => _recordingOrientation;
  int get minimumBarcodeLength => _minimumBarcodeLength;
  int get historyPageSize => _historyPageSize;
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
      // broad-catch: 版本信息失败时仍返回稳定的空字段，不能阻塞相机初始化
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
    RecordingOperationMode? operationMode,
    DateTime? start,
    DateTime? end,
  }) => _repository.querySessions(
    page: page,
    pageSize: pageSize,
    keyword: keyword,
    operationMode: operationMode,
    start: start,
    end: end,
  );

  Future<LocalRecordingPage> loadAdjacentLocalRecordings({
    required int page,
    required int pageSize,
    required LocalRecordingCursor cursor,
    required LocalRecordingPageDirection direction,
    required int knownTotal,
    String keyword = '',
    RecordingOperationMode? operationMode,
    DateTime? start,
    DateTime? end,
  }) => _repository.queryAdjacentSessions(
    page: page,
    pageSize: pageSize,
    cursor: cursor,
    direction: direction,
    knownTotal: knownTotal,
    keyword: keyword,
    operationMode: operationMode,
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
    RecordingOperationMode? operationMode,
  }) => _lanBackupService.fetchRemoteRecordings(
    page: page,
    pageSize: pageSize,
    keyword: keyword,
    operationMode: operationMode,
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

  void _beginInitialPromptFlow() {
    _initialPromptTimer?.cancel();
    _initialPromptTimer = null;
    _initialPromptPolicy.beginWork(_operationMode);
  }

  void _scheduleInitialModeAnnouncement() {
    _initialPromptTimer?.cancel();
    _initialPromptTimer = Timer(
      PackingSessionController.initialModeAnnouncementDelay,
      () {
        _initialPromptTimer = null;
        if (_disposed || !isWorking || isRecording) {
          return;
        }
        final SpeechPrompt? prompt = _initialPromptPolicy
            .onModeAnnouncementElapsed();
        if (prompt != null) {
          _speechService.enqueue(prompt);
        }
      },
    );
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
}
