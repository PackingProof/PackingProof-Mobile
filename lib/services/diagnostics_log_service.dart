import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/app_build_config.dart';

/// 统一运行日志：低频事件写入 `diagnostics/runtime.jsonl`。
///
/// 与相机心跳（camera.jsonl）、路径/播放诊断（path_fix.jsonl）分开，
/// 导出时合并。所有追加通过 future 链串行化，避免并发写坏文件。
class DiagnosticsLogService {
  DiagnosticsLogService({
    Future<Directory> Function()? rootProvider,
    this.maximumEntries = 500,
    // Named parameters cannot use a private initializing formal.
    // ignore: prefer_initializing_formals
    Future<Map<String, Object?>> Function()? runtimeMetadataLoader,
  }) : _rootProvider = rootProvider ?? getApplicationDocumentsDirectory,
       // ignore: prefer_initializing_formals
       _runtimeMetadataLoader =
           runtimeMetadataLoader ?? _defaultRuntimeMetadataLoader;

  final Future<Directory> Function() _rootProvider;
  final int maximumEntries;
  final Future<Map<String, Object?>> Function()? _runtimeMetadataLoader;
  Future<void> _pending = Future<void>.value();
  Future<Map<String, Object?>>? _runtimeMetadata;

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
      final Map<String, Object?> metadata = await _loadRuntimeMetadata();
      final List<String> lines = await file.exists()
          ? await file.readAsLines()
          : <String>[];
      lines.add(
        jsonEncode(<String, Object?>{
          ...metadata,
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

  Future<Map<String, Object?>> _loadRuntimeMetadata() {
    final Future<Map<String, Object?>>? existing = _runtimeMetadata;
    if (existing != null) {
      return existing;
    }
    final Future<Map<String, Object?>> loaded =
        (_runtimeMetadataLoader?.call() ??
                Future<Map<String, Object?>>.value(_fallbackRuntimeMetadata()))
            .then<Map<String, Object?>>(
              (Map<String, Object?> value) => Map<String, Object?>.from(value),
              onError: (Object _, StackTrace _) => _fallbackRuntimeMetadata(),
            );
    _runtimeMetadata = loaded;
    return loaded;
  }

  Map<String, Object?> _fallbackRuntimeMetadata() => const <String, Object?>{
    'appVersion': null,
    'appBuildNumber': null,
    'buildRevision': null,
    'buildTimestamp': null,
  };
}

Future<Map<String, Object?>> _defaultRuntimeMetadataLoader() async {
  String? appVersion;
  int? appBuildNumber;
  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    appVersion = info.version;
    appBuildNumber = int.tryParse(info.buildNumber);
  } on Object {
    // 版本信息失败时仍返回稳定空字段，不能阻塞业务日志。
  }
  const AppBuildConfig build = AppBuildConfig.environment;
  return <String, Object?>{
    'appVersion': appVersion,
    'appBuildNumber': appBuildNumber,
    'buildRevision': build.buildRevision.isEmpty ? null : build.buildRevision,
    'buildTimestamp': build.buildTimestamp.isEmpty
        ? null
        : build.buildTimestamp,
  };
}
