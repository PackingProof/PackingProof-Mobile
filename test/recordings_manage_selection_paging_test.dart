import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/models/work_mode.dart';
import 'package:packing_proof_mobile/screens/recordings_screen.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';

List<String> _visibleCodes(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((Text text) => text.data ?? '')
    .where((String value) => RegExp(r'^NO-\d+$').hasMatch(value))
    .toList(growable: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('本机与电脑录像混合时跨页全选来回翻页不串页', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    final List<RecordingSession> all = List<RecordingSession>.generate(
      60,
      (int index) {
        final DateTime start = startedAt.subtract(Duration(minutes: index));
        return RecordingSession(
          id: 'clip-$index',
          filePath: 'pubspec.yaml',
          startedAt: start,
          endedAt: start.add(const Duration(seconds: 8)),
          markers: <BarcodeMarker>[
            BarcodeMarker(
              code: 'NO-${index + 1}',
              occurredAt: start,
              offset: Duration.zero,
            ),
          ],
        );
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: all,
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onLoadLocalRecordings:
              ({
                required page,
                required pageSize,
                keyword = '',
                operationMode,
                DateTime? start,
                DateTime? end,
              }) async {
                final int offset = (page - 1) * pageSize;
                return LocalRecordingPage(
                  data: offset >= all.length
                      ? const <RecordingSession>[]
                      : all.skip(offset).take(pageSize).toList(growable: false),
                  page: page,
                  pageSize: pageSize,
                  total: all.length,
                );
              },
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
              ({required page, required pageSize, keyword = '', operationMode}) async {
                final int offset = (page - 1) * pageSize;
                final List<RemoteRecording> remote = List<RemoteRecording>.generate(
                  30,
                  (int index) {
                    final DateTime start = startedAt.subtract(
                      Duration(minutes: index * 2, seconds: 30),
                    );
                    return RemoteRecording(
                      id: 100 + index,
                      trackingNumber: 'PC-${index + 1}',
                      startedAt: start,
                      duration: const Duration(seconds: 8),
                      sourceType: 'pc',
                      sourceDeviceId: 'computer-1',
                      sourceDeviceName: '电脑',
                      sourceSessionId: '',
                      contentSha256: 'sha-$index',
                      playUri: Uri.parse(
                        'http://192.168.1.20:5280/video/${100 + index}',
                      ),
                    );
                  },
                );
                return RemoteRecordingPage(
                  data: offset >= remote.length
                      ? const <RemoteRecording>[]
                      : remote.skip(offset).take(pageSize).toList(growable: false),
                  page: page,
                  pageSize: pageSize,
                  total: remote.length,
                  deviceTotal: 0,
                );
              },
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

    Future<void> tapPager(Key key) async {
      await tester.ensureVisible(find.byKey(key));
      await tester.pump();
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    Future<void> selectAll() async {
      await tester.tap(find.text('全选本页'));
      await tester.pump();
    }

    await selectAll();
    await tapPager(const Key('recording-page-next'));
    await selectAll();
    await tapPager(const Key('recording-page-next'));
    await selectAll();
    await tapPager(const Key('recording-page-next'));
    await selectAll();
    final List<String> page4Codes = _visibleCodes(tester);
    expect(find.text('取消全选'), findsOneWidget, reason: '第 4 页应处于全选状态');

    await tapPager(const Key('recording-page-next'));
    await tapPager(const Key('recording-page-next'));
    await tapPager(const Key('recording-page-previous'));
    await tapPager(const Key('recording-page-previous'));
    final List<String> backCodes = _visibleCodes(tester);

    expect(backCodes, page4Codes, reason: '回到第 4 页应显示同一批录像');
    expect(
      find.text('取消全选'),
      findsOneWidget,
      reason: '第 4 页应保持全选状态',
    );
  });
}
