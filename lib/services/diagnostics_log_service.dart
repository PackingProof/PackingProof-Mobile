import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 统一运行日志：低频事件写入 `diagnostics/runtime.jsonl`。
///
/// 与相机心跳（camera.jsonl）、路径/播放诊断（path_fix.jsonl）分开，
/// 导出时合并。所有追加通过 future 链串行化，避免并发写坏文件。
class DiagnosticsLogService {
  DiagnosticsLogService({
    Future<Directory> Function()? rootProvider,
    this.maximumEntries = 500,
  }) : _rootProvider = rootProvider ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _rootProvider;
  final int maximumEntries;
  Future<void> _pending = Future<void>.value();

  Future<File> logFile() async {
    final Directory root = await _rootProvider();
    final Directory directory = Directory(p.join(root.path, 'diagnostics'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'runtime.jsonl'));
  }

  Future<void> log({
    required String kind,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    final Future<void> next = _pending.then((_) => _append(kind, extra));
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> _append(String kind, Map<String, Object?> extra) async {
    try {
      final File file = await logFile();
      final List<String> lines = await file.exists()
          ? await file.readAsLines()
          : <String>[];
      lines.add(
        jsonEncode(<String, Object?>{
          'ts': DateTime.now().toIso8601String(),
          'kind': kind,
          ...extra,
        }),
      );
      final List<String> bounded = lines.length > maximumEntries
          ? lines.sublist(lines.length - maximumEntries)
          : lines;
      await file.writeAsString('${bounded.join('\n')}\n');
    } on Object {
      // 日志失败绝不影响业务。
    }
  }
}
