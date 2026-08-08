import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('原生录像分片与关闭声音体积对比', (WidgetTester tester) async {
    if (!Platform.isAndroid) {
      return;
    }
    final Directory root = await getApplicationDocumentsDirectory();
    final Directory output = Directory(p.join(root.path, 'integration-test'));
    await output.create(recursive: true);
    final File first = File(p.join(output.path, 'segment-1.mp4'));
    final File second = File(p.join(output.path, 'segment-2.mp4'));
    final File withAudio = File(p.join(output.path, 'with-audio.mp4'));
    final File withoutAudio = File(p.join(output.path, 'without-audio.mp4'));
    for (final File file in <File>[first, second, withAudio, withoutAudio]) {
      if (await file.exists()) {
        await file.delete();
      }
    }

    final ContinuousCameraService camera = ContinuousCameraService();
    addTearDown(camera.dispose);
    final ContinuousCameraInitialization initialization = await camera
        .initialize();
    expect(initialization.textureId, greaterThanOrEqualTo(0));
    expect(initialization.fps, 30);

    final CameraDiagnosticsSnapshot initialDiagnostics = (await camera
        .getDiagnostics())!;
    expect(initialDiagnostics.initialized, isTrue);
    await Future<void>.delayed(const Duration(seconds: 1));
    final CameraDiagnosticsSnapshot previewAlive = (await camera
        .getDiagnostics())!;
    expect(
      previewAlive.previewFrameCount,
      greaterThan(initialDiagnostics.previewFrameCount),
    );

    // 工作扫描开启后预览帧必须继续前进；此步可捕获“开始工作后预览冻结”。
    await camera.setWorkScanEnabled(true);
    final CameraDiagnosticsSnapshot beforeScan = (await camera
        .getDiagnostics())!;
    await Future<void>.delayed(const Duration(seconds: 2));
    final CameraDiagnosticsSnapshot afterScan = (await camera
        .getDiagnostics())!;
    expect(
      afterScan.previewFrameCount,
      greaterThan(beforeScan.previewFrameCount),
    );
    expect(afterScan.previewFrameAgeMs, lessThan(3000));
    await camera.setWorkScanEnabled(false);

    final NativeRecordingStart started = await camera.startWork(
      first.path,
      recordAudio: true,
    );
    expect(started.path, first.path);
    await Future<void>.delayed(const Duration(seconds: 4));

    final NativeRecordingSplit split = await camera.split(second.path);
    expect(split.completedPath, first.path);
    expect(split.nextPath, second.path);
    expect(split.boundaryAt.isAfter(started.startedAt), isTrue);
    await Future<void>.delayed(const Duration(seconds: 4));

    final CameraDiagnosticsSnapshot beforeStop = (await camera
        .getDiagnostics())!;
    final NativeRecordingStop stopped = await camera.stopWork();
    expect(stopped.path, second.path);
    expect(await first.length(), greaterThan(100000));
    expect(await second.length(), greaterThan(100000));
    // 停止后预览帧必须继续前进；此步可捕获“按结束后仍卡住”。
    await Future<void>.delayed(const Duration(seconds: 3));
    final CameraDiagnosticsSnapshot previewAfterStop = (await camera
        .getDiagnostics())!;
    expect(
      previewAfterStop.previewFrameCount,
      greaterThan(beforeStop.previewFrameCount),
    );
    expect(previewAfterStop.previewFrameAgeMs, lessThan(4000));

    final NativeRecordingStart audioStart = await camera.startWork(
      withAudio.path,
      recordAudio: true,
    );
    expect(audioStart.path, withAudio.path);
    await Future<void>.delayed(const Duration(seconds: 5));
    await camera.stopWork();

    final NativeRecordingStart silentStart = await camera.startWork(
      withoutAudio.path,
      recordAudio: false,
    );
    expect(silentStart.path, withoutAudio.path);
    await Future<void>.delayed(const Duration(seconds: 5));
    await camera.stopWork();

    final int withAudioBytes = await withAudio.length();
    final int withoutAudioBytes = await withoutAudio.length();
    debugPrint('音频开视频大小: $withAudioBytes bytes');
    debugPrint('音频关视频大小: $withoutAudioBytes bytes');
    debugPrint('差值: ${withAudioBytes - withoutAudioBytes} bytes');
    expect(withAudioBytes, greaterThan(100000));
    expect(withoutAudioBytes, greaterThan(100000));
    expect(withoutAudioBytes, lessThan(withAudioBytes));
  });
}
