import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/widgets/recording_info_card.dart';

void main() {
  test('录像时间同年只显示月日与时分', () {
    expect(
      formatRecordingTime(
        DateTime(2026, 9, 13, 19, 19),
        now: DateTime(2026, 12, 1),
      ),
      '9月13日 19:19',
    );
  });

  test('录像时间跨年补上年份', () {
    expect(
      formatRecordingTime(
        DateTime(2025, 12, 31, 8, 5),
        now: DateTime(2026, 1, 1),
      ),
      '2025年12月31日 08:05',
    );
  });

  test('时长超过一小时补小时位', () {
    expect(formatRecordingDuration(const Duration(seconds: 45)), '00:45');
    expect(
      formatRecordingDuration(const Duration(minutes: 12, seconds: 7)),
      '12:07',
    );
    expect(
      formatRecordingDuration(const Duration(hours: 1, minutes: 5, seconds: 3)),
      '1:05:03',
    );
    expect(formatRecordingDuration(const Duration(seconds: -5)), '00:00');
  });

  test('文件大小按量级切换单位', () {
    expect(formatRecordingSize(0), '未知');
    expect(formatRecordingSize(512), '512 B');
    expect(formatRecordingSize(2048), '2 KB');
    expect(formatRecordingSize(12 * 1024 * 1024), '12 MB');
    expect(formatRecordingSize(3 * 1024 * 1024 * 1024), '3.00 GB');
  });

  test('分辨率按短边归类，横竖屏一致', () {
    expect(formatRecordingResolution(const Size(3840, 2160)), '4K');
    expect(formatRecordingResolution(const Size(2160, 3840)), '4K');
    expect(formatRecordingResolution(const Size(1920, 1080)), '1080p');
    expect(formatRecordingResolution(const Size(1080, 1920)), '1080p');
    expect(formatRecordingResolution(const Size(1280, 720)), '720p');
    expect(formatRecordingResolution(const Size(640, 480)), '480p');
    expect(formatRecordingResolution(const Size(320, 240)), '240p');
  });

  test('分辨率拿不到时返回空文案', () {
    expect(formatRecordingResolution(null), '');
    expect(formatRecordingResolution(Size.zero), '');
  });

  test('编码文案归一化', () {
    expect(formatRecordingCodec('h265'), 'H.265');
    expect(formatRecordingCodec('HEVC'), 'H.265');
    expect(formatRecordingCodec('h264'), 'H.264');
    expect(formatRecordingCodec('avc'), 'H.264');
    expect(formatRecordingCodec(''), '');
  });

  testWidgets('信息卡片用位置表达含义，不写冗余标注', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecordingInfoCard(
            code: 'JD0001',
            codeCopyable: true,
            recordedAt: '9月13日 19:19',
            metadata: <String>['00:45', '12.3 MB'],
            source: '仓库电脑',
            backupLabel: '已备份到电脑',
          ),
        ),
      ),
    );

    expect(find.text('JD0001'), findsOneWidget);
    expect(find.text('9月13日 19:19 录制'), findsOneWidget);
    expect(find.text('00:45'), findsOneWidget);
    expect(find.text('12.3 MB'), findsOneWidget);
    expect(find.text('仓库电脑'), findsOneWidget);
    expect(find.text('已备份到电脑'), findsOneWidget);
    // 这些标注由位置与形态表达，不再出现在卡片里。
    for (final String label in <String>['来源', '录制时间', '时长', '大小', '备份', '操作']) {
      expect(find.text(label), findsNothing, reason: '不应出现标注 $label');
    }
  });

  testWidgets('点按面单号复制到剪贴板', (WidgetTester tester) async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') calls.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecordingInfoCard(
            code: 'JD0001',
            codeCopyable: true,
            recordedAt: '9月13日 19:19',
            metadata: <String>['00:45'],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('playback-copy-code')));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect((calls.single.arguments as Map<Object?, Object?>)['text'], 'JD0001');
    expect(find.text('面单号已复制'), findsOneWidget);
  });

  testWidgets('未识别面单时不给复制入口', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecordingInfoCard(
            code: '未识别面单',
            codeCopyable: false,
            recordedAt: '9月13日 19:19',
            metadata: <String>['00:45'],
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('playback-copy-code')), findsNothing);
    expect(find.text('未识别面单'), findsOneWidget);
  });

  testWidgets('未备份时用警示色提示', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecordingInfoCard(
            code: 'JD0001',
            codeCopyable: true,
            recordedAt: '9月13日 19:19',
            metadata: <String>['00:45'],
            backupLabel: '未备份，仅在本机',
            backupHighlighted: true,
          ),
        ),
      ),
    );

    expect(find.text('未备份，仅在本机'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
  });

  testWidgets('卡片底部可放订单信息入口', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordingInfoCard(
            code: 'JD0001',
            codeCopyable: true,
            recordedAt: '9月13日 19:19',
            metadata: const <String>['00:45'],
            trailing: TextButton(
              onPressed: () => taps++,
              child: const Text('查看订单'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('查看订单'));
    expect(taps, 1);
  });
}
