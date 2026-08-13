import 'package:flutter/services.dart';

import '../platform/contracts/thumbnail_platform.dart';
import '../platform/platform_container.dart';

class RecordingThumbnailService {
  RecordingThumbnailService({
    MethodChannel? channel,
    ThumbnailPlatform? platform,
  }) : _platform =
           platform ??
           (channel != null
               ? _LegacyThumbnailPlatform(channel)
               : AppContainer.forCurrentPlatform().thumbnail);

  final ThumbnailPlatform _platform;

  Future<String?> generate(String filePath) async {
    if (filePath.isEmpty) return null;
    try {
      return await _platform.generate(filePath);
    } on PlatformException {
      return null;
    }
  }
}

class _LegacyThumbnailPlatform implements ThumbnailPlatform {
  const _LegacyThumbnailPlatform(this.channel);

  final MethodChannel channel;

  @override
  Future<String?> generate(String filePath) async {
    return channel.invokeMethod<String>('generate', <String, Object>{
      'path': filePath,
    });
  }
}
