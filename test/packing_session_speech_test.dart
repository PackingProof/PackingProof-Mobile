import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';

import 'test_repository.dart';
import 'package:packing_proof_mobile/services/max_volume_service.dart';
import 'package:packing_proof_mobile/services/speech_prompt_service.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('packing-proof-controller-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('摄像头未就绪时保持静音', () async {
    final _FakeSpeechSink speech = _FakeSpeechSink();
    final _FakeMaxVolumeSink volume = _FakeMaxVolumeSink();
    final PackingSessionController controller = PackingSessionController(
      repository: testRepository(root),
      speechService: speech,
      maxVolumeService: volume,
    );

    await controller.startWork();

    expect(speech.prompts, isEmpty);
    expect(volume.beginCount, 0);
    expect(volume.boostCount, 0);
  });

  test('语音开关同步服务并持久化', () async {
    final _FakeSpeechSink speech = _FakeSpeechSink();
    final SessionRepository repository = testRepository(root);
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: speech,
    );

    await controller.setSpeechEnabled(false);

    expect(controller.speechEnabled, isFalse);
    expect(speech.enabled, isFalse);
    expect((await repository.loadSettings()).speechEnabled, isFalse);
  });

  test('订单播报开关独立持久化', () async {
    final SessionRepository repository = testRepository(root);
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
    );

    await controller.setOrderSpeechEnabled(false);

    expect(controller.orderSpeechEnabled, isFalse);
    expect((await repository.loadSettings()).orderSpeechEnabled, isFalse);
  });

  test('最大音量开关同步服务并持久化', () async {
    final _FakeMaxVolumeSink volume = _FakeMaxVolumeSink();
    final SessionRepository repository = testRepository(root);
    final PackingSessionController controller = PackingSessionController(
      repository: repository,
      speechService: _FakeSpeechSink(),
      maxVolumeService: volume,
    );

    await controller.setMaxVolumeEnabled(false);
    expect(controller.maxVolumeEnabled, isFalse);
    expect(volume.disableCount, 1);
    expect((await repository.loadSettings()).maxVolumeEnabled, isFalse);

    await controller.setMaxVolumeEnabled(true);
    expect(volume.beginCount, 0);
    expect((await repository.loadSettings()).maxVolumeEnabled, isTrue);
  });
}

class _FakeMaxVolumeSink implements MaxVolumeSink {
  int beginCount = 0;
  int endCount = 0;
  int disableCount = 0;
  int boostCount = 0;

  @override
  Future<void> beginSession() async => beginCount++;

  @override
  Future<void> endSession() async => endCount++;

  @override
  Future<void> disable() async => disableCount++;

  @override
  Future<void> boost() async => boostCount++;

  @override
  Future<void> dispose() async {}
}

class _FakeSpeechSink implements SpeechPromptSink {
  final List<SpeechPrompt> prompts = <SpeechPrompt>[];
  int beepCount = 0;
  int clearCount = 0;

  @override
  bool enabled = true;

  @override
  void enqueue(SpeechPrompt prompt, {String? incidentKey}) {
    if (enabled) {
      prompts.add(prompt);
    }
  }

  @override
  Future<void> setEnabled(bool value) async => enabled = value;

  @override
  Future<void> preview() async {}

  @override
  void playShortBeep() {
    if (enabled) {
      beepCount++;
    }
  }

  @override
  void resetIncidents() {}

  @override
  void resolveIncident(String incidentKey) {}

  @override
  Future<void> clear() async {
    clearCount++;
  }

  @override
  Future<void> dispose() async {}
}
