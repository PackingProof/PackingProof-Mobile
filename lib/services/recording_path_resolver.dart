import 'dart:io';

import 'package:path/path.dart' as p;

/// 录像路径解析结果。
class RecordingPathResolution {
  const RecordingPathResolution({
    required this.storedPath,
    required this.resolvedPath,
    required this.attemptedPaths,
  });

  final String storedPath;

  /// 实际可用的录像文件路径；所有尝试失败时为 null。
  final String? resolvedPath;

  /// 按顺序尝试过的候选路径（不含目录搜索）。
  final List<String> attemptedPaths;

  bool get found => resolvedPath != null;

  /// 找到的路径与数据库保存的路径不一致（需要修复数据库）。
  bool get repaired => found && resolvedPath != storedPath;
}

/// 针对“数据库里保存的绝对路径在部分手机（如鸿蒙）上失效”的容错解析。
///
/// 优先按原路径判断；失败后依次尝试等价前缀、按当前录像根目录重建、
/// 以及受限的按文件名搜索。整个过程只读文件系统，不修改任何数据。
class RecordingPathResolver {
  RecordingPathResolver(this.recordingsRoot);

  /// 当前录像根目录（<应用文档目录>/recordings）。
  final String recordingsRoot;

  static const int maximumSearchEntries = 2000;
  static const int maximumSearchDepth = 3;

  Future<RecordingPathResolution> resolve(String storedPath) async {
    final RecordingPathResolution? direct = _resolveDirect(storedPath);
    if (direct != null) return direct;
    final String? searched = await _searchByBasename(storedPath);
    return RecordingPathResolution(
      storedPath: storedPath,
      resolvedPath: searched,
      attemptedPaths: _candidatePaths(storedPath),
    );
  }

  Future<Map<String, RecordingPathResolution>> resolveBatch(
    Iterable<String> storedPaths,
  ) async {
    final List<String> paths = storedPaths
        .where((String path) => path.trim().isNotEmpty)
        .toSet()
        .toList(growable: false);
    final Map<String, RecordingPathResolution> results =
        <String, RecordingPathResolution>{};
    final List<String> unresolved = <String>[];
    for (final String storedPath in paths) {
      final RecordingPathResolution? direct = _resolveDirect(storedPath);
      if (direct != null) {
        results[storedPath] = direct;
      } else {
        unresolved.add(storedPath);
      }
    }
    if (unresolved.isEmpty) return results;

    final Map<String, String> basenameIndex = await _buildBasenameIndex();
    for (final String storedPath in unresolved) {
      results[storedPath] = RecordingPathResolution(
        storedPath: storedPath,
        resolvedPath: _searchByBasenameWithIndex(storedPath, basenameIndex),
        attemptedPaths: _candidatePaths(storedPath),
      );
    }
    return results;
  }

  List<String> _candidatePaths(String storedPath) => <String>[
    storedPath,
    ...alternateAppPrivateCandidates(storedPath),
    if (relativeRecordingTail(storedPath) case final String tail)
      p.normalize(p.join(recordingsRoot, tail)),
  ];

  RecordingPathResolution? _resolveDirect(String storedPath) {
    final List<String> attempted = <String>[];
    for (final String candidate in _candidatePaths(storedPath)) {
      attempted.add(candidate);
      if (File(candidate).existsSync()) {
        return RecordingPathResolution(
          storedPath: storedPath,
          resolvedPath: candidate,
          attemptedPaths: attempted,
        );
      }
    }
    return null;
  }

  Future<String?> _searchByBasename(String storedPath) async {
    return _searchByBasenameWithIndex(storedPath, await _buildBasenameIndex());
  }

  Future<Map<String, String>> _buildBasenameIndex() async {
    final Map<String, String> index = <String, String>{};
    final Directory root = Directory(recordingsRoot);
    if (!await root.exists()) return index;
    var visited = 0;
    await for (final FileSystemEntity entry in root.list(
      recursive: true,
      followLinks: false,
    )) {
      if (++visited > maximumSearchEntries) break;
      if (entry is! File) continue;
      final String basename = p.basename(entry.path);
      index.putIfAbsent(basename, () => entry.path);
    }
    return index;
  }

  String? _searchByBasenameWithIndex(
    String storedPath,
    Map<String, String> basenameIndex,
  ) {
    final String basename = _basenameAny(storedPath);
    if (basename.isEmpty) return null;
    final String? path = basenameIndex[basename];
    if (path == null) return null;
    final String relative = path
        .substring(recordingsRoot.length)
        .replaceAll('\\', '/');
    final int depth = relative
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .length;
    if (depth > maximumSearchDepth) return null;
    if (path.contains('${p.separator}.pending${p.separator}')) return null;
    return path;
  }
}

/// 生成 Android 应用私有目录的等价路径：
/// `/data/user/0/<包名>/…` 与 `/data/data/<包名>/…` 互换。
List<String> alternateAppPrivateCandidates(String path) {
  const String userRoot = '/data/user/0/';
  const String dataRoot = '/data/data/';
  if (path.startsWith(userRoot)) {
    return <String>['$dataRoot${path.substring(userRoot.length)}'];
  }
  if (path.startsWith(dataRoot)) {
    return <String>['$userRoot${path.substring(dataRoot.length)}'];
  }
  return const <String>[];
}

/// 提取录像路径中 `recordings/` 之后的相对部分，用于按当前根目录重建路径。
/// 例如 `/data/user/0/pkg/app_flutter/recordings/2026-01-01/a.mp4`
/// 返回 `2026-01-01/a.mp4`；不含 `recordings/` 时返回 null。
String? relativeRecordingTail(String path) {
  const String marker = '/recordings/';
  final int index = path.indexOf(marker);
  if (index < 0) return null;
  return path.substring(index + marker.length);
}

String _basenameAny(String path) {
  final int slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}
