import 'barcode_marker.dart';
import 'order_info.dart';
import 'recording_operation_mode.dart';

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
  });

  static const String unrecognizedLabel = '未识别面单';

  final String id;
  final String filePath;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<BarcodeMarker> markers;
  final Duration mediaStart;
  final Duration? mediaEnd;
  final OrderInfo? orderInfo;
  final RecordingOperationMode operationMode;

  Duration get duration => endedAt.difference(startedAt);

  Duration get playbackEnd => mediaEnd ?? mediaStart + duration;

  Duration get playbackDuration => playbackEnd - mediaStart;

  String get displayCode =>
      markers.isEmpty ? unrecognizedLabel : markers.first.code;

  RecordingSession copyWith({String? filePath}) => RecordingSession(
    id: id,
    filePath: filePath ?? this.filePath,
    startedAt: startedAt,
    endedAt: endedAt,
    markers: markers,
    mediaStart: mediaStart,
    mediaEnd: mediaEnd,
    orderInfo: orderInfo,
    operationMode: operationMode,
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
    );
  }
}
