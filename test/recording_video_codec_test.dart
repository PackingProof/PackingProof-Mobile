import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';

void main() {
  test('编码枚举存储值与标签', () {
    expect(RecordingVideoCodec.hevc.storageValue, 'hevc');
    expect(RecordingVideoCodec.h264.storageValue, 'h264');
    expect(RecordingVideoCodec.hevc.label, contains('H.265'));
    expect(RecordingVideoCodec.h264.label, contains('H.264'));
    expect(RecordingVideoCodec.hevc.description, isNotEmpty);
    expect(RecordingVideoCodec.h264.description, isNotEmpty);
  });

  test('未知编码回退到默认 H.264，显式存过 H.265 的仍保留', () {
    expect(recordingVideoCodecFromStorage(null), RecordingVideoCodec.h264);
    expect(recordingVideoCodecFromStorage(''), RecordingVideoCodec.h264);
    expect(recordingVideoCodecFromStorage('weird'), RecordingVideoCodec.h264);
    expect(recordingVideoCodecFromStorage('h264'), RecordingVideoCodec.h264);
    expect(recordingVideoCodecFromStorage('avc'), RecordingVideoCodec.h264);
    expect(recordingVideoCodecFromStorage('hevc'), RecordingVideoCodec.hevc);
    expect(recordingVideoCodecFromStorage('h265'), RecordingVideoCodec.hevc);
  });

  test('按实际视频轨道 MIME 反推编码', () {
    expect(recordingVideoCodecFromMime('video/avc'), RecordingVideoCodec.h264);
    expect(recordingVideoCodecFromMime('video/hevc'), RecordingVideoCodec.hevc);
    expect(recordingVideoCodecFromMime('video/avc1'), RecordingVideoCodec.h264);
    expect(recordingVideoCodecFromMime('video/hvc1'), RecordingVideoCodec.hevc);
  });

  test('无法识别或缺失 MIME 时回退到指定编码', () {
    expect(recordingVideoCodecFromMime(null), RecordingVideoCodec.hevc);
    expect(recordingVideoCodecFromMime('video/mp4'), RecordingVideoCodec.hevc);
    expect(
      recordingVideoCodecFromMime(null, fallback: RecordingVideoCodec.h264),
      RecordingVideoCodec.h264,
    );
    expect(
      recordingVideoCodecFromMime(
        'video/mp4',
        fallback: RecordingVideoCodec.h264,
      ),
      RecordingVideoCodec.h264,
    );
  });
}
