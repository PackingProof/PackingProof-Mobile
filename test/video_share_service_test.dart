import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/platform/contracts/media_platform.dart';
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
      remuxFullRangeHevc: false,
    );

    final File result = await service.prepare(
      sourcePath: source.path,
      mediaStart: Duration.zero,
      mediaEnd: const Duration(seconds: 30),
      sourceDuration: const Duration(seconds: 30),
    );

    expect(result.path, source.path);
  });

  test('iOS 完整 HEVC 分享生成无损重封装副本', () async {
    final File source = File('${root.path}${Platform.pathSeparator}source.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    int exportCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'progress') return 50;
          exportCalls++;
          final Map<Object?, Object?> arguments =
              call.arguments as Map<Object?, Object?>;
          expect(arguments['startMs'], 0);
          expect(arguments['endMs'], 30000);
          expect(arguments['passthrough'], isTrue);
          final File output = File(arguments['outputPath']! as String);
          await output.writeAsBytes(<int>[4, 5, 6]);
          return output.path;
        });
    final VideoShareService service = VideoShareService(
      channel: channel,
      cacheDirectory: Directory('${root.path}${Platform.pathSeparator}cache'),
      nativeExportSupported: true,
      remuxFullRangeHevc: true,
      systemMediaPresenter: const _FakeSystemMediaPresenter('video/hevc'),
    );

    final File result = await service.prepare(
      sourcePath: source.path,
      mediaStart: Duration.zero,
      mediaEnd: const Duration(seconds: 30),
      sourceDuration: const Duration(seconds: 30),
    );

    expect(result.path, isNot(source.path));
    expect(await result.readAsBytes(), <int>[4, 5, 6]);
    expect(exportCalls, 1);
  });

  test('iOS 完整 H.264 分享直接复用原视频', () async {
    final File source = File('${root.path}${Platform.pathSeparator}source.mp4');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final VideoShareService service = VideoShareService(
      channel: channel,
      cacheDirectory: Directory('${root.path}${Platform.pathSeparator}cache'),
      nativeExportSupported: true,
      remuxFullRangeHevc: true,
      systemMediaPresenter: const _FakeSystemMediaPresenter('video/avc'),
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
          expect(arguments['passthrough'], isFalse);
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

  test('分享副本使用可读文件名并保留视频内容', () async {
    final File source = File(
      '${root.path}${Platform.pathSeparator}remux_hash.mp4',
    );
    await source.writeAsBytes(<int>[7, 8, 9]);
    final VideoShareService service = VideoShareService(
      cacheDirectory: Directory('${root.path}${Platform.pathSeparator}cache'),
      nativeExportSupported: false,
    );

    final File result = await service.prepareForSharing(
      source,
      fileName: 'JT1234567890_20260901_010918_发货.mp4',
    );

    expect(result.path, endsWith('JT1234567890_20260901_010918_发货.mp4'));
    expect(await result.readAsBytes(), <int>[7, 8, 9]);
  });
}

class _FakeSystemMediaPresenter implements SystemMediaPresenter {
  const _FakeSystemMediaPresenter(this.mime);

  final String? mime;

  @override
  Future<String?> getVideoTrackMime(String path) async => mime;

  @override
  Future<SystemVideoDecodeSupport?> getVideoDecodeSupport() async => null;

  @override
  Future<void> openWithSystemPlayer(String path) async {}
}
