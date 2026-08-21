import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';

void main() {
  test('dispose 等待排队的数据库写入后再关闭句柄', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'packing-proof-repository-lifecycle-',
    );
    final SessionRepository repository = SessionRepository(rootDirectory: root);
    await repository.initialize();
    final DateTime startedAt = DateTime(2026, 8, 21, 10);
    final List<Future<List<RecordingSession>>> writes = List.generate(
      30,
      (int index) => repository.addSession(
        RecordingSession(
          id: 'session-$index',
          filePath: '${root.path}/recording-$index.mp4',
          startedAt: startedAt.add(Duration(seconds: index)),
          endedAt: startedAt.add(Duration(seconds: index + 1)),
          markers: const <Never>[],
        ),
      ),
    );

    await repository.dispose();
    await Future.wait(writes);
    await repository.dispose();

    await root.delete(recursive: true);
    expect(await root.exists(), isFalse);
  });
}
