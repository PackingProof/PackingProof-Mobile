import 'dart:io';

import 'adapters/pigeon_thumbnail_platform.dart';
import 'adapters/pigeon_order_receiver_platform.dart';
import 'adapters/unsupported_thumbnail_platform.dart';
import 'adapters/unsupported_order_receiver_platform.dart';
import 'contracts/thumbnail_platform.dart';
import 'contracts/order_receiver_platform.dart';
import 'platform_capabilities.dart';

/// 应用启动时创建一次的平台实现容器。
///
/// Service 应通过构造函数接收这里的适配器，不应在内部直接读取全局实例。
class AppContainer {
  const AppContainer({
    required this.capabilities,
    required this.thumbnail,
    required this.orderReceiver,
  });

  factory AppContainer.forCurrentPlatform() {
    return AppContainer(
      capabilities: Platform.isAndroid
          ? const PlatformCapabilities(<PlatformCapability>{
              PlatformCapability.continuousCameraRecording,
              PlatformCapability.cameraBarcodeScanning,
              PlatformCapability.lanBackup,
              PlatformCapability.orderInfoReceiver,
              PlatformCapability.videoWatermark,
              PlatformCapability.videoExport,
              PlatformCapability.recordingThumbnail,
              PlatformCapability.systemVideoPlayer,
              PlatformCapability.alertAudioSession,
            })
          : const PlatformCapabilities(<PlatformCapability>{}),
      thumbnail: Platform.isAndroid
          ? PigeonThumbnailPlatform()
          : const UnsupportedThumbnailPlatform(),
      orderReceiver: Platform.isAndroid
          ? PigeonOrderReceiverPlatform()
          : const UnsupportedOrderReceiverPlatform(),
    );
  }

  final PlatformCapabilities capabilities;
  final ThumbnailPlatform thumbnail;
  final OrderReceiverPlatform orderReceiver;
}
