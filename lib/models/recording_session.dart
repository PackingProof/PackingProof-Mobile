import 'barcode_marker.dart';
import 'order_info.dart';
import 'recording_operation_mode.dart';
import 'recording_orientation.dart';

enum WatermarkProcessingStatus { pending, processing, completed, failed }

extension WatermarkProcessingStatusValue on WatermarkProcessingStatus {
  String get storageValue => name;
}

WatermarkProcessingStatus watermarkProcessingStatusFromStorage(Object? value) {
  return switch (value) {
    'pending' => WatermarkProcessingStatus.pending,
    'processing' => WatermarkProcessingStatus.processing,
    'failed' => WatermarkProcessingStatus.failed,
    _ => WatermarkProcessingStatus.completed,
  };
}

class RecordingSession {
  const RecordingSession({
    required this.id,
    required this.filePath,
    required this.startedAt,
    required this.endedAt,
    required this.markers,
    this.mediaStart = Duration.zero,
    this.mediaEnd,
    this.orderInfo,
    this.operationMode = RecordingOperationMode.shipping,
    this.recordingOrientation = RecordingOrientation.portrait,
    this.videoCodec = '',
    this.watermarkStatus = WatermarkProcessingStatus.completed,
    this.watermarkAttemptCount = 0,
  });

  static const String unrecognizedLabel = '未识别面单';

  static String automaticName(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year.toString().padLeft(4, '0')}'
        '${two(value.month)}${two(value.day)}_'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }

  final String id;
  final String filePath;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<BarcodeMarker> markers;
  final Duration mediaStart;
  final Duration? mediaEnd;
  final OrderInfo? orderInfo;
  final RecordingOperationMode operationMode;
  final RecordingOrientation recordingOrientation;
  final String videoCodec;
  final WatermarkProcessingStatus watermarkStatus;
  final int watermarkAttemptCount;

  Duration get duration => endedAt.difference(startedAt);

  Duration get playbackEnd => mediaEnd ?? mediaStart + duration;

  Duration get playbackDuration => playbackEnd - mediaStart;

  String get displayCode =>
      markers.isEmpty ? automaticName(startedAt) : markers.first.code;

  RecordingSession copyWith({
    String? filePath,
    String? videoCodec,
    WatermarkProcessingStatus? watermarkStatus,
    int? watermarkAttemptCount,
  }) => RecordingSession(
    id: id,
    filePath: filePath ?? this.filePath,
    startedAt: startedAt,
    endedAt: endedAt,
    markers: markers,
    mediaStart: mediaStart,
    mediaEnd: mediaEnd,
    orderInfo: orderInfo,
    operationMode: operationMode,
    recordingOrientation: recordingOrientation,
    videoCodec: videoCodec ?? this.videoCodec,
    watermarkStatus: watermarkStatus ?? this.watermarkStatus,
    watermarkAttemptCount: watermarkAttemptCount ?? this.watermarkAttemptCount,
  );

  RecordingSession trimmed({
    required Duration startOffset,
    required Duration endOffset,
  }) => trimmedToMediaRange(
    mediaStart: mediaStart + startOffset,
    mediaEnd: mediaStart + endOffset,
  );

  RecordingSession trimmedToMediaRange({
    required Duration mediaStart,
    required Duration mediaEnd,
  }) {
    if (mediaStart.isNegative || mediaEnd <= mediaStart) {
      throw ArgumentError('剪辑区间必须位于源视频内');
    }
    final DateTime sourceStartedAt = startedAt.subtract(this.mediaStart);
    final Duration newDuration = mediaEnd - mediaStart;
    final List<BarcodeMarker> adjustedMarkers = markers
        .map((BarcodeMarker marker) {
          Duration offset = marker.occurredAt.difference(
            sourceStartedAt.add(mediaStart),
          );
          if (offset.isNegative || offset > newDuration) {
            offset = Duration.zero;
          }
          return BarcodeMarker(
            code: marker.code,
            occurredAt: marker.occurredAt,
            offset: offset,
          );
        })
        .toList(growable: false);
    return RecordingSession(
      id: id,
      filePath: filePath,
      startedAt: sourceStartedAt.add(mediaStart),
      endedAt: sourceStartedAt.add(mediaEnd),
      markers: adjustedMarkers,
      mediaStart: mediaStart,
      mediaEnd: mediaEnd,
      orderInfo: orderInfo,
      operationMode: operationMode,
      recordingOrientation: recordingOrientation,
      videoCodec: videoCodec,
      watermarkStatus: watermarkStatus,
      watermarkAttemptCount: watermarkAttemptCount,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'filePath': filePath,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'markers': markers.map((BarcodeMarker marker) => marker.toJson()).toList(),
    'mediaStartMilliseconds': mediaStart.inMilliseconds,
    'mediaEndMilliseconds': playbackEnd.inMilliseconds,
    if (orderInfo != null) 'orderInfo': orderInfo!.toJson(),
    'operationMode': operationMode.storageValue,
    'recordingOrientation': recordingOrientation.storageValue,
    if (videoCodec.isNotEmpty) 'videoCodec': videoCodec,
    'watermarkStatus': watermarkStatus.storageValue,
    'watermarkAttemptCount': watermarkAttemptCount,
  };

  factory RecordingSession.fromJson(Map<String, Object?> json) {
    final List<Object?> markerValues = json['markers']! as List<Object?>;
    return RecordingSession(
      id: json['id']! as String,
      filePath: json['filePath']! as String,
      startedAt: DateTime.parse(json['startedAt']! as String),
      endedAt: DateTime.parse(json['endedAt']! as String),
      markers: markerValues
          .map(
            (Object? value) => BarcodeMarker.fromJson(
              Map<String, Object?>.from(value! as Map<Object?, Object?>),
            ),
          )
          .toList(growable: false),
      mediaStart: Duration(
        milliseconds: (json['mediaStartMilliseconds'] as num?)?.toInt() ?? 0,
      ),
      mediaEnd: json['mediaEndMilliseconds'] == null
          ? null
          : Duration(
              milliseconds: (json['mediaEndMilliseconds']! as num).toInt(),
            ),
      orderInfo: json['orderInfo'] is Map
          ? OrderInfo.fromMap(
              Map<Object?, Object?>.from(json['orderInfo']! as Map),
            )
          : null,
      operationMode: recordingOperationModeFromStorage(json['operationMode']),
      recordingOrientation: recordingOrientationFromStorage(
        json['recordingOrientation'],
      ),
      videoCodec: (json['videoCodec'] as String?)?.trim().toLowerCase() ?? '',
      watermarkStatus: watermarkProcessingStatusFromStorage(
        json['watermarkStatus'],
      ),
      watermarkAttemptCount:
          (json['watermarkAttemptCount'] as num?)?.toInt() ?? 0,
    );
  }
}
