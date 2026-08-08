import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';

void main() {
  test('远程录像解析视频编码字段并兼容缺失', () {
    final RemoteRecording remote = RemoteRecording.fromJson(<String, Object?>{
      'id': 5,
      'startTime': '2026-08-09 10:00:00',
      'durationSec': 3,
      'playUrl': '/api/mobile-backup/videos/5/play?ticket=x',
      'videoCodec': 'h265',
    }, Uri.parse('http://host'));
    expect(remote.videoCodec, 'h265');

    final RemoteRecording legacy = RemoteRecording.fromJson(<String, Object?>{
      'id': 6,
      'durationSec': 1,
    }, Uri.parse('http://host'));
    expect(legacy.videoCodec, '');
  });
}
