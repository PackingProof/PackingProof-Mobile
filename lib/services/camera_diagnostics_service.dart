import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'continuous_camera_service.dart';
import '../platform/generated/platform_api.g.dart';

/// 相机/预览诊断记录。
///
/// 定期通过原生 `getDiagnostics` 轮询相机心跳，把有界 JSONL 写到
/// `diagnostics/camera.jsonl`，供“关于”页导出回传；诊断失败绝不影响
/// 相机与录像工作流。
class CameraDiagnosticsService {
  CameraDiagnosticsService({
    Future<Directory> Function()? rootProvider,
    Future<CameraDiagnosticsSnapshot?> Function()? snapshotLoader,
    this.maximumEntries = 300,
  }) : _rootProvider = rootProvider ?? getApplicationDocumentsDirectory,
       _snapshotLoader = snapshotLoader ?? _nativeSnapshotLoader;

  static const Duration heartbeatInterval = Duration(seconds: 10);
  static const Duration livenessInterval = Duration(seconds: 60);

  /// 心跳去重时只比较这些“状态字段”，忽略会持续变化的计数类指标
  /// （如 previewFrameCount / muxWriteMaxMs），避免永远判成“有变化”。
  static const List<String> _heartbeatStateKeys = <String>[
    'initialized',
    'sessionRunning',
    'disposed',
    'workScanEnabled',
    'pairingScanEnabled',
    'metadataOutputAttached',
    'videoOutputAttached',
    'audioOutputAttached',
    'recordingSpec',
    'videoMime',
    'cameraId',
    'cameraPipelineVersion',
    'stallActive',
    'recordingFallbackMode',
  ];

  final Future<Directory> Function() _rootProvider;
  final Future<CameraDiagnosticsSnapshot?> Function() _snapshotLoader;
  final int maximumEntries;
  Future<void> _pending = Future<void>.value();
  Map<String, Object?>? _lastHeartbeatState;
  DateTime? _lastHeartbeatLoggedAt;

  Future<CameraDiagnosticsSnapshot?> loadSnapshot() async {
    try {
      return await _snapshotLoader();
    } on Object {
      return null;
    }
  }

  Future<void> recordSnapshot({
    required String trigger,
    CameraDiagnosticsSnapshot? snapshot,
  }) async {
    final CameraDiagnosticsSnapshot? current = snapshot ?? await loadSnapshot();
    if (current == null) return;
    if (trigger == 'heartbeat') {
      final Map<String, Object?> state = <String, Object?>{
        for (final String key in _heartbeatStateKeys) key: current.camera[key],
      };
      final bool changed = !mapEquals(_lastHeartbeatState, state);
      final bool livenessDue = _lastHeartbeatLoggedAt == null ||
          DateTime.now().difference(_lastHeartbeatLoggedAt!) >= livenessInterval;
      if (!changed && !livenessDue) {
        return;
      }
      _lastHeartbeatState = state;
      _lastHeartbeatLoggedAt = DateTime.now();
    }
    await _append(<String, Object?>{
      'kind': 'snapshot',
      'trigger': trigger,
      ...current.device.map(
        (String key, Object? value) =>
            MapEntry<String, Object?>('device.$key', value),
      ),
      ...current.camera.map(
        (String key, Object? value) => MapEntry<String, Object?>(key, value),
      ),
      ...current.process.map(
        (String key, Object? value) => MapEntry<String, Object?>('process.$key', value),
      ),
    });
  }

  Future<void> recordEvent({
    required String kind,
    Map<String, Object?> extra = const <String, Object?>{},
  }) async {
    await _append(<String, Object?>{'kind': kind, ...extra});
  }

  Future<void> _append(Map<String, Object?> entry) {
    final Future<void> next = _pending.then((_) => _appendNow(entry));
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> _appendNow(Map<String, Object?> entry) async {
    try {
      final File file = await _logFile();
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
      // 诊断失败不得影响相机与录像工作流。
    }
  }

  Future<File> _logFile() async {
    final Directory root = await _rootProvider();
    final Directory directory = Directory(p.join(root.path, 'diagnostics'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'camera.jsonl'));
  }

  /// 合并相机日志、录像路径诊断与可选的头部说明，导出的内容永不为空。
  Future<String> exportText({String? header}) async {
    final Directory root = await _rootProvider();
    final List<String> parts = <String>[];
    if (header != null && header.trim().isNotEmpty) {
      parts.add(header);
    }
    for (final String name in const <String>[
      'runtime.jsonl',
      'camera.jsonl',
      'path_fix.jsonl',
      'crash.jsonl',
    ]) {
      final File file = File(p.join(root.path, 'diagnostics', name));
      if (await file.exists()) {
        final String content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          parts.add(content.trim());
        }
      }
    }
    return parts.join('\n\n');
  }

  Future<File> writeExportFile(String text) async {
    final Directory root = await _rootProvider();
    final Directory directory = Directory(p.join(root.path, 'diagnostics'));
    await directory.create(recursive: true);
    final String stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final File file = File(p.join(directory.path, 'export_$stamp.txt'));
    await file.writeAsString(text);
    return file;
  }
}

Future<CameraDiagnosticsSnapshot?> _nativeSnapshotLoader() async {
  final Map<String?, Object?>? values = await CameraHostApi().getDiagnostics();
  if (values == null) return null;
  return CameraDiagnosticsSnapshot.fromMap(Map<Object?, Object?>.from(values));
}
