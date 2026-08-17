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

  test('运行时元数据只加载一次且缺失字段稳定为 null', () async {
    int loadCount = 0;
    final DiagnosticsLogService service = DiagnosticsLogService(
      rootProvider: () async => temp,
      maximumEntries: 10,
      runtimeMetadataLoader: () async {
        loadCount++;
        return <String, Object?>{
          'appVersion': '0.5.22',
          'appBuildNumber': 11029,
          'buildRevision': 'abc1234',
          'buildTimestamp': null,
        };
      },
    );
    await service.log(kind: 'first');
    await service.log(kind: 'second');

    expect(loadCount, 1);
    final File file = File('${temp.path}/diagnostics/runtime.jsonl');
    for (final String line in await file.readAsLines()) {
      final Map<String, Object?> entry =
          jsonDecode(line) as Map<String, Object?>;
      expect(entry['appVersion'], '0.5.22');
      expect(entry['appBuildNumber'], 11029);
      expect(entry['buildRevision'], 'abc1234');
      expect(entry.containsKey('buildTimestamp'), isTrue);
      expect(entry['buildTimestamp'], isNull);
    }
  });

  test('元数据加载失败时仍写入稳定空字段', () async {
    final DiagnosticsLogService service = DiagnosticsLogService(
      rootProvider: () async => temp,
      maximumEntries: 10,
      runtimeMetadataLoader: () async => throw StateError('missing'),
    );
    await service.log(kind: 'event');

    final File file = File('${temp.path}/diagnostics/runtime.jsonl');
    final Map<String, Object?> entry =
        jsonDecode((await file.readAsLines()).single) as Map<String, Object?>;
    expect(entry['appVersion'], isNull);
    expect(entry['appBuildNumber'], isNull);
    expect(entry['buildRevision'], isNull);
    expect(entry['buildTimestamp'], isNull);
  });
}
