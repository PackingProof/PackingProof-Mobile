import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/video_share_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(
    'app.packingproof.mobile/video_export_test',
  );
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('packing-proof-share-');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('完整范围直接复用原视频', () async {
    final File source = File('${root.path}${Platform.pathSeparator}source.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final VideoShareService service = VideoShareService(
      channel: channel,
      cacheDirectory: Directory('${root.path}${Platform.pathSeparator}cache'),
      nativeExportSupported: true,
    );

    final File result = await service.prepare(
      sourcePath: source.path,
      mediaStart: Duration.zero,
      mediaEnd: const Duration(seconds: 30),
      sourceDuration: const Duration(seconds: 30),
    );

    expect(result.path, source.path);
  });

  test('相同剪辑范围复用生成缓存', () async {
    final File source = File('${root.path}${Platform.pathSeparator}source.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    int exportCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'progress') return 50;
          exportCalls++;
          final Map<Object?, Object?> arguments =
              call.arguments as Map<Object?, Object?>;
          final File output = File(arguments['outputPath']! as String);
          await output.writeAsBytes(<int>[4, 5, 6]);
          return output.path;
        });
    final VideoShareService service = VideoShareService(
      channel: channel,
      cacheDirectory: Directory('${root.path}${Platform.pathSeparator}cache'),
      nativeExportSupported: true,
    );

    final File first = await service.prepare(
      sourcePath: source.path,
      mediaStart: const Duration(seconds: 2),
      mediaEnd: const Duration(seconds: 8),
      sourceDuration: const Duration(seconds: 10),
    );
    final File second = await service.prepare(
      sourcePath: source.path,
      mediaStart: const Duration(seconds: 2),
      mediaEnd: const Duration(seconds: 8),
      sourceDuration: const Duration(seconds: 10),
    );

    expect(first.path, second.path);
    expect(exportCalls, 1);
  });

  test('平台不支持视频导出时拒绝剪辑范围', () async {
    final File source = File('${root.path}${Platform.pathSeparator}source.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final VideoShareService service = VideoShareService(
      channel: channel,
      cacheDirectory: Directory('${root.path}${Platform.pathSeparator}cache'),
      nativeExportSupported: false,
    );

    await expectLater(
      service.prepare(
        sourcePath: source.path,
        mediaStart: const Duration(seconds: 2),
        mediaEnd: const Duration(seconds: 8),
        sourceDuration: const Duration(seconds: 10),
      ),
      throwsUnsupportedError,
    );
  });
}
