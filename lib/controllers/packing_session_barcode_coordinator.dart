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
    required OrderInfo? nextOrderInfo,
    required void Function(BarcodeMarker marker) onSegmentStarted,
  });
  Future<BarcodeMarker?> _splitCameraRecording(
    String code, {
    required OrderInfo? nextOrderInfo,
    required void Function(BarcodeMarker marker) onSegmentStarted,
  });
  Future<void> startWork();

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

  void _processNativeBarcodeFrame(List<NativeBarcodeCandidate> candidates) {
    if (_recognizedBeepPolicy.shouldBeep(
      candidates.map((NativeBarcodeCandidate candidate) => candidate.value),
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
      _showRejectedBarcodeNotice(rejected, now);
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

          final BarcodeMarker? marker = _supportsNativeCamera
              ? await _splitNativeRecording(
                  code,
                  nextOrderInfo: nextOrderInfo,
                  onSegmentStarted: announceSegmentStarted,
                )
              : await _splitCameraRecording(
                  code,
                  nextOrderInfo: nextOrderInfo,
                  onSegmentStarted: announceSegmentStarted,
                );
          if (marker != null && !announced) {
            _setActiveOrderInfo(nextOrderInfo, announce: false);
            announceSegmentStarted(marker);
          }
          if (marker != null) {
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

  /// 手机版指令码执行：切发货/切退货/停止录制。
  /// 刻意不支持 START（扫码即自动开始）与 CLEAR（无输入框可清）。
  Future<void> _handleMobileBarcodeCommand(MobileBarcodeCommand command) async {
    switch (command) {
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
