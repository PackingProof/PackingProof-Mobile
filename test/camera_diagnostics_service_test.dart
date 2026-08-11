import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/camera_diagnostics_service.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';
import 'package:packing_proof_mobile/services/diagnostics_log_service.dart';

void main() {
  late Directory temp;
  late CameraDiagnosticsService service;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('camera_diagnostics_test_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  CameraDiagnosticsSnapshot snapshot({int count = 1, int ageMs = 10}) =>
      CameraDiagnosticsSnapshot(
        device: <String, Object?>{
          'manufacturer': 'vivo',
          'model': 'V2241A',
          'sdkInt': 34,
          'release': '14',
        },
        camera: <String, Object?>{
          'initialized': true,
          'previewFrameCount': count,
          'previewFrameAgeMs': ageMs,
          'storageAvailableBytes': 123456789,
          'storageTotalBytes': 999999999,
          'muxWriteMaxMs': 140,
          'muxWriteStallCount': 3,
          'workScanEnabled': true,
          'lastRequestTemplate': 'preview',
          'stallActive': false,
          'initFailureStage': 'session_config',
          'recordingFallbackMode': 'encoder_analysis',
          'probeResults': <Object?>[
            <String, Object?>{
              'name': 'preview_only',
              'result': 'configured',
            },
          ],
          'hardwareLevel': 0,
          'capabilities': <Object?>['backward_compatible'],
          'yuvSizes': <Object?>['960x540', '640x480'],
        },
      );

  test('记录快照并保留有界条数', () async {
    service = CameraDiagnosticsService(
      rootProvider: () async => temp,
      snapshotLoader: () async => snapshot(),
      maximumEntries: 3,
    );
    for (int i = 1; i <= 5; i++) {
      await service.recordSnapshot(trigger: 'heartbeat');
    }

    final File file = File('${temp.path}/diagnostics/camera.jsonl');
    expect(await file.exists(), isTrue);
    final List<String> lines = await file.readAsLines();
    expect(lines, hasLength(3));
    final Map<String, Object?> first =
        jsonDecode(lines.first) as Map<String, Object?>;
    expect(first['kind'], 'snapshot');
    expect(first['trigger'], 'heartbeat');
    expect(first['previewFrameCount'], 1);
    expect(first['storageAvailableBytes'], 123456789);
    expect(first['storageTotalBytes'], 999999999);
    expect(first['muxWriteMaxMs'], 140);
    expect(first['muxWriteStallCount'], 3);
    expect(first['initFailureStage'], 'session_config');
    expect(first['recordingFallbackMode'], 'encoder_analysis');
    expect(first['probeResults'], isA<List<Object?>>());
    expect(first['hardwareLevel'], 0);
    expect(first['yuvSizes'], <Object?>['960x540', '640x480']);
    expect(first['device.manufacturer'], 'vivo');
  });

  test('记录事件', () async {
    service = CameraDiagnosticsService(
      rootProvider: () async => temp,
      snapshotLoader: () async => null,
    );
    await service.recordEvent(
      kind: 'native_error',
      extra: <String, Object?>{'message': 'camera error'},
    );

    final File file = File('${temp.path}/diagnostics/camera.jsonl');
    final Map<String, Object?> entry =
        jsonDecode((await file.readAsLines()).single) as Map<String, Object?>;
    expect(entry['kind'], 'native_error');
    expect(entry['message'], 'camera error');
  });

  test('记录初始化失败事件', () async {
    service = CameraDiagnosticsService(
      rootProvider: () async => temp,
      snapshotLoader: () async => null,
    );
    await service.recordEvent(
      kind: 'init_failed',
      extra: <String, Object?>{
        'code': 'session_config',
        'message': '摄像头无法同时提供预览、识别和录像',
      },
    );

    final File file = File('${temp.path}/diagnostics/camera.jsonl');
    final Map<String, Object?> entry =
        jsonDecode((await file.readAsLines()).single) as Map<String, Object?>;
    expect(entry['kind'], 'init_failed');
    expect(entry['code'], 'session_config');
    expect(entry['message'], contains('摄像头'));
  });

  test('导出合并头部、运行日志、相机日志与路径诊断', () async {
    service = CameraDiagnosticsService(
      rootProvider: () async => temp,
      snapshotLoader: () async => null,
    );
    await service.recordEvent(kind: 'snapshot_test');
    await DiagnosticsLogService(
      rootProvider: () async => temp,
    ).log(kind: 'app_start');
    final Directory diagnostics = Directory('${temp.path}/diagnostics');
    await diagnostics.create(recursive: true);
    await File(
      '${diagnostics.path}/path_fix.jsonl',
    ).writeAsString('{"kind":"path"}\n');

    final String text = await service.exportText(header: 'header-line');

    expect(text, contains('header-line'));
    expect(text, contains('app_start'));
    expect(text, contains('snapshot_test'));
    expect(text, contains('"kind":"path"'));
  });

  test('导出文件写入后可读取', () async {
    service = CameraDiagnosticsService(
      rootProvider: () async => temp,
      snapshotLoader: () async => null,
    );

    final File file = await service.writeExportFile('abc');

    expect(file.path, contains('export_'));
    expect(await file.readAsString(), 'abc');
  });
}
