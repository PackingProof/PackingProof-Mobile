import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/recording_path_diagnostics.dart';

void main() {
  test('解析失败记录写入诊断文件并可导出', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'path_diagnostics_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final RecordingPathDiagnostics diagnostics = RecordingPathDiagnostics(
      rootProvider: () async => root,
    );

    expect(await diagnostics.exportText(), isNull);

    await diagnostics.recordMissing(
      storedPath: '/data/user/0/pkg/app_flutter/recordings/a.mp4',
      recordingsRoot: '/data/user/0/pkg/app_flutter/recordings',
      attemptedPaths: <String>['/data/user/0/pkg/app_flutter/recordings/a.mp4'],
    );

    final String? text = await diagnostics.exportText();
    expect(text, isNotNull);
    expect(text, contains('/data/user/0/pkg/app_flutter/recordings/a.mp4'));
  });

  test('诊断文件最多保留 200 条', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'path_diagnostics_bounded_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final RecordingPathDiagnostics diagnostics = RecordingPathDiagnostics(
      rootProvider: () async => root,
    );

    for (int index = 0; index < 205; index++) {
      await diagnostics.recordMissing(
        storedPath: '/data/user/0/pkg/a_$index.mp4',
        recordingsRoot: '/data/user/0/pkg/recordings',
        attemptedPaths: const <String>[],
      );
    }

    final String? text = await diagnostics.exportText();
    expect(text, isNotNull);
    expect(text!.split('\n'), hasLength(200));
  });

  test('播放失败记录包含来源、编码与错误信息', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'path_diagnostics_playback_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final RecordingPathDiagnostics diagnostics = RecordingPathDiagnostics(
      rootProvider: () async => root,
    );

    await diagnostics.recordPlaybackFailure(
      source: 'local',
      sessionId: 's1',
      pathOrUri: '/data/user/0/pkg/app_flutter/recordings/a.mp4',
      fileSizeBytes: 12345,
      videoMime: 'video/hevc',
      errorCode: 'VideoError',
      errorMessage: 'Failed to load video',
    );

    final String? text = await diagnostics.exportText();
    expect(text, isNotNull);
    expect(text, contains('"kind":"playback"'));
    expect(text, contains('"source":"local"'));
    expect(text, contains('"sessionId":"s1"'));
    expect(text, contains('"videoMime":"video/hevc"'));
    expect(text, contains('"errorCode":"VideoError"'));
    expect(text, contains('"fileSizeBytes":12345'));
  });

  test('远程播放失败记录设备、HTTP 状态与主机错误码', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'path_diagnostics_remote_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final RecordingPathDiagnostics diagnostics = RecordingPathDiagnostics(
      rootProvider: () async => root,
    );

    await diagnostics.recordPlaybackFailure(
      source: 'remote',
      sessionId: 'remote-4',
      pathOrUri:
          'http://192.168.31.63:5280/api/mobile-backup/videos/4/play?ticket=abc',
      deviceManufacturer: 'vivo',
      deviceModel: 'V2241A',
      deviceSdkInt: 34,
      errorCode: 'VideoError',
      errorMessage: 'Source error',
      httpStatus: 403,
      hostErrorCode: 'device_identity_required',
      hostError: '设备身份验证失败',
    );

    final String? text = await diagnostics.exportText();
    expect(text, isNotNull);
    expect(text, contains('"source":"remote"'));
    expect(text, contains('"deviceManufacturer":"vivo"'));
    expect(text, contains('"httpStatus":403'));
    expect(text, contains('"hostErrorCode":"device_identity_required"'));
    expect(text, contains('"hostError":"设备身份验证失败"'));
  });
}
