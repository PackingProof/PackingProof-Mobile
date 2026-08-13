import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/generated/platform_api.g.dart',
    dartPackageName: 'packing_proof_mobile',
    kotlinOut:
        'android/app/src/main/kotlin/app/packingproof/mobile/generated/PlatformApi.kt',
    kotlinOptions: KotlinOptions(
      package: 'app.packingproof.mobile.generated',
      includeErrorClass: true,
    ),
    swiftOut: 'ios/Runner/Generated/PlatformApi.swift',
    swiftOptions: SwiftOptions(includeErrorClass: true),
  ),
)
class ThumbnailRequest {
  String path;
}

class WatermarkRequest {
  String inputPath;
  String outputPath;
  int startedAtMs;
  String trackingNumber;
  String videoCodec;
}

class ExportRequest {
  String inputPath;
  String outputPath;
  int startMs;
  int endMs;
}

class VideoDecodeSupportDto {
  String manufacturer;
  String brand;
  String model;
  int sdkInt;
  String release;
  bool hasHevcDecoder;
  bool hasAvcDecoder;
  bool forceSoftwareDecode;
}

class OrderInfoDto {
  String trackingNumber;
  String orderId;
  String buyerMessage;
  String sellerMemo;
  String productInfo;
  bool hasRefund;
  bool isPrintedRefund;
  String refundStatus;
  String refundProductInfo;
  int? pushTimeMs;
  bool isTest;
}

class OrderReceiverStatusDto {
  bool running;
  String ipAddress;
  String url;
  int port;
  String errorMessage;
}

class CameraInitializeRequest {
  String videoCodec;
  String recordingSpec;
  bool fallbackRecording;
}

class CameraInitializationDto {
  int textureId;
  int previewWidth;
  int previewHeight;
  int sensorOrientation;
  int fps;
  String videoMime;
  String? codecFallbackReason;
  bool flashAvailable;
  String lensDirection;
  bool canSwitchCamera;
  String? cameraId;
  double zoomRatio;
}

class CameraLensDto {
  String cameraId;
  double focalLength;
  double zoomRatio;
  bool isMain;
}

class CameraRecordingStartDto {
  String path;
  int startedAtMs;
}

class CameraRecordingSplitDto {
  String completedPath;
  String nextPath;
  int completedStartedAtMs;
  int boundaryAtMs;
}

class CameraRecordingStopDto {
  String path;
  int startedAtMs;
  int endedAtMs;
}

class BarcodeCandidateDto {
  String value;
  int area;
  String? format;
}

class CameraSessionStartedDto {
  String sessionId;
  int startedAtMs;
}

class CameraSegmentStartedDto {
  String sessionId;
  String segmentId;
  int startedAtMs;
}

class CameraSegmentCompletedDto {
  String sessionId;
  String segmentId;
  String path;
  int startedAtMs;
  int endedAtMs;
}

class CameraSegmentFailedDto {
  String sessionId;
  String segmentId;
  String reason;
}

class CameraSessionFailedDto {
  String sessionId;
  String reason;
}

@HostApi()
abstract class MediaProcessingHostApi {
  @async
  String? generateThumbnail(ThumbnailRequest request);
  String applyWatermark(WatermarkRequest request);
  String exportRange(ExportRequest request);
  int exportProgress();
}

@HostApi()
abstract class SystemMediaPresenterHostApi {
  String? getVideoTrackMime(String path);
  VideoDecodeSupportDto? getVideoDecodeSupport();
  void openWithSystemPlayer(String path);
}

@HostApi()
abstract class AlertAudioSessionHostApi {
  void beginSession();
  void endSession();
  void disable();
  void boost();
}

@HostApi()
abstract class OrderReceiverHostApi {
  OrderReceiverStatusDto startReceiver(bool backgroundDelivery);
  OrderReceiverStatusDto getReceiverStatus();
  OrderInfoDto? lookup(String trackingNumber);
  void updateBackgroundDelivery(bool enabled);
  void stopReceiver();
}

@FlutterApi()
abstract class OrderReceiverEventApi {
  void orderInfoReceived(List<OrderInfoDto> items);
}

@HostApi()
abstract class CameraHostApi {
  CameraInitializationDto initialize(CameraInitializeRequest request);
  bool ensurePermissions(bool recordAudio);
  CameraRecordingStartDto startWork(String path, bool recordAudio);
  CameraRecordingSplitDto split(String nextPath);
  CameraRecordingStopDto stopWork();
  Map<String?, Object?>? getDiagnostics();
  void setPairingScanEnabled(bool enabled);
  void setWorkScanEnabled(bool enabled);
  void setPreviewActive(bool active);
  bool setTorchEnabled(bool enabled);
  CameraInitializationDto switchCamera();
  List<CameraLensDto> listCameras();
  CameraInitializationDto switchToCamera(String cameraId);
  void dispose();
}

@FlutterApi()
abstract class CameraEventApi {
  void sessionStarted(CameraSessionStartedDto event);
  void segmentStarted(CameraSegmentStartedDto event);
  void segmentCompleted(CameraSegmentCompletedDto event);
  void segmentFailed(CameraSegmentFailedDto event);
  void sessionFailed(CameraSessionFailedDto event);
  void barcodeBatch(List<BarcodeCandidateDto> candidates);
  void nativeError(String message);
  void storageCritical();
  void probeFinished(Map<String?, Object?> results);
  void recordingFallback(Map<String?, Object?> info);
}

@HostApi()
abstract class BackupNativeHostApi {
  Map<String?, Object?>? snapshot();
  Map<String?, Object?>? initialize(Map<String?, Object?> request);
  String? loadAccessKey();
  bool isWifiConnected();
  void saveConnection(Map<String?, Object?> connection);
  void disconnect();
  void enqueueJob(Map<String?, Object?> request);
  void requeueJob(String jobId);
  void cancelJob(String jobId);
  void updateRetentionSchedule(Map<String?, Object?> request);
  Map<String?, Object?> reclaimStorageIfNeeded();
  Map<String?, Object?>? getNetworkDiagnostics();
}

@FlutterApi()
abstract class BackupNativeEventApi {
  void snapshotChanged(Map<String?, Object?> snapshot);
}
