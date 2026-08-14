import 'dart:io';

import 'adapters/pigeon_camera_platform.dart';
import 'adapters/pigeon_backup_platform.dart';
import 'adapters/pigeon_thumbnail_platform.dart';
import 'adapters/pigeon_order_receiver_platform.dart';
import 'adapters/pigeon_media_platforms.dart';
import 'adapters/unsupported_camera_platform.dart';
import 'adapters/unsupported_backup_platform.dart';
import 'adapters/unsupported_thumbnail_platform.dart';
import 'adapters/unsupported_order_receiver_platform.dart';
import 'adapters/unsupported_media_platforms.dart';
import 'contracts/backup_platform.dart';
import 'contracts/camera_platform.dart';
import 'contracts/thumbnail_platform.dart';
import 'contracts/order_receiver_platform.dart';
import 'contracts/media_platform.dart';
import 'platform_capabilities.dart';

/// 应用启动时创建一次的平台实现容器。
///
/// Service 应通过构造函数接收这里的适配器，不应在内部直接读取全局实例。
class AppContainer {
  const AppContainer({
    required this.capabilities,
    required this.thumbnail,
    required this.orderReceiver,
    required this.camera,
    required this.backup,
    required this.mediaProcessing,
    required this.systemMediaPresenter,
    required this.alertAudioSession,
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
          : const PlatformCapabilities(<PlatformCapability>{
              PlatformCapability.cameraBarcodeScanning,
              PlatformCapability.lanBackup,
              PlatformCapability.videoWatermark,
              PlatformCapability.videoExport,
              PlatformCapability.recordingThumbnail,
              PlatformCapability.systemVideoPlayer,
              PlatformCapability.alertAudioSession,
            }),
      thumbnail: Platform.isAndroid
          ? PigeonThumbnailPlatform()
          : const UnsupportedThumbnailPlatform(),
      orderReceiver: Platform.isAndroid
          ? PigeonOrderReceiverPlatform()
          : const UnsupportedOrderReceiverPlatform(),
      camera: Platform.isAndroid
          ? PigeonCameraPlatform()
          : UnsupportedCameraPlatform(),
      backup: Platform.isAndroid
          ? PigeonBackupNativePlatform()
          : const UnsupportedBackupNativePlatform(),
      mediaProcessing: Platform.isAndroid
          ? PigeonMediaProcessingPlatform()
          : const UnsupportedMediaProcessingPlatform(),
      systemMediaPresenter: Platform.isAndroid
          ? PigeonSystemMediaPresenter()
          : const UnsupportedSystemMediaPresenter(),
      alertAudioSession: Platform.isAndroid
          ? PigeonAlertAudioSessionPlatform()
          : const UnsupportedAlertAudioSessionPlatform(),
    );
  }

  final PlatformCapabilities capabilities;
  final ThumbnailPlatform thumbnail;
  final OrderReceiverPlatform orderReceiver;
  final CameraPlatform camera;
  final BackupNativePlatform backup;
  final MediaProcessingPlatform mediaProcessing;
  final SystemMediaPresenter systemMediaPresenter;
  final AlertAudioSessionPlatform alertAudioSession;
}
