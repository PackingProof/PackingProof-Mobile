import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/backup_retention_policy.dart';
import '../models/recording_session.dart';
import '../models/recording_operation_mode.dart';
import '../models/recording_spec.dart';
import '../models/recording_video_codec.dart';
import '../models/work_mode.dart';
import '../models/storage_notice.dart';
import 'recording_database.dart';
import 'recording_path_diagnostics.dart';
import 'recording_path_resolver.dart';

/// 用户手动删除的审计原因。
///
/// 产品要求把“用户手动删除”与自动清理（保留策略、容量清理等）严格区分：
/// 手动删除写入 [DeletionReason.userManual]，自动清理使用各自的清理原因。
abstract final class DeletionReason {
  static const String userManual = '手动删除';
}

class SessionRepository {
  SessionRepository({Directory? rootDirectory}) : this._(rootDirectory);

  SessionRepository._(this._rootDirectory);

  Directory? _rootDirectory;
  late Directory _recordingsDirectory;
  late Directory _pendingRecordingsDirectory;
  late File _indexFile;
  late File _settingsFile;
  late RecordingDatabase _recordingDatabase;
  late RecordingPathResolver _pathResolver;
  late RecordingPathDiagnostics _pathDiagnostics;
  bool _initialized = false;
  Future<void> _sessionMutationTail = Future<void>.value();
  Future<void> _settingsMutationTail = Future<void>.value();

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _rootDirectory ??= await getApplicationDocumentsDirectory();
    _recordingsDirectory = Directory(
      p.join(_rootDirectory!.path, 'recordings'),
    );
    await _recordingsDirectory.create(recursive: true);
    _pendingRecordingsDirectory = Directory(
      p.join(_recordingsDirectory.path, '.pending'),
    );
    await _pendingRecordingsDirectory.create(recursive: true);
    _indexFile = File(p.join(_rootDirectory!.path, 'sessions.json'));
    _settingsFile = File(p.join(_rootDirectory!.path, 'settings.json'));
    _recordingDatabase = RecordingDatabase(
      path: p.join(_rootDirectory!.path, 'recordings.db'),
    );
    await _recordingDatabase.initialize();
    _pathResolver = RecordingPathResolver(_recordingsDirectory.path);
    _pathDiagnostics = RecordingPathDiagnostics(
      rootProvider: () async => _rootDirectory!,
    );
    await _recordingDatabase.migrateLegacyIndex(_indexFile);
    _initialized = true;
    await _recoverPendingRecordings();
  }

  Future<void> _recoverPendingRecordings() async {
    final List<FileSystemEntity> entries = await _pendingRecordingsDirectory
        .list(followLinks: false)
        .toList();
    for (final FileSystemEntity entry in entries) {
      if (entry is! File ||
          p.extension(entry.path).toLowerCase() != '.mp4' ||
          !await entry.exists()) {
        continue;
      }
      try {
        final FileStat stat = await entry.stat();
        final DateTime startedAt =
            _startedAtFromPendingName(p.basenameWithoutExtension(entry.path)) ??
            stat.modified;
        final DateTime endedAt = stat.modified.isAfter(startedAt)
            ? stat.modified
            : startedAt.add(const Duration(seconds: 1));
        if (await entry.length() <= 0 ||
            !await hasPlayableMp4Structure(entry)) {
          await _preserveCorruptPendingRecording(entry, startedAt);
          continue;
        }
        final Directory recoveryDirectory = Directory(
          p.join(
            _recordingsDirectory.path,
            '异常恢复',
            _dateDirectoryName(startedAt),
          ),
        );
        await recoveryDirectory.create(recursive: true);
        final String sourceStem = _sanitizeFileName(
          p.basenameWithoutExtension(entry.path),
        );
        String destinationPath = p.join(
          recoveryDirectory.path,
          '未识别面单_${_timestamp(startedAt)}_异常恢复_$sourceStem.mp4',
        );
        var collisionIndex = 1;
        while (await File(destinationPath).exists()) {
          destinationPath = p.join(
            recoveryDirectory.path,
            '未识别面单_${_timestamp(startedAt)}_异常恢复_'
            '${sourceStem}_$collisionIndex.mp4',
          );
          collisionIndex++;
        }
        final File recovered = await entry.rename(destinationPath);
        final String sessionId =
            'recovered-${p.basenameWithoutExtension(entry.path)}-'
            '${stat.modified.microsecondsSinceEpoch}';
        try {
          await _recordingDatabase.upsertSessions(<RecordingSession>[
            RecordingSession(
              id: sessionId,
              filePath: recovered.path,
              startedAt: startedAt,
              endedAt: endedAt,
              markers: const [],
            ),
          ]);
        } on Object {
          try {
            await recovered.rename(entry.path);
          } on Object {
            // The recovered file remains preserved even if indexing failed.
          }
          rethrow;
        }
        developer.log(
          '已保全异常退出录像：${recovered.path}',
          name: 'PackingProof.VideoRecovery',
        );
      } on Object catch (error) {
        developer.log(
          '异常录像保全失败，原文件已保留：${entry.path}',
          name: 'PackingProof.VideoRecovery',
          error: error,
        );
      }
    }
  }

  Future<void> _preserveCorruptPendingRecording(
    File entry,
    DateTime startedAt,
  ) async {
    final Directory corruptDirectory = Directory(
      p.join(_recordingsDirectory.path, '损坏录像', _dateDirectoryName(startedAt)),
    );
    await corruptDirectory.create(recursive: true);
    final String sourceStem = _sanitizeFileName(
      p.basenameWithoutExtension(entry.path),
    );
    String preservedPath = p.join(
      corruptDirectory.path,
      '未识别面单_${_timestamp(startedAt)}_异常退出_损坏_$sourceStem.mp4',
    );
    var collisionIndex = 1;
    while (await File(preservedPath).exists()) {
      preservedPath = p.join(
        corruptDirectory.path,
        '未识别面单_${_timestamp(startedAt)}_异常退出_损坏_'
        '${sourceStem}_$collisionIndex.mp4',
      );
      collisionIndex++;
    }
    final File preserved = await entry.rename(preservedPath);
    developer.log(
      '发现无法播放的异常录像，已隔离保留：${preserved.path}',
      name: 'PackingProof.VideoRecovery',
    );
  }

  @visibleForTesting
  static Future<bool> hasPlayableMp4Structure(File file) async {
    final int length = await file.length();
    final RandomAccessFile raf = await file.open();
    try {
      var offset = 0;
      var sawFtyp = false;
      final Uint8List header = Uint8List(16);
      while (true) {
        if (offset >= length) return false;
        await raf.setPosition(offset);
        final int read = await raf.readInto(header, 0, 8);
        if (read < 8) return false;
        final ByteData data = header.buffer.asByteData(0);
        final int size32 = data.getUint32(0);
        final String type = String.fromCharCodes(header.sublist(4, 8));
        if (offset == 0 && type == 'ftyp') sawFtyp = true;
        if (type == 'moov') return sawFtyp;
        int boxSize = size32;
        if (size32 == 1) {
          final int read64 = await raf.readInto(header, 8, 8);
          if (read64 < 8) return false;
          boxSize = data.getUint64(8);
        } else if (size32 == 0) {
          return false;
        }
        if (boxSize < 8 || offset > length - boxSize) return false;
        offset += boxSize;
      }
    } finally {
      await raf.close();
    }
  }

  static DateTime? _startedAtFromPendingName(String value) {
    final RegExpMatch? match = RegExp(
      r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})_(\d{3})',
    ).firstMatch(value);
    if (match == null) return null;
    try {
      return DateTime(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        int.parse(match.group(4)!),
        int.parse(match.group(5)!),
        int.parse(match.group(6)!),
        int.parse(match.group(7)!),
      );
    } on Object {
      return null;
    }
  }

  Future<List<RecordingSession>> loadSessions({
    bool includeMissingFiles = false,
  }) => _serializeSessionMutation(
    () => _loadSessionsUnlocked(includeMissingFiles: includeMissingFiles),
  );

  Future<List<RecordingSession>> _loadSessionsUnlocked({
    required bool includeMissingFiles,
  }) async {
    await initialize();
    final List<RecordingSession> sessions = await _recordingDatabase
        .loadActiveSessions();
    final List<RecordingSession> resolved = await _resolveAndRepair(sessions);
    if (includeMissingFiles) return resolved;
    return resolved
        .where(
          (RecordingSession session) => File(session.filePath).existsSync(),
        )
        .toList(growable: false);
  }

  Future<LocalRecordingPage> querySessions({
    required int page,
    required int pageSize,
    String keyword = '',
    DateTime? start,
    DateTime? end,
  }) async {
    await initialize();
    final LocalRecordingPage result = await _recordingDatabase
        .queryActiveSessions(
          page: page,
          pageSize: pageSize,
          keyword: keyword,
          start: start,
          end: end,
        );
    final List<RecordingSession> resolved = await _resolveAndRepair(
      result.data,
    );
    return LocalRecordingPage(
      data: resolved,
      page: result.page,
      pageSize: result.pageSize,
      total: result.total,
    );
  }

  Future<bool> hasRecentTrackingNumber(String trackingNumber) async {
    await initialize();
    return _recordingDatabase.hasRecentTrackingNumber(trackingNumber);
  }

  Future<List<RecordingDeleteLog>> loadDeleteLogs({int limit = 100}) async {
    await initialize();
    return _recordingDatabase.loadDeleteLogs(limit: limit);
  }

  Future<void> recordAutomaticCleanup({
    required String eventId,
    required String filePath,
    required int fileSizeBytes,
    required DateTime deletedAt,
    required String reason,
  }) async {
    await initialize();
    await _recordingDatabase.recordAutomaticCleanup(
      eventId: eventId,
      filePath: filePath,
      fileSizeBytes: fileSizeBytes,
      deletedAt: deletedAt,
      reason: reason,
    );
  }

  Future<List<RecordingSession>> loadBackupBatch({
    required int page,
    int pageSize = 100,
  }) async {
    await initialize();
    final List<RecordingSession> sessions = await _recordingDatabase
        .queryBackupBatch(page: page, pageSize: pageSize);
    return _resolveAndRepair(sessions);
  }

  Future<List<RecordingSession>> _loadRecentSessionsUnlocked() async =>
      (await _recordingDatabase.queryActiveSessions(
        page: 1,
        pageSize: 50,
      )).data;

  Future<void> dispose() async {
    if (!_initialized) return;
    _initialized = false;
    await _recordingDatabase.close();
  }

  Future<String> finalizeVideo({
    required String sourcePath,
    required String sessionId,
    required DateTime startedAt,
    required String trackingNumber,
    RecordingOperationMode operationMode = RecordingOperationMode.shipping,
  }) => _serializeSessionMutation(
    () => _finalizeVideo(
      sourcePath: sourcePath,
      sessionId: sessionId,
      startedAt: startedAt,
      trackingNumber: trackingNumber,
      operationMode: operationMode,
    ),
  );

  Future<String> _finalizeVideo({
    required String sourcePath,
    required String sessionId,
    required DateTime startedAt,
    required String trackingNumber,
    required RecordingOperationMode operationMode,
  }) async {
    await initialize();
    final Directory dateDirectory = Directory(
      p.join(_recordingsDirectory.path, _dateDirectoryName(startedAt)),
    );
    await dateDirectory.create(recursive: true);
    final String baseName = _sanitizeFileName(
      '${trackingNumber.trim().isEmpty ? '未识别面单' : trackingNumber.trim()}_'
      '${_timestamp(startedAt)}_${operationMode.label}',
    );
    String destinationPath = p.join(dateDirectory.path, '$baseName.mp4');
    final File source = File(sourcePath);
    if (p.normalize(source.path) == p.normalize(destinationPath)) {
      return destinationPath;
    }
    if (await File(destinationPath).exists()) {
      final String suffix = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      final String shortSuffix = suffix.length <= 8
          ? suffix
          : suffix.substring(suffix.length - 8);
      final String collisionSuffix = shortSuffix.isEmpty
          ? '${startedAt.millisecondsSinceEpoch}'
          : shortSuffix;
      var collisionIndex = 1;
      do {
        final String numberedSuffix = collisionIndex == 1
            ? collisionSuffix
            : '${collisionSuffix}_$collisionIndex';
        destinationPath = p.join(
          dateDirectory.path,
          '${baseName}_$numberedSuffix.mp4',
        );
        collisionIndex++;
      } while (await File(destinationPath).exists());
    }
    try {
      await source.rename(destinationPath);
    } on FileSystemException {
      await source.copy(destinationPath);
      try {
        await source.delete();
      } on FileSystemException {
        // The copied recording is already safe; temp cleanup can be retried by the OS.
      }
    }
    return destinationPath;
  }

  Future<String> recordingPath(String sessionId) async {
    await initialize();
    return p.join(_pendingRecordingsDirectory.path, '$sessionId.mp4');
  }

  static String _dateDirectoryName(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static String _timestamp(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}'
      '${value.month.toString().padLeft(2, '0')}'
      '${value.day.toString().padLeft(2, '0')}_'
      '${value.hour.toString().padLeft(2, '0')}'
      '${value.minute.toString().padLeft(2, '0')}'
      '${value.second.toString().padLeft(2, '0')}';

  static String _sanitizeFileName(String value) {
    final String sanitized = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    return sanitized.isEmpty ? '未识别面单' : sanitized;
  }

  Future<List<RecordingSession>> addSession(RecordingSession session) async {
    return addSessions(<RecordingSession>[session]);
  }

  Future<List<RecordingSession>> addSessions(
    List<RecordingSession> newSessions,
  ) => _serializeSessionMutation(() async {
    await initialize();
    await _recordingDatabase.upsertSessions(newSessions);
    return _loadRecentSessionsUnlocked();
  });

  Future<List<RecordingSession>> updateSession(
    RecordingSession updatedSession,
  ) => _serializeSessionMutation(() async {
    await initialize();
    final List<RecordingSession> existing = await _recordingDatabase
        .findActiveByIds(<String>{updatedSession.id});
    if (existing.isEmpty) {
      throw StateError('找不到要更新的录像片段');
    }
    await _recordingDatabase.upsertSessions(<RecordingSession>[updatedSession]);
    return _loadRecentSessionsUnlocked();
  });

  Future<List<RecordingSession>> deleteSessions(
    Set<String> sessionIds,
  ) => _serializeSessionMutation(() async {
    if (sessionIds.isEmpty) {
      await initialize();
      return _loadRecentSessionsUnlocked();
    }
    await initialize();
    final List<RecordingSession> removed = await _recordingDatabase
        .findActiveByIds(sessionIds);
    await _recordingDatabase.markDeleted(
      removed,
      reason: DeletionReason.userManual,
    );
    for (final String filePath
        in removed
            .map((RecordingSession item) => p.normalize(item.filePath))
            .toSet()) {
      if (await _recordingDatabase.activeReferenceCount(filePath) > 0 ||
          !p.isWithin(_recordingsDirectory.path, filePath)) {
        continue;
      }
      final File file = File(filePath);
      if (await file.exists()) {
        try {
          await file.delete();
        } on FileSystemException {
          // The record is already removed; an orphan file is safer than data loss.
        }
      }
    }
    return _loadRecentSessionsUnlocked();
  });

  Future<void> deleteFileIfUnreferenced(String filePath) =>
      _serializeSessionMutation(() async {
        await initialize();
        final String normalizedPath = p.normalize(filePath);
        if (await _recordingDatabase.activeReferenceCount(normalizedPath) > 0 ||
            !p.isWithin(_recordingsDirectory.path, normalizedPath)) {
          return;
        }
        final File file = File(normalizedPath);
        if (!await file.exists()) return;
        try {
          await file.delete();
          developer.log(
            '已清理完成水印替换的旧录像：$normalizedPath',
            name: 'PackingProof.VideoCleanup',
          );
        } on FileSystemException {
          // Keeping an unreferenced source is safer than removing a newer file.
        }
      });

  Future<WorkMode> loadWorkMode() async {
    return (await loadSettings()).workMode;
  }

  Future<AppSettings> loadSettings() =>
      _serializeSettingsMutation(_loadSettingsUnlocked);

  Future<AppSettings> _loadSettingsUnlocked() async {
    await initialize();
    final File backupFile = File('${_settingsFile.path}.bak');
    if (!await _settingsFile.exists() && await backupFile.exists()) {
      await backupFile.rename(_settingsFile.path);
    }
    if (!await _settingsFile.exists()) {
      return const AppSettings();
    }
    try {
      return await _readSettingsFile();
    } on Object {
      await _archiveCorruptSettings();
      if (await backupFile.exists()) {
        await backupFile.rename(_settingsFile.path);
        try {
          return await _readSettingsFile();
        } on Object {
          await _archiveCorruptSettings();
        }
      }
      return const AppSettings(
        unbackedRetention: UnbackedRetentionPolicy.keepForever,
        backedRetention: BackedRetentionPolicy.keepForever,
      );
    }
  }

  Future<AppSettings> _readSettingsFile() async {
    final Object? decoded = jsonDecode(await _settingsFile.readAsString());
    final Map<String, Object?> values = Map<String, Object?>.from(
      decoded! as Map<Object?, Object?>,
    );
    return AppSettings.fromJson(values);
  }

  Future<void> _archiveCorruptSettings() async {
    if (!await _settingsFile.exists()) return;
    final String backupName =
        'settings-corrupt-${DateTime.now().microsecondsSinceEpoch}.json';
    await _settingsFile.rename(p.join(_rootDirectory!.path, backupName));
  }

  Future<void> saveWorkMode(WorkMode mode) =>
      _updateSettings((AppSettings value) => value.copyWith(workMode: mode));

  Future<void> saveOperationMode(RecordingOperationMode mode) =>
      _updateSettings(
        (AppSettings value) => value.copyWith(operationMode: mode),
      );

  Future<void> saveSpeechEnabled(bool enabled) => _updateSettings(
    (AppSettings value) => value.copyWith(speechEnabled: enabled),
  );

  Future<void> saveOrderSpeechEnabled(bool enabled) => _updateSettings(
    (AppSettings value) => value.copyWith(orderSpeechEnabled: enabled),
  );

  Future<void> saveMaxVolumeEnabled(bool enabled) => _updateSettings(
    (AppSettings value) => value.copyWith(maxVolumeEnabled: enabled),
  );

  Future<void> saveRecordAudioEnabled(bool enabled) => _updateSettings(
    (AppSettings value) => value.copyWith(recordAudioEnabled: enabled),
  );

  Future<void> saveNativeRecordingFallback(bool enabled) => _updateSettings(
    (AppSettings value) => value.copyWith(nativeRecordingFallback: enabled),
  );

  Future<void> saveCameraCapabilityState(Map<String, Object?> state) =>
      _updateSettings(
        (AppSettings value) => value.copyWith(
          cameraCapabilityState: Map<String, Object?>.of(state),
        ),
      );

  Future<void> savePreferredVideoCodec(RecordingVideoCodec codec) =>
      _updateSettings(
        (AppSettings value) => value.copyWith(preferredVideoCodec: codec),
      );

  Future<void> saveRecordingSpec(RecordingSpecPreset spec) => _updateSettings(
    (AppSettings value) => value.copyWith(recordingSpec: spec),
  );

  Future<void> saveMinimumBarcodeLength(int minimumLength) => _updateSettings(
    (AppSettings settings) => settings.copyWith(
      minimumBarcodeLength: AppSettings.normalizeBarcodeLength(minimumLength),
    ),
  );

  Future<void> saveHistoryPageSize(int pageSize) => _updateSettings(
    (AppSettings settings) => settings.copyWith(
      historyPageSize: AppSettings.normalizeHistoryPageSize(pageSize),
    ),
  );

  Future<List<RecordingSession>> pruneMissingSessions({
    Set<String> retainedMissingPaths = const <String>{},
  }) => _serializeSessionMutation(() async {
    await initialize();
    final List<({String id, String filePath})> activePaths =
        await _recordingDatabase.loadActiveSessionPaths();
    final Map<String, String?> resolvedPaths = await _resolvePathMap(
      activePaths.map((({String id, String filePath}) item) => item.filePath),
    );
    final Map<String, String> repairs = <String, String>{};
    for (final ({String id, String filePath}) item in activePaths) {
      final String? resolved = resolvedPaths[item.filePath];
      if (resolved != null && resolved != item.filePath) {
        repairs[item.id] = resolved;
      }
    }
    await _recordingDatabase.refreshMissingState(
      retainedMissingPaths: retainedMissingPaths.map(p.normalize).toSet(),
      resolvedPaths: repairs,
    );
    final List<RecordingSession> recent =
        (await _recordingDatabase.queryActiveSessions(
          page: 1,
          pageSize: 50,
        )).data;
    return _resolveAndRepair(recent);
  });

  /// 解析录像文件的实际路径；找不到时返回 null，并记录诊断信息。
  Future<String?> resolveRecordingPath(String storedPath) async {
    await initialize();
    final RecordingPathResolution resolution = await _pathResolver.resolve(
      storedPath,
    );
    final String? resolved = resolution.resolvedPath;
    if (resolution.repaired) {
      developer.log(
        '录像路径自动修复：$storedPath -> $resolved',
        name: 'PackingProof.PathFix',
      );
    } else if (resolved == null) {
      await _pathDiagnostics.recordMissing(
        storedPath: storedPath,
        recordingsRoot: _recordingsDirectory.path,
        attemptedPaths: resolution.attemptedPaths,
      );
    }
    return resolved;
  }

  Future<List<RecordingSession>> _resolveAndRepair(
    List<RecordingSession> sessions,
  ) async {
    if (sessions.isEmpty) return sessions;
    final Map<String, String?> resolvedPaths = await _resolvePathMap(
      sessions.map((RecordingSession session) => session.filePath).toSet(),
    );
    final List<RecordingSession> resolved = <RecordingSession>[];
    final Map<String, String> repairs = <String, String>{};
    for (final RecordingSession session in sessions) {
      final String? resolvedPath = resolvedPaths[session.filePath];
      final RecordingSession sessionWithPath =
          resolvedPath == null || resolvedPath == session.filePath
          ? session
          : session.copyWith(filePath: resolvedPath);
      resolved.add(sessionWithPath);
      if (sessionWithPath.filePath != session.filePath) {
        repairs[session.id] = sessionWithPath.filePath;
      }
    }
    if (repairs.isNotEmpty) {
      await _recordingDatabase.repairFilePaths(repairs);
    }
    return resolved;
  }

  Future<Map<String, String?>> _resolvePathMap(
    Iterable<String> storedPaths,
  ) async {
    final Map<String, String?> resolved = <String, String?>{};
    final Map<String, RecordingPathResolution> resolutions = await _pathResolver
        .resolveBatch(storedPaths);
    for (final MapEntry<String, RecordingPathResolution> entry
        in resolutions.entries) {
      final RecordingPathResolution resolution = entry.value;
      resolved[entry.key] = resolution.resolvedPath;
      if (resolution.repaired) {
        developer.log(
          '录像路径自动修复：${entry.key} -> ${resolution.resolvedPath}',
          name: 'PackingProof.PathFix',
        );
      } else if (resolution.resolvedPath == null) {
        await _pathDiagnostics.recordMissing(
          storedPath: entry.key,
          recordingsRoot: _recordingsDirectory.path,
          attemptedPaths: resolution.attemptedPaths,
        );
      }
    }
    return resolved;
  }

  Future<void> saveStartupNoticeVersion(int version) => _updateSettings(
    (AppSettings value) => value.copyWith(startupNoticeVersion: version),
  );

  Future<void> saveLastLoggedAppIdentity({
    required String version,
    required int buildNumber,
    required String buildIdentity,
  }) => _updateSettings(
    (AppSettings value) => value.copyWith(
      lastLoggedAppVersion: version,
      lastLoggedAppBuildNumber: buildNumber,
      lastLoggedBuildIdentity: buildIdentity,
    ),
  );

  Future<bool> tryReserveMobileUpdatePrompt(
    DateTime now, {
    int maximumPerDay = 2,
  }) => _serializeSettingsMutation(() async {
    final AppSettings settings = await _loadSettingsUnlocked();
    final String today =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final int currentCount = settings.mobileUpdatePromptDate == today
        ? settings.mobileUpdatePromptCount
        : 0;
    if (currentCount >= maximumPerDay) {
      return false;
    }

    await _writeSettingsUnlocked(
      settings.copyWith(
        mobileUpdatePromptDate: today,
        mobileUpdatePromptCount: currentCount + 1,
      ),
    );
    return true;
  });

  Future<void> saveLanBackupAutoEnabled(bool enabled) => _updateSettings(
    (AppSettings value) => value.copyWith(lanBackupAutoEnabled: enabled),
  );

  Future<void> saveHiddenRemoteRecordingIds(Set<int> ids) => _updateSettings(
    (AppSettings value) => value.copyWith(hiddenRemoteRecordingIds: ids),
  );

  Future<void> saveBackupRetention({
    required UnbackedRetentionPolicy unbacked,
    required BackedRetentionPolicy backed,
  }) => _updateSettings(
    (AppSettings value) =>
        value.copyWith(unbackedRetention: unbacked, backedRetention: backed),
  );

  Future<void> queueStorageNotice(StorageNotice notice) => _updateSettings(
    (AppSettings value) => value.copyWith(
      storageNoticeState: value.storageNoticeState.queue(notice),
    ),
  );

  Future<StorageNotice?> takeStorageNoticeAfterWork(DateTime now) =>
      _serializeSettingsMutation(() async {
        final AppSettings settings = await _loadSettingsUnlocked();
        final result = settings.storageNoticeState.take(now);
        await _writeSettingsUnlocked(
          settings.copyWith(storageNoticeState: result.state),
        );
        return result.notice;
      });

  Future<void> saveSettings(AppSettings settings) =>
      _serializeSettingsMutation(() => _writeSettingsUnlocked(settings));

  Future<void> _updateSettings(
    AppSettings Function(AppSettings value) update,
  ) => _serializeSettingsMutation(() async {
    final AppSettings settings = await _loadSettingsUnlocked();
    await _writeSettingsUnlocked(update(settings));
  });

  Future<void> _writeSettingsUnlocked(AppSettings settings) async {
    await initialize();
    final String contents = const JsonEncoder.withIndent(
      '  ',
    ).convert(settings.toJson());
    final File tempFile = File('${_settingsFile.path}.tmp');
    final File backupFile = File('${_settingsFile.path}.bak');
    await tempFile.writeAsString(contents, flush: true);
    if (await backupFile.exists()) {
      await backupFile.delete();
    }
    final bool hadSettings = await _settingsFile.exists();
    if (hadSettings) {
      await _settingsFile.rename(backupFile.path);
    }
    try {
      await tempFile.rename(_settingsFile.path);
    } on Object {
      if (hadSettings &&
          !await _settingsFile.exists() &&
          await backupFile.exists()) {
        await backupFile.rename(_settingsFile.path);
      }
      rethrow;
    }
    if (await backupFile.exists()) {
      await backupFile.delete();
    }
  }

  Future<T> _serializeSessionMutation<T>(Future<T> Function() action) {
    final Completer<T> result = Completer<T>();
    _sessionMutationTail = _sessionMutationTail.catchError((Object _) {}).then((
      _,
    ) async {
      try {
        result.complete(await action());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<T> _serializeSettingsMutation<T>(Future<T> Function() action) {
    final Completer<T> result = Completer<T>();
    _settingsMutationTail = _settingsMutationTail
        .catchError((Object _) {})
        .then((_) async {
          try {
            result.complete(await action());
          } on Object catch (error, stackTrace) {
            result.completeError(error, stackTrace);
          }
        });
    return result.future;
  }
}
