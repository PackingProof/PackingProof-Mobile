import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/order_info.dart';
import 'package:packing_proof_mobile/platform/contracts/order_receiver_platform.dart';
import 'package:packing_proof_mobile/services/order_info_receiver_service.dart';

class _FakeOrderReceiverPlatform implements OrderReceiverPlatform {
  _FakeOrderReceiverPlatform({
    this.statusResult = const OrderReceiverPlatformSnapshot(),
  });

  final OrderReceiverPlatformSnapshot statusResult;
  final StreamController<OrderInfo> _controller =
      StreamController<OrderInfo>.broadcast();

  @override
  Stream<OrderInfo> get received => _controller.stream;

  void emit(OrderInfo item) => _controller.add(item);

  @override
  Future<OrderReceiverPlatformSnapshot> start({
    required bool backgroundDelivery,
  }) async => statusResult;

  @override
  Future<OrderReceiverPlatformSnapshot> status() async => statusResult;

  @override
  Future<OrderInfo?> lookup(String trackingNumber) async => null;

  @override
  Future<void> updateBackgroundDelivery(bool enabled) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

void main() {
  test('初始化时同步平台状态并转发订单事件', () async {
    final _FakeOrderReceiverPlatform platform = _FakeOrderReceiverPlatform(
      statusResult: const OrderReceiverPlatformSnapshot(
        running: true,
        ipAddress: '192.168.1.2',
        port: 5280,
      ),
    );
    final OrderInfoReceiverService service = OrderInfoReceiverService(
      platform: platform,
    );
    addTearDown(service.dispose);

    await service.initialize();

    expect(service.snapshot.running, isTrue);
    expect(service.snapshot.ipAddress, '192.168.1.2');

    final OrderInfo item = OrderInfo(
      trackingNumber: 'SF123',
      buyerMessage: '请尽快发货',
    );
    final Future<OrderInfo> received = service.received.first;
    platform.emit(item);

    expect(await received, same(item));
    expect(service.snapshot.lastReceivedAt, isNotNull);
  });

  test('查询空单号时直接返回 null', () async {
    final OrderInfoReceiverService service = OrderInfoReceiverService(
      platform: _FakeOrderReceiverPlatform(),
    );
    addTearDown(service.dispose);

    expect(await service.lookup('   '), isNull);
  });
}
