import '../contracts/media_platform.dart';
import '../generated/platform_api.g.dart';

class PigeonMediaProcessingPlatform implements MediaProcessingPlatform {
  PigeonMediaProcessingPlatform({MediaProcessingHostApi? api})
    : _api = api ?? MediaProcessingHostApi();

  final MediaProcessingHostApi _api;

  @override
  Future<String> applyWatermark({
    required String inputPath,
    required String outputPath,
    required int startedAtMs,
    required String trackingNumber,
    required String videoCodec,
    String recordingOrientation = 'portrait',
  }) => _api.applyWatermark(
    WatermarkRequest(
      inputPath: inputPath,
      outputPath: outputPath,
      startedAtMs: startedAtMs,
      trackingNumber: trackingNumber,
      videoCodec: videoCodec,
      recordingOrientation: recordingOrientation,
    ),
  );

  @override
  Future<String> exportRange({
    required String inputPath,
    required String outputPath,
    required int startMs,
    required int endMs,
  }) => _api.exportRange(
    ExportRequest(
      inputPath: inputPath,
      outputPath: outputPath,
      startMs: startMs,
      endMs: endMs,
    ),
  );

  @override
  Future<int> exportProgress() => _api.exportProgress();
}

class PigeonSystemMediaPresenter implements SystemMediaPresenter {
  PigeonSystemMediaPresenter({SystemMediaPresenterHostApi? api})
    : _api = api ?? SystemMediaPresenterHostApi();

  final SystemMediaPresenterHostApi _api;

  @override
  Future<String?> getVideoTrackMime(String path) =>
      _api.getVideoTrackMime(path);

  @override
  Future<SystemVideoDecodeSupport?> getVideoDecodeSupport() async {
    final VideoDecodeSupportDto? value = await _api.getVideoDecodeSupport();
    if (value == null) return null;
    return SystemVideoDecodeSupport(
      manufacturer: value.manufacturer,
      brand: value.brand,
      model: value.model,
      sdkInt: value.sdkInt,
      release: value.release,
      hasHevcDecoder: value.hasHevcDecoder,
      hasAvcDecoder: value.hasAvcDecoder,
      forceSoftwareDecode: value.forceSoftwareDecode,
    );
  }

  @override
  Future<void> openWithSystemPlayer(String path) =>
      _api.openWithSystemPlayer(path);
}

class PigeonAlertAudioSessionPlatform implements AlertAudioSessionPlatform {
  PigeonAlertAudioSessionPlatform({AlertAudioSessionHostApi? api})
    : _api = api ?? AlertAudioSessionHostApi();

  final AlertAudioSessionHostApi _api;

  @override
  Future<void> beginSession() => _api.beginSession();

  @override
  Future<void> endSession() => _api.endSession();

  @override
  Future<void> disable() => _api.disable();

  @override
  Future<void> boost() => _api.boost();

  @override
  Future<void> dispose() => _api.endSession();
}
