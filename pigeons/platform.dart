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
  String recordingOrientation;
}

class ExportRequest {
  String inputPath;
  String outputPath;
  int startMs;
  int endMs;
  bool passthrough;
}

class VideoDecodeSupportDto {
  String manufacturer;
  String brand;
  String model;
  int sdkInt;
  String release;
  bool hasHevcDecoder;
  bool hasAvcDecoder;
  bool hasHevcEncoder;
  bool hasAvcEncoder;
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
  String capabilityMode;
  String recordingOrientation;
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

enum CameraWatermarkDisposition {
  completed,
  postProcessRequired,
  failedPartial,
}

class CameraRecordingSplitDto {
  String completedPath;
  String nextPath;
  int completedStartedAtMs;
  int boundaryAtMs;
  CameraWatermarkDisposition watermarkDisposition;
}

class CameraRecordingStopDto {
  String path;
  int startedAtMs;
  int endedAtMs;
  CameraWatermarkDisposition watermarkDisposition;
}

class BarcodeCandidateDto {
  String value;
  int area;
  String? format;
  int detectedAtMs;
}

class BackupJobDto {
  int revision;
  String id;
  String filePath;
  String state;
  int uploadedBytes;
  int totalBytes;
  int? lastModifiedMs;
  String? contentSha256;
  String? errorMessage;
  String? failureKind;
  int? fileCreatedAtMs;
  int? backupCompletedAtMs;
  int? scheduledCleanupAtMs;
  int? localDeletedAtMs;
  bool waitingCleanup;
  int? remoteRecordId;
  String destinationComputerId;
  String? cleanupReason;
}

class BackupSummaryDto {
  int schemaVersion;
  int revision;
  int completedRevision;
  int cleanupHighWatermark;
  String deviceId;
  String deviceName;
  String? baseUrl;
  String? computerId;
  String? computerName;
  int? lastConnectedAtMs;
  String? preferredHostId;
  String? preferredHostName;
  int totalCount;
  int pendingCount;
  int uploadingCount;
  int pausedCount;
  int completedCount;
  int failedCount;
  int waitingCleanupCount;
  int localDeletedCount;
  int unfinishedUploadedBytes;
  int unfinishedTotalBytes;
  String? dominantFailureKind;
  BackupJobDto? activeJob;
  BackupJobDto? problemJob;
}

class BackupJobsByPathsDto {
  int revision;
  List<BackupJobDto> jobs;
  List<String> missingPaths;
}

class BackupCleanupEventDto {
  int revision;
  String eventId;
  String jobId;
  String filePath;
  int fileSizeBytes;
  int deletedAtMs;
  String reason;
}

class BackupCleanupPageDto {
  int latestRevision;
  int nextAfterRevision;
  bool hasMore;
  List<BackupCleanupEventDto> events;
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
  @async
  String applyWatermark(WatermarkRequest request);
  @async
  void cancelWatermark();
  @async
  String exportRange(ExportRequest request);
  @async
  int exportProgress();
}

@HostApi()
abstract class SystemMediaPresenterHostApi {
  @async
  String? getVideoTrackMime(String path);
  @async
  VideoDecodeSupportDto? getVideoDecodeSupport();
  @async
  void openWithSystemPlayer(String path);
}

@HostApi()
abstract class AlertAudioSessionHostApi {
  @async
  void beginSession();
  @async
  void endSession();
  @async
  void disable();
  @async
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
  @async
  CameraInitializationDto initialize(CameraInitializeRequest request);
  @async
  bool ensurePermissions(bool recordAudio);
  @async
  CameraRecordingStartDto startWork(
    String path,
    bool recordAudio,
    String trackingNumber,
  );
  @async
  CameraRecordingSplitDto split(String nextPath, String trackingNumber);
  @async
  CameraRecordingStopDto stopWork();
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  Map<String?, Object?>? getDiagnostics();
  @async
  void setPairingScanEnabled(bool enabled);
  @async
  void setWorkScanEnabled(bool enabled);
  @async
  void setPreviewActive(bool active);
  @async
  bool setTorchEnabled(bool enabled);
  @async
  CameraInitializationDto switchCamera();
  @async
  List<CameraLensDto> listCameras();
  @async
  CameraInitializationDto switchToCamera(String cameraId);
  @async
  Map<String?, Object?>? probeSequence(String sequence, int budgetMs);
  void setCapabilityMode(String mode);
  @async
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
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  BackupSummaryDto summary();
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  BackupSummaryDto initialize(Map<String?, Object?> request);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void setAutoEnabled(bool enabled);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  BackupJobsByPathsDto jobsForPaths(List<String> paths);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  BackupCleanupPageDto cleanupEvents(int afterRevision, int limit);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void acknowledgeCleanupEvents(int throughRevision);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  bool hasPendingJobsOutsideDestination(String computerId);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  String? loadAccessKey();
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  bool isWifiConnected();
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void saveConnection(Map<String?, Object?> connection);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void disconnect();
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void enqueueJob(Map<String?, Object?> request);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void enqueueJobs(List<Map<String?, Object?>> requests);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void requeueJob(String jobId, bool manual);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void cancelJob(String jobId);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void updateRetentionSchedule(Map<String?, Object?> request);
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  int? availableRecordingStorageBytes();
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  Map<String?, Object?> reclaimStorageIfNeeded();
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  Map<String?, Object?>? getNetworkDiagnostics();
}

@FlutterApi()
abstract class BackupNativeEventApi {
  void summaryChanged(BackupSummaryDto summary);
}
