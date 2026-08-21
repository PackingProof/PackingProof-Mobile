import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/services/video_watermark_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('水印输出发布前始终保留原录像', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_watermark_test',
    );
    addTearDown(() => root.delete(recursive: true));
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/video_watermark_test',
    );
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          final Map<Object?, Object?> arguments =
              call.arguments! as Map<Object?, Object?>;
          final File output = File(arguments['outputPath']! as String);
          await output.writeAsBytes(<int>[9, 8, 7], flush: true);
          return output.path;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final File input = File('${root.path}${Platform.pathSeparator}source.mp4');
    await input.writeAsBytes(<int>[1, 2, 3], flush: true);

    final String outputPath =
        await VideoWatermarkService(channel: channel, isAndroid: true).apply(
          inputPath: input.path,
          startedAt: DateTime(2026, 7, 22, 10),
          trackingNumber: 'DEMO',
          videoCodec: RecordingVideoCodec.h264,
        );

    expect(File(outputPath).existsSync(), isTrue);
    expect(input.existsSync(), isTrue);
    expect(await input.readAsBytes(), <int>[1, 2, 3]);
    expect(calls.single.arguments, containsPair('videoCodec', 'h264'));
  });

  test('水印输出为空文件时拒绝发布并保留原录像', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing_proof_watermark_empty_test',
    );
    addTearDown(() => root.delete(recursive: true));
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/video_watermark_empty_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          final Map<Object?, Object?> arguments =
              call.arguments! as Map<Object?, Object?>;
          final File output = File(arguments['outputPath']! as String);
          await output.create();
          return output.path;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final File input = File('${root.path}${Platform.pathSeparator}source.mp4');
    await input.writeAsBytes(<int>[1, 2, 3], flush: true);

    await expectLater(
      VideoWatermarkService(channel: channel, isIOS: true).apply(
        inputPath: input.path,
        startedAt: DateTime(2026, 8, 21, 10),
        trackingNumber: 'DEMO',
      ),
      throwsStateError,
    );
    expect(await input.readAsBytes(), <int>[1, 2, 3]);
  });
}
