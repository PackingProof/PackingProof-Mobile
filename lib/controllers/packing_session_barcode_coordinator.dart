part of 'packing_session_controller.dart';

/// 统一原生与 ML Kit 条码观察、稳定判定及工作模式动作。
mixin _PackingSessionBarcodeCoordinator on _PackingSessionWatermarkCoordinator {
  SpeechPromptSink get _speechService;
  ContinuousCameraService? get _nativeCamera;
  CameraCapabilityMode get _capabilityMode;
  CameraController? get _cameraController;
  BarcodeScanner get _barcodeScanner;
  bool get _supportsNativeCamera;
  bool get isRecording;
  RecordingTimeline get _timeline;
  OrderInfoReceiverSink get _orderInfoReceiver;
  set _errorMessage(String? value);
  WorkMode get _workMode;
  RecordingOperationMode get _operationMode;
  set _operationMode(RecordingOperationMode value);
  int get _minimumBarcodeLength;
  Duration get _analysisInterval;
  bool get _pairingScanActive;
  bool get _pairingBusy;
  bool get torchEnabled;

  Future<void> _tryPairComputer(String value);
  void _showRejectedBarcodeNotice(
    RejectedBarcodeDecision decision,
    DateTime now,
  );
  void _showCameraNotice(String message);
  Future<bool> _hasRecentTrackingNumber(String trackingNumber);
  void _setActiveOrderInfo(OrderInfo? value, {required bool announce});
  Future<void> _startRecording(String trackingNumber);
  void _bindCurrentCode(String code, DateTime now);
  void _showDuplicateOrderWarning(String trackingNumber);
  void _announceOrderInfo(OrderInfo? info);
  void _setPhase(PackingSessionPhase value);
  Future<RecordingSession?> _saveCurrentVideoAndWait();
  void _showMarkerFeedback(BarcodeMarker marker);
  Future<BarcodeMarker?> _splitNativeRecording(
    String code, {
    required void Function(BarcodeMarker marker) onSegmentStarted,
  });
  Future<BarcodeMarker?> _splitCameraRecording(
    String code, {
    required OrderInfo? nextOrderInfo,
    required void Function(BarcodeMarker marker) onSegmentStarted,
  });
  Future<void> startWork();
  Future<void> toggleTorch();

  final BarcodeStabilityTracker _stabilityTracker = BarcodeStabilityTracker();
  final BarcodeRecognizedBeepPolicy _recognizedBeepPolicy =
      BarcodeRecognizedBeepPolicy();
  DateTime _lastAnalysisAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _candidateCode = '';
  String? _alternatingLastCompletedCode;
  DateTime? _alternatingNoCodeSince;
  String _lastRejectedBarcodeCode = '';
  DateTime? _lastRejectedBarcodeAt;
  String? _lastTriggeredCommandCode;
  bool _processingFrame = false;
  bool _handlingBarcode = false;
  bool _historyScanActive = false;
  String? _historyScanResult;

  void _logRejectedBarcode(RejectedBarcodeDecision decision) {
    unawaited(
      _runtimeLog.log(
        kind: 'barcode_rejected',
        extra: <String, Object?>{
          'code': decision.code,
          'format': decision.format,
          'reason': decision.reason.name,
        },
      ),
    );
  }

  /// 静默码制（面单二维码、商品码）不打扰操作员，但必须能在导出日志里查到，
  /// 否则"二维码扫不动条形码"这类现场问题将没有任何痕迹。
  void _logSilentBarcodeFrame(List<RejectedBarcodeCandidate> candidates) {
    if (candidates.isEmpty) return;
    final bool allSilent = candidates.every(
      (RejectedBarcodeCandidate candidate) =>
          !BarcodeCandidatePolicy.acknowledgesScanFeedback(candidate.format),
    );
    if (!allSilent) return;
    final RejectedBarcodeCandidate largest = candidates.reduce(
      (RejectedBarcodeCandidate a, RejectedBarcodeCandidate b) =>
          b.area > a.area ? b : a,
    );
    unawaited(
      _runtimeLog.log(
        kind: 'barcode_silent',
        extra: <String, Object?>{
          'code': BarcodeCandidatePolicy.normalize(largest.value),
          'format': largest.format,
          'reason': BarcodeCandidatePolicy.rejectionForWorkScan(
            largest.value,
            format: largest.format,
            minimumLength: _minimumBarcodeLength,
          )?.name,
          'count': candidates.length,
        },
      ),
    );
  }

  void _processNativeBarcodeFrame(List<NativeBarcodeCandidate> candidates) {
    if (_recognizedBeepPolicy.shouldBeep(
      candidates.map(
        (NativeBarcodeCandidate candidate) =>
            (value: candidate.value, format: candidate.format),
      ),
      // 除配对扫码外都不为二维码/商品码出声：它们不是可用单号。
      skipSilentFormats: !_pairingScanActive,
    )) {
      _speechService.playShortBeep();
      unawaited(
        _runtimeLog.log(
          kind: 'recognized_beep',
          extra: <String, Object?>{
            'source': _pairingScanActive
                ? 'pairing'
                : _historyScanActive
                ? 'history'
                : 'work',
          },
        ),
      );
    }
    String? visibleCode;
    for (final NativeBarcodeCandidate candidate in candidates) {
      final String normalized = BarcodeCandidatePolicy.normalize(
        candidate.value,
      );
      if (normalized.isNotEmpty) {
        visibleCode = normalized;
        break;
      }
    }
    if (visibleCode != null) {
      final MobileBarcodeCommand? command =
          BarcodeCandidatePolicy.mobileCommandFor(visibleCode);
      if (command != null) {
        if (!_historyScanActive &&
            !_pairingScanActive &&
            !_handlingBarcode &&
            visibleCode != _lastTriggeredCommandCode) {
          _lastTriggeredCommandCode = visibleCode;
          _handlingBarcode = true;
          _runInBackground(
            _handleMobileBarcodeCommand(command).whenComplete(() {
              _handlingBarcode = false;
            }),
          );
        }
      } else if (_lastTriggeredCommandCode != null) {
        // 画面换成普通码后，允许同一条指令再次触发。
        _lastTriggeredCommandCode = null;
      }
    } else {
      _lastTriggeredCommandCode = null;
    }
    if (_historyScanActive) {
      NativeBarcodeCandidate? match;
      for (final NativeBarcodeCandidate candidate in candidates) {
        if (BarcodeCandidatePolicy.isValidForHistoryScan(
          candidate.value,
          format: candidate.format,
        )) {
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
    final String? validCode = BarcodeCandidatePolicy.selectForWorkScan(
      candidates.map(
        (c) => (value: c.value, area: c.area.toDouble(), format: c.format),
      ),
      minimumLength: _minimumBarcodeLength,
    );
    final DateTime now = DateTime.now();
    if (_capabilityMode == CameraCapabilityMode.alternating &&
        _alternatingLastCompletedCode != null) {
      if (validCode == null) {
        _alternatingNoCodeSince ??= now;
      } else {
        _alternatingNoCodeSince = null;
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
      _logRejectedBarcode(rejected);
      _showRejectedBarcodeNotice(rejected, now);
    } else {
      _logSilentBarcodeFrame(rejectedCandidates);
    }
    final BarcodeObservation observation = _stabilityTracker.observe(
      validCode,
      now,
    );
    if (observation.confirmedCode.isNotEmpty) {
      _candidateCode = '';
      final int receivedAtMs = now.millisecondsSinceEpoch;
      int? nativeToDartMs;
      for (final NativeBarcodeCandidate candidate in candidates) {
        if (BarcodeCandidatePolicy.normalize(candidate.value) ==
                observation.confirmedCode &&
            candidate.detectedAtMs > 0) {
          nativeToDartMs = receivedAtMs - candidate.detectedAtMs;
          break;
        }
      }
      if (nativeToDartMs != null) {
        unawaited(
          _runtimeLog.log(
            kind: 'barcode_native_to_dart',
            extra: <String, Object?>{
              'code': observation.confirmedCode,
              'ms': nativeToDartMs,
              'negative': nativeToDartMs < 0,
            },
          ),
        );
      }
      _runInBackground(_handleConfirmedBarcode(observation.confirmedCode, now));
    } else if (observation.candidateCode != _candidateCode) {
      _candidateCode = observation.candidateCode;
      notifyListeners();
    }
  }

  @visibleForTesting
  void handleNativeBarcodeFrameForTesting(
    List<NativeBarcodeCandidate> candidates,
  ) {
    _processNativeBarcodeFrame(candidates);
  }

  Future<void> _processFrame(CameraImage image) async {
    if (_processingFrame || !isWorking || isBusy || _handlingBarcode) {
      return;
    }
    final DateTime now = DateTime.now();
    if (now.difference(_lastAnalysisAt) < _analysisInterval) {
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
      if (barcodes.isEmpty && _supportsNativeCamera) {
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
      final String? validCode = BarcodeCandidatePolicy.selectForWorkScan(
        barcodes.map(
          (b) => (
            value: b.rawValue ?? '',
            area: b.boundingBox.width.abs() * b.boundingBox.height.abs(),
            format: b.format.name,
          ),
        ),
        minimumLength: _minimumBarcodeLength,
      );

      final RejectedBarcodeDecision? rejected = RejectedBarcodePolicy.decide(
        candidates: rejectedCandidates,
        minimumLength: _minimumBarcodeLength,
        now: now,
        lastCode: _lastRejectedBarcodeCode,
        lastShownAt: _lastRejectedBarcodeAt,
      );
      if (rejected != null) {
        _logRejectedBarcode(rejected);
        _showRejectedBarcodeNotice(rejected, now);
      } else {
        _logSilentBarcodeFrame(rejectedCandidates);
      }
      final BarcodeObservation observation = _stabilityTracker.observe(
        validCode,
        now,
      );
      if (observation.confirmedCode.isNotEmpty) {
        _candidateCode = '';
        _runInBackground(
          _handleConfirmedBarcode(observation.confirmedCode, now),
        );
      } else if (observation.candidateCode != _candidateCode) {
        _candidateCode = observation.candidateCode;
        notifyListeners();
      }
    } on Object {
      // broad-catch: A malformed analysis frame is isolated so it cannot
      // interrupt the active recording.
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
        format: _supportsNativeCamera
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
    if (!_supportsNativeCamera) {
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
    final MobileBarcodeCommand? command =
        BarcodeCandidatePolicy.mobileCommandFor(code);
    if (command != null) {
      _handlingBarcode = true;
      try {
        await _handleMobileBarcodeCommand(command);
      } finally {
        _handlingBarcode = false;
      }
      return;
    }
    if (_capabilityMode == CameraCapabilityMode.alternating &&
        !isRecording &&
        _alternatingLastCompletedCode != null &&
        shouldSuppressAlternatingSameCode(
          lastCompletedCode: _alternatingLastCompletedCode!,
          noCodeSince: _alternatingNoCodeSince,
          code: code,
          now: now,
        )) {
      _showCameraNotice('该面单已录制，请扫描下一张');
      return;
    }
    if (_capabilityMode == CameraCapabilityMode.alternating &&
        !isRecording &&
        _alternatingLastCompletedCode != null &&
        code == _alternatingLastCompletedCode) {
      _alternatingLastCompletedCode = null;
    }
    if (!isRecording || !_timeline.isActive) {
      _handlingBarcode = true;
      try {
        final int t0 = DateTime.now().millisecondsSinceEpoch;
        final bool duplicate = await _hasRecentTrackingNumber(code);
        final int t1 = DateTime.now().millisecondsSinceEpoch;
        final OrderInfo? orderInfo = await _orderInfoReceiver.lookup(code);
        final int t2 = DateTime.now().millisecondsSinceEpoch;
        _setActiveOrderInfo(orderInfo, announce: false);
        await _startRecording(code);
        final int t3 = DateTime.now().millisecondsSinceEpoch;
        unawaited(
          _runtimeLog.log(
            kind: 'barcode_stage_timing',
            extra: <String, Object?>{
              'code': code,
              'duplicateMs': t1 - t0,
              'lookupMs': t2 - t1,
              'startRecordingMs': t3 - t2,
            },
          ),
        );
        _bindCurrentCode(code, _timeline.segmentStartedAt ?? now);
        if (_capabilityMode == CameraCapabilityMode.alternating) {
          _alternatingLastCompletedCode = null;
          _alternatingNoCodeSince = null;
        }
        if (duplicate) _showDuplicateOrderWarning(code);
        _announceOrderInfo(orderInfo);
      } on Object catch (error) {
        // broad-catch: Start failures are converted to visible error state and
        // a fixed offline speech incident below.
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
        if (_workMode == WorkMode.sameCodeStop &&
            _timeline.currentCode.isNotEmpty &&
            !JdBarcodePolicy.sameRecordingCode(_timeline.currentCode, code)) {
          _showCameraNotice('单号不一致：$code');
          final String incidentKey = 'recording-order-mismatch:$code';
          _speechService.enqueue(
            SpeechPrompt.trackingNumberMismatch,
            incidentKey: incidentKey,
          );
          Timer(const Duration(seconds: 3), () {
            _speechService.resolveIncident(incidentKey);
          });
        }
        notifyListeners();
        return;
      case BarcodeWorkAction.stopVideo:
        _handlingBarcode = true;
        try {
          final BarcodeMarker? completed = _timeline.completePackageIdentity(
            code,
          );
          if (completed != null) _showMarkerFeedback(completed);
          await _saveCurrentVideoAndWait();
        } finally {
          _handlingBarcode = false;
        }
        return;
      case BarcodeWorkAction.startNextVideo:
        _handlingBarcode = true;
        try {
          bool announced = false;
          void announceSegmentStarted(BarcodeMarker marker) {
            announced = true;
            _speechService.resolveIncident(SpeechPrompt.segmentSaveFailed.name);
            _speechService.enqueue(SpeechPrompt.recordingStarted);
            _showMarkerFeedback(marker);
          }

          late final bool duplicate;
          late final OrderInfo? nextOrderInfo;
          final BarcodeMarker? marker;
          if (_supportsNativeCamera) {
            final Future<bool> duplicateLookup = _hasRecentTrackingNumber(code);
            final Future<OrderInfo?> orderLookup = _lookupOrderInfoForSplit(
              code,
            );
            marker = await _splitNativeRecording(
              code,
              onSegmentStarted: announceSegmentStarted,
            );
            duplicate = await duplicateLookup;
            nextOrderInfo = await orderLookup;
          } else {
            duplicate = await _hasRecentTrackingNumber(code);
            nextOrderInfo = await _orderInfoReceiver.lookup(code);
            marker = await _splitCameraRecording(
              code,
              nextOrderInfo: nextOrderInfo,
              onSegmentStarted: announceSegmentStarted,
            );
          }
          final bool isCurrentSegment = _isCurrentSegmentCode(code);
          if (marker != null && isCurrentSegment) {
            if (_supportsNativeCamera) {
              _setActiveOrderInfo(nextOrderInfo, announce: false);
            } else if (!announced) {
              _setActiveOrderInfo(nextOrderInfo, announce: false);
              announceSegmentStarted(marker);
            }
            if (duplicate) _showDuplicateOrderWarning(code);
            _announceOrderInfo(nextOrderInfo);
          }
        } on Object catch (error) {
          // broad-catch: Split failures keep the current recording recoverable
          // and surface both UI and offline speech errors below.
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

  /// 提交外部单号（手动输入或扫码枪），复用工作中的确认流程
  Future<bool> submitExternalTrackingNumber(
    String rawCode, {
    required bool validate,
  }) async {
    if (_handlingBarcode ||
        isBusy ||
        _pairingScanActive ||
        _historyScanActive) {
      return false;
    }
    final String code = validate
        ? BarcodeCandidatePolicy.normalize(rawCode)
        : rawCode.trim();
    if (code.isEmpty) return false;

    // 手动输入和扫码枪也支持与摄像头相同的包含式指令码。
    final MobileBarcodeCommand? command =
        BarcodeCandidatePolicy.mobileCommandFor(code);
    if (command != null) {
      _handlingBarcode = true;
      try {
        await _handleMobileBarcodeCommand(command);
      } finally {
        _handlingBarcode = false;
      }
      return true;
    }

    if (validate) {
      final DateTime now = DateTime.now();
      final RejectedBarcodeDecision? rejected = RejectedBarcodePolicy.decide(
        candidates: <RejectedBarcodeCandidate>[
          RejectedBarcodeCandidate(value: code, area: 1, format: 'code128'),
        ],
        minimumLength: _minimumBarcodeLength,
        now: now,
        lastCode: _lastRejectedBarcodeCode,
        lastShownAt: _lastRejectedBarcodeAt,
        // 摄像头提示需要节流，提交结果不能因重复回车被节流而放行。
        throttle: false,
      );
      if (rejected != null) {
        _showRejectedBarcodeNotice(rejected, now);
        return false;
      }
    }
    if (!isWorking) {
      await startWork();
      if (!isWorking) return false;
    }
    await _handleConfirmedBarcode(code, DateTime.now());
    return true;
  }

  Future<OrderInfo?> _lookupOrderInfoForSplit(String code) async {
    try {
      return await _orderInfoReceiver.lookup(code);
    } on Object catch (error) {
      unawaited(
        _runtimeLog.log(
          kind: 'barcode_order_lookup_failed',
          extra: <String, Object?>{'error': '$error'},
        ),
      );
      return null;
    }
  }

  bool _isCurrentSegmentCode(String code) =>
      _timeline.currentCode.trim().toUpperCase() == code.trim().toUpperCase();

  /// 手机版指令码执行：清除输入、切发货/切退货、开始/停止工作。
  Future<void> _handleMobileBarcodeCommand(MobileBarcodeCommand command) async {
    switch (command) {
      case MobileBarcodeCommand.clearInput:
        _candidateCode = '';
        _showCameraNotice('扫码框已清除');
        break;
      case MobileBarcodeCommand.openFlash:
        await toggleTorch();
        break;
      case MobileBarcodeCommand.switchShipping:
        if (_operationMode != RecordingOperationMode.shipping) {
          _operationMode = RecordingOperationMode.shipping;
          if (!_disposed) {
            notifyListeners();
          }
          _speechService.enqueue(SpeechPrompt.shippingMode);
          _runInBackground(_repository.saveOperationMode(_operationMode));
        }
        break;
      case MobileBarcodeCommand.switchReturn:
        if (_operationMode != RecordingOperationMode.returnGoods) {
          _operationMode = RecordingOperationMode.returnGoods;
          if (!_disposed) {
            notifyListeners();
          }
          _speechService.enqueue(SpeechPrompt.returnMode);
          _runInBackground(_repository.saveOperationMode(_operationMode));
        }
        break;
      case MobileBarcodeCommand.startWork:
        await startWork();
        break;
      case MobileBarcodeCommand.stopWork:
        if (isWorking) {
          await stopWork();
        }
        break;
    }
  }
}
