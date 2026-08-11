import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/services/camera_diagnostics_service.dart';
import 'package:packing_proof_mobile/services/diagnostics_log_service.dart';
import 'package:packing_proof_mobile/services/speech_prompt_service.dart';

import 'test_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'packing-proof-controller-diag-',
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('初始化失败记录 init_failed 诊断事件', () async {
    final PackingSessionController controller = PackingSessionController(
      repository: testRepository(root),
      speechService: _FakeSpeechSink(),
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    await controller.initialize();

    expect(controller.phase, PackingSessionPhase.error);
    final File file = File('${root.path}/diagnostics/camera.jsonl');
    final String content = await _waitForInitFailed(file);
    expect(content, contains('"kind":"init_failed"'));
    expect(content, contains('"code":"unknown"'));
  });
}

Future<String> _waitForInitFailed(
  File file, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) {
      final String content = await file.readAsString();
      if (content.contains('"kind":"init_failed"')) {
        return content;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('camera.jsonl 未在 $timeout 内记录 init_failed 事件');
}

class _FakeSpeechSink implements SpeechPromptSink {
  final List<SpeechPrompt> prompts = <SpeechPrompt>[];

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
  void resetIncidents() {}

  @override
  void resolveIncident(String incidentKey) {}

  @override
  Future<void> dispose() async {}
}
