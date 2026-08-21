part of 'packing_session_controller.dart';

/// 协调订单接收绑定、活动订单状态、订单播报与重复单号提示。
mixin _PackingSessionOrderCoordinator on _PackingSessionBarcodeCoordinator {
  bool get _speechEnabled;
  bool get _orderSpeechEnabled;

  bool _orderReceiverListenerAttached = false;
  StreamSubscription<OrderInfo>? _orderInfoSubscription;
  OrderInfo? _activeOrderInfo;
  String _lastAnnouncedOrderSignature = '';
  Timer? _scanWarningTimer;
  String? _scanWarningMessage;

  OrderInfo? get activeOrderInfo => _activeOrderInfo;
  OrderInfoReceiverSnapshot get orderReceiverSnapshot =>
      _orderInfoReceiver.snapshot;

  Future<void> retryOrderReceiver() => _orderInfoReceiver.retry();

  Future<void> _initializeOrderReceiverBinding() async {
    if (_orderReceiverListenerAttached) return;
    _orderInfoReceiver.addListener(_handleOrderReceiverChanged);
    _orderReceiverListenerAttached = true;
    _orderInfoSubscription = _orderInfoReceiver.received.listen(
      _handleReceivedOrderInfo,
    );
    try {
      await _orderInfoReceiver.initialize().timeout(const Duration(seconds: 8));
    } on Object {
      // broad-catch: Order push is optional during camera preparation; the
      // settings retry action can initialize the receiver again after startup.
    }
  }

  void _detachOrderReceiverBinding() {
    if (!_orderReceiverListenerAttached) return;
    _orderInfoReceiver.removeListener(_handleOrderReceiverChanged);
    _orderReceiverListenerAttached = false;
  }

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
      // broad-catch: Duplicate-order lookup is advisory; repository failures
      // must not prevent the already scanned order from starting recording.
      return false;
    }
  }
}
