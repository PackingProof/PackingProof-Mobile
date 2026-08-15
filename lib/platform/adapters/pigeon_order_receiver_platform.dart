import 'dart:async';

import '../../models/order_info.dart';
import '../contracts/order_receiver_platform.dart';
import '../generated/platform_api.g.dart';

class PigeonOrderReceiverPlatform implements OrderReceiverPlatform {
  static final StreamController<OrderInfo> _sharedController =
      StreamController<OrderInfo>.broadcast();

  PigeonOrderReceiverPlatform({OrderReceiverHostApi? hostApi})
    : _hostApi = hostApi ?? OrderReceiverHostApi() {
    _eventSink = _OrderReceiverEventSink(_sharedController);
    OrderReceiverEventApi.setUp(_eventSink);
  }

  final OrderReceiverHostApi _hostApi;
  late final _OrderReceiverEventSink _eventSink;

  @override
  Stream<OrderInfo> get received => _sharedController.stream;

  @override
  Future<OrderReceiverPlatformSnapshot> start({
    required bool backgroundDelivery,
  }) async {
    return _snapshotFromDto(await _hostApi.startReceiver(backgroundDelivery));
  }

  @override
  Future<OrderReceiverPlatformSnapshot> status() async {
    return _snapshotFromDto(await _hostApi.getReceiverStatus());
  }

  @override
  Future<OrderInfo?> lookup(String trackingNumber) async {
    if (trackingNumber.trim().isEmpty) return null;
    final OrderInfoDto? value = await _hostApi.lookup(trackingNumber.trim());
    return value == null ? null : _orderInfoFromDto(value);
  }

  @override
  Future<void> updateBackgroundDelivery(bool enabled) =>
      _hostApi.updateBackgroundDelivery(enabled);

  @override
  Future<void> stop() => _hostApi.stopReceiver();

  @override
  Future<void> dispose() async {
    OrderReceiverEventApi.setUp(null);
  }
}

class _OrderReceiverEventSink extends OrderReceiverEventApi {
  _OrderReceiverEventSink(this._controller);

  final StreamController<OrderInfo> _controller;

  @override
  void orderInfoReceived(List<OrderInfoDto> items) {
    for (final OrderInfoDto item in items) {
      if (!PigeonOrderReceiverPlatform._sharedController.isClosed) {
        PigeonOrderReceiverPlatform._sharedController.add(_orderInfoFromDto(item));
      }
    }
  }
}

OrderReceiverPlatformSnapshot _snapshotFromDto(OrderReceiverStatusDto value) =>
    OrderReceiverPlatformSnapshot(
      running: value.running,
      ipAddress: value.ipAddress,
      url: value.url,
      port: value.port,
      errorMessage: value.errorMessage,
    );

OrderInfo _orderInfoFromDto(OrderInfoDto value) =>
    OrderInfo.fromMap(<Object?, Object?>{
      'trackingNumber': value.trackingNumber,
      'orderId': value.orderId,
      'buyerMessage': value.buyerMessage,
      'sellerMemo': value.sellerMemo,
      'productInfo': value.productInfo,
      'hasRefund': value.hasRefund,
      'isPrintedRefund': value.isPrintedRefund,
      'refundStatus': value.refundStatus,
      'refundProductInfo': value.refundProductInfo,
      if (value.pushTimeMs != null) 'pushTimeMilliseconds': value.pushTimeMs,
      'isTest': value.isTest,
    });
