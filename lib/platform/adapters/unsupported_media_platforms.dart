import '../contracts/media_platform.dart';
import '../platform_capabilities.dart';
import '../platform_exceptions.dart';

class UnsupportedMediaProcessingPlatform implements MediaProcessingPlatform {
  const UnsupportedMediaProcessingPlatform();

  @override
  Future<String> applyWatermark({
    required String inputPath,
    required String outputPath,
    required int startedAtMs,
    required String trackingNumber,
    required String videoCodec,
    String recordingOrientation = 'portrait',
  }) {
    throw const CapabilityUnavailableException(
      PlatformCapability.videoWatermark,
      reason: '当前平台暂不支持录像水印',
    );
  }

  @override
  Future<String> exportRange({
    required String inputPath,
    required String outputPath,
    required int startMs,
    required int endMs,
  }) {
    throw const CapabilityUnavailableException(
      PlatformCapability.videoExport,
      reason: '当前平台暂不支持分享剪辑',
    );
  }

  @override
  Future<int> exportProgress() async => 100;
}

class UnsupportedSystemMediaPresenter implements SystemMediaPresenter {
  const UnsupportedSystemMediaPresenter();

  @override
  Future<String?> getVideoTrackMime(String path) async => null;

  @override
  Future<SystemVideoDecodeSupport?> getVideoDecodeSupport() async => null;

  @override
  Future<void> openWithSystemPlayer(String path) async {}
}

class UnsupportedAlertAudioSessionPlatform
    implements AlertAudioSessionPlatform {
  const UnsupportedAlertAudioSessionPlatform();

  @override
  Future<void> beginSession() async {}

  @override
  Future<void> endSession() async {}

  @override
  Future<void> disable() async {}

  @override
  Future<void> boost() async {}

  @override
  Future<void> dispose() async {}
}
