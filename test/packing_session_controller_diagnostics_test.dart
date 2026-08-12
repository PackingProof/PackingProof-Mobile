import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/controllers/packing_session_controller.dart';
import 'package:packing_proof_mobile/models/speech_prompt.dart';
import 'package:packing_proof_mobile/services/camera_diagnostics_service.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';
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
    if (!await root.exists()) {
      return;
    }
    // Windows 上日志/诊断服务可能仍有文件句柄未释放，删除临时目录会偶发
    // “目录不是空的”；重试几次避免打包脚本里的全量测试被误判失败。
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        await root.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
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

  test('任意状态识别条码都会触发独立滴声且同码不重复', () async {
    final _FakeSpeechSink speech = _FakeSpeechSink();
    final PackingSessionController controller = PackingSessionController(
      repository: testRepository(root),
      speechService: speech,
      runtimeLog: DiagnosticsLogService(rootProvider: () async => root),
      cameraDiagnostics: CameraDiagnosticsService(
        rootProvider: () async => root,
      ),
    );

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'CLEAR', area: 100),
    ]);
    expect(speech.beepCount, 1);
    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'CLEAR', area: 100),
    ]);
    expect(speech.beepCount, 1);
    controller.handleNativeBarcodeFrameForTesting(
      const <NativeBarcodeCandidate>[],
    );
    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'CLEAR', area: 100),
    ]);
    expect(speech.beepCount, 2);

    controller.handleNativeBarcodeFrameForTesting(<NativeBarcodeCandidate>[
      const NativeBarcodeCandidate(value: 'YT123456789012', area: 200),
    ]);
    expect(speech.beepCount, 3);
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
  int beepCount = 0;

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
  Future<void> dispose() async {}
}
