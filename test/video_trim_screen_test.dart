import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/screens/video_trim_screen.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// 只实现剪辑页用到的播放器平台接口，避免打开平台通道。
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events =
      <int, StreamController<VideoEvent>>{};
  int _nextPlayerId = 0;

  /// 初始化事件上报的视频尺寸，决定 `VideoPlayerValue.aspectRatio`。
  Size videoSize = const Size(1080, 1920);

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final int playerId = _nextPlayerId++;
    final StreamController<VideoEvent> controller =
        StreamController<VideoEvent>();
    _events[playerId] = controller;
    controller.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: videoSize,
        duration: const Duration(seconds: 30),
      ),
    );
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.black);

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
}

RecordingSession _session() {
  final DateTime startedAt = DateTime(2026, 9, 13, 10);
  return RecordingSession(
    id: 'session-1',
    filePath: 'C:/recordings/session-1.mp4',
    startedAt: startedAt,
    endedAt: startedAt.add(const Duration(seconds: 30)),
    markers: const <BarcodeMarker>[],
  );
}

void main() {
  late _FakeVideoPlayerPlatform videoPlatform;

  setUp(() {
    videoPlatform = _FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = videoPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => Directory.systemTemp.path,
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
    });
  });

  Future<void> pumpTrim(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: VideoTrimScreen(session: _session())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('竖版预览不拉伸，剪辑控件留在可见区域', (WidgetTester tester) async {
    videoPlatform.videoSize = const Size(1080, 1920);
    await pumpTrim(tester);

    // 预览按视频宽高比等比缩放：9:16，宽高比必须保持在 0.5625。
    final Rect preview = tester.getRect(find.byType(AspectRatio).first);
    expect(preview.width / preview.height, closeTo(9 / 16, 0.01));
    // 高度受限后控件仍在屏幕内。
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(preview.height, lessThanOrEqualTo(screen.height * 0.46 + 0.5));
    expect(find.byKey(const Key('trim-range')), findsOneWidget);
  });

  testWidgets('横版预览同样等比缩放', (WidgetTester tester) async {
    videoPlatform.videoSize = const Size(1920, 1080);
    await pumpTrim(tester);

    final Rect preview = tester.getRect(find.byType(AspectRatio).first);
    expect(preview.width / preview.height, closeTo(16 / 9, 0.01));
  });
}
