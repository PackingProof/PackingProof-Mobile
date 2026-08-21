part of 'packing_session_controller.dart';

/// 协调运行设置变更、服务同步、持久化与必要的相机重建。
mixin _PackingSessionSettingsCoordinator on _PackingSessionPairingCoordinator {
  PackingSessionPhase get _phase;

  Future<void> retryInitialize();
  Future<void> _beginMaxVolumeIfNeeded();
  Future<void> _disableMaxVolume();

  @override
  WorkMode _workMode = WorkMode.continuousScan;
  @override
  RecordingOperationMode _operationMode = RecordingOperationMode.shipping;
  @override
  bool _speechEnabled = true;
  @override
  bool _orderSpeechEnabled = true;
  bool _maxVolumeEnabled = true;
  bool _recordAudioEnabled = true;
  @override
  RecordingVideoCodec _preferredVideoCodec = RecordingVideoCodec.hevc;
  RecordingSpecPreset _recordingSpec = RecordingSpecPreset.hd1080p30;
  RecordingOrientation _recordingOrientation = RecordingOrientation.portrait;
  @override
  int _minimumBarcodeLength = AppSettings.defaultMinimumBarcodeLength;
  int _historyPageSize = AppSettings.defaultHistoryPageSize;

  bool get orderSpeechEnabled => _orderSpeechEnabled;

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
    if (_supportsNativeCamera && _phase != PackingSessionPhase.saving) {
      // 原生写入器在相机初始化时读取方向；工作中切换时必须先等待当前
      // 录像完成保存，再重建相机，避免未完成文件被 dispose 截断。
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
      // broad-catch: 这里只做尽力而为的权限预请求；实际开始录像时，
      // startWork 会报告可操作的麦克风错误。
    }
  }
}
