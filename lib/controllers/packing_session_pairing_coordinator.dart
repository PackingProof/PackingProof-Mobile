part of 'packing_session_controller.dart';

class ComputerReplacementPrompt {
  const ComputerReplacementPrompt({
    required this.currentComputer,
    required this.newComputer,
  });

  final String currentComputer;
  final String newComputer;
}

/// 协调电脑配对扫码、异步竞态门禁、替换确认与结果提示。
mixin _PackingSessionPairingCoordinator on _PackingSessionOrderCoordinator {
  Timer? _pairingFeedbackTimer;
  int _pairingAttemptRevision = 0;
  String? _pairingMessage;
  int _pairingSuccessRevision = 0;
  int _pairingFailureRevision = 0;
  String? _pairingFailureMessage;
  int _pairingReplacementRevision = 0;
  ComputerReplacementPrompt? _pairingReplacementPrompt;
  String? _pendingReplacementQr;
  LanBackupPairingConfirmation? _pendingReplacementConfirmation;
  @override
  bool _pairingScanActive = false;
  @override
  bool _pairingBusy = false;

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
      // broad-catch: Pairing transports can surface platform-specific errors;
      // only the current revision may convert them into an actionable message.
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
      // broad-catch: Replacement confirmation may fail in any platform or
      // transport layer; stale revisions must never overwrite current UI state.
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
      // broad-catch: Camera scan teardown is secondary to surfacing the
      // replacement prompt, which must remain actionable after a scan error.
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
      // broad-catch: Camera scan teardown failure must not suppress the
      // actionable pairing error or keep the UI waiting for scan completion.
    }
    notifyListeners();
  }
}

bool _looksLikeComputerPairingQr(String value) {
  final String normalized = value.trim().toLowerCase();
  return normalized.startsWith('http://') || normalized.startsWith('https://');
}
