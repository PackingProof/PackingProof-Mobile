import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/recording_timeline.dart';

void main() {
  test('拒绝把未物理分段的连续录像保存成多条记录', () {
    final RecordingTimeline timeline = RecordingTimeline();
    final DateTime startedAt = DateTime(2026, 7, 18, 9);
    timeline.start(startedAt);

    timeline.bindCode('CODE-001', startedAt.add(const Duration(seconds: 2)));
    timeline.startNext('CODE-002', startedAt.add(const Duration(seconds: 10)));
    expect(
      () => timeline.buildSessions(
        endedAt: startedAt.add(const Duration(seconds: 20)),
        filePath: 'legacy.mp4',
        recordingId: 'recording-1',
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          '每个录像片段必须先保存为独立视频文件',
        ),
      ),
    );
  });

  test('连续扫码会返回可立即保存的已完成实体片段', () {
    final RecordingTimeline timeline = RecordingTimeline();
    final DateTime startedAt = DateTime(2026, 7, 18, 9);
    timeline.start(startedAt);
    timeline.bindCode('CODE-001', startedAt.add(const Duration(seconds: 2)));

    final RecordingSegmentTransition transition = timeline.startNext(
      'CODE-002',
      startedAt.add(const Duration(seconds: 10)),
    )!;

    expect(transition.completed.startedAt, startedAt);
    expect(
      transition.completed.endedAt,
      startedAt.add(const Duration(seconds: 10)),
    );
    expect(transition.completed.markers.single.code, 'CODE-001');
    expect(transition.marker.code, 'CODE-002');
    expect(transition.marker.offset, Duration.zero);
    expect(
      timeline.segmentStartedAt,
      startedAt.add(const Duration(seconds: 10)),
    );
  });

  test('没有识别到面单时保留完整工作录像', () {
    final RecordingTimeline timeline = RecordingTimeline();
    final DateTime startedAt = DateTime(2026, 7, 18, 9);
    timeline.start(startedAt);

    final List<RecordingSession> sessions = timeline.buildSessions(
      endedAt: startedAt.add(const Duration(seconds: 8)),
      filePath: 'legacy.mp4',
      recordingId: 'recording-1',
    );

    expect(sessions, hasLength(1));
    expect(sessions.single.displayCode, '未识别面单');
    expect(sessions.single.duration, const Duration(seconds: 8));
    expect(sessions.single.mediaStart, Duration.zero);
    expect(sessions.single.playbackEnd, const Duration(seconds: 8));
  });
}
