import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/widgets/recording_detail_card.dart';

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
  });

  test('时长负数按零处理', () {
    expect(formatRecordingDuration(const Duration(seconds: -5)), '00:00');
  });

  test('文件大小按量级切换单位', () {
    expect(formatRecordingSize(0), '未知');
    expect(formatRecordingSize(512), '512 B');
    expect(formatRecordingSize(2048), '2 KB');
    expect(formatRecordingSize(12 * 1024 * 1024), '12 MB');
    expect(formatRecordingSize(3 * 1024 * 1024 * 1024), '3.00 GB');
  });

  testWidgets('详情卡片逐行展示标签与取值', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecordingDetailCard(
            details: <RecordingDetail>[
              RecordingDetail('来源', '手机'),
              RecordingDetail('时长', '00:45'),
              RecordingDetail('备份', '已备份到电脑', emphasized: true),
            ],
          ),
        ),
      ),
    );

    expect(find.text('来源'), findsOneWidget);
    expect(find.text('手机'), findsOneWidget);
    expect(find.text('时长'), findsOneWidget);
    expect(find.text('00:45'), findsOneWidget);
    expect(find.text('备份'), findsOneWidget);
    expect(find.text('已备份到电脑'), findsOneWidget);
  });

  testWidgets('详情卡片在底部展示补充入口', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordingDetailCard(
            details: const <RecordingDetail>[RecordingDetail('来源', '电脑')],
            trailing: TextButton(
              onPressed: () => taps++,
              child: const Text('查看订单'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('查看订单'), findsOneWidget);
    await tester.tap(find.text('查看订单'));
    expect(taps, 1);
  });

  testWidgets('没有内容时不渲染卡片', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: RecordingDetailCard(details: <RecordingDetail>[])),
      ),
    );

    expect(find.byType(Padding), findsNothing);
  });
}
