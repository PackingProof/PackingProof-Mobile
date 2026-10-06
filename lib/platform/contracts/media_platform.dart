class SystemVideoDecodeSupport {
  const SystemVideoDecodeSupport({
    required this.manufacturer,
    required this.brand,
    required this.model,
    required this.sdkInt,
    required this.release,
    required this.hasHevcDecoder,
    required this.hasAvcDecoder,
    required this.hasHevcEncoder,
    required this.hasAvcEncoder,
    required this.forceSoftwareDecode,
  });

  final String manufacturer;
  final String brand;
  final String model;
  final int sdkInt;
  final String release;
  final bool hasHevcDecoder;
  final bool hasAvcDecoder;
  final bool hasHevcEncoder;
  final bool hasAvcEncoder;
  final bool forceSoftwareDecode;
}

abstract interface class MediaProcessingPlatform {
  Future<String> applyWatermark({
    required String inputPath,
    required String outputPath,
    required int startedAtMs,
    required String trackingNumber,
    required String videoCodec,
    String recordingOrientation = 'portrait',
  });

  Future<void> cancelWatermark();

  Future<String> exportRange({
    required String inputPath,
    required String outputPath,
    required int startMs,
    required int endMs,
    required bool passthrough,
  });

  Future<int> exportProgress();
}

abstract interface class SystemMediaPresenter {
  Future<String?> getVideoTrackMime(String path);

  Future<SystemVideoDecodeSupport?> getVideoDecodeSupport();

  Future<void> openWithSystemPlayer(String path);

  Future<void> saveVideoToGallery(String path);
}

abstract interface class AlertAudioSessionPlatform {
  Future<void> beginSession();

  Future<void> endSession();

  Future<void> disable();

  Future<void> boost();

  Future<void> dispose();
}
