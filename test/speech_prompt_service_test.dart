import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/services/speech_prompt_service.dart';

void main() {
  test('固定提示优先播放内置 Edge 语音', () async {
    final _FakeSpeechOutput output = _FakeSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueue(SpeechPrompt.recordingFailed);
    await service.waitUntilIdle();

    expect(output.assetPaths, <String>['audio/tts/recording_failed.mp3']);
    expect(output.systemTexts, isEmpty);
    await service.dispose();
  });

  test('固定语音资源损坏时回退离线系统语音', () async {
    final _FakeSpeechOutput output = _FakeSpeechOutput(failAssets: true);
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueue(SpeechPrompt.recordingFailed);
    await service.waitUntilIdle();

    expect(output.systemTexts, <String>['录制失败']);
    expect(output.offlineOnlyRequests, <bool>[true]);
    await service.dispose();
  });

  test('动态订单提示使用离线系统语音', () async {
    final _FakeSpeechOutput output = _FakeSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueueText('卖家备注，核对颜色');
    await service.waitUntilIdle();

    expect(output.systemTexts, <String>['卖家备注，核对颜色']);
    expect(output.offlineOnlyRequests, <bool>[true]);
    await service.dispose();
  });

  test('备注播报先播放提示音', () async {
    final _FakeSpeechOutput output = _FakeSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueueText('卖家备注，核对颜色', playRemarkTone: true);
    await service.waitUntilIdle();

    expect(output.remarkToneCount, 1);
    expect(output.systemTexts, <String>['卖家备注，核对颜色']);
    await service.dispose();
  });

  test('测试订单使用内置语音并保留备注提示音', () async {
    final _FakeSpeechOutput output = _FakeSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueue(SpeechPrompt.testOrderReceived);
    await service.waitUntilIdle();

    expect(output.remarkToneCount, 1);
    expect(output.assetPaths, <String>['audio/tts/test_order_received.mp3']);
    expect(output.systemTexts, isEmpty);
    await service.dispose();
  });

  test('退款播报先播放一次电脑端同款工业警报音', () async {
    final _FakeSpeechOutput output = _FakeSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    for (int index = 0; index < 2; index++) {
      service.enqueueText(
        '退款提醒，退款完成',
        priority: SpeechPromptPriority.warning,
        incidentKey: 'order-refund:TRACK-1:ORDER-1:SUCCESS',
        playIndustrialAlarm: true,
      );
    }
    await service.waitUntilIdle();

    expect(output.industrialAlarmCount, 1);
    expect(output.warningToneCount, 0);
    expect(output.remarkToneCount, 0);
    expect(output.systemTexts, <String>['退款提醒，退款完成']);
    await service.dispose();
  });

  test('重复单号使用电脑端同款普通警告音', () async {
    final _FakeSpeechOutput output = _FakeSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueue(
      SpeechPrompt.duplicateOrderWarning,
      incidentKey: 'duplicate-order-number:TRACK-1',
    );
    await service.waitUntilIdle();

    expect(output.warningToneCount, 1);
    expect(output.industrialAlarmCount, 0);
    expect(output.assetPaths, <String>[
      'audio/tts/duplicate_order_warning.mp3',
    ]);
    expect(output.systemTexts, isEmpty);
    await service.dispose();
  });

  test('提示音播放失败时仍继续语音播报', () async {
    final _FakeSpeechOutput output = _FakeSpeechOutput(failWarningTone: true);
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueueText('警告，重复单号，请确认', playWarningTone: true);
    await service.waitUntilIdle();

    expect(output.warningToneCount, 1);
    expect(output.systemTexts, <String>['警告，重复单号，请确认']);
    await service.dispose();
  });

  test('同一故障恢复前只播报一次', () async {
    final _FakeSpeechOutput output = _FakeSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueue(SpeechPrompt.cameraDisconnected, incidentKey: 'camera');
    service.enqueue(SpeechPrompt.cameraDisconnected, incidentKey: 'camera');
    await service.waitUntilIdle();
    expect(output.assetPaths, hasLength(1));

    service.resolveIncident('camera');
    service.enqueue(SpeechPrompt.cameraDisconnected, incidentKey: 'camera');
    await service.waitUntilIdle();
    expect(output.assetPaths, hasLength(2));
    await service.dispose();
  });

  test('重复单号警告在释放 incident 后可再次播报', () async {
    final _FakeSpeechOutput output = _FakeSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueue(
      SpeechPrompt.duplicateOrderWarning,
      incidentKey: 'duplicate-order-number:TRACK-1',
    );
    service.enqueue(
      SpeechPrompt.duplicateOrderWarning,
      incidentKey: 'duplicate-order-number:TRACK-1',
    );
    await service.waitUntilIdle();
    expect(output.assetPaths, hasLength(1));

    service.resolveIncident('duplicate-order-number:TRACK-1');
    service.enqueue(
      SpeechPrompt.duplicateOrderWarning,
      incidentKey: 'duplicate-order-number:TRACK-1',
    );
    await service.waitUntilIdle();
    expect(output.assetPaths, hasLength(2));
    await service.dispose();
  });

  test('开始录制会打断仍在播放的模式播报', () async {
    final _InterruptibleSpeechOutput output = _InterruptibleSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueue(SpeechPrompt.shippingMode);
    while (output.assetPaths.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    service.enqueue(SpeechPrompt.recordingStarted);
    await service.waitUntilIdle();

    expect(output.assetPaths, <String>[
      'audio/tts/shipping_mode.mp3',
      'audio/tts/recording_started.mp3',
    ]);
    expect(output.stopCount, greaterThanOrEqualTo(1));
    await service.dispose();
  });

  test('识别短滴声使用电脑端同款单音波形', () {
    final Uint8List wav = DeviceSpeechOutput.buildShortBeepWav();
    expect(wav.length, greaterThan(44));
    expect(wav.sublist(0, 4), <int>[82, 73, 70, 70]); // RIFF
    expect(wav.sublist(8, 12), <int>[87, 65, 86, 69]); // WAVE
    expect(wav.sublist(12, 16), <int>[102, 109, 116, 32]); // fmt
    expect(wav.sublist(36, 40), <int>[100, 97, 116, 97]); // data
    // 80ms @ 22050Hz 单声道 16bit
    expect((wav.length - 44) ~/ 2, 22050 * 80 ~/ 1000);
  });

  test('识别短滴声跟随语音提示开关且不打断播报', () async {
    final _InterruptibleSpeechOutput output = _InterruptibleSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.playShortBeep();
    expect(output.shortBeepCount, 1);
    expect(output.stopCount, 0);

    await service.setEnabled(false);
    service.playShortBeep();
    expect(output.shortBeepCount, 1);
    await service.dispose();
  });

  test('clear 清空积压并打断当前播放', () async {
    final _BlockingSpeechOutput output = _BlockingSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueue(SpeechPrompt.recordingFailed);
    while (output.assetPaths.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    service.enqueue(SpeechPrompt.recordingFailed);

    await service.clear();
    await service.waitUntilIdle();

    expect(output.assetPaths, <String>['audio/tts/recording_failed.mp3']);
    expect(output.stopCount, greaterThanOrEqualTo(1));
    await service.dispose();
  });

  test('clear 后可继续播放新语音', () async {
    final _FakeSpeechOutput output = _FakeSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    await service.clear();
    service.enqueue(SpeechPrompt.recordingFailed);
    await service.waitUntilIdle();

    expect(output.assetPaths, <String>['audio/tts/recording_failed.mp3']);
    await service.dispose();
  });

  test('连续 clear 复用同一个清理流程', () async {
    final _DelayedStopOutput output = _DelayedStopOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    final Future<void> first = service.clear();
    final Future<void> second = service.clear();

    output.unblockStop();
    await Future.wait(<Future<void>>[first, second]);

    expect(output.stopCount, 1);
    await service.dispose();
  });

  test('clear 后 enqueue 停止语音仍能播放', () async {
    final _BlockingSpeechOutput output = _BlockingSpeechOutput();
    final SpeechPromptService service = SpeechPromptService(output: output);

    service.enqueue(SpeechPrompt.recordingFailed);
    while (output.assetPaths.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }

    await service.clear();
    service.enqueue(SpeechPrompt.recordingStopped);
    await service.waitUntilIdle();

    expect(output.assetPaths, contains('audio/tts/recording_stopped.mp3'));
    await service.dispose();
  });
}

class _FakeSpeechOutput implements SpeechOutput {
  _FakeSpeechOutput({this.failAssets = false, this.failWarningTone = false});

  final bool failAssets;
  final bool failWarningTone;
  final List<String> assetPaths = <String>[];
  final List<String> systemTexts = <String>[];
  final List<bool> offlineOnlyRequests = <bool>[];
  int remarkToneCount = 0;
  int warningToneCount = 0;
  int industrialAlarmCount = 0;
  int shortBeepCount = 0;

  @override
  Future<void> playAsset(String assetPath) async {
    assetPaths.add(assetPath);
    if (failAssets) throw StateError('asset unavailable');
  }

  @override
  Future<void> playRemarkTone() async => remarkToneCount++;

  @override
  Future<void> playWarningTone() async {
    warningToneCount++;
    if (failWarningTone) throw StateError('warning tone unavailable');
  }

  @override
  Future<void> playIndustrialAlarm() async => industrialAlarmCount++;

  @override
  Future<void> playShortBeep() async => shortBeepCount++;

  @override
  Future<void> speakSystem(String text, {bool offlineOnly = false}) async {
    systemTexts.add(text);
    offlineOnlyRequests.add(offlineOnly);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _InterruptibleSpeechOutput extends _FakeSpeechOutput {
  final Completer<void> _modePlayback = Completer<void>();
  int stopCount = 0;

  @override
  Future<void> playAsset(String assetPath) async {
    await super.playAsset(assetPath);
    if (assetPath == 'audio/tts/shipping_mode.mp3') {
      await _modePlayback.future;
    }
  }

  @override
  Future<void> stop() async {
    stopCount++;
    if (!_modePlayback.isCompleted) _modePlayback.complete();
  }
}

class _BlockingSpeechOutput extends _FakeSpeechOutput {
  final Completer<void> _blocker = Completer<void>();
  int stopCount = 0;

  @override
  Future<void> playAsset(String assetPath) async {
    await super.playAsset(assetPath);
    await _blocker.future;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    if (!_blocker.isCompleted) {
      _blocker.complete();
    }
  }
}

class _DelayedStopOutput extends _FakeSpeechOutput {
  final Completer<void> _stopBlocker = Completer<void>();
  int stopCount = 0;

  @override
  Future<void> stop() async {
    stopCount++;
    await _stopBlocker.future;
  }

  void unblockStop() {
    if (!_stopBlocker.isCompleted) {
      _stopBlocker.complete();
    }
  }
}
