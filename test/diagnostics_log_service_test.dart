import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/diagnostics_log_service.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('runtime_log_test_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('并发写入串行落盘且每行都是合法 JSON', () async {
    final DiagnosticsLogService service = DiagnosticsLogService(
      rootProvider: () async => temp,
      maximumEntries: 100,
    );
    await Future.wait(
      List<Future<void>>.generate(
        30,
        (int index) => service.log(
          kind: 'event',
          extra: <String, Object?>{'index': index},
        ),
      ),
    );

    final File file = File('${temp.path}/diagnostics/runtime.jsonl');
    final List<String> lines = await file.readAsLines();
    expect(lines, hasLength(30));
    final List<int> indexes = lines.map((String line) {
      final Map<String, Object?> entry =
          jsonDecode(line) as Map<String, Object?>;
      expect(entry['kind'], 'event');
      return entry['index']! as int;
    }).toList()..sort();
    expect(indexes, List<int>.generate(30, (int index) => index));
  });

  test('超过上限只保留最近条目', () async {
    final DiagnosticsLogService service = DiagnosticsLogService(
      rootProvider: () async => temp,
      maximumEntries: 3,
    );
    for (int index = 0; index < 5; index++) {
      await service.log(
        kind: 'event',
        extra: <String, Object?>{'index': index},
      );
    }

    final File file = File('${temp.path}/diagnostics/runtime.jsonl');
    final List<String> lines = await file.readAsLines();
    expect(lines, hasLength(3));
    final Map<String, Object?> last =
        jsonDecode(lines.last) as Map<String, Object?>;
    expect(last['index'], 4);
  });
}
