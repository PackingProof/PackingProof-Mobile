import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/order_info.dart';
import '../platform/contracts/order_receiver_platform.dart';
import '../platform/platform_container.dart';
import '../platform/platform_exceptions.dart';

class OrderInfoReceiverSnapshot {
  const OrderInfoReceiverSnapshot({
    this.running = false,
    this.ipAddress = '',
    this.url = '',
    this.port = 5280,
    this.errorMessage = '',
    this.lastReceivedAt,
  });

  final bool running;
  final String ipAddress;
  final String url;
  final int port;
  final String errorMessage;
  final DateTime? lastReceivedAt;

  OrderInfoReceiverSnapshot copyWith({
    bool? running,
    String? ipAddress,
    String? url,
    int? port,
    String? errorMessage,
    DateTime? lastReceivedAt,
  }) => OrderInfoReceiverSnapshot(
    running: running ?? this.running,
    ipAddress: ipAddress ?? this.ipAddress,
    url: url ?? this.url,
    port: port ?? this.port,
    errorMessage: errorMessage ?? this.errorMessage,
    lastReceivedAt: lastReceivedAt ?? this.lastReceivedAt,
  );
}

abstract interface class OrderInfoReceiverSink implements Listenable {
  OrderInfoReceiverSnapshot get snapshot;

  Stream<OrderInfo> get received;

  Future<void> initialize();

  Future<void> retry();

  Future<OrderInfo?> lookup(String trackingNumber);

  Future<void> setBackgroundKeepAlive(bool enabled);

  Future<void> dispose();
}

class OrderInfoReceiverService extends ChangeNotifier
    implements OrderInfoReceiverSink {
  OrderInfoReceiverService({OrderReceiverPlatform? platform})
    : _platform = platform ?? AppContainer.forCurrentPlatform().orderReceiver {
    _platformSubscription = _platform.received.listen(_handleReceived);
  }

  final OrderReceiverPlatform _platform;
  StreamSubscription<OrderInfo>? _platformSubscription;
  final StreamController<OrderInfo> _received =
      StreamController<OrderInfo>.broadcast();
  OrderInfoReceiverSnapshot _snapshot = const OrderInfoReceiverSnapshot();
  bool _disposed = false;

  @override
  OrderInfoReceiverSnapshot get snapshot => _snapshot;

  @override
  Stream<OrderInfo> get received => _received.stream;

  @override
  Future<void> initialize() async {
    if (_disposed) return;
    try {
      await _applyStatus(await _platform.start(backgroundDelivery: false));
    } on CapabilityUnavailableException {
      // 非 Android 平台保持现有静默行为。
    }
  }

  @override
  Future<void> retry() async {
    if (_disposed) return;
    try {
      await _applyStatus(await _platform.start(backgroundDelivery: false));
    } on CapabilityUnavailableException {
      // 非 Android 平台保持现有静默行为。
    }
  }

  @override
  Future<OrderInfo?> lookup(String trackingNumber) async {
    if (_disposed || trackingNumber.trim().isEmpty) return null;
    try {
      return await _platform.lookup(trackingNumber.trim());
    } on CapabilityUnavailableException {
      return null;
    }
  }

  @override
  Future<void> setBackgroundKeepAlive(bool enabled) async {
    if (_disposed) return;
    try {
      await _platform.updateBackgroundDelivery(enabled);
    } on CapabilityUnavailableException {
      // 非 Android 平台保持现有静默行为。
    }
  }

  void _handleReceived(OrderInfo item) {
    if (_disposed) return;
    _snapshot = _snapshot.copyWith(lastReceivedAt: DateTime.now());
    notifyListeners();
    if (!_received.isClosed) _received.add(item);
  }

  Future<void> _applyStatus(OrderReceiverPlatformSnapshot? value) async {
    if (value == null || _disposed) return;
    _snapshot = OrderInfoReceiverSnapshot(
      running: value.running,
      ipAddress: value.ipAddress,
      url: value.url,
      port: value.port,
      errorMessage: value.errorMessage,
      lastReceivedAt: _snapshot.lastReceivedAt,
    );
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _platformSubscription?.cancel();
    await _platform.dispose();
    await _received.close();
    super.dispose();
  }
}
