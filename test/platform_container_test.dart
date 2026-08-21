import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/platform/adapters/unsupported_backup_platform.dart';
import 'package:packing_proof_mobile/platform/adapters/unsupported_camera_platform.dart';
import 'package:packing_proof_mobile/platform/adapters/unsupported_media_platforms.dart';
import 'package:packing_proof_mobile/platform/adapters/unsupported_order_receiver_platform.dart';
import 'package:packing_proof_mobile/platform/adapters/unsupported_thumbnail_platform.dart';
import 'package:packing_proof_mobile/platform/platform_capabilities.dart';
import 'package:packing_proof_mobile/platform/platform_exceptions.dart';
import 'package:packing_proof_mobile/platform/platform_container.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('current platform container is reused for the process lifetime', () {
    final AppContainer first = AppContainer.forCurrentPlatform();
    final AppContainer second = AppContainer.forCurrentPlatform();

    expect(identical(first, second), isTrue);
    expect(identical(first.camera, second.camera), isTrue);
  });

  test('platform capability matrix distinguishes Android, iOS and desktop', () {
    final AppContainer android = AppContainer.forOperatingSystem('android');
    final AppContainer ios = AppContainer.forOperatingSystem('ios');

    expect(
      android.capabilities.supported,
      containsAll(PlatformCapability.values),
    );
    expect(
      ios.capabilities.supported,
      containsAll(<PlatformCapability>{
        PlatformCapability.continuousCameraRecording,
        PlatformCapability.lanBackup,
        PlatformCapability.orderInfoReceiver,
        PlatformCapability.videoWatermark,
        PlatformCapability.videoExport,
        PlatformCapability.recordingThumbnail,
        PlatformCapability.systemVideoPlayer,
        PlatformCapability.alertAudioSession,
      }),
    );
    expect(
      ios.capabilities.supports(PlatformCapability.alertVolumeBoost),
      isFalse,
    );

    for (final String operatingSystem in <String>[
      'linux',
      'macos',
      'windows',
    ]) {
      final AppContainer container = AppContainer.forOperatingSystem(
        operatingSystem,
      );
      expect(container.capabilities.supported, isEmpty);
      expect(container.thumbnail, isA<UnsupportedThumbnailPlatform>());
      expect(container.orderReceiver, isA<UnsupportedOrderReceiverPlatform>());
      expect(container.camera, isA<UnsupportedCameraPlatform>());
      expect(container.backup, isA<UnsupportedBackupNativePlatform>());
      expect(
        container.mediaProcessing,
        isA<UnsupportedMediaProcessingPlatform>(),
      );
      expect(
        container.systemMediaPresenter,
        isA<UnsupportedSystemMediaPresenter>(),
      );
      expect(
        container.alertAudioSession,
        isA<UnsupportedAlertAudioSessionPlatform>(),
      );
    }
  });

  test(
    'unsupported adapters fail explicitly instead of reporting success',
    () async {
      final UnsupportedBackupNativePlatform backup =
          const UnsupportedBackupNativePlatform();
      final UnsupportedCameraPlatform camera = UnsupportedCameraPlatform();
      final UnsupportedMediaProcessingPlatform media =
          const UnsupportedMediaProcessingPlatform();
      final UnsupportedSystemMediaPresenter presenter =
          const UnsupportedSystemMediaPresenter();
      final UnsupportedOrderReceiverPlatform order =
          const UnsupportedOrderReceiverPlatform();

      Future<void> expectUnavailable(
        Future<Object?> Function() operation,
      ) async {
        await expectLater(
          operation,
          throwsA(isA<CapabilityUnavailableException>()),
        );
      }

      await expectUnavailable(backup.isWifiConnected);
      await expectUnavailable(backup.snapshot);
      await expectUnavailable(
        () => camera.ensurePermissions(recordAudio: false),
      );
      await expectUnavailable(() => camera.setPreviewActive(true));
      await expectUnavailable(media.exportProgress);
      await expectUnavailable(presenter.getVideoDecodeSupport);
      await expectUnavailable(() => order.lookup('tracking'));
    },
  );
}
