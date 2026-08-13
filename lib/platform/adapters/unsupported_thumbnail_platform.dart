import '../contracts/thumbnail_platform.dart';
import '../platform_capabilities.dart';
import '../platform_exceptions.dart';

class UnsupportedThumbnailPlatform implements ThumbnailPlatform {
  const UnsupportedThumbnailPlatform();

  @override
  Future<String?> generate(String filePath) {
    throw const CapabilityUnavailableException(
      PlatformCapability.recordingThumbnail,
      reason: '当前平台暂不支持生成录像预览图',
    );
  }
}
