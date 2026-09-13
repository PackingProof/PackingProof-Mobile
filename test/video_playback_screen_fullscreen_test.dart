import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/recording_orientation.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/screens/video_playback_screen.dart';
import 'package:packing_proof_mobile/services/playback_display_mode_controller.dart';
import 'package:video_player/video_player.dart' show VideoPlayer;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// 记录页面下发的方向，替代真实 `SystemChrome`。
class _FakePlaybackDisplayPlatform implements PlaybackDisplayPlatform {
  final List<List<DeviceOrientation>> applied = <List<DeviceOrientation>>[];

  List<DeviceOrientation> get last => applied.last;

  @override
  Future<void> setPreferredOrientations(
    List<DeviceOrientation> orientations,
  ) async {
    applied.add(List<DeviceOrientation>.of(orientations));
  }
}

/// 只实现当前页面用到的播放器平台接口，避免打开平台通道。
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
  Future<void> dispose(int playerId) async {}

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

RecordingSession _session({
  RecordingOrientation orientation = RecordingOrientation.portrait,
}) {
  final DateTime startedAt = DateTime(2026, 9, 13, 10);
  return RecordingSession(
    id: 'session-1',
    filePath: 'C:/recordings/session-1.mp4',
    startedAt: startedAt,
    endedAt: startedAt.add(const Duration(seconds: 30)),
    markers: const <BarcodeMarker>[],
    recordingOrientation: orientation,
  );
}

void main() {
  late _FakeVideoPlayerPlatform videoPlatform;
  late _FakePlaybackDisplayPlatform displayPlatform;

  setUp(() {
    videoPlatform = _FakeVideoPlayerPlatform();
    displayPlatform = _FakePlaybackDisplayPlatform();
    VideoPlayerPlatform.instance = videoPlatform;
    // 播放诊断日志会写应用文档目录；测试里把根目录指向临时目录。
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

  Future<void> pumpPlayer(
    WidgetTester tester, {
    RecordingOrientation orientation = RecordingOrientation.portrait,
  }) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlaybackScreen(
          session: _session(orientation: orientation),
          onSessionUpdated: (_) async {},
          playbackDisplayPlatform: displayPlatform,
        ),
      ),
    );
    // 初始化播放器并等待首个事件与后续 seek/play 完成。
    await tester.pumpAndSettle();
  }

  /// 直接触发按钮回调：点按会弹出 tooltip 浮层，浮层里还有一份按钮副本，
  /// 按 key 查找与命中测试会同时命中两份控件。
  Future<void> pressFullscreenToggle(WidgetTester tester) async {
    tester
        .widget<IconButton>(find.byKey(const Key('playback-fullscreen-toggle')))
        .onPressed!();
    await tester.pumpAndSettle();
  }

  testWidgets('窗口布局显示全屏按钮并可进入全屏', (WidgetTester tester) async {
    await pumpPlayer(tester);

    final Finder toggle = find.byKey(const Key('playback-fullscreen-toggle'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<IconButton>(toggle).tooltip, '全屏');
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);

    await pressFullscreenToggle(tester);

    // 全屏态只保留一份控件，不能出现窗口态残留的第二份按钮。
    expect(toggle, findsOneWidget);
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(tester.widget<IconButton>(toggle).tooltip, '退出全屏');
    expect(displayPlatform.last, <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_rounded), findsNothing);
  });

  testWidgets('横版录像全屏请求横屏方向', (WidgetTester tester) async {
    videoPlatform.videoSize = const Size(1920, 1080);
    await pumpPlayer(tester, orientation: RecordingOrientation.landscapeLeft);

    await pressFullscreenToggle(tester);

    expect(displayPlatform.last, <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  });

  testWidgets('全屏中系统返回键只退出全屏', (WidgetTester tester) async {
    videoPlatform.videoSize = const Size(1920, 1080);
    await pumpPlayer(tester, orientation: RecordingOrientation.landscapeLeft);

    await pressFullscreenToggle(tester);
    expect(find.byType(AppBar), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsOneWidget);
    expect(displayPlatform.last, <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('playback-fullscreen-toggle')),
          )
          .tooltip,
      '全屏',
    );
    // 页面没有被关闭，仍停留在播放页。
    expect(find.text('分享'), findsOneWidget);
  });

  testWidgets('退出全屏按钮恢复竖屏并保持播放页', (WidgetTester tester) async {
    await pumpPlayer(tester);

    await pressFullscreenToggle(tester);
    await pressFullscreenToggle(tester);

    expect(displayPlatform.applied, <List<DeviceOrientation>>[
      <DeviceOrientation>[DeviceOrientation.portraitUp],
      <DeviceOrientation>[DeviceOrientation.portraitUp],
    ]);
    expect(find.byType(AppBar), findsOneWidget);
    expect(
      tester.widget<IconButton>(
        find.byKey(const Key('playback-fullscreen-toggle')),
      ).tooltip,
      '全屏',
    );
  });

  testWidgets('页面销毁时恢复竖屏', (WidgetTester tester) async {
    videoPlatform.videoSize = const Size(1920, 1080);
    await pumpPlayer(tester, orientation: RecordingOrientation.landscapeLeft);

    await pressFullscreenToggle(tester);
    expect(displayPlatform.last, <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    expect(displayPlatform.last, <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
  });
}
