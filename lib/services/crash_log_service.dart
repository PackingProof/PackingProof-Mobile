import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 全局未捕获异常记录：写入 `diagnostics/crash.jsonl`，随诊断日志一起导出。
///
/// 只捕获 Dart/Flutter 侧未捕获异常；原生崩溃（SIGABRT/SIGSEGV）需要
/// Crashlytics/Sentry 这类原生崩溃 SDK，不在本服务范围。
class CrashLogService {
  CrashLogService({
    Future<Directory> Function()? rootProvider,
    this.maximumEntries = 50,
  }) : _rootProvider = rootProvider ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _rootProvider;
  final int maximumEntries;
  Future<void> _pending = Future<void>.value();

  Future<void> record(Object error, StackTrace stack) {
    final Future<void> next = _pending.then((_) => _append(error, stack));
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> _append(Object error, StackTrace stack) async {
    try {
      final Directory root = await _rootProvider();
      final Directory directory = Directory(p.join(root.path, 'diagnostics'));
      await directory.create(recursive: true);
      final File file = File(p.join(directory.path, 'crash.jsonl'));
      final List<String> lines = await file.exists()
          ? await file.readAsLines()
          : <String>[];
      lines.add(
        jsonEncode(<String, Object?>{
          'ts': DateTime.now().toIso8601String(),
          'error': '$error',
          'stack': stack.toString(),
        }),
      );
      final List<String> bounded = lines.length > maximumEntries
          ? lines.sublist(lines.length - maximumEntries)
          : lines;
      await file.writeAsString('${bounded.join('\n')}\n');
    } on Object {
      // 崩溃记录失败不得影响业务。
    }
  }
}
