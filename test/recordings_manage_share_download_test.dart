import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/models/work_mode.dart';
import 'package:packing_proof_mobile/screens/recordings_screen.dart';
import 'package:packing_proof_mobile/services/remote_video_clip_service.dart';
import 'package:packing_proof_mobile/services/share_file_naming.dart';
import 'package:path/path.dart' as p;

class _FakeRemoteClipSink implements RemoteVideoClipSink {
  _FakeRemoteClipSink(this.file);

  final File file;
  final List<Uri> downloadedUris = <Uri>[];

  @override
  Map<String, String> get headers => const <String, String>{};

  @override
  Future<File> download(
    Uri uri, {
    void Function(double progress)? onProgress,
  }) async {
    downloadedUris.add(uri);
    onProgress?.call(1);
    return file;
  }

  @override
  Future<List<RemoteClipFrame>> loadTimeline(
    int videoId, {
    int frameCount = 10,
  }) async => const <RemoteClipFrame>[];

  @override
  Future<String> start(
    int videoId,
    double startSeconds,
    double endSeconds,
  ) async => '';

  @override
  Future<Map<String, Object?>> task(String taskId) async =>
      const <String, Object?>{};

  @override
  Future<void> cancel(String taskId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('管理页分享会把电脑上的录像先下载到本机', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    final RemoteRecording remote = RemoteRecording(
      id: 11,
      trackingNumber: 'REMOTE-1',
      startedAt: startedAt,
      duration: const Duration(seconds: 5),
      sourceType: 'pc',
      sourceDeviceId: 'computer-1',
      sourceDeviceName: '电脑',
      sourceSessionId: '',
      contentSha256: 'sha',
      playUri: Uri.parse('http://192.168.1.20/video/11'),
    );
    final RecordingSession remoteSession = RecordingSession(
      id: 'remote-11',
      filePath: '',
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 5)),
      markers: <BarcodeMarker>[
        BarcodeMarker(
          code: 'REMOTE-1',
          occurredAt: startedAt,
          offset: Duration.zero,
        ),
      ],
    );
    final Directory directory = Directory.systemTemp.createTempSync(
      'pp_manage_share',
    );
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    // 下载结果直接沿用分享文件名，避免准备阶段再复制一次
    //（widget 测试环境没有 path_provider 插件）。
    final File downloaded = File(
      p.join(directory.path, shareFileName(remoteSession)),
    )..writeAsBytesSync(<int>[0, 1, 2, 3]);
    final _FakeRemoteClipSink sink = _FakeRemoteClipSink(downloaded);
    Uri? resolvedRequest;

    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const <RecordingSession>[],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: LanBackupSnapshot(
            endpoint: LanBackupEndpoint(
              baseUri: Uri.parse('http://192.168.1.20:5280'),
              accessKey: '',
              computerId: 'computer-1',
              computerName: '电脑',
            ),
            connectionStatus: LanConnectionStatus.connected,
            deviceId: 'phone-device',
            deviceName: '安卓1',
          ),
          onLoadRemoteRecordings:
              ({
                required page,
                required pageSize,
                keyword = '',
                operationMode,
              }) async => RemoteRecordingPage(
                data: page == 1
                    ? <RemoteRecording>[remote]
                    : const <RemoteRecording>[],
                page: page,
                pageSize: pageSize,
                total: 1,
                deviceTotal: 0,
              ),
          onResolveRemoteUri: (Uri remoteUri) async {
            resolvedRequest = remoteUri;
            return remoteUri;
          },
          remoteClipServiceFactory: (Uri remoteUri) => sink,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-recordings-button')));
    await tester.pump();
    await tester.tap(find.text('REMOTE-1'));
    await tester.pump();

    await tester.tap(find.byKey(const Key('share-selected-recordings')));
    await tester.pumpAndSettle();
    expect(find.text('分享给其他应用'), findsOneWidget);
    await tester.tap(find.text('分享给其他应用'));
    // 系统分享面板在测试环境不会返回结果，按钮上的进度圈会一直转，
    // 这里只按有限帧推进，等下载与文件名准备完成后就断言。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(resolvedRequest, remote.playUri);
    expect(sink.downloadedUris, <Uri>[remote.playUri]);
    expect(tester.takeException(), isNull);
  });
}
