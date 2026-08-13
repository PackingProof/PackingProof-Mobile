import 'dart:io';

import 'platform_capabilities.dart';

/// 应用启动时创建一次的平台实现容器。
///
/// Service 应通过构造函数接收这里的适配器，不应在内部直接读取全局实例。
class AppContainer {
  const AppContainer({required this.capabilities});

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
    );
  }

  final PlatformCapabilities capabilities;
}
