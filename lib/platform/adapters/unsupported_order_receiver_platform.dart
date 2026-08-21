import '../../models/order_info.dart';
import '../contracts/order_receiver_platform.dart';
import '../platform_capabilities.dart';
import '../platform_exceptions.dart';

class UnsupportedOrderReceiverPlatform implements OrderReceiverPlatform {
  const UnsupportedOrderReceiverPlatform();

  @override
  Stream<OrderInfo> get received => const Stream<OrderInfo>.empty();

  @override
  Future<OrderReceiverPlatformSnapshot> start({
    required bool backgroundDelivery,
  }) {
    throw const CapabilityUnavailableException(
      PlatformCapability.orderInfoReceiver,
      reason: '当前平台暂不支持订单语音接收',
    );
  }

  @override
  Future<OrderReceiverPlatformSnapshot> status() {
    throw const CapabilityUnavailableException(
      PlatformCapability.orderInfoReceiver,
      reason: '当前平台暂不支持订单语音接收',
    );
  }

  @override
  Future<OrderInfo?> lookup(String trackingNumber) => _unsupported();

  @override
  Future<void> updateBackgroundDelivery(bool enabled) => _unsupported();

  @override
  Future<void> stop() => _unsupported();

  @override
  Future<void> dispose() async {}

  Never _unsupported() {
    throw const CapabilityUnavailableException(
      PlatformCapability.orderInfoReceiver,
      reason: '当前平台暂不支持订单语音接收',
    );
  }
}
