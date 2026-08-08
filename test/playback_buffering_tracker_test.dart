import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/screens/video_playback_screen.dart';
import 'package:video_player/video_player.dart';

void main() {
  test('进入缓冲时累计次数并在恢复播放后重置判定', () {
    final PlaybackBufferingTracker tracker = PlaybackBufferingTracker();
    tracker.observe(
      const VideoPlayerValue(
        duration: Duration(minutes: 1),
        position: Duration(seconds: 2),
      ),
    );
    tracker.observe(
      const VideoPlayerValue(
        duration: Duration(minutes: 1),
        position: Duration(seconds: 2),
        isBuffering: true,
      ),
    );
    tracker.observe(
      const VideoPlayerValue(
        duration: Duration(minutes: 1),
        position: Duration(seconds: 3),
        isBuffering: true,
      ),
    );

    expect(tracker.bufferingCount, 1);

    tracker.observe(
      const VideoPlayerValue(
        duration: Duration(minutes: 1),
        position: Duration(seconds: 4),
      ),
    );
    tracker.observe(
      const VideoPlayerValue(
        duration: Duration(minutes: 1),
        position: Duration(seconds: 4),
        isBuffering: true,
      ),
    );

    expect(tracker.bufferingCount, 2);
  });

  test('记录最近一次播放位置', () {
    final PlaybackBufferingTracker tracker = PlaybackBufferingTracker();
    tracker.observe(
      const VideoPlayerValue(
        duration: Duration(minutes: 1),
        position: Duration(seconds: 12),
      ),
    );
    tracker.observe(
      const VideoPlayerValue(
        duration: Duration(minutes: 1),
        position: Duration(seconds: 30),
      ),
    );

    expect(tracker.lastPositionMs, 30000);
  });
}
