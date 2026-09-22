import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';
import 'package:packing_proof_mobile/models/order_info.dart';
import 'package:packing_proof_mobile/models/recording_orientation.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/screens/video_playback_screen.dart';
import 'package:packing_proof_mobile/services/playback_display_mode_controller.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// 记录页面下发的方向，替代真实 `SystemChrome`。
class _FakePlaybackDisplayPlatform implements PlaybackDisplayPlatform {
  final List<List<DeviceOrientation>> applied = <List<DeviceOrientation>>[];

  List<DeviceOrientation> get last => applied.last;

  @override
  Future<void> setPreferredOrientations(List<DeviceOrientation> orientations) {
    // 同步记录，避免页面销毁时调用方来不及 await。
    applied.add(List<DeviceOrientation>.of(orientations));
    return Future<void>.value();
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
  Future<void> dispose(int playerId) async {
    // 真实插件在释放时会关闭事件流；不关闭会让 controller.dispose() 卡在
    // 取消订阅上，播放页也就关不掉。
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

RecordingSession _session({
  RecordingOrientation orientation = RecordingOrientation.portrait,
  OrderInfo? orderInfo,
  List<BarcodeMarker> markers = const <BarcodeMarker>[],
}) {
  final DateTime startedAt = DateTime(2026, 9, 13, 10);
  return RecordingSession(
    id: 'session-1',
    filePath: 'C:/recordings/session-1.mp4',
    startedAt: startedAt,
    endedAt: startedAt.add(const Duration(seconds: 9)),
    markers: markers,
    recordingOrientation: orientation,
    orderInfo: orderInfo,
  );
}

const OrderInfo _orderInfo = OrderInfo(
  trackingNumber: 'JD0001',
  orderId: 'ORDER-1',
  buyerMessage: '请放门口',
);

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

  /// 把播放页作为真实路由推入，确保关闭播放页的返回行为与线上一致。
  Future<void> pumpPlayer(
    WidgetTester tester, {
    RecordingOrientation orientation = RecordingOrientation.portrait,
    bool withOrder = false,
    List<BarcodeMarker> markers = const <BarcodeMarker>[],
    bool backedUp = false,
    bool backupInProgress = false,
    Future<LanBackupManualUploadResult> Function()? onUpload,
    Future<LanBackupPlaybackStatus> Function()? backupStatusLoader,
    Listenable? backupListenable,
  }) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) => VideoPlaybackScreen(
                      session: _session(
                        orientation: orientation,
                        orderInfo: withOrder ? _orderInfo : null,
                        markers: markers,
                      ),
                      onSessionUpdated: (_) async {},
                      backedUp: backedUp,
                      backupInProgress: backupInProgress,
                      onUpload: onUpload,
                      backupStatusLoader: backupStatusLoader,
                      backupListenable: backupListenable,
                      playbackDisplayPlatform: displayPlatform,
                    ),
                  ),
                ),
                child: const Text('打开录像'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开录像'));
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

  testWidgets('播放页展示录像信息与订单信息入口', (WidgetTester tester) async {
    await pumpPlayer(
      tester,
      withOrder: true,
      markers: <BarcodeMarker>[
        BarcodeMarker(
          code: 'JD0001',
          occurredAt: DateTime(2026, 9, 13, 10),
          offset: Duration.zero,
        ),
      ],
    );

    // 竖版视频占位较高，信息卡片需要滚动才会进入可见区域。
    await tester.scrollUntilVisible(
      find.byKey(const Key('playback-order-info')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // 面单号可复制；时间自带「录制」字样，不再写「来源 / 时长」这类标注。
    expect(find.byKey(const Key('playback-copy-code')), findsOneWidget);
    // 标题栏与信息卡片各有一处面单号。
    expect(find.text('JD0001'), findsNWidgets(2));
    expect(find.text('9月13日 10:00 录制'), findsOneWidget);
    // 进度条右侧也显示总时长，因此这里有两处 00:09。
    expect(find.text('00:09'), findsNWidgets(2));
    // 业务类型与分辨率直接标在录像事实里。
    expect(find.text('发货'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('手机'), findsOneWidget);
    expect(find.text('未备份，仅在本机'), findsOneWidget);
    for (final String label in <String>['来源', '录制时间', '时长', '大小', '备份']) {
      expect(find.text(label), findsNothing, reason: '不应出现标注 $label');
    }

    // 有订单信息时展示摘要，并保留查看入口。
    expect(find.byKey(const Key('playback-order-info')), findsOneWidget);
    expect(find.textContaining('买家留言'), findsOneWidget);
    expect(find.text('查看'), findsOneWidget);
  });

  testWidgets('未备份时可点按信息卡片手动上传', (WidgetTester tester) async {
    int uploads = 0;
    await pumpPlayer(
      tester,
      onUpload: () async {
        uploads++;
        return LanBackupManualUploadResult.uploading;
      },
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('playback-backup-upload')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('未备份，仅在本机'), findsOneWidget);
    expect(find.text('点按上传'), findsOneWidget);

    await tester.tap(find.byKey(const Key('playback-backup-upload')));
    await tester.pumpAndSettle();

    expect(uploads, 1);
    // 上传中卡片自己会显示「正在上传到电脑」+进度条，不再重复弹提示。
    expect(find.text('已开始上传到电脑'), findsNothing);
  });

  testWidgets('点按上传后卡片保持上传中并显示进度条', (WidgetTester tester) async {
    final ValueNotifier<int> backupChanges = ValueNotifier<int>(0);
    addTearDown(backupChanges.dispose);
    LanBackupJob job = LanBackupJob(
      id: 'job-progress',
      filePath: 'C:/recordings/session-1.mp4',
      state: LanBackupJobState.pending,
      uploadedBytes: 0,
      totalBytes: 1000,
    );
    await pumpPlayer(
      tester,
      backupListenable: backupChanges,
      backupStatusLoader: () async => LanBackupPlaybackStatus(
        backedUp: job.state == LanBackupJobState.completed,
        job: job,
      ),
      onUpload: () async {
        // 手动上传开始后，任务立刻进入上传中并带出进度。
        job = LanBackupJob(
          id: 'job-progress',
          filePath: 'C:/recordings/session-1.mp4',
          state: LanBackupJobState.uploading,
          uploadedBytes: 420,
          totalBytes: 1000,
        );
        backupChanges.value++;
        return LanBackupManualUploadResult.uploading;
      },
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('playback-backup-upload')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('未备份，仅在本机'), findsOneWidget);

    await tester.tap(find.byKey(const Key('playback-backup-upload')));
    await tester.pumpAndSettle();

    // 不能退回「未备份」：保持上传中并显示进度条与百分比。
    expect(find.text('正在上传到电脑'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.byKey(const Key('playback-backup-progress')), findsOneWidget);
    expect(find.text('未备份，仅在本机'), findsNothing);
  });

  testWidgets('上传过程中从滚动进度条切换成真实进度', (WidgetTester tester) async {
    final ValueNotifier<int> backupChanges = ValueNotifier<int>(0);
    addTearDown(backupChanges.dispose);
    LanBackupJob? job;
    await pumpPlayer(
      tester,
      backupListenable: backupChanges,
      backupStatusLoader: () async => LanBackupPlaybackStatus(
        backedUp: job?.state == LanBackupJobState.completed,
        job: job,
      ),
      onUpload: () async {
        job = LanBackupJob(
          id: 'job-rolling',
          filePath: 'C:/recordings/session-1.mp4',
          state: LanBackupJobState.pending,
          uploadedBytes: 0,
          totalBytes: 0,
        );
        backupChanges.value++;
        return LanBackupManualUploadResult.uploading;
      },
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('playback-backup-upload')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playback-backup-upload')));
    await tester.pump();

    LinearProgressIndicator bar() => tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('playback-backup-progress')),
    );

    // 还不知道总大小：滚动进度条。
    expect(bar().value, isNull);

    // 拿到真实进度后立刻切成百分比进度条。
    job = LanBackupJob(
      id: 'job-rolling',
      filePath: 'C:/recordings/session-1.mp4',
      state: LanBackupJobState.uploading,
      uploadedBytes: 300,
      totalBytes: 1000,
    );
    backupChanges.value++;
    await tester.pump();
    await tester.pump();
    expect(bar().value, closeTo(0.3, 0.001));
    expect(find.text('30%'), findsOneWidget);

    job = LanBackupJob(
      id: 'job-rolling',
      filePath: 'C:/recordings/session-1.mp4',
      state: LanBackupJobState.uploading,
      uploadedBytes: 850,
      totalBytes: 1000,
      revision: 1,
    );
    backupChanges.value++;
    await tester.pump();
    await tester.pump();
    expect(bar().value, closeTo(0.85, 0.001));
    expect(find.text('85%'), findsOneWidget);
    expect(find.text('未备份，仅在本机'), findsNothing);
  });

  testWidgets('主机不在线时手动上传提示先连主机', (WidgetTester tester) async {
    await pumpPlayer(
      tester,
      onUpload: () async => LanBackupManualUploadResult.hostOffline,
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('playback-backup-upload')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playback-backup-upload')));
    await tester.pumpAndSettle();

    expect(find.text('主机不在线，请连接主机后重试'), findsOneWidget);
  });

  testWidgets('已备份或正在上传时不给手动上传入口', (WidgetTester tester) async {
    await pumpPlayer(
      tester,
      backedUp: true,
      onUpload: () async => LanBackupManualUploadResult.uploading,
    );
    await tester.scrollUntilVisible(
      find.text('已备份到电脑'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('点按上传'), findsNothing);
    expect(find.byKey(const Key('playback-backup-upload')), findsNothing);
  });

  testWidgets('正在上传时信息卡片显示进度条且不给上传入口', (WidgetTester tester) async {
    await pumpPlayer(
      tester,
      backupStatusLoader: () async => const LanBackupPlaybackStatus(
        backedUp: false,
        job: LanBackupJob(
          id: 'job-uploading',
          filePath: 'C:/recordings/session-1.mp4',
          state: LanBackupJobState.uploading,
          uploadedBytes: 420,
          totalBytes: 1000,
        ),
      ),
      onUpload: () async => LanBackupManualUploadResult.alreadyUploading,
    );
    await tester.scrollUntilVisible(
      find.text('正在上传到电脑'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('正在上传到电脑'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.byKey(const Key('playback-backup-progress')), findsOneWidget);
    expect(find.text('点按上传'), findsNothing);
  });

  testWidgets('电脑端记录不可用时可以重新上传，上传中与完成后都不回到未备份', (WidgetTester tester) async {
    final Completer<LanBackupManualUploadResult> upload =
        Completer<LanBackupManualUploadResult>();
    final ValueNotifier<int> backupChanges = ValueNotifier<int>(0);
    addTearDown(backupChanges.dispose);
    // 这台电脑上以前传过，但电脑端录像记录已经不可用：列表和播放页都要当成未备份。
    LanBackupJob job = LanBackupJob(
      id: 'job-fast',
      filePath: 'C:/recordings/session-1.mp4',
      state: LanBackupJobState.completed,
      uploadedBytes: 1000,
      totalBytes: 1000,
      remoteRecordId: 7,
    );
    bool remoteAvailable = false;
    await pumpPlayer(
      tester,
      backupListenable: backupChanges,
      backupStatusLoader: () async =>
          LanBackupPlaybackStatus(backedUp: remoteAvailable, job: job),
      onUpload: () => upload.future,
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('playback-backup-upload')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('未备份，仅在本机'), findsOneWidget);
    expect(find.text('点按上传'), findsOneWidget);

    await tester.tap(find.byKey(const Key('playback-backup-upload')));
    // 请求还没回来：进度未知，用滚动进度条占位，不能回到「未备份」。
    await tester.pump();
    expect(find.text('正在上传到电脑'), findsOneWidget);
    expect(find.byKey(const Key('playback-backup-progress')), findsOneWidget);
    expect(find.text('未备份，仅在本机'), findsNothing);

    // 重新上传完成：电脑端记录恢复可用，卡片直接切到「已备份到电脑」。
    job = LanBackupJob(
      id: 'job-fast',
      filePath: 'C:/recordings/session-1.mp4',
      state: LanBackupJobState.completed,
      uploadedBytes: 1000,
      totalBytes: 1000,
      remoteRecordId: 8,
    );
    remoteAvailable = true;
    backupChanges.value++;
    upload.complete(LanBackupManualUploadResult.uploading);
    await tester.pump();
    await tester.pump();

    expect(find.text('已备份到电脑'), findsOneWidget);
    expect(find.text('未备份，仅在本机'), findsNothing);
  });

  testWidgets('点按后读到点按前的旧任务状态也不会闪回未备份', (WidgetTester tester) async {
    final ValueNotifier<int> backupChanges = ValueNotifier<int>(0);
    addTearDown(backupChanges.dispose);
    // 自动备份关着：任务是暂停态，revision 停在 5。
    LanBackupJob job = LanBackupJob(
      id: 'job-paused',
      filePath: 'C:/recordings/session-1.mp4',
      state: LanBackupJobState.paused,
      uploadedBytes: 0,
      totalBytes: 1000,
      revision: 5,
    );
    await pumpPlayer(
      tester,
      backupListenable: backupChanges,
      backupStatusLoader: () async => LanBackupPlaybackStatus(
        backedUp: job.state == LanBackupJobState.completed,
        job: job,
      ),
      onUpload: () async => LanBackupManualUploadResult.uploading,
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('playback-backup-upload')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playback-backup-upload')));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在上传到电脑'), findsOneWidget);

    // 原生重新排队还没落状态，卡片又读到同一条暂停任务（revision 未变）：
    // 这不能当成"上传结束"，否则会闪回未备份。
    backupChanges.value++;
    await tester.pump();
    await tester.pump();
    expect(find.text('未备份，仅在本机'), findsNothing);
    expect(find.text('正在上传到电脑'), findsOneWidget);

    // 真正开始上传：revision 前进，显示真实进度。
    job = LanBackupJob(
      id: 'job-paused',
      filePath: 'C:/recordings/session-1.mp4',
      state: LanBackupJobState.uploading,
      uploadedBytes: 250,
      totalBytes: 1000,
      revision: 6,
    );
    backupChanges.value++;
    await tester.pump();
    await tester.pump();
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('未备份，仅在本机'), findsNothing);

    // 上传失败（revision 前进后停在暂停）：这时才回到未备份并给重试入口。
    job = LanBackupJob(
      id: 'job-paused',
      filePath: 'C:/recordings/session-1.mp4',
      state: LanBackupJobState.paused,
      uploadedBytes: 250,
      totalBytes: 1000,
      failureKind: LanBackupFailureKind.offlineOrTimeout,
      revision: 7,
    );
    backupChanges.value++;
    await tester.pump();
    await tester.pump();
    expect(find.text('未备份，仅在本机'), findsOneWidget);
    expect(find.text('点按上传'), findsOneWidget);
  });

  testWidgets('窗口布局显示全屏按钮并可进入全屏', (WidgetTester tester) async {
    await pumpPlayer(tester);

    final Finder toggle = find.byKey(const Key('playback-fullscreen-toggle'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<IconButton>(toggle).tooltip, '全屏');
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
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

  testWidgets('全屏按钮位于进度条右侧，且全屏态不引入多余按钮', (WidgetTester tester) async {
    await pumpPlayer(tester);

    final Finder toggle = find.byKey(const Key('playback-fullscreen-toggle'));
    final Rect toggleRect = tester.getRect(toggle);
    // 按钮与进度条同一行，且落在进度条右端。
    final Rect sliderRect = tester.getRect(find.byType(Slider));
    expect(toggleRect.center.dy, closeTo(sliderRect.center.dy, 1));
    expect(toggleRect.left, greaterThanOrEqualTo(sliderRect.right - 1));

    await pressFullscreenToggle(tester);

    // 全屏只保留退出全屏这一个按钮，不再叠加返回按钮。
    expect(toggle, findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
    expect(find.byKey(const Key('playback-fullscreen-back')), findsNothing);
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
  });

  testWidgets('窗口态系统返回键关闭播放页', (WidgetTester tester) async {
    await pumpPlayer(tester);

    expect(find.byType(AppBar), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // 窗口态返回应当真正退出播放页，而不是被拦住。
    expect(find.byType(VideoPlaybackScreen), findsNothing);
  });

  testWidgets('窗口态 AppBar 返回按钮关闭播放页', (WidgetTester tester) async {
    await pumpPlayer(tester);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(VideoPlaybackScreen), findsNothing);
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

  testWidgets('全屏中系统返回键直接关闭播放页并恢复竖屏', (WidgetTester tester) async {
    videoPlatform.videoSize = const Size(1920, 1080);
    await pumpPlayer(tester, orientation: RecordingOrientation.landscapeLeft);

    await pressFullscreenToggle(tester);
    expect(find.byType(AppBar), findsNothing);
    expect(displayPlatform.last, <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // 返回键一定能离开播放页，不会卡在全屏里。
    expect(find.byType(VideoPlaybackScreen), findsNothing);
    expect(displayPlatform.last, <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
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
      tester
          .widget<IconButton>(
            find.byKey(const Key('playback-fullscreen-toggle')),
          )
          .tooltip,
      '全屏',
    );
  });

  testWidgets('全屏中关闭播放页会恢复竖屏', (WidgetTester tester) async {
    videoPlatform.videoSize = const Size(1920, 1080);
    await pumpPlayer(tester, orientation: RecordingOrientation.landscapeLeft);

    await pressFullscreenToggle(tester);
    expect(displayPlatform.last, <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // 页面被销毁（返回上一级）时也必须把方向恢复成竖屏。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(VideoPlaybackScreen), findsNothing);
    expect(displayPlatform.last, <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
  });
}
