import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_spec.dart';

void main() {
  test('规格枚举存储值与标签', () {
    expect(RecordingSpecPreset.hd1080p30.storageValue, 'hd1080p30');
    expect(RecordingSpecPreset.smooth720p30.storageValue, 'smooth720p30');
    expect(RecordingSpecPreset.hd1080p30.label, contains('1080p'));
    expect(RecordingSpecPreset.smooth720p30.label, contains('720p'));
    expect(RecordingSpecPreset.hd1080p30.description, isNotEmpty);
    expect(RecordingSpecPreset.smooth720p30.description, isNotEmpty);
  });

  test('未知规格回退到默认高清', () {
    expect(recordingSpecFromStorage(null), RecordingSpecPreset.hd1080p30);
    expect(recordingSpecFromStorage(''), RecordingSpecPreset.hd1080p30);
    expect(recordingSpecFromStorage('weird'), RecordingSpecPreset.hd1080p30);
    expect(
      recordingSpecFromStorage('smooth720p30'),
      RecordingSpecPreset.smooth720p30,
    );
    expect(
      recordingSpecFromStorage('720p30'),
      RecordingSpecPreset.smooth720p30,
    );
  });

  test('高清与流畅档参数符合预期', () {
    const RecordingSpecPreset hd = RecordingSpecPreset.hd1080p30;
    const RecordingSpecPreset smooth = RecordingSpecPreset.smooth720p30;

    expect(hd.videoWidth, 1920);
    expect(hd.videoHeight, 1080);
    expect(hd.fps, 30);
    expect(hd.avcBitRate, 10000000);
    expect(hd.hevcBitRate, 7000000);

    expect(smooth.videoWidth, 1280);
    expect(smooth.videoHeight, 720);
    expect(smooth.fps, 30);
    expect(smooth.avcBitRate, 6000000);
    expect(smooth.hevcBitRate, 4500000);
  });
}
