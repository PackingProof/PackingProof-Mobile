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
  Future<int> exportProgress() {
    throw const CapabilityUnavailableException(
      PlatformCapability.videoExport,
      reason: '当前平台暂不支持分享剪辑',
    );
  }
}

class UnsupportedSystemMediaPresenter implements SystemMediaPresenter {
  const UnsupportedSystemMediaPresenter();

  @override
  Future<String?> getVideoTrackMime(String path) => _unsupported();

  @override
  Future<SystemVideoDecodeSupport?> getVideoDecodeSupport() => _unsupported();

  @override
  Future<void> openWithSystemPlayer(String path) => _unsupported();

  Never _unsupported() {
    throw const CapabilityUnavailableException(
      PlatformCapability.systemVideoPlayer,
      reason: '当前平台暂不支持系统播放器',
    );
  }
}

class UnsupportedAlertAudioSessionPlatform
    implements AlertAudioSessionPlatform {
  const UnsupportedAlertAudioSessionPlatform();

  @override
  Future<void> beginSession() => _unsupported();

  @override
  Future<void> endSession() => _unsupported();

  @override
  Future<void> disable() => _unsupported();

  @override
  Future<void> boost() => _unsupported();

  @override
  Future<void> dispose() async {}

  Never _unsupported() {
    throw const CapabilityUnavailableException(
      PlatformCapability.alertAudioSession,
      reason: '当前平台暂不支持提醒音频会话',
    );
  }
}
