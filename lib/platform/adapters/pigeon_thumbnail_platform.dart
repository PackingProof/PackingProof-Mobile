import '../contracts/thumbnail_platform.dart';
import '../generated/platform_api.g.dart';

class PigeonThumbnailPlatform implements ThumbnailPlatform {
  PigeonThumbnailPlatform({MediaProcessingHostApi? api})
    : _api = api ?? MediaProcessingHostApi();

  final MediaProcessingHostApi _api;

  @override
  Future<String?> generate(String filePath) async {
    if (filePath.isEmpty) return null;
    return _api.generateThumbnail(ThumbnailRequest(path: filePath));
  }
}
