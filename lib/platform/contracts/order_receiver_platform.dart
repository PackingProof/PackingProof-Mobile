import '../../models/order_info.dart';

class OrderReceiverPlatformSnapshot {
  const OrderReceiverPlatformSnapshot({
    this.running = false,
    this.ipAddress = '',
    this.url = '',
    this.port = 5280,
    this.errorMessage = '',
  });

  final bool running;
  final String ipAddress;
  final String url;
  final int port;
  final String errorMessage;
}

abstract interface class OrderReceiverPlatform {
  Stream<OrderInfo> get received;

  Future<OrderReceiverPlatformSnapshot> start({
    required bool backgroundDelivery,
  });

  Future<OrderReceiverPlatformSnapshot> status();

  Future<OrderInfo?> lookup(String trackingNumber);

  Future<void> updateBackgroundDelivery(bool enabled);

  Future<void> stop();

  Future<void> dispose();
}
