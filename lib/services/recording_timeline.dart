import '../models/barcode_marker.dart';
import '../models/recording_session.dart';
import '../models/recording_operation_mode.dart';

class RecordingTimeline {
  final List<RecordingSegmentDraft> _completedSegments =
      <RecordingSegmentDraft>[];
  final List<BarcodeMarker> _activeMarkers = <BarcodeMarker>[];

  DateTime? _recordingStartedAt;
  DateTime? _segmentStartedAt;
  String _currentCode = '';

  DateTime? get recordingStartedAt => _recordingStartedAt;
  DateTime? get segmentStartedAt => _segmentStartedAt;
  String get currentCode => _currentCode;
  bool get isActive => _recordingStartedAt != null;

  void start(DateTime startedAt) {
    reset();
    _recordingStartedAt = startedAt;
    _segmentStartedAt = startedAt;
  }

  BarcodeMarker? bindCode(String code, DateTime occurredAt) {
    final DateTime? segmentStartedAt = _segmentStartedAt;
    if (segmentStartedAt == null || _currentCode.isNotEmpty) {
      return null;
    }
    final BarcodeMarker marker = BarcodeMarker(
      code: code,
      occurredAt: occurredAt,
      offset: _difference(occurredAt, segmentStartedAt),
    );
    _currentCode = code;
    _activeMarkers.add(marker);
    return marker;
  }

  RecordingSegmentTransition? startNext(String code, DateTime occurredAt) {
    if (_segmentStartedAt == null) {
      return null;
    }
    final RecordingSegmentDraft completed = _completeActiveSegment(occurredAt)!;
    _segmentStartedAt = occurredAt;
    _currentCode = '';
    _activeMarkers.clear();
    final BarcodeMarker marker = bindCode(code, occurredAt)!;
    return RecordingSegmentTransition(completed: completed, marker: marker);
  }

  RecordingSegmentDraft? finish(DateTime endedAt) {
    return _completeActiveSegment(endedAt);
  }

  List<RecordingSession> buildSessions({
    required DateTime endedAt,
    required String filePath,
    required String recordingId,
    RecordingOperationMode operationMode = RecordingOperationMode.shipping,
  }) {
    final DateTime? recordingStartedAt = _recordingStartedAt;
    if (recordingStartedAt == null || _segmentStartedAt == null) {
      return <RecordingSession>[];
    }

    _completeActiveSegment(endedAt);
    if (_completedSegments.length != 1) {
      throw StateError('每个录像片段必须先保存为独立视频文件');
    }
    return List<RecordingSession>.generate(_completedSegments.length, (
      int index,
    ) {
      final RecordingSegmentDraft draft = _completedSegments[index];
      final String id = _completedSegments.length == 1
          ? recordingId
          : '${recordingId}_${(index + 1).toString().padLeft(3, '0')}';
      return RecordingSession(
        id: id,
        filePath: filePath,
        startedAt: draft.startedAt,
        endedAt: draft.endedAt,
        markers: List<BarcodeMarker>.unmodifiable(draft.markers),
        mediaStart: _difference(draft.startedAt, recordingStartedAt),
        mediaEnd: _difference(draft.endedAt, recordingStartedAt),
        operationMode: operationMode,
      );
    }, growable: false);
  }

  void reset() {
    _completedSegments.clear();
    _activeMarkers.clear();
    _recordingStartedAt = null;
    _segmentStartedAt = null;
    _currentCode = '';
  }

  RecordingSegmentDraft? _completeActiveSegment(DateTime endedAt) {
    final DateTime? startedAt = _segmentStartedAt;
    if (startedAt == null) {
      return null;
    }
    final RecordingSegmentDraft completed = RecordingSegmentDraft(
      startedAt: startedAt,
      endedAt: endedAt.isBefore(startedAt) ? startedAt : endedAt,
      markers: List<BarcodeMarker>.of(_activeMarkers),
    );
    _completedSegments.add(completed);
    _segmentStartedAt = null;
    return completed;
  }
}

class RecordingSegmentDraft {
  const RecordingSegmentDraft({
    required this.startedAt,
    required this.endedAt,
    required this.markers,
  });

  final DateTime startedAt;
  final DateTime endedAt;
  final List<BarcodeMarker> markers;
}

class RecordingSegmentTransition {
  const RecordingSegmentTransition({
    required this.completed,
    required this.marker,
  });

  final RecordingSegmentDraft completed;
  final BarcodeMarker marker;
}

Duration _difference(DateTime later, DateTime earlier) {
  final Duration value = later.difference(earlier);
  return value.isNegative ? Duration.zero : value;
}
