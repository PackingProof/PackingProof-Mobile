import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 录像路径解析失败的诊断记录。
///
/// 写入有界 JSONL 文件，供现场用户在“关于”页导出回传，帮助确认
/// 鸿蒙等机型上“录像不在本机”提示的具体触发机制。
class RecordingPathDiagnostics {
  RecordingPathDiagnostics({Future<Directory> Function()? rootProvider})
    : _rootProvider = rootProvider ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _rootProvider;

  static const int maximumEntries = 200;
  Future<void> _pending = Future<void>.value();

  Future<File> logFile() async {
    final Directory root = await _rootProvider();
    final Directory directory = Directory(p.join(root.path, 'diagnostics'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'path_fix.jsonl'));
  }

  Future<void> recordMissing({
    required String storedPath,
    required String recordingsRoot,
    required List<String> attemptedPaths,
  }) async {
    developer.log('录像路径解析失败：$storedPath', name: 'PackingProof.PathFix');
    await _appendEntry(<String, Object?>{
      'kind': 'path',
      'storedPath': storedPath,
      'recordingsRoot': recordingsRoot,
      'attemptedPaths': attemptedPaths,
    });
  }

  Future<void> recordPlaybackFailure({
    required String source,
    required String sessionId,
    required String pathOrUri,
    int? fileSizeBytes,
    String? videoMime,
    String? deviceManufacturer,
    String? deviceModel,
    int? deviceSdkInt,
    bool? deviceHasHevcDecoder,
    bool? deviceHasAvcDecoder,
    required String errorCode,
    required String errorMessage,
    int? httpStatus,
    String? hostErrorCode,
    String? hostError,
    String? probeError,
  }) async {
    developer.log(
      '录像播放失败：$errorCode $errorMessage',
      name: 'PackingProof.Playback',
    );
    await _appendEntry(<String, Object?>{
      'kind': 'playback',
      'source': source,
      'sessionId': sessionId,
      'pathOrUri': pathOrUri,
      'fileSizeBytes': ?fileSizeBytes,
      'videoMime': ?videoMime,
      'deviceManufacturer': ?deviceManufacturer,
      'deviceModel': ?deviceModel,
      'deviceSdkInt': ?deviceSdkInt,
      'deviceHasHevcDecoder': ?deviceHasHevcDecoder,
      'deviceHasAvcDecoder': ?deviceHasAvcDecoder,
      'errorCode': errorCode,
      'errorMessage': errorMessage,
      'httpStatus': ?httpStatus,
      'hostErrorCode': ?hostErrorCode,
      'hostError': ?hostError,
      'probeError': ?probeError,
    });
  }

  Future<void> _appendEntry(Map<String, Object?> entry) {
    final Future<void> next = _pending.then((_) => _appendEntryNow(entry));
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> _appendEntryNow(Map<String, Object?> entry) async {
    try {
      final File file = await logFile();
      final List<String> lines = await file.exists()
          ? await file.readAsLines()
          : <String>[];
      lines.add(
        jsonEncode(<String, Object?>{
          'ts': DateTime.now().toIso8601String(),
          ...entry,
        }),
      );
      final List<String> bounded = lines.length > maximumEntries
          ? lines.sublist(lines.length - maximumEntries)
          : lines;
      await file.writeAsString('${bounded.join('\n')}\n');
    } on Object {
      // 诊断失败不得影响录像列表正常使用。
    }
  }

  Future<String?> exportText() async {
    try {
      final Directory root = await _rootProvider();
      final File file = File(
        p.join(root.path, 'diagnostics', 'path_fix.jsonl'),
      );
      if (!await file.exists()) return null;
      final List<String> lines = await file.readAsLines();
      if (lines.isEmpty) return null;
      return lines.join('\n');
    } on Object {
      return null;
    }
  }
}
