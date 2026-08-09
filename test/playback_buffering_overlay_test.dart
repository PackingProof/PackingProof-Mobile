import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/screens/video_playback_screen.dart';

void main() {
  testWidgets('缓冲覆盖层显示转圈与缓冲中文案', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlaybackBufferingOverlay(
            key: Key('playback-buffering-indicator'),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('playback-buffering-indicator')),
      findsOneWidget,
    );
    expect(find.text('缓冲中…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
