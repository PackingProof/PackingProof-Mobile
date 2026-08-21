import 'dart:io';

import 'package:flutter/foundation.dart';

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

  factory AppContainer.forCurrentPlatform() =>
      _currentPlatform ??= _createForCurrentPlatform();

  static AppContainer? _currentPlatform;

  static AppContainer _createForCurrentPlatform() {
    return forOperatingSystem(Platform.operatingSystem);
  }

  @visibleForTesting
  static AppContainer forOperatingSystem(String operatingSystem) {
    final _AppPlatform platform = switch (operatingSystem) {
      'android' => _AppPlatform.android,
      'ios' => _AppPlatform.ios,
      _ => _AppPlatform.unsupported,
    };
    final bool isAndroid = platform == _AppPlatform.android;
    final bool isMobile = isAndroid || platform == _AppPlatform.ios;
    return AppContainer(
      capabilities: isAndroid
          ? const PlatformCapabilities(<PlatformCapability>{
              PlatformCapability.continuousCameraRecording,
              PlatformCapability.lanBackup,
              PlatformCapability.orderInfoReceiver,
              PlatformCapability.videoWatermark,
              PlatformCapability.videoExport,
              PlatformCapability.recordingThumbnail,
              PlatformCapability.systemVideoPlayer,
              PlatformCapability.alertAudioSession,
              PlatformCapability.alertVolumeBoost,
            })
          : platform == _AppPlatform.ios
          ? const PlatformCapabilities(<PlatformCapability>{
              PlatformCapability.continuousCameraRecording,
              PlatformCapability.lanBackup,
              PlatformCapability.orderInfoReceiver,
              PlatformCapability.videoWatermark,
              PlatformCapability.videoExport,
              PlatformCapability.recordingThumbnail,
              PlatformCapability.systemVideoPlayer,
              PlatformCapability.alertAudioSession,
            })
          : const PlatformCapabilities(<PlatformCapability>{}),
      thumbnail: isMobile
          ? PigeonThumbnailPlatform()
          : const UnsupportedThumbnailPlatform(),
      orderReceiver: isMobile
          ? PigeonOrderReceiverPlatform()
          : const UnsupportedOrderReceiverPlatform(),
      camera: isMobile ? PigeonCameraPlatform() : UnsupportedCameraPlatform(),
      backup: isMobile
          ? PigeonBackupNativePlatform()
          : const UnsupportedBackupNativePlatform(),
      mediaProcessing: isMobile
          ? PigeonMediaProcessingPlatform()
          : const UnsupportedMediaProcessingPlatform(),
      systemMediaPresenter: isMobile
          ? PigeonSystemMediaPresenter()
          : const UnsupportedSystemMediaPresenter(),
      alertAudioSession: isMobile
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

enum _AppPlatform { android, ios, unsupported }
