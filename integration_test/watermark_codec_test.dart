import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:packing_proof_mobile/models/recording_orientation.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/services/video_watermark_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

// 1 秒 160x120 H.264 基线测试视频（base64 内嵌，避免依赖外部文件）。
const String _inputMp4Base64 =
    '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';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('水印管线按编码设置输出对应格式', (WidgetTester tester) async {
    final Directory root = await getApplicationDocumentsDirectory();
    final File inputA = File(p.join(root.path, 'wm_input_a.mp4'));
    final File inputB = File(p.join(root.path, 'wm_input_b.mp4'));
    await inputA.writeAsBytes(base64Decode(_inputMp4Base64), flush: true);
    await inputB.writeAsBytes(base64Decode(_inputMp4Base64), flush: true);
    addTearDown(() async {
      for (final File file in <File>[inputA, inputB]) {
        if (await file.exists()) await file.delete();
      }
    });

    final VideoWatermarkService service = VideoWatermarkService(
      isAndroid: true,
    );

    final File h264Output = File(
      await service.apply(
        inputPath: inputA.path,
        startedAt: DateTime(2026, 8, 7, 10),
        trackingNumber: 'TEST001',
        videoCodec: RecordingVideoCodec.h264,
      ),
    );
    addTearDown(() async {
      if (await h264Output.exists()) await h264Output.delete();
    });
    expect(await h264Output.exists(), isTrue);
    expect(_videoCodecMarker(h264Output), 'avc1', reason: 'H.264 设置应输出 AVC');

    final File hevcOutput = File(
      await service.apply(
        inputPath: inputB.path,
        startedAt: DateTime(2026, 8, 7, 10),
        trackingNumber: 'TEST001',
        videoCodec: RecordingVideoCodec.hevc,
      ),
    );
    addTearDown(() async {
      if (await hevcOutput.exists()) await hevcOutput.delete();
    });
    expect(await hevcOutput.exists(), isTrue);
    final String hevcMarker = _videoCodecMarker(hevcOutput);
    expect(
      hevcMarker == 'hvc1' || hevcMarker == 'hev1',
      isTrue,
      reason: 'H.265 设置应输出 HEVC，实际 $hevcMarker',
    );
  });

  testWidgets('三方向水印通过真实导出与播放链路', (WidgetTester tester) async {
    if (!Platform.isAndroid) return;
    final Directory root = await getApplicationDocumentsDirectory();
    final VideoWatermarkService service = VideoWatermarkService(
      isAndroid: true,
    );
    final List<File> temporaryFiles = <File>[];
    addTearDown(() async {
      for (final File file in temporaryFiles) {
        if (await file.exists()) await file.delete();
      }
    });

    for (final RecordingOrientation orientation
        in RecordingOrientation.values) {
      final File input = File(
        p.join(root.path, 'wm_orientation_${orientation.storageValue}.mp4'),
      );
      await input.writeAsBytes(base64Decode(_inputMp4Base64), flush: true);
      temporaryFiles.add(input);

      final File output = File(
        await service.applyWithOrientation(
          inputPath: input.path,
          startedAt: DateTime.utc(2026, 8, 21, 9, 30),
          trackingNumber: 'ORIENTATION-${orientation.storageValue}',
          videoCodec: RecordingVideoCodec.h264,
          recordingOrientation: orientation,
        ),
      );
      temporaryFiles.add(output);
      expect(await output.exists(), isTrue);
      expect(await output.length(), greaterThan(0));
      expect(_videoCodecMarker(output), 'avc1');

      final VideoPlayerController player = VideoPlayerController.file(output);
      try {
        await player.initialize();
        expect(player.value.isInitialized, isTrue);
        expect(player.value.hasError, isFalse);
        expect(player.value.duration, greaterThan(Duration.zero));
        expect(player.value.size.width, greaterThan(0));
        expect(player.value.size.height, greaterThan(0));
        await player.play();
        final Stopwatch playbackWait = Stopwatch()..start();
        while (player.value.position <= Duration.zero &&
            playbackWait.elapsed < const Duration(seconds: 3)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(player.value.hasError, isFalse);
        expect(
          player.value.position,
          greaterThan(Duration.zero),
          reason: '${orientation.label}水印视频应能实际开始播放',
        );
      } finally {
        await player.dispose();
      }
    }
  });
}

String _videoCodecMarker(File file) {
  final List<int> bytes = file.readAsBytesSync();
  bool has(String marker) {
    final List<int> needle = marker.codeUnits;
    for (int i = 0; i + needle.length <= bytes.length; i++) {
      bool matched = true;
      for (int j = 0; j < needle.length; j++) {
        if (bytes[i + j] != needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return true;
    }
    return false;
  }

  if (has('avc1') || has('avc3')) return 'avc1';
  if (has('hvc1') || has('hev1')) return 'hvc1';
  return 'unknown';
}
