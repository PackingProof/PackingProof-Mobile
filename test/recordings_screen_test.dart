import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/models/recording_operation_mode.dart';
import 'package:packing_proof_mobile/models/recording_spec.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/models/work_mode.dart';
import 'package:packing_proof_mobile/screens/recordings_screen.dart';
import 'package:packing_proof_mobile/services/recording_database.dart';
import 'package:packing_proof_mobile/services/order_info_receiver_service.dart';
import 'package:packing_proof_mobile/services/lan_backup_discovery_service.dart';
import 'package:packing_proof_mobile/services/lan_backup_service.dart';

void main() {
  testWidgets('历史页标题显示当前录像设备名称', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: const LanBackupSnapshot(
            deviceId: 'android-1234567890a1b2c3',
            deviceName: '设备 A1B2C3',
          ),
          orderReceiverSnapshot: const OrderInfoReceiverSnapshot(
            ipAddress: '192.168.1.25',
          ),
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.text('设备 A1B2C3'), findsOneWidget);
    final Text ip = tester.widget<Text>(
      find.byKey(const Key('recordings-history-ip')),
    );
    expect(ip.data, ' · 192.168.1.25');
    expect(ip.style?.fontSize, 12);
    expect(ip.style?.fontWeight, FontWeight.w400);
    expect(find.text('订单历史'), findsNothing);
  });

  test('历史页标题在局域网地址不可用时只显示手机昵称', () {
    expect(recordingsHistoryTitle('手机1', ''), '手机1');
    expect(
      recordingsHistoryTitle('  手机2  ', ' 192.168.1.26 '),
      '手机2 · 192.168.1.26',
    );
  });

  test('未知连接错误不会向用户暴露状态码或异常类型', () {
    final String message = friendlyBackupConnectionError(
      const HttpException('电脑连接失败（426）'),
    );
    expect(message, '暂时无法连接保存主机，请稍后再试');
    expect(message, isNot(contains('426')));
    expect(message, isNot(contains('Exception')));
  });

  testWidgets('历史录像用颜色条和语义区分发货退货', (WidgetTester tester) async {
    final DateTime startedAt = DateTime(2026, 7, 31, 10);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            RecordingSession(
              id: 'return-session',
              filePath: 'return.mp4',
              startedAt: startedAt,
              endedAt: startedAt.add(const Duration(seconds: 8)),
              markers: const <BarcodeMarker>[],
              operationMode: RecordingOperationMode.returnGoods,
            ),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(
      find.byKey(const Key('recording-operation-mode-strip')),
      findsOneWidget,
    );
    final Positioned stripPosition = tester.widget<Positioned>(
      find.byKey(const Key('recording-operation-mode-strip')),
    );
    expect(stripPosition.left, 0);
    expect(stripPosition.right, isNull);
    final Semantics semantics = tester.widget<Semantics>(
      find.descendant(
        of: find.byKey(const Key('recording-operation-mode-strip')),
        matching: find.byType(Semantics),
      ),
    );
    expect(semantics.properties.label, '退货录像');
    final DecoratedBox strip = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const Key('recording-operation-mode-strip')),
        matching: find.byType(DecoratedBox),
      ),
    );
    final BoxDecoration stripDecoration = strip.decoration as BoxDecoration;
    expect(stripDecoration.color, const Color(0xFFFF9800));
    expect(
      stripDecoration.borderRadius,
      const BorderRadius.horizontal(right: Radius.circular(4)),
    );
  });

  testWidgets('设置卡片按工作和语音关系排列', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          mode: RecordingsScreenMode.settings,
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    final double workModeY = tester
        .getTopLeft(find.byKey(const Key('work-mode-settings')))
        .dy;
    final double retentionY = tester.getTopLeft(find.text('录像清理')).dy;
    final double recordAudioY = tester
        .getTopLeft(find.byKey(const Key('record-audio-settings')))
        .dy;
    final double speechY = tester
        .getTopLeft(find.byKey(const Key('speech-prompt-settings')))
        .dy;
    final double maxVolumeY = tester
        .getTopLeft(find.byKey(const Key('max-volume-settings')))
        .dy;
    final double orderSpeechY = tester
        .getTopLeft(find.byKey(const Key('order-speech-settings')))
        .dy;

    expect(workModeY, lessThan(retentionY));
    expect(retentionY, lessThan(speechY));
    expect(retentionY, lessThan(recordAudioY));
    expect(recordAudioY, lessThan(speechY));
    expect(speechY, lessThan(maxVolumeY));
    expect(maxVolumeY, lessThan(orderSpeechY));
    expect(find.textContaining('不会自动删除未备份录像'), findsNothing);
    expect(find.byKey(const Key('retention-info-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('retention-info-button')));
    await tester.pumpAndSettle();

    expect(find.text('录像清理说明'), findsOneWidget);
    expect(find.textContaining('未备份录像超过'), findsOneWidget);
    expect(find.textContaining('最老的'), findsOneWidget);
  });

  testWidgets('面单条码最短长度可调整', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    int? changedLength;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          mode: RecordingsScreenMode.settings,
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          minimumBarcodeLength: 11,
          onMinimumBarcodeLengthChanged: (int value) async {
            changedLength = value;
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

    final Finder workCard = find.byKey(const Key('work-settings-card'));
    expect(
      find.descendant(
        of: workCard,
        matching: find.byKey(const Key('minimum-barcode-length-settings')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: workCard,
        matching: find.byKey(const Key('video-codec-settings')),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('minimum-barcode-length-card')), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const Key('work-mode-settings'))).dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('minimum-barcode-length-settings')),
            )
            .dy,
      ),
    );
    await tester.tap(find.byKey(const Key('minimum-barcode-length-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('12 位').last);
    await tester.pumpAndSettle();

    expect(changedLength, 12);
  });

  testWidgets('订单接收重试按钮仅在未启动时显示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget build({required bool running}) => MaterialApp(
      home: RecordingsScreen(
        mode: RecordingsScreenMode.settings,
        sessions: const [],
        workMode: WorkMode.continuousScan,
        speechEnabled: true,
        maxVolumeEnabled: true,
        orderReceiverSnapshot: OrderInfoReceiverSnapshot(
          running: running,
          url: running ? 'http://192.168.1.10:5280' : '',
        ),
        onRetryOrderReceiver: () async {},
        onWorkModeChanged: (_) async {},
        onSpeechEnabledChanged: (_) async {},
        onMaxVolumeEnabledChanged: (_) async {},
        onSpeechPreview: () async {},
        onSessionUpdated: (_) async {},
        onDeleteSessions: (_) async {},
      ),
    );

    await tester.pumpWidget(build(running: false));
    expect(find.text('重试'), findsOneWidget);

    await tester.pumpWidget(build(running: true));
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('设置按录像、语音、接收分组为独立卡片', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          mode: RecordingsScreenMode.settings,
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    final Finder workCard = find.byKey(const Key('work-settings-card'));
    final Finder recordingCard = find.byKey(
      const Key('recording-settings-card'),
    );
    final Finder voiceCard = find.byKey(const Key('voice-settings-card'));
    expect(workCard, findsOneWidget);
    expect(recordingCard, findsOneWidget);
    expect(voiceCard, findsOneWidget);

    expect(
      find.descendant(
        of: workCard,
        matching: find.byKey(const Key('work-mode-settings')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: workCard, matching: find.text('录像清理')),
      findsNothing,
    );
    expect(
      find.descendant(of: recordingCard, matching: find.text('录像清理')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: recordingCard,
        matching: find.byKey(const Key('video-codec-settings')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: recordingCard,
        matching: find.byKey(const Key('recording-spec-settings')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: recordingCard,
        matching: find.byKey(const Key('record-audio-settings')),
      ),
      findsOneWidget,
    );

    expect(
      find.descendant(
        of: voiceCard,
        matching: find.byKey(const Key('speech-prompt-settings')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: voiceCard,
        matching: find.byKey(const Key('max-volume-settings')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: voiceCard,
        matching: find.byKey(const Key('order-speech-settings')),
      ),
      findsNothing,
    );

    // 订单播报并入订单接收卡片，订单接收与关于保持独立卡片。
    final Finder orderReceiverCard = find.byKey(
      const Key('order-receiver-settings'),
    );
    expect(orderReceiverCard, findsOneWidget);
    expect(
      find.descendant(
        of: orderReceiverCard,
        matching: find.byKey(const Key('order-speech-settings')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: recordingCard,
        matching: find.byKey(const Key('order-receiver-settings')),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: voiceCard,
        matching: find.byKey(const Key('order-receiver-settings')),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('about-settings-open')), findsOneWidget);
    expect(
      find.descendant(
        of: recordingCard,
        matching: find.byKey(const Key('about-settings-open')),
      ),
      findsNothing,
    );
  });

  testWidgets('录像页面可切换工作模式', (WidgetTester tester) async {
    WorkMode selected = WorkMode.continuousScan;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          mode: RecordingsScreenMode.settings,
          sessions: const [],
          workMode: selected,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (WorkMode mode) async {
            selected = mode;
          },
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.byKey(const Key('work-mode-settings')), findsOneWidget);
    expect(find.text('连续扫码'), findsOneWidget);
    expect(find.text('同码停录'), findsOneWidget);

    await tester.tap(find.text('同码停录'));
    await tester.pump();

    expect(selected, WorkMode.sameCodeStop);
    expect(find.textContaining('再次识别当前面单'), findsOneWidget);
  });

  testWidgets('语音设置可关闭并在开启时试听', (WidgetTester tester) async {
    bool enabled = true;
    int previewCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          mode: RecordingsScreenMode.settings,
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: enabled,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (bool value) async {
            enabled = value;
          },
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {
            previewCount++;
          },
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    await tester.dragUntilVisible(
      find.byKey(const Key('speech-prompt-settings')),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('speech-prompt-settings')), findsOneWidget);
    expect(find.text('离线自动使用系统语音'), findsOneWidget);
    await tester.tap(find.text('试听'));
    await tester.pump();
    expect(previewCount, 1);

    await tester.tap(find.byKey(const Key('speech-enabled-switch')));
    await tester.pump();
    expect(enabled, isFalse);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('speech-preview-button')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('最大音量默认开启且可关闭', (WidgetTester tester) async {
    bool enabled = true;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          mode: RecordingsScreenMode.settings,
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: enabled,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (bool value) async {
            enabled = value;
          },
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    await tester.dragUntilVisible(
      find.byKey(const Key('max-volume-enabled-switch')),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('最大音量'), findsOneWidget);
    expect(find.text('工作时自动提高媒体音量'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('max-volume-enabled-switch')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('max-volume-enabled-switch')));
    await tester.pump();
    expect(enabled, isFalse);
  });

  testWidgets('录制声音默认开启且可关闭', (WidgetTester tester) async {
    bool enabled = true;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          mode: RecordingsScreenMode.settings,
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          recordAudioEnabled: enabled,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onRecordAudioEnabledChanged: (bool value) async {
            enabled = value;
          },
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.text('录制声音'), findsOneWidget);
    expect(find.text('关闭后录像不带声音'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('record-audio-enabled-switch')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-audio-enabled-switch')));
    await tester.pump();
    expect(enabled, isFalse);
  });

  testWidgets('切换录像编码会回调并提示已生效', (WidgetTester tester) async {
    RecordingVideoCodec? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          mode: RecordingsScreenMode.settings,
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onPreferredVideoCodecChanged: (RecordingVideoCodec codec) async {
            changed = codec;
          },
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    await tester.dragUntilVisible(
      find.text('H.264 兼容优先'),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('H.264 兼容优先'));
    await tester.pumpAndSettle();

    expect(changed, RecordingVideoCodec.h264);
    expect(find.text('录像编码已切换，新录像将使用所选编码'), findsOneWidget);
  });

  testWidgets('切换录像规格会回调并提示已生效', (WidgetTester tester) async {
    RecordingSpecPreset? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          mode: RecordingsScreenMode.settings,
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onRecordingSpecChanged: (RecordingSpecPreset spec) async {
            changed = spec;
          },
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    await tester.dragUntilVisible(
      find.text('流畅 720p'),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('流畅 720p'));
    await tester.pumpAndSettle();

    expect(changed, RecordingSpecPreset.smooth720p30);
    expect(find.text('录像规格已切换，新录像将使用所选规格'), findsOneWidget);
  });

  testWidgets('电脑备份未连接时提供扫码入口', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    int scanCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.getData') {
            return <String, Object?>{'text': 'SF1234567890'};
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(58),
            ),
          ),
        ),
        home: RecordingsScreen(
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: const LanBackupSnapshot(),
          onScanSearch: () => scanCount++,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.byKey(const Key('computer-backup-settings')), findsOneWidget);
    expect(find.text('电脑备份'), findsOneWidget);
    expect(find.text('扫码连接'), findsOneWidget);
    expect(find.text('重新搜索'), findsOneWidget);
    expect(find.text('全部完成'), findsOneWidget);
    expect(find.text(' · 连接后自动备份'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.byKey(const Key('computer-backup-state-text')), findsOneWidget);
    expect(find.byKey(const Key('computer-backup-state-pill')), findsNothing);
    expect(find.byIcon(Icons.cloud_upload_rounded), findsNothing);
    expect(find.text('总占用'), findsOneWidget);
    expect(find.text('0 MB'), findsOneWidget);
    expect(
      tester.getCenter(find.text('本机今日')).dx,
      lessThan(tester.getCenter(find.text('本机全部')).dx),
    );
    final Text totalSizeText = tester.widget<Text>(find.text('0 MB'));
    final List<InlineSpan> totalSizeParts =
        (totalSizeText.textSpan! as TextSpan).children!;
    expect(
      (totalSizeParts[1] as TextSpan).style!.fontSize,
      lessThan((totalSizeParts[0] as TextSpan).style!.fontSize!),
    );
    expect(tester.getSize(find.text('电脑备份')).height, lessThan(32));
    final Rect connectButtonRect = tester.getRect(
      find.byKey(const Key('connect-computer-button')),
    );
    final Rect backupCountRect = tester.getRect(find.text('全部完成'));
    expect(connectButtonRect.height, greaterThanOrEqualTo(48));
    expect(connectButtonRect.top, greaterThan(backupCountRect.bottom));
    final Rect backupCardRect = tester.getRect(
      find.byKey(const Key('computer-backup-settings')),
    );
    expect(connectButtonRect.left, greaterThan(backupCardRect.left + 16));
    expect(connectButtonRect.right, backupCardRect.right - 14);
    expect(
      tester.widget(find.byKey(const Key('connect-computer-button'))),
      isA<FilledButton>(),
    );
    expect(
      tester
          .widget(find.byKey(const Key('search-backup-host-button')))
          .runtimeType,
      tester
          .widget(find.byKey(const Key('connect-computer-button')))
          .runtimeType,
    );
    expect(
      tester.getSize(find.byKey(const Key('search-backup-host-button'))).height,
      connectButtonRect.height,
    );
    expect(find.byKey(const Key('scan-search-button')), findsOneWidget);
    expect(find.byKey(const Key('paste-search-button')), findsOneWidget);
    expect(find.byKey(const Key('recording-source-filter')), findsOneWidget);

    await tester.tap(find.byKey(const Key('scan-search-button')));
    expect(scanCount, 1);

    await tester.tap(find.byKey(const Key('paste-search-button')));
    await tester.pump();
    expect(find.text('SF1234567890'), findsOneWidget);

    await tester.tap(find.byKey(const Key('recording-source-filter')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('本地'), findsOneWidget);
  });

  testWidgets('电脑备份未连接时同时提供搜索和扫码入口', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onConnectComputer: () {},
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('backup-host-search-progress')), findsNothing);
    expect(find.text('正在搜索'), findsNothing);
    expect(find.text('扫码连接'), findsOneWidget);
    expect(find.text('重新搜索'), findsOneWidget);
  });

  testWidgets('只找到一台主机时自动申请但仍显示电脑允许提示', (WidgetTester tester) async {
    final _FakeBackupHostDiscovery discovery = _FakeBackupHostDiscovery();
    int connectCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const <RecordingSession>[],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupHostDiscovery: discovery,
          onConnectBackupHost: (host, confirmation) async {
            connectCount++;
            expect(host.nodeId, 'host-1');
            expect(confirmation, isNull);
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
    await tester.pump();
    await tester.pumpAndSettle();

    expect(discovery.searchCount, 1);
    expect(connectCount, 1);
    expect(find.textContaining('电脑上点击允许'), findsOneWidget);
  });

  testWidgets('找到多台主机时保留简洁列表并由用户选择连接', (WidgetTester tester) async {
    final _FakeBackupHostDiscovery discovery = _FakeBackupHostDiscovery(
      hosts: const <LanBackupDiscoveredHost>[
        LanBackupDiscoveredHost(
          nodeId: 'host-1',
          name: '电脑1',
          address: '192.168.1.10:5280',
        ),
        LanBackupDiscoveredHost(
          nodeId: 'host-2',
          name: '电脑2',
          address: '192.168.1.20:5280',
        ),
      ],
    );
    String? selectedHost;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const <RecordingSession>[],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: const LanBackupSnapshot(preferredHostId: 'host-1'),
          backupHostDiscovery: discovery,
          onConnectBackupHost: (host, confirmation) async {
            selectedHost = host.nodeId;
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

    expect(selectedHost, isNull);
    expect(find.text('找到的电脑'), findsOneWidget);
    expect(find.text('电脑1'), findsOneWidget);
    expect(find.text('电脑2'), findsOneWidget);
    expect(find.text('连接'), findsNWidgets(2));

    await tester.tap(
      find.byKey(const ValueKey<String>('discovered-backup-host-host-2')),
    );
    await tester.pump();
    expect(selectedHost, 'host-2');
  });

  testWidgets('缓存主机保持显示但未重新发现前不可连接', (WidgetTester tester) async {
    final _FakeBackupHostDiscovery discovery = _FakeBackupHostDiscovery(
      hosts: const <LanBackupDiscoveredHost>[
        LanBackupDiscoveredHost(
          nodeId: 'host-cache',
          name: '电脑1',
          address: '192.168.1.10:5280',
          reachable: false,
        ),
      ],
    );
    int connectCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const <RecordingSession>[],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupHostDiscovery: discovery,
          onConnectBackupHost: (host, confirmation) async => connectCount++,
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

    expect(connectCount, 0);
    expect(find.text('电脑1'), findsOneWidget);
    expect(find.textContaining('上次找到'), findsOneWidget);
    expect(find.text('未在线'), findsOneWidget);
    final InkWell button = tester.widget<InkWell>(
      find.byKey(const ValueKey<String>('discovered-backup-host-host-cache')),
    );
    expect(button.onTap, isNull);
  });

  testWidgets('共享发现服务时隐藏的设置页不会重复申请', (WidgetTester tester) async {
    final _FakeBackupHostDiscovery discovery = _FakeBackupHostDiscovery();
    int connectCount = 0;
    RecordingsScreen buildScreen({
      required RecordingsScreenMode mode,
      required bool active,
    }) => RecordingsScreen(
      mode: mode,
      active: active,
      sessions: const <RecordingSession>[],
      workMode: WorkMode.continuousScan,
      speechEnabled: true,
      maxVolumeEnabled: true,
      backupHostDiscovery: discovery,
      onConnectBackupHost: (host, confirmation) async => connectCount++,
      onWorkModeChanged: (_) async {},
      onSpeechEnabledChanged: (_) async {},
      onMaxVolumeEnabledChanged: (_) async {},
      onSpeechPreview: () async {},
      onSessionUpdated: (_) async {},
      onDeleteSessions: (_) async {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: IndexedStack(
          index: 0,
          children: <Widget>[
            buildScreen(mode: RecordingsScreenMode.history, active: true),
            buildScreen(mode: RecordingsScreenMode.settings, active: false),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(discovery.searchCount, 1);
    expect(connectCount, 1);
  });

  testWidgets('切换到历史页后才启动保存主机搜索', (WidgetTester tester) async {
    final _FakeBackupHostDiscovery discovery = _FakeBackupHostDiscovery();
    late StateSetter setHostState;
    bool active = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setHostState = setState;
            return RecordingsScreen(
              active: active,
              sessions: const <RecordingSession>[],
              workMode: WorkMode.continuousScan,
              speechEnabled: true,
              maxVolumeEnabled: true,
              backupHostDiscovery: discovery,
              onConnectBackupHost: (host, confirmation) async {},
              onWorkModeChanged: (_) async {},
              onSpeechEnabledChanged: (_) async {},
              onMaxVolumeEnabledChanged: (_) async {},
              onSpeechPreview: () async {},
              onSessionUpdated: (_) async {},
              onDeleteSessions: (_) async {},
            );
          },
        ),
      ),
    );
    await tester.pump();
    expect(discovery.searchCount, 0);

    setHostState(() => active = true);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(discovery.searchCount, 1);
  });

  testWidgets('等待电脑允许时显示醒目状态并只允许取消等待', (WidgetTester tester) async {
    int cancelCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const <RecordingSession>[],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: const LanBackupSnapshot(
            connectionStatus: LanConnectionStatus.awaitingApproval,
            message: '已向“仓库电脑”发送连接申请，请在电脑上点击“允许连接”',
          ),
          onCancelBackupPairing: () => cancelCount++,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.byKey(const Key('backup-approval-status')), findsOneWidget);
    expect(find.textContaining('仓库电脑'), findsOneWidget);
    expect(find.text('重新搜索'), findsNothing);
    expect(find.text('扫码连接'), findsNothing);
    await tester.tap(find.byKey(const Key('cancel-backup-approval-button')));
    expect(cancelCount, 1);
  });

  testWidgets('自动申请期间立即显示等待状态并在拒绝后刷新', (WidgetTester tester) async {
    final _FakeBackupHostDiscovery discovery = _FakeBackupHostDiscovery();
    final Completer<void> approval = Completer<void>();
    final ValueNotifier<LanBackupSnapshot> snapshots =
        ValueNotifier<LanBackupSnapshot>(const LanBackupSnapshot());
    addTearDown(snapshots.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const <RecordingSession>[],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupListenable: snapshots,
          backupSnapshotProvider: () => snapshots.value,
          backupHostDiscovery: discovery,
          onConnectBackupHost: (host, confirmation) => approval.future,
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

    expect(find.textContaining('电脑上点击“允许连接”'), findsOneWidget);
    expect(find.text('取消等待'), findsOneWidget);

    snapshots.value = const LanBackupSnapshot(
      connectionStatus: LanConnectionStatus.disconnected,
      message: '尚未连接保存主机',
    );
    await tester.pump();

    expect(find.textContaining('电脑上点击“允许连接”'), findsOneWidget);
    expect(find.text('取消等待'), findsOneWidget);
    expect(find.text('重新搜索'), findsNothing);

    snapshots.value = const LanBackupSnapshot(
      connectionStatus: LanConnectionStatus.approvalDenied,
      message: '电脑端已拒绝本次连接',
    );
    approval.completeError(const LanBackupApprovalDeniedException());
    await tester.pump();
    await tester.pump();

    expect(find.text('电脑端已拒绝本次连接'), findsWidgets);
    expect(find.text('再次申请'), findsOneWidget);
    expect(find.textContaining('403'), findsNothing);
  });

  testWidgets('审批失败后直接提供再次申请且不要求重新搜索', (WidgetTester tester) async {
    final _FakeBackupHostDiscovery discovery = _FakeBackupHostDiscovery();
    int requestCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const <RecordingSession>[],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: const LanBackupSnapshot(
            connectionStatus: LanConnectionStatus.approvalDenied,
            message: '电脑端已拒绝本次连接',
          ),
          backupHostDiscovery: discovery,
          onConnectBackupHost: (host, confirmation) async => requestCount++,
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

    expect(find.text('电脑端已拒绝本次连接'), findsOneWidget);
    expect(find.text('再次申请'), findsOneWidget);
    expect(find.textContaining('403'), findsNothing);
    await tester.tap(find.text('再次申请'));
    await tester.pump();
    expect(requestCount, 2);
  });

  testWidgets('电脑清理本地录像后立即刷新历史统计', (WidgetTester tester) async {
    const MethodChannel thumbnailChannel = MethodChannel(
      'app.packingproof.mobile/recording_thumbnail',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(thumbnailChannel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(thumbnailChannel, null),
    );
    final Directory directory = Directory.systemTemp.createTempSync(
      'packing-proof-cleanup-stats-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final File video = File('${directory.path}/cleaned.mp4')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final ValueNotifier<LanBackupSnapshot> snapshots =
        ValueNotifier<LanBackupSnapshot>(
          LanBackupSnapshot(
            jobs: <LanBackupJob>[
              LanBackupJob(
                id: 'job-cleanup',
                filePath: video.path,
                state: LanBackupJobState.completed,
                uploadedBytes: 3,
                totalBytes: 3,
              ),
            ],
          ),
        );
    addTearDown(snapshots.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            _session(
              'local-cleanup',
              'SF-CLEANUP',
              DateTime.now(),
              filePath: video.path,
            ),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: snapshots.value,
          backupListenable: snapshots,
          backupSnapshotProvider: () => snapshots.value,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.text('<1 MB'), findsOneWidget);
    video.deleteSync();
    snapshots.value = LanBackupSnapshot(
      jobs: <LanBackupJob>[
        LanBackupJob(
          id: 'job-cleanup',
          filePath: video.path,
          state: LanBackupJobState.completed,
          uploadedBytes: 3,
          totalBytes: 3,
          localDeletedAt: DateTime.now(),
        ),
      ],
    );
    await tester.pump();

    expect(find.text('0 MB'), findsOneWidget);
    expect(find.text('<1 MB'), findsNothing);
  });

  testWidgets('连接后持续显示电脑名称和局域网地址', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: LanBackupSnapshot(
            endpoint: LanBackupEndpoint(
              baseUri: Uri.parse('http://192.168.1.20:5280'),
              accessKey: '',
              computerId: 'computer-1',
              computerName: '仓库电脑',
            ),
            connectionStatus: LanConnectionStatus.connected,
          ),
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.byKey(const Key('connected-computer-summary')), findsOneWidget);
    expect(find.byKey(const Key('connected-computer-address')), findsNothing);
    expect(find.text('仓库电脑 · 192.168.1.20'), findsOneWidget);
  });

  testWidgets('本机录像全部备份后只显示完成状态', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final String videoPath = File('pubspec.yaml').absolute.path;
    final DateTime startedAt = DateTime(2026, 7, 19, 12);
    int backupCount = 0;
    bool? autoBackupEnabled;

    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            RecordingSession(
              id: 'local-1',
              filePath: videoPath,
              startedAt: startedAt,
              endedAt: startedAt.add(const Duration(seconds: 5)),
              markers: const <BarcodeMarker>[],
            ),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: LanBackupSnapshot(
            endpoint: LanBackupEndpoint(
              baseUri: Uri.parse('http://192.168.1.20:5280'),
              accessKey: '',
              computerId: 'computer-1',
              computerName: '仓库电脑',
            ),
            jobs: <LanBackupJob>[
              LanBackupJob(
                id: 'job-pending',
                filePath: videoPath,
                state: LanBackupJobState.pending,
                uploadedBytes: 0,
                totalBytes: 1,
                destinationComputerId: 'computer-1',
              ),
              LanBackupJob(
                id: 'job-1',
                filePath: videoPath,
                state: LanBackupJobState.completed,
                uploadedBytes: 1,
                totalBytes: 1,
                destinationComputerId: 'computer-1',
                remoteRecordIds: const <int>[1],
              ),
            ],
            connectionStatus: LanConnectionStatus.connected,
          ),
          onBackupNow: () async => backupCount++,
          onAutoBackupChanged: (bool enabled) async {
            autoBackupEnabled = enabled;
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

    expect(find.text('备份完成'), findsOneWidget);
    expect(find.byKey(const Key('backup-now-button')), findsOneWidget);
    expect(find.byKey(const Key('auto-backup-button')), findsOneWidget);
    expect(find.text('暂停自动备份'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    final Rect backupCardRect = tester.getRect(
      find.byKey(const Key('computer-backup-settings')),
    );
    expect(backupCardRect.height, lessThanOrEqualTo(190));
    final Rect backupNowRect = tester.getRect(
      find.byKey(const Key('backup-now-button')),
    );
    final Rect autoBackupRect = tester.getRect(
      find.byKey(const Key('auto-backup-button')),
    );
    expect(backupNowRect.height, autoBackupRect.height);
    expect(backupNowRect.width, autoBackupRect.width);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('backup-now-button')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('auto-backup-button')));
    await tester.pump();
    expect(autoBackupEnabled, isFalse);
    expect(backupCount, 0);

    await tester.drag(find.byType(ListView), const Offset(0, -460));
    await tester.pump();
    expect(find.text('已备份'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('recording-backed-up-chip'))).dy,
      closeTo(
        tester.getCenter(find.byKey(const Key('recording-date-duration'))).dy,
        1,
      ),
    );
  });

  testWidgets('未连接当前电脑时显示剩余数量并保留已备份标签', (WidgetTester tester) async {
    final String videoPath = File('pubspec.yaml').absolute.path;
    final DateTime startedAt = DateTime(2026, 7, 19, 12);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            RecordingSession(
              id: 'local-1',
              filePath: videoPath,
              startedAt: startedAt,
              endedAt: startedAt.add(const Duration(seconds: 5)),
              markers: const <BarcodeMarker>[],
            ),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: LanBackupSnapshot(
            jobs: <LanBackupJob>[
              LanBackupJob(
                id: 'job-1',
                filePath: videoPath,
                state: LanBackupJobState.completed,
                uploadedBytes: 1,
                totalBytes: 1,
                destinationComputerId: 'previous-computer',
                remoteRecordIds: const <int>[1],
              ),
            ],
          ),
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.text('1 个未备份'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -460));
    await tester.pump();
    expect(find.text('已备份'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('recording-backed-up-chip'))).dy,
      closeTo(
        tester.getCenter(find.byKey(const Key('recording-date-duration'))).dy,
        1,
      ),
    );
  });

  testWidgets('电脑离线时使用中性状态且不请求远程历史', (WidgetTester tester) async {
    int loadCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: LanBackupSnapshot(
            endpoint: LanBackupEndpoint(
              baseUri: Uri.parse('http://192.168.1.20:5280'),
              accessKey: '',
              computerId: 'computer-1',
              computerName: '仓库电脑',
            ),
            connectionStatus: LanConnectionStatus.offline,
          ),
          onLoadRemoteRecordings:
              ({required page, required pageSize, keyword = ''}) async {
                loadCount++;
                return const RemoteRecordingPage.empty();
              },
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onAutoBackupChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('离线'), findsOneWidget);
    expect(find.text('电脑离线，备份已暂停'), findsOneWidget);
    expect(loadCount, 0);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key('auto-backup-button')), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('delete-computer-button')))
          .tooltip,
      '删除电脑',
    );
    final IconButton deleteButton = tester.widget<IconButton>(
      find.byKey(const Key('delete-computer-button')),
    );
    expect(
      deleteButton.style?.shape?.resolve(<WidgetState>{}),
      isA<CircleBorder>(),
    );
    expect(
      deleteButton.style?.foregroundColor?.resolve(<WidgetState>{}),
      Theme.of(
        tester.element(find.byKey(const Key('delete-computer-button'))),
      ).colorScheme.error,
    );
  });

  testWidgets('删除电脑需要两次确认并显示名称与地址', (WidgetTester tester) async {
    int deleteCount = 0;
    final _FakeBackupHostDiscovery discovery = _FakeBackupHostDiscovery();
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupHostDiscovery: discovery,
          backupSnapshot: LanBackupSnapshot(
            endpoint: LanBackupEndpoint(
              baseUri: Uri.parse('http://192.168.1.20:5280'),
              accessKey: '',
              computerId: 'computer-1',
              computerName: '仓库电脑',
            ),
            connectionStatus: LanConnectionStatus.connected,
          ),
          onDisconnectBackup: () async => deleteCount++,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('delete-computer-button')));
    await tester.pumpAndSettle();
    expect(find.text('删除这台电脑？'), findsOneWidget);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('再次确认删除'), findsOneWidget);
    expect(find.textContaining('仓库电脑'), findsWidgets);
    expect(find.textContaining('192.168.1.20:5280'), findsWidgets);
    expect(deleteCount, 0);
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(deleteCount, 1);
    expect(discovery.forgetCount, 1);
    expect(discovery.forgottenNodeId, 'computer-1');
    expect(discovery.forgottenAddress, '192.168.1.20:5280');
  });

  testWidgets('等待续传不会误显示为正在备份', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: LanBackupSnapshot(
            endpoint: LanBackupEndpoint(
              baseUri: Uri.parse('http://192.168.1.20:5280'),
              accessKey: '',
              computerId: 'computer-1',
              computerName: '仓库电脑',
            ),
            jobs: const <LanBackupJob>[
              LanBackupJob(
                id: 'job-1',
                filePath: 'video.mp4',
                state: LanBackupJobState.paused,
                uploadedBytes: 0,
                totalBytes: 1024,
                errorMessage: '网络中断，等待自动续传',
              ),
            ],
            connectionStatus: LanConnectionStatus.connected,
          ),
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.text('网络中断，等待自动续传'), findsOneWidget);
    expect(find.textContaining('正在备份'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('设备令牌失效时只显示重新申请并保留原电脑', (WidgetTester tester) async {
    int approvalCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: LanBackupSnapshot(
            endpoint: LanBackupEndpoint(
              baseUri: Uri.parse('http://192.168.1.20:5280'),
              accessKey: '',
              computerId: 'computer-1',
              computerName: '仓库电脑',
            ),
            jobs: const <LanBackupJob>[
              LanBackupJob(
                id: 'old-offline-job',
                filePath: 'old-video.mp4',
                state: LanBackupJobState.failed,
                uploadedBytes: 0,
                totalBytes: 1024,
                errorMessage: '电脑离线',
                failureKind: LanBackupFailureKind.offlineOrTimeout,
              ),
              LanBackupJob(
                id: 'credential-job',
                filePath: 'video.mp4',
                state: LanBackupJobState.paused,
                uploadedBytes: 0,
                totalBytes: 1024,
                errorMessage: '设备连接已失效',
                failureKind: LanBackupFailureKind.credentialInvalid,
              ),
            ],
            connectionStatus: LanConnectionStatus.rePair,
          ),
          onConnectBackupHost: (host, confirmation) async => approvalCount++,
          onAutoBackupChanged: (_) async {},
          onBackupNow: () async {},
          onRetryBackup: (_) async {},
          onDisconnectBackup: () async {},
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.text('仓库电脑 · 192.168.1.20'), findsOneWidget);
    expect(find.text('需允许'), findsOneWidget);
    expect(find.text('重新申请'), findsOneWidget);
    expect(find.byKey(const Key('delete-computer-button')), findsOneWidget);
    expect(find.byKey(const Key('backup-now-button')), findsNothing);
    expect(find.byKey(const Key('auto-backup-button')), findsNothing);
    expect(find.text('重试失败任务'), findsNothing);

    await tester.tap(find.byKey(const Key('backup-failure-action-button')));
    expect(approvalCount, 1);
  });

  testWidgets('电脑不是备份主机时显示重新申请并覆盖旧版本失败提示', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const [],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: LanBackupSnapshot(
            endpoint: LanBackupEndpoint(
              baseUri: Uri.parse('http://192.168.1.20:5280'),
              accessKey: '',
              computerId: 'computer-1',
              computerName: '录像电脑',
            ),
            jobs: const <LanBackupJob>[
              LanBackupJob(
                id: 'legacy-404',
                filePath: 'video.mp4',
                state: LanBackupJobState.failed,
                uploadedBytes: 0,
                totalBytes: 1024,
                errorMessage: '电脑端版本不兼容',
                failureKind: LanBackupFailureKind.incompatibleVersion,
              ),
            ],
            connectionStatus: LanConnectionStatus.notBackupHost,
          ),
          onDisconnectBackup: () async {},
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.text('需允许'), findsOneWidget);
    expect(find.text('重新申请'), findsOneWidget);
    expect(find.textContaining('不是录像备份主机'), findsOneWidget);
    expect(find.text('请更新电脑端'), findsNothing);
    expect(find.byKey(const Key('backup-now-button')), findsNothing);
    expect(find.byKey(const Key('auto-backup-button')), findsNothing);
  });

  testWidgets('录像卡片不重复显示内部识别标记数量', (WidgetTester tester) async {
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            RecordingSession(
              id: 'recording-1',
              filePath: 'legacy.mp4',
              startedAt: startedAt,
              endedAt: startedAt.add(const Duration(seconds: 8)),
              markers: <BarcodeMarker>[
                BarcodeMarker(
                  code: 'CODE-001',
                  occurredAt: startedAt,
                  offset: Duration.zero,
                ),
              ],
            ),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    expect(find.text('CODE-001'), findsOneWidget);
    expect(find.textContaining('00:08'), findsOneWidget);
    expect(find.textContaining('个标记'), findsNothing);
  });

  testWidgets('可按面单号搜索录像', (WidgetTester tester) async {
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            _session('clip-1', 'JT1234567890', startedAt),
            _session('clip-2', 'SF9876543210', startedAt),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pump();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('recording-search')),
        matching: find.byType(EditableText),
      ),
      'SF9876',
    );
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();

    expect(find.text('SF9876543210'), findsOneWidget);
    expect(find.text('JT1234567890'), findsNothing);
  });

  testWidgets('录像记录每页显示五条并可翻页', (WidgetTester tester) async {
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: List<RecordingSession>.generate(
            11,
            (int index) => _session(
              'clip-$index',
              'CODE-${index.toString().padLeft(2, '0')}',
              startedAt.subtract(Duration(minutes: index)),
            ),
          ),
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    expect(find.text('CODE-00'), findsOneWidget);
    expect(find.text('CODE-10'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('CODE-04'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('CODE-04'), findsOneWidget);
    expect(find.text('CODE-10'), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(const Key('recording-page-next')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pump();
    expect(find.text('1 / 3 页'), findsOneWidget);
    await tester.tap(find.byKey(const Key('recording-page-next')));
    await tester.pump();

    expect(find.text('CODE-00'), findsNothing);
    expect(find.text('CODE-05'), findsOneWidget);
    expect(find.text('CODE-10'), findsNothing);
    expect(find.text('2 / 3 页'), findsOneWidget);
  });

  testWidgets('本机录像从数据库分页并用关键词重新查询', (WidgetTester tester) async {
    final List<int> requestedPages = <int>[];
    final List<String> requestedKeywords = <String>[];
    Future<LocalRecordingPage> loadLocal({
      required int page,
      required int pageSize,
      String keyword = '',
    }) async {
      requestedPages.add(page);
      requestedKeywords.add(keyword);
      final int start = (page - 1) * pageSize;
      final DateTime startedAt = DateTime(2026, 7, 23, 12);
      return LocalRecordingPage(
        data: List<RecordingSession>.generate(
          keyword.isEmpty ? pageSize : 1,
          (int index) => _session(
            keyword.isEmpty ? 'local-${start + index}' : 'local-search',
            keyword.isEmpty ? 'LOCAL-${start + index}' : 'LOCAL-SEARCHED',
            startedAt.subtract(Duration(minutes: start + index)),
          ),
        ),
        page: page,
        pageSize: pageSize,
        total: keyword.isEmpty ? 20 : 1,
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const <RecordingSession>[],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onLoadLocalRecordings: loadLocal,
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

    expect(requestedPages, <int>[1, 2]);
    expect(find.text('LOCAL-0'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('recording-search')),
        matching: find.byType(EditableText),
      ),
      'SEARCHED',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(requestedKeywords.last, 'SEARCHED');
    expect(find.text('LOCAL-SEARCHED'), findsOneWidget);
    expect(find.text('LOCAL-0'), findsNothing);
  });

  testWidgets('电脑录像首次缓存两页且搜索重置分页', (WidgetTester tester) async {
    final List<int> requestedPages = <int>[];
    final List<String> requestedKeywords = <String>[];
    Future<RemoteRecordingPage> loadRemote({
      required int page,
      required int pageSize,
      String keyword = '',
    }) async {
      requestedPages.add(page);
      requestedKeywords.add(keyword);
      final int start = (page - 1) * pageSize;
      return RemoteRecordingPage(
        data: List<RemoteRecording>.generate(
          keyword.isEmpty ? 10 : 1,
          (int index) => RemoteRecording(
            id: start + index + 1,
            trackingNumber: keyword.isEmpty
                ? 'REMOTE-${start + index}'
                : 'SEARCHED',
            startedAt: DateTime(
              2026,
              7,
              19,
              12,
            ).subtract(Duration(minutes: start + index)),
            duration: const Duration(seconds: 5),
            sourceType: 'pc',
            sourceDeviceId: '',
            sourceDeviceName: '',
            sourceSessionId: '',
            contentSha256: '',
            playUri: Uri.parse('http://192.168.1.20/video'),
          ),
        ),
        page: page,
        pageSize: pageSize,
        total: keyword.isEmpty ? 20 : 1,
        deviceTotal: 0,
      );
    }

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
          ),
          onLoadRemoteRecordings: loadRemote,
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
    expect(requestedPages, <int>[1, 2]);

    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(requestedPages, <int>[1, 2]);

    await tester.scrollUntilVisible(
      find.byKey(const Key('recording-page-next')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('recording-page-next')));
    await tester.pumpAndSettle();
    expect(requestedPages, <int>[1, 2, 3]);

    await tester.tap(find.byKey(const Key('recording-page-previous')));
    await tester.pump();
    expect(requestedPages, <int>[1, 2, 3]);

    await tester.drag(find.byType(ListView), const Offset(0, 1800));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('recording-search')),
        matching: find.byType(EditableText),
      ),
      'SEARCH',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(requestedPages.last, 1);
    expect(requestedKeywords.last, 'SEARCH');
    expect(find.text('SEARCHED'), findsOneWidget);
  });

  testWidgets('电脑已清理的录像显示灰色状态且禁止播放', (WidgetTester tester) async {
    final RemoteRecording remote = RemoteRecording(
      id: 7,
      trackingNumber: 'CLEANED-001',
      startedAt: DateTime(2026, 7, 19, 12),
      duration: const Duration(seconds: 5),
      sourceType: 'external',
      sourceDeviceId: 'phone-1',
      sourceDeviceName: '手机2',
      sourceSessionId: 'session-1',
      contentSha256: 'sha',
      playUri: Uri.parse('http://192.168.1.20/api/videos/7/play'),
    );
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
          ),
          onLoadRemoteRecordings:
              ({required page, required pageSize, keyword = ''}) async =>
                  RemoteRecordingPage(
                    data: page == 1 ? <RemoteRecording>[remote] : const [],
                    page: page,
                    pageSize: pageSize,
                    total: 1,
                    deviceTotal: 1,
                  ),
          onLoadRemoteRecordingStatuses: (ids) async => {
            7: (
              status: RemoteRecordingStatus.deleted,
              exists: false,
              reason: '容量清理',
            ),
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

    expect(find.text('手机2'), findsOneWidget);
    await tester.tap(find.text('CLEANED-001'));
    await tester.pump();
    expect(find.text('录像已清理或文件不存在，无法播放'), findsOneWidget);
  });

  testWidgets('录像来源标签显示在快递单号右侧', (WidgetTester tester) async {
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            _session('clip-1', 'TRACKING-001', startedAt),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: const LanBackupSnapshot(
            deviceId: 'phone-1',
            deviceName: '手机1',
          ),
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pump();
    final Offset codeCenter = tester.getCenter(find.text('TRACKING-001'));
    final Offset sourceCenter = tester.getCenter(
      find.byKey(const Key('recording-source-chip')),
    );
    expect((codeCenter.dy - sourceCenter.dy).abs(), lessThan(2));
    expect(sourceCenter.dx, greaterThan(codeCenter.dx));
    expect(
      tester.getSize(find.byKey(const Key('recording-thumbnail'))),
      const Size.square(56),
    );
  });

  testWidgets('录像来源标签区分电脑和其他手机', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    final List<RemoteRecording> recordings = <RemoteRecording>[
      RemoteRecording(
        id: 11,
        trackingNumber: 'PC-001',
        startedAt: startedAt,
        duration: const Duration(seconds: 5),
        sourceType: 'pc',
        sourceDeviceId: 'computer-1',
        sourceDeviceName: '仓库电脑',
        sourceSessionId: '',
        contentSha256: 'pc-sha',
        playUri: Uri.parse('http://192.168.1.20/api/videos/11/play'),
      ),
      RemoteRecording(
        id: 12,
        trackingNumber: 'PHONE-002',
        startedAt: startedAt.subtract(const Duration(minutes: 1)),
        duration: const Duration(seconds: 5),
        sourceType: 'external',
        sourceDeviceId: 'phone-2',
        sourceDeviceName: '手机2',
        sourceSessionId: 'session-2',
        contentSha256: 'phone-sha',
        playUri: Uri.parse('http://192.168.1.20/api/videos/12/play'),
      ),
      RemoteRecording(
        id: 13,
        trackingNumber: 'PHONE-003',
        startedAt: startedAt.subtract(const Duration(minutes: 2)),
        duration: const Duration(seconds: 5),
        sourceType: 'external',
        sourceDeviceId: 'phone-3',
        sourceDeviceName: '手机3',
        sourceSessionId: 'session-3',
        contentSha256: 'phone-sha-3',
        playUri: Uri.parse('http://192.168.1.20/api/videos/13/play'),
      ),
    ];
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
              computerName: '仓库电脑',
            ),
            connectionStatus: LanConnectionStatus.connected,
            deviceId: 'phone-1',
            deviceName: '手机1',
          ),
          onLoadRemoteRecordings:
              ({required page, required pageSize, keyword = ''}) async =>
                  RemoteRecordingPage(
                    data: page == 1 ? recordings : const <RemoteRecording>[],
                    page: page,
                    pageSize: pageSize,
                    total: recordings.length,
                    deviceTotal: 0,
                  ),
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

    expect(find.text('仓库电脑'), findsOneWidget);
    expect(find.text('手机2'), findsOneWidget);
    expect(find.text('手机3'), findsOneWidget);
    final DecoratedBox phone2Chip = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey<String>('recording-source-chip-color-phone-2')),
    );
    final DecoratedBox phone3Chip = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey<String>('recording-source-chip-color-phone-3')),
    );
    expect(
      (phone2Chip.decoration as BoxDecoration).color,
      isNot((phone3Chip.decoration as BoxDecoration).color),
    );
  });

  testWidgets('已备份、等待续传和未备份标签使用不同颜色', (WidgetTester tester) async {
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    final List<String> paths = <String>[
      File('pubspec.yaml').absolute.path,
      File('README.md').absolute.path,
      File('AGENTS.md').absolute.path,
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            _session('completed', 'COMPLETED', startedAt, filePath: paths[0]),
            _session(
              'paused',
              'PAUSED',
              startedAt.subtract(const Duration(minutes: 1)),
              filePath: paths[1],
            ),
            _session(
              'pending',
              'PENDING',
              startedAt.subtract(const Duration(minutes: 2)),
              filePath: paths[2],
            ),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: LanBackupSnapshot(
            jobs: <LanBackupJob>[
              LanBackupJob(
                id: 'completed',
                filePath: paths[0],
                state: LanBackupJobState.completed,
                uploadedBytes: 1,
                totalBytes: 1,
                remoteRecordIds: const <int>[1],
              ),
              LanBackupJob(
                id: 'paused',
                filePath: paths[1],
                state: LanBackupJobState.paused,
                uploadedBytes: 1,
                totalBytes: 2,
              ),
              LanBackupJob(
                id: 'pending',
                filePath: paths[2],
                state: LanBackupJobState.pending,
                uploadedBytes: 0,
                totalBytes: 2,
              ),
            ],
          ),
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -460));
    await tester.pump();

    Color chipColor(String label) {
      final DecoratedBox chip = tester.widget<DecoratedBox>(
        find
            .ancestor(of: find.text(label), matching: find.byType(DecoratedBox))
            .first,
      );
      return (chip.decoration as BoxDecoration).color!;
    }

    expect(find.text('已备份'), findsOneWidget);
    expect(find.text('等待续传'), findsOneWidget);
    expect(find.text('未备份'), findsOneWidget);
    expect(<Color>{
      chipColor('已备份'),
      chipColor('等待续传'),
      chipColor('未备份'),
    }, hasLength(3));
  });

  testWidgets('已备份标签只匹配当前手机设备', (WidgetTester tester) async {
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    final String videoPath = File('pubspec.yaml').absolute.path;
    RemoteRecording remote({
      required int id,
      required String deviceId,
      required String code,
    }) => RemoteRecording(
      id: id,
      trackingNumber: code,
      startedAt: startedAt,
      duration: const Duration(seconds: 8),
      sourceType: 'external',
      sourceDeviceId: deviceId,
      sourceDeviceName: '手机',
      sourceSessionId: 'session-1',
      contentSha256: 'sha-$id',
      playUri: Uri.parse('http://192.168.1.20/api/videos/$id/play'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            RecordingSession(
              id: 'session-1',
              filePath: videoPath,
              startedAt: startedAt,
              endedAt: startedAt.add(const Duration(seconds: 8)),
              markers: <BarcodeMarker>[
                BarcodeMarker(
                  code: 'THIS-PHONE',
                  occurredAt: startedAt,
                  offset: Duration.zero,
                ),
              ],
            ),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: LanBackupSnapshot(
            deviceId: 'this-phone',
            endpoint: LanBackupEndpoint(
              baseUri: Uri.parse('http://192.168.1.20:5280'),
              accessKey: '',
              computerId: 'computer-1',
              computerName: '电脑',
            ),
            connectionStatus: LanConnectionStatus.connected,
          ),
          onLoadRemoteRecordings:
              ({required page, required pageSize, keyword = ''}) async =>
                  RemoteRecordingPage(
                    data: page == 1
                        ? <RemoteRecording>[
                            remote(
                              id: 1,
                              deviceId: 'another-phone',
                              code: 'OTHER-PHONE',
                            ),
                            remote(
                              id: 2,
                              deviceId: 'this-phone',
                              code: 'THIS-PHONE',
                            ),
                          ]
                        : const <RemoteRecording>[],
                    page: page,
                    pageSize: pageSize,
                    total: 2,
                    deviceTotal: 1,
                  ),
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
    await tester.drag(find.byType(ListView), const Offset(0, -460));
    await tester.pump();

    expect(find.text('THIS-PHONE'), findsOneWidget);
    expect(find.text('OTHER-PHONE'), findsOneWidget);
    expect(find.text('已备份'), findsOneWidget);
  });

  testWidgets('手动刷新按钮会去抖并避免重复请求', (WidgetTester tester) async {
    final Completer<void> refresh = Completer<void>();
    int refreshCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const <RecordingSession>[],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
          onRefreshHistory: () {
            refreshCount++;
            return refresh.future;
          },
        ),
      ),
    );

    final Finder button = find.byKey(const Key('refresh-recordings-button'));
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();
    expect(refreshCount, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    refresh.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('备份任务完成后自动刷新电脑录像缓存', (WidgetTester tester) async {
    final ValueNotifier<LanBackupSnapshot> snapshots =
        ValueNotifier<LanBackupSnapshot>(
          LanBackupSnapshot(
            endpoint: LanBackupEndpoint(
              baseUri: Uri.parse('http://192.168.1.20:5280'),
              accessKey: '',
              computerId: 'computer-1',
              computerName: '电脑',
            ),
            connectionStatus: LanConnectionStatus.connected,
            jobs: const <LanBackupJob>[
              LanBackupJob(
                id: 'job-1',
                filePath: '/recordings/one.mp4',
                state: LanBackupJobState.uploading,
                uploadedBytes: 1,
                totalBytes: 2,
                destinationComputerId: 'computer-1',
              ),
            ],
          ),
        );
    addTearDown(snapshots.dispose);
    int remoteLoadCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const <RecordingSession>[],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: snapshots.value,
          backupListenable: snapshots,
          backupSnapshotProvider: () => snapshots.value,
          onLoadRemoteRecordings:
              ({required page, required pageSize, keyword = ''}) async {
                remoteLoadCount++;
                return RemoteRecordingPage(
                  data: const <RemoteRecording>[],
                  page: page,
                  pageSize: pageSize,
                  total: 0,
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
    expect(remoteLoadCount, 1);

    snapshots.value = LanBackupSnapshot(
      endpoint: snapshots.value.endpoint,
      connectionStatus: LanConnectionStatus.connected,
      jobs: const <LanBackupJob>[
        LanBackupJob(
          id: 'job-1',
          filePath: '/recordings/one.mp4',
          state: LanBackupJobState.completed,
          uploadedBytes: 2,
          totalBytes: 2,
          remoteRecordIds: <int>[42],
          destinationComputerId: 'computer-1',
        ),
      ],
    );
    await tester.pumpAndSettle();
    expect(remoteLoadCount, 2);
  });

  testWidgets('电脑重新上线后自动刷新远程历史', (WidgetTester tester) async {
    final LanBackupEndpoint endpoint = LanBackupEndpoint(
      baseUri: Uri.parse('http://192.168.1.20:5280'),
      accessKey: '',
      computerId: 'computer-1',
      computerName: '电脑',
    );
    final ValueNotifier<LanBackupSnapshot> snapshots =
        ValueNotifier<LanBackupSnapshot>(
          LanBackupSnapshot(
            endpoint: endpoint,
            connectionStatus: LanConnectionStatus.connected,
          ),
        );
    addTearDown(snapshots.dispose);
    int remoteLoadCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: const <RecordingSession>[],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: snapshots.value,
          backupListenable: snapshots,
          backupSnapshotProvider: () => snapshots.value,
          onLoadRemoteRecordings:
              ({required page, required pageSize, keyword = ''}) async {
                remoteLoadCount++;
                return RemoteRecordingPage(
                  data: <RemoteRecording>[
                    RemoteRecording(
                      id: 99,
                      trackingNumber: 'REMOTE-99',
                      startedAt: DateTime(2026, 7, 26, 12),
                      duration: const Duration(seconds: 5),
                      sourceType: 'external',
                      sourceDeviceId: 'phone-2',
                      sourceDeviceName: '手机2',
                      sourceSessionId: 'session-99',
                      contentSha256: 'sha-99',
                      playUri: Uri.parse(
                        'http://192.168.1.20:5280/api/videos/99/play',
                      ),
                    ),
                  ],
                  page: page,
                  pageSize: pageSize,
                  total: 1,
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
    expect(remoteLoadCount, 1);

    snapshots.value = LanBackupSnapshot(
      endpoint: endpoint,
      connectionStatus: LanConnectionStatus.offline,
    );
    await tester.pump();
    snapshots.value = LanBackupSnapshot(
      endpoint: endpoint,
      connectionStatus: LanConnectionStatus.connected,
    );
    await tester.pumpAndSettle();

    expect(remoteLoadCount, 2);
    expect(find.text('手机2'), findsOneWidget);
  });

  testWidgets('管理模式可多选并确认删除录像', (WidgetTester tester) async {
    const MethodChannel thumbnailChannel = MethodChannel(
      'app.packingproof.mobile/recording_thumbnail',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(thumbnailChannel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(thumbnailChannel, null),
    );
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    final File localVideo = File('pubspec.yaml').absolute;
    Set<String>? deletedIds;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            RecordingSession(
              id: 'clip-1',
              filePath: localVideo.path,
              startedAt: startedAt,
              endedAt: startedAt.add(const Duration(seconds: 8)),
              markers: <BarcodeMarker>[
                BarcodeMarker(
                  code: 'JT1234567890',
                  occurredAt: startedAt,
                  offset: Duration.zero,
                ),
              ],
            ),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (Set<String> ids) async {
            deletedIds = ids;
          },
        ),
      ),
    );
    await tester.tap(find.text('管理'));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pump();
    await tester.tap(find.text('JT1234567890'));
    await tester.pump();

    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-selected-recordings')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('应用会按保留策略自动清理录像，一般无需手动删除。删除后无法恢复。'), findsOneWidget);
    expect(find.textContaining('共享同一录像文件'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '仍要删除'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(deletedIds, <String>{'clip-1'});
    expect(find.text('JT1234567890'), findsNothing);
  });

  testWidgets('日期筛选面板提供快捷项和自定义范围', (WidgetTester tester) async {
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            RecordingSession(
              id: 'clip-1',
              filePath: 'pubspec.yaml',
              startedAt: startedAt,
              endedAt: startedAt.add(const Duration(seconds: 8)),
              markers: <BarcodeMarker>[
                BarcodeMarker(
                  code: 'JT1234567890',
                  occurredAt: startedAt,
                  offset: Duration.zero,
                ),
              ],
            ),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('recording-date-filter')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('recording-date-filter')));
    await tester.pumpAndSettle();
    for (final String label in <String>[
      '全部日期',
      '今天',
      '最近7天',
      '最近30天',
      '自定义范围',
    ]) {
      expect(find.text(label), findsAtLeastNWidgets(1));
    }
  });

  testWidgets('选择最近7天只显示该日期范围内的录像（含电脑录像）', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day, 10);
    final DateTime old = today.subtract(const Duration(days: 30));
    final RemoteRecording remoteToday = RemoteRecording(
      id: 11,
      trackingNumber: 'REMOTE-TODAY',
      startedAt: today.add(const Duration(hours: 1)),
      duration: const Duration(seconds: 5),
      sourceType: 'pc',
      sourceDeviceId: '',
      sourceDeviceName: '',
      sourceSessionId: '',
      contentSha256: '',
      playUri: Uri.parse('http://192.168.1.20/video/11'),
    );
    final RemoteRecording remoteOld = RemoteRecording(
      id: 12,
      trackingNumber: 'REMOTE-OLD',
      startedAt: old,
      duration: const Duration(seconds: 5),
      sourceType: 'pc',
      sourceDeviceId: '',
      sourceDeviceName: '',
      sourceSessionId: '',
      contentSha256: '',
      playUri: Uri.parse('http://192.168.1.20/video/12'),
    );
    RecordingSession session(String id, String code, DateTime startedAt) =>
        RecordingSession(
          id: id,
          filePath: 'pubspec.yaml',
          startedAt: startedAt,
          endedAt: startedAt.add(const Duration(seconds: 8)),
          markers: <BarcodeMarker>[
            BarcodeMarker(
              code: code,
              occurredAt: startedAt,
              offset: Duration.zero,
            ),
          ],
        );
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            session('today', 'LOCAL-TODAY', today),
            session('old', 'LOCAL-OLD', old),
          ],
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
          ),
          onLoadRemoteRecordings:
              ({required page, required pageSize, keyword = ''}) async =>
                  RemoteRecordingPage(
                    data: page == 1
                        ? <RemoteRecording>[remoteToday, remoteOld]
                        : const <RemoteRecording>[],
                    page: page,
                    pageSize: pageSize,
                    total: 2,
                    deviceTotal: 0,
                  ),
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
    await tester.scrollUntilVisible(
      find.text('LOCAL-TODAY'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('LOCAL-TODAY'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('LOCAL-OLD'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('LOCAL-OLD'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('REMOTE-OLD'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('REMOTE-OLD'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('recording-date-filter')),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('recording-date-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近7天'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('LOCAL-TODAY'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('LOCAL-TODAY'), findsOneWidget);
    expect(find.text('REMOTE-TODAY'), findsOneWidget);
    expect(find.text('LOCAL-OLD'), findsNothing);
    expect(find.text('REMOTE-OLD'), findsNothing);
  });

  testWidgets('自定义日期范围过滤只显示范围内的录像（含电脑录像）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day, 10);
    final DateTime yesterday = today.subtract(const Duration(days: 1));
    final RemoteRecording remoteToday = RemoteRecording(
      id: 21,
      trackingNumber: 'REMOTE-CUSTOM-TODAY',
      startedAt: today.add(const Duration(hours: 1)),
      duration: const Duration(seconds: 5),
      sourceType: 'pc',
      sourceDeviceId: '',
      sourceDeviceName: '',
      sourceSessionId: '',
      contentSha256: '',
      playUri: Uri.parse('http://192.168.1.20/video/21'),
    );
    final RemoteRecording remoteYesterday = RemoteRecording(
      id: 22,
      trackingNumber: 'REMOTE-CUSTOM-OLD',
      startedAt: yesterday,
      duration: const Duration(seconds: 5),
      sourceType: 'pc',
      sourceDeviceId: '',
      sourceDeviceName: '',
      sourceSessionId: '',
      contentSha256: '',
      playUri: Uri.parse('http://192.168.1.20/video/22'),
    );
    RecordingSession session(String id, String code, DateTime startedAt) =>
        RecordingSession(
          id: id,
          filePath: 'pubspec.yaml',
          startedAt: startedAt,
          endedAt: startedAt.add(const Duration(seconds: 8)),
          markers: <BarcodeMarker>[
            BarcodeMarker(
              code: code,
              occurredAt: startedAt,
              offset: Duration.zero,
            ),
          ],
        );
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            session('today', 'LOCAL-CUSTOM-TODAY', today),
            session('yesterday', 'LOCAL-CUSTOM-OLD', yesterday),
          ],
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
          ),
          onLoadRemoteRecordings:
              ({required page, required pageSize, keyword = ''}) async =>
                  RemoteRecordingPage(
                    data: page == 1
                        ? <RemoteRecording>[remoteToday, remoteYesterday]
                        : const <RemoteRecording>[],
                    page: page,
                    pageSize: pageSize,
                    total: 2,
                    deviceTotal: 0,
                  ),
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

    await tester.tap(find.byKey(const Key('recording-date-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义范围'));
    await tester.pumpAndSettle();

    // 日历初始显示当前月；同一天点两次作为起止日期，保存后即为“今天”范围。
    await tester.tap(find.text('${today.day}').first);
    await tester.pump();
    await tester.tap(find.text('${today.day}').first);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('LOCAL-CUSTOM-TODAY'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('LOCAL-CUSTOM-TODAY'), findsOneWidget);
    expect(find.text('REMOTE-CUSTOM-TODAY'), findsOneWidget);
    expect(find.text('LOCAL-CUSTOM-OLD'), findsNothing);
    expect(find.text('REMOTE-CUSTOM-OLD'), findsNothing);
  });

  testWidgets('管理模式复制单号去重并写入剪贴板', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    RecordingSession session(String id, String code) => RecordingSession(
      id: id,
      filePath: 'pubspec.yaml',
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 8)),
      markers: code.isEmpty
          ? const <BarcodeMarker>[]
          : <BarcodeMarker>[
              BarcodeMarker(
                code: code,
                occurredAt: startedAt,
                offset: Duration.zero,
              ),
            ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            session('clip-1', 'A-1111'),
            session('clip-2', 'A-1111'),
            session('clip-3', 'B-2222'),
            session('clip-4', ''),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('管理'));
    await tester.pump();
    await tester.tap(find.text('A-1111').first);
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.text('A-1111').last);
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);
    await tester.tap(find.text('B-2222'));
    await tester.pump();
    expect(find.text('已选 3 项'), findsOneWidget);
    await tester.tap(find.text('未识别面单'));
    await tester.pump();

    expect(find.text('已选 4 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('copy-selected-tracking-numbers')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(copied, 'A-1111\nB-2222');
    expect(find.text('已复制 2 个单号'), findsOneWidget);
  });

  testWidgets('所选记录没有可复制单号时提示且不复制', (WidgetTester tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: <RecordingSession>[
            RecordingSession(
              id: 'clip-1',
              filePath: 'pubspec.yaml',
              startedAt: startedAt,
              endedAt: startedAt.add(const Duration(seconds: 8)),
              markers: const <BarcodeMarker>[],
            ),
          ],
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          onWorkModeChanged: (_) async {},
          onSpeechEnabledChanged: (_) async {},
          onMaxVolumeEnabledChanged: (_) async {},
          onSpeechPreview: () async {},
          onSessionUpdated: (_) async {},
          onDeleteSessions: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('管理'));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pump();
    await tester.tap(find.text('未识别面单'));
    await tester.pump();

    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('copy-selected-tracking-numbers')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(copied, isNull);
    expect(find.text('所选记录没有可复制的单号'), findsOneWidget);
  });
  testWidgets('未连接电脑时后台通知不会重置历史页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    final List<RecordingSession> all = List<RecordingSession>.generate(
      12,
      (int index) => _session(
        'clip-$index',
        'NO-${index + 1}',
        startedAt.subtract(Duration(minutes: index)),
        filePath: 'pubspec.yaml',
      ),
    );
    final ChangeNotifier notifier = ChangeNotifier();
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: all,
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupListenable: notifier,
          onLoadLocalRecordings:
              ({required page, required pageSize, keyword = ''}) async {
                final int start = (page - 1) * pageSize;
                return LocalRecordingPage(
                  data: start >= all.length
                      ? const <RecordingSession>[]
                      : all.skip(start).take(pageSize).toList(growable: false),
                  page: page,
                  pageSize: pageSize,
                  total: all.length,
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
    await tester.tap(find.byKey(const Key('recording-page-next')));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3 页'), findsOneWidget);
    expect(find.text('NO-6'), findsOneWidget);

    for (int i = 0; i < 3; i++) {
      notifier.notifyListeners();
      await tester.pump();
    }
    expect(find.text('2 / 3 页'), findsOneWidget);
    expect(find.text('NO-6'), findsOneWidget);
  });

  testWidgets('电脑断开时才重置历史页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final DateTime startedAt = DateTime(2026, 7, 18, 12);
    final List<RecordingSession> all = List<RecordingSession>.generate(
      12,
      (int index) => _session(
        'clip-$index',
        'NO-${index + 1}',
        startedAt.subtract(Duration(minutes: index)),
        filePath: 'pubspec.yaml',
      ),
    );
    final ChangeNotifier notifier = ChangeNotifier();
    LanBackupSnapshot snapshot = LanBackupSnapshot(
      endpoint: LanBackupEndpoint(
        baseUri: Uri.parse('http://192.168.1.20:5280'),
        accessKey: '',
        computerId: 'computer-1',
        computerName: '电脑',
      ),
      connectionStatus: LanConnectionStatus.connected,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingsScreen(
          sessions: all,
          workMode: WorkMode.continuousScan,
          speechEnabled: true,
          maxVolumeEnabled: true,
          backupSnapshot: snapshot,
          backupSnapshotProvider: () => snapshot,
          backupListenable: notifier,
          onLoadLocalRecordings:
              ({required page, required pageSize, keyword = ''}) async {
                final int start = (page - 1) * pageSize;
                return LocalRecordingPage(
                  data: start >= all.length
                      ? const <RecordingSession>[]
                      : all.skip(start).take(pageSize).toList(growable: false),
                  page: page,
                  pageSize: pageSize,
                  total: all.length,
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
    await tester.tap(find.byKey(const Key('recording-page-next')));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3 页'), findsOneWidget);

    notifier.notifyListeners();
    await tester.pump();
    expect(find.text('2 / 3 页'), findsOneWidget);

    snapshot = const LanBackupSnapshot(
      connectionStatus: LanConnectionStatus.disconnected,
    );
    notifier.notifyListeners();
    await tester.pump();
    expect(find.text('1 / 3 页'), findsOneWidget);
    expect(find.text('NO-1'), findsOneWidget);
  });
}

class _FakeBackupHostDiscovery extends ChangeNotifier
    implements LanBackupHostDiscovery {
  _FakeBackupHostDiscovery({
    this.hosts = const <LanBackupDiscoveredHost>[
      LanBackupDiscoveredHost(
        nodeId: 'host-1',
        name: '保存主机',
        address: '192.168.1.10:5280',
      ),
    ],
  }) : _currentHosts = List<LanBackupDiscoveredHost>.of(hosts);

  final List<LanBackupDiscoveredHost> hosts;
  final List<LanBackupDiscoveredHost> _currentHosts;
  int searchCount = 0;
  int forgetCount = 0;
  String? forgottenNodeId;
  String? forgottenAddress;
  LanBackupDiscoverySnapshot _snapshot = const LanBackupDiscoverySnapshot();

  @override
  LanBackupDiscoverySnapshot get snapshot => _snapshot;

  @override
  Future<void> search() async {
    searchCount++;
    _snapshot = const LanBackupDiscoverySnapshot(
      searching: true,
      total: 1,
      message: '正在搜索 0 / 1',
    );
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    _snapshot = LanBackupDiscoverySnapshot(
      completed: 1,
      total: 1,
      hosts: List<LanBackupDiscoveredHost>.unmodifiable(_currentHosts),
      message: '找到 ${_currentHosts.length} 台录像文件备份主机',
    );
    notifyListeners();
  }

  @override
  void cancel() {}

  @override
  Future<void> forgetHost({
    required String nodeId,
    required String address,
  }) async {
    forgetCount++;
    forgottenNodeId = nodeId;
    forgottenAddress = address;
    _currentHosts.removeWhere((LanBackupDiscoveredHost host) {
      final bool sameNodeId =
          nodeId.trim().isNotEmpty && host.nodeId.trim() == nodeId.trim();
      final bool sameAddress = host.address == address;
      return sameNodeId || sameAddress;
    });
    if (_snapshot.hosts.isNotEmpty) {
      _snapshot = LanBackupDiscoverySnapshot(
        completed: _snapshot.completed,
        total: _snapshot.total,
        hosts: List<LanBackupDiscoveredHost>.unmodifiable(_currentHosts),
        message: _snapshot.message,
      );
      notifyListeners();
    }
  }
}

RecordingSession _session(
  String id,
  String code,
  DateTime startedAt, {
  String filePath = 'legacy.mp4',
}) {
  return RecordingSession(
    id: id,
    filePath: filePath,
    startedAt: startedAt,
    endedAt: startedAt.add(const Duration(seconds: 8)),
    markers: <BarcodeMarker>[
      BarcodeMarker(code: code, occurredAt: startedAt, offset: Duration.zero),
    ],
  );
}
