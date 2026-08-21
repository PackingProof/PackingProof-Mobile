import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/recording_session.dart';
import '../models/recording_orientation.dart';

class LocalRecordingPage {
  const LocalRecordingPage({
    required this.data,
    required this.page,
    required this.pageSize,
    required this.total,
  });

  final List<RecordingSession> data;
  final int page;
  final int pageSize;
  final int total;

  int get pageCount => total <= 0 ? 0 : (total + pageSize - 1) ~/ pageSize;
}

class RecordingBackupRow {
  const RecordingBackupRow({
    required this.updatedAt,
    required this.id,
    required this.session,
  });

  final int updatedAt;
  final String id;
  final RecordingSession session;
}

class WatermarkAttemptClaim {
  const WatermarkAttemptClaim({
    required this.session,
    required this.claimed,
    required this.exhausted,
  });

  final RecordingSession session;
  final bool claimed;
  final bool exhausted;
}

class LocalRecordingStatistics {
  const LocalRecordingStatistics({
    this.total = 0,
    this.today = 0,
    this.totalBytes = 0,
  });

  final int total;
  final int today;
  final int totalBytes;
}

class RecordingDeleteLog {
  const RecordingDeleteLog({
    required this.filePath,
    required this.sessionId,
    required this.trackingNumber,
    required this.fileSizeBytes,
    required this.deletedAt,
    required this.reason,
  });

  final String filePath;
  final String sessionId;
  final String trackingNumber;
  final int fileSizeBytes;
  final DateTime deletedAt;
  final String reason;
}

class RecordingDatabase {
  RecordingDatabase({required this.path});

  final String path;
  Database? _database;

  static const List<String> _sessionPayloadColumns = <String>[
    'payload_json',
    'file_path',
    'recording_orientation',
    'watermark_status',
    'watermark_attempt_count',
  ];

  Future<Database> get _db async => _database ??= await openDatabase(
    path,
    version: 2,
    onConfigure: (Database db) async {
      // Android treats journal_mode as a result-returning PRAGMA and rejects
      // execute(); sqflite's helper falls back to rawQuery on that platform.
      await db.setJournalMode('WAL');
      await db.execute('PRAGMA synchronous=NORMAL');
      await db.execute('PRAGMA foreign_keys=ON');
    },
    onCreate: (Database db, int version) async {
      await db.execute('''
        CREATE TABLE recording_sessions (
          id TEXT PRIMARY KEY,
          file_path TEXT NOT NULL,
          started_at INTEGER NOT NULL,
          ended_at INTEGER NOT NULL,
          tracking_number TEXT NOT NULL DEFAULT '',
          order_id TEXT NOT NULL DEFAULT '',
          search_text TEXT NOT NULL DEFAULT '',
          payload_json TEXT NOT NULL,
          file_size_bytes INTEGER NOT NULL DEFAULT 0,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          deleted_at INTEGER,
          delete_reason TEXT NOT NULL DEFAULT '',
          missing_at INTEGER,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          recording_orientation TEXT NOT NULL DEFAULT 'portrait',
          watermark_status TEXT NOT NULL DEFAULT 'completed',
          watermark_attempt_count INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE recording_delete_logs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          file_path TEXT NOT NULL,
          session_id TEXT NOT NULL DEFAULT '',
          tracking_number TEXT NOT NULL DEFAULT '',
          file_size_bytes INTEGER NOT NULL DEFAULT 0,
          deleted_at INTEGER NOT NULL,
          reason TEXT NOT NULL DEFAULT ''
        )
      ''');
      await db.execute('''
        CREATE TABLE recording_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_recording_active_time '
        'ON recording_sessions(is_deleted, started_at DESC, id DESC)',
      );
      await db.execute(
        'CREATE INDEX idx_recording_file_path '
        'ON recording_sessions(file_path)',
      );
      await db.execute(
        'CREATE INDEX idx_recording_tracking '
        'ON recording_sessions(tracking_number)',
      );
      await db.execute(
        'CREATE INDEX idx_recording_order '
        'ON recording_sessions(order_id)',
      );
    },
    onUpgrade: (Database db, int oldVersion, int newVersion) async {
      if (oldVersion < 2) {
        await db.execute(
          "ALTER TABLE recording_sessions ADD COLUMN recording_orientation "
          "TEXT NOT NULL DEFAULT 'portrait'",
        );
        await db.execute(
          "ALTER TABLE recording_sessions ADD COLUMN watermark_status "
          "TEXT NOT NULL DEFAULT 'completed'",
        );
        await db.execute(
          "ALTER TABLE recording_sessions ADD COLUMN watermark_attempt_count "
          'INTEGER NOT NULL DEFAULT 0',
        );
      }
    },
  );

  Future<void> initialize() async {
    final Database db = await _db;
    await _materializeSharedFileReferences(db);
  }

  @visibleForTesting
  Future<void> setUpdatedAtForTesting({
    required String id,
    required int updatedAt,
  }) async {
    final Database db = await _db;
    await db.update(
      'recording_sessions',
      <String, Object?>{'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> close() async {
    final Database? database = _database;
    _database = null;
    await database?.close();
  }

  Future<void> migrateLegacyIndex(File indexFile) async {
    final Database db = await _db;
    final List<Map<String, Object?>> migrated = await db.query(
      'recording_metadata',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>['legacy_sessions_migrated'],
      limit: 1,
    );
    if (migrated.isNotEmpty) return;

    final File backupFile = File('${indexFile.path}.bak');
    File? source;
    List<RecordingSession> sessions = <RecordingSession>[];
    for (final File candidate in <File>[indexFile, backupFile]) {
      if (!await candidate.exists()) continue;
      try {
        sessions = _decodeLegacySessions(await candidate.readAsString());
        source = candidate;
        break;
      } on Object {
        await _archiveCorruptLegacyIndex(candidate, indexFile);
      }
    }

    await db.transaction((Transaction txn) async {
      for (final RecordingSession session in sessions) {
        await txn.insert(
          'recording_sessions',
          await _sessionRow(session),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await txn.insert('recording_metadata', <String, Object?>{
        'key': 'legacy_sessions_migrated',
        'value': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });

    await _materializeSharedFileReferences(db);

    if (source != null && await source.exists()) {
      final String migratedPath = '${indexFile.path}.migrated';
      final File migratedFile = File(migratedPath);
      if (!await migratedFile.exists()) {
        await source.copy(migratedPath);
      }
    }
  }

  static List<RecordingSession> _decodeLegacySessions(String contents) {
    final List<Object?> values = jsonDecode(contents) as List<Object?>;
    return values
        .map(
          (Object? value) => RecordingSession.fromJson(
            Map<String, Object?>.from(value! as Map<Object?, Object?>),
          ),
        )
        .toList(growable: false);
  }

  static Future<void> _archiveCorruptLegacyIndex(
    File source,
    File indexFile,
  ) async {
    final String sourceLabel = source.path == indexFile.path ? '' : '-backup';
    final String archivePath =
        '${indexFile.parent.path}${Platform.pathSeparator}'
        'sessions$sourceLabel-corrupt-'
        '${DateTime.now().microsecondsSinceEpoch}.json';
    await source.copy(archivePath);
  }

  Future<List<RecordingSession>> loadActiveSessions() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'recording_sessions',
      columns: _sessionPayloadColumns,
      where: 'is_deleted = 0',
      orderBy: 'started_at DESC, id DESC',
    );
    return rows.map(_sessionFromRow).toList(growable: false);
  }

  Future<List<({String id, String filePath})>> loadActiveSessionPaths() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'recording_sessions',
      columns: <String>['id', 'file_path'],
      where: 'is_deleted = 0',
      orderBy: 'started_at DESC, id DESC',
    );
    return rows
        .map(
          (Map<String, Object?> row) =>
              (id: row['id']! as String, filePath: row['file_path']! as String),
        )
        .toList(growable: false);
  }

  Future<LocalRecordingPage> queryActiveSessions({
    required int page,
    required int pageSize,
    String keyword = '',
    DateTime? start,
    DateTime? end,
  }) async {
    final Database db = await _db;
    final int normalizedPage = page < 1 ? 1 : page;
    final int normalizedSize = pageSize.clamp(1, 100);
    final String query = keyword.trim().toLowerCase();
    final List<String> conditions = <String>['is_deleted = 0'];
    final List<Object?> args = <Object?>[];
    if (query.isNotEmpty) {
      conditions.add('search_text LIKE ?');
      args.add('%$query%');
    }
    if (start != null) {
      conditions.add('started_at >= ?');
      args.add(start.millisecondsSinceEpoch);
    }
    if (end != null) {
      conditions.add('started_at < ?');
      args.add(end.millisecondsSinceEpoch);
    }
    final String where = conditions.join(' AND ');
    final List<Map<String, Object?>> countRows = await db.rawQuery(
      'SELECT COUNT(1) AS total FROM recording_sessions WHERE $where',
      args,
    );
    final int total = Sqflite.firstIntValue(countRows) ?? 0;
    final List<Map<String, Object?>> rows = await db.query(
      'recording_sessions',
      columns: _sessionPayloadColumns,
      where: where,
      whereArgs: args,
      orderBy: 'started_at DESC, id DESC',
      limit: normalizedSize,
      offset: (normalizedPage - 1) * normalizedSize,
    );
    return LocalRecordingPage(
      data: rows.map(_sessionFromRow).toList(growable: false),
      page: normalizedPage,
      pageSize: normalizedSize,
      total: total,
    );
  }

  Future<bool> hasRecentTrackingNumber(
    String trackingNumber, {
    Duration lookback = const Duration(days: 30),
  }) async {
    final String normalized = trackingNumber.trim().toUpperCase();
    if (normalized.isEmpty) return false;
    final Database db = await _db;
    final int since = DateTime.now().subtract(lookback).millisecondsSinceEpoch;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COUNT(1) FROM recording_sessions '
      'WHERE is_deleted = 0 AND tracking_number = ? AND started_at >= ?',
      <Object?>[normalized, since],
    );
    return (Sqflite.firstIntValue(rows) ?? 0) > 0;
  }

  Future<List<RecordingSession>> queryBackupBatch({
    required int page,
    required int pageSize,
  }) async {
    final Database db = await _db;
    final int normalizedPage = page < 1 ? 1 : page;
    final int normalizedSize = pageSize.clamp(1, 100);
    final List<Map<String, Object?>> rows = await db.query(
      'recording_sessions',
      columns: _sessionPayloadColumns,
      where: "is_deleted = 0 AND watermark_status IN ('completed', 'failed')",
      orderBy: 'started_at ASC, id ASC',
      limit: normalizedSize,
      offset: (normalizedPage - 1) * normalizedSize,
    );
    return rows.map(_sessionFromRow).toList(growable: false);
  }

  Future<List<RecordingBackupRow>> queryBackupRows({
    required int? afterUpdatedAt,
    required String? afterId,
    required int? highUpdatedAt,
    required String? highId,
    required int pageSize,
  }) async {
    final Database db = await _db;
    final List<String> conditions = <String>[
      'is_deleted = 0',
      "watermark_status IN ('completed', 'failed')",
    ];
    final List<Object?> args = <Object?>[];
    if (afterUpdatedAt != null && afterId != null) {
      conditions.add('(updated_at > ? OR (updated_at = ? AND id > ?))');
      args.addAll(<Object?>[afterUpdatedAt, afterUpdatedAt, afterId]);
    }
    if (highUpdatedAt != null && highId != null) {
      conditions.add('(updated_at < ? OR (updated_at = ? AND id <= ?))');
      args.addAll(<Object?>[highUpdatedAt, highUpdatedAt, highId]);
    }
    final String where = conditions.join(' AND ');
    final int normalizedSize = pageSize.clamp(1, 1000);
    final List<Map<String, Object?>> rows = await db.query(
      'recording_sessions',
      columns: <String>[..._sessionPayloadColumns, 'updated_at', 'id'],
      where: where,
      whereArgs: args,
      orderBy: 'updated_at ASC, id ASC',
      limit: normalizedSize,
    );
    return rows
        .map(
          (Map<String, Object?> row) => RecordingBackupRow(
            updatedAt: row['updated_at']! as int,
            id: row['id']! as String,
            session: _sessionFromRow(row),
          ),
        )
        .toList(growable: false);
  }

  Future<({int updatedAt, String id})?> loadBackupHighWatermark() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'recording_sessions',
      columns: <String>['updated_at', 'id'],
      where: "is_deleted = 0 AND watermark_status IN ('completed', 'failed')",
      orderBy: 'updated_at DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (
      updatedAt: rows.first['updated_at']! as int,
      id: rows.first['id']! as String,
    );
  }

  Future<LocalRecordingStatistics> loadLocalRecordingStatistics() async {
    final Database db = await _db;
    final DateTime now = DateTime.now();
    final int todayStart = DateTime(
      now.year,
      now.month,
      now.day,
    ).millisecondsSinceEpoch;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT
        COUNT(*) AS total,
        SUM(CASE WHEN started_at >= ? THEN 1 ELSE 0 END) AS today,
        SUM(file_size_bytes) AS total_bytes
      FROM recording_sessions
      WHERE is_deleted = 0 AND missing_at IS NULL
      ''',
      <Object?>[todayStart],
    );
    if (rows.isEmpty) {
      return const LocalRecordingStatistics();
    }
    return LocalRecordingStatistics(
      total: (rows.first['total'] as num?)?.toInt() ?? 0,
      today: (rows.first['today'] as num?)?.toInt() ?? 0,
      totalBytes: (rows.first['total_bytes'] as num?)?.toInt() ?? 0,
    );
  }

  Future<String?> readMetadataValue(String key) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'recording_metadata',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> writeMetadataValue(String key, String value) async {
    final Database db = await _db;
    await db.insert('recording_metadata', <String, Object?>{
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertSessions(List<RecordingSession> sessions) async {
    if (sessions.isEmpty) return;
    final Database db = await _db;
    await _validateDistinctFileReferences(db, sessions);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<String> ids = sessions
        .map((RecordingSession session) => session.id)
        .toList(growable: false);
    final Map<String, Object?> createdAts = await _readCreatedAtMap(db, ids);
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[];

    // 文件 stat 放在事务外，并按小批次并发处理，避免一次同时打开过多文件描述符。
    const int statBatchSize = 200;
    for (var start = 0; start < sessions.length; start += statBatchSize) {
      final int end = start + statBatchSize < sessions.length
          ? start + statBatchSize
          : sessions.length;
      final List<RecordingSession> batch = sessions.sublist(start, end);
      final List<_RecordingFileMetadata> metadata = await Future.wait(
        batch.map(
          (RecordingSession session) =>
              _readFileMetadata(File(session.filePath)),
        ),
      );
      for (var index = 0; index < batch.length; index++) {
        final RecordingSession session = batch[index];
        final Map<String, Object?> row = await _sessionRow(
          session,
          fileMetadata: metadata[index],
          now: now,
        );
        row['created_at'] = createdAts[session.id] ?? row['created_at'];
        rows.add(row);
      }
    }

    await db.transaction((Transaction txn) async {
      final Batch batch = txn.batch();
      for (final Map<String, Object?> row in rows) {
        batch.insert(
          'recording_sessions',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<Map<String, Object?>> _readCreatedAtMap(
    Database db,
    List<String> ids,
  ) async {
    final Map<String, Object?> result = <String, Object?>{};
    const int queryBatchSize = 500;
    for (var start = 0; start < ids.length; start += queryBatchSize) {
      final int end = start + queryBatchSize < ids.length
          ? start + queryBatchSize
          : ids.length;
      final List<String> batch = ids.sublist(start, end);
      final String placeholders = List<String>.filled(
        batch.length,
        '?',
      ).join(',');
      final List<Map<String, Object?>> rows = await db.query(
        'recording_sessions',
        columns: <String>['id', 'created_at'],
        where: 'id IN ($placeholders)',
        whereArgs: batch,
      );
      for (final Map<String, Object?> row in rows) {
        result[row['id']! as String] = row['created_at'];
      }
    }
    return result;
  }

  Future<List<RecordingSession>> findActiveByIds(Set<String> ids) async {
    if (ids.isEmpty) return <RecordingSession>[];
    final Database db = await _db;
    final String placeholders = List<String>.filled(ids.length, '?').join(',');
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT ${_sessionPayloadColumns.join(', ')} FROM recording_sessions '
      'WHERE is_deleted = 0 AND id IN ($placeholders)',
      ids.toList(growable: false),
    );
    return rows.map(_sessionFromRow).toList(growable: false);
  }

  Future<List<RecordingSession>> loadPendingWatermarkSessions() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'recording_sessions',
      columns: _sessionPayloadColumns,
      where: "is_deleted = 0 AND watermark_status = 'pending'",
      orderBy: 'started_at ASC, id ASC',
    );
    return rows.map(_sessionFromRow).toList(growable: false);
  }

  Future<WatermarkAttemptClaim?> claimPendingWatermarkAttempt({
    required String sessionId,
    required int expectedAttempt,
    required int maximumAttempts,
  }) async {
    final Database db = await _db;
    return db.transaction((Transaction txn) async {
      Future<RecordingSession?> loadCurrent() async {
        final List<Map<String, Object?>> rows = await txn.query(
          'recording_sessions',
          columns: _sessionPayloadColumns,
          where: 'id = ? AND is_deleted = 0',
          whereArgs: <Object?>[sessionId],
          limit: 1,
        );
        return rows.isEmpty ? null : _sessionFromRow(rows.single);
      }

      final RecordingSession? current = await loadCurrent();
      if (current == null ||
          current.watermarkStatus != WatermarkProcessingStatus.pending) {
        return null;
      }
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (current.watermarkAttemptCount >= maximumAttempts) {
        final RecordingSession failed = current.copyWith(
          watermarkStatus: WatermarkProcessingStatus.failed,
        );
        await txn.update(
          'recording_sessions',
          <String, Object?>{
            'payload_json': jsonEncode(failed.toJson()),
            'watermark_status': failed.watermarkStatus.storageValue,
            'updated_at': now,
          },
          where:
              "id = ? AND is_deleted = 0 AND watermark_status = 'pending' "
              'AND watermark_attempt_count >= ?',
          whereArgs: <Object?>[sessionId, maximumAttempts],
        );
        final RecordingSession latest = (await loadCurrent()) ?? failed;
        return WatermarkAttemptClaim(
          session: latest,
          claimed: false,
          exhausted: latest.watermarkStatus == WatermarkProcessingStatus.failed,
        );
      }
      if (current.watermarkAttemptCount != expectedAttempt) {
        return WatermarkAttemptClaim(
          session: current,
          claimed: false,
          exhausted: false,
        );
      }
      final RecordingSession claimed = current.copyWith(
        watermarkAttemptCount: current.watermarkAttemptCount + 1,
      );
      final int updated = await txn.update(
        'recording_sessions',
        <String, Object?>{
          'payload_json': jsonEncode(claimed.toJson()),
          'watermark_attempt_count': claimed.watermarkAttemptCount,
          'updated_at': now,
        },
        where:
            "id = ? AND is_deleted = 0 AND watermark_status = 'pending' "
            'AND watermark_attempt_count = ? AND watermark_attempt_count < ?',
        whereArgs: <Object?>[sessionId, expectedAttempt, maximumAttempts],
      );
      if (updated == 1) {
        return WatermarkAttemptClaim(
          session: claimed,
          claimed: true,
          exhausted: false,
        );
      }
      final RecordingSession? latest = await loadCurrent();
      return latest == null
          ? null
          : WatermarkAttemptClaim(
              session: latest,
              claimed: false,
              exhausted: false,
            );
    });
  }

  Future<void> markDeleted(
    List<RecordingSession> sessions, {
    required String reason,
  }) async {
    if (sessions.isEmpty) return;
    final Database db = await _db;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Map<String, int> fileSizes = <String, int>{};
    final Map<String, _RecordingFileMetadata> fileMetadata =
        <String, _RecordingFileMetadata>{};
    for (final RecordingSession session in sessions) {
      final String normalized = _normalizedFilePath(session.filePath);
      if (fileMetadata.containsKey(normalized)) continue;
      fileMetadata[normalized] = await _readFileMetadata(
        File(session.filePath),
      );
    }
    for (final MapEntry<String, _RecordingFileMetadata> entry
        in fileMetadata.entries) {
      fileSizes[entry.key] = entry.value.size;
    }

    await db.transaction((Transaction txn) async {
      final Batch batch = txn.batch();
      for (final RecordingSession session in sessions) {
        final String normalized = _normalizedFilePath(session.filePath);
        batch.update(
          'recording_sessions',
          <String, Object?>{
            'is_deleted': 1,
            'deleted_at': now,
            'delete_reason': reason,
            'updated_at': now,
          },
          where: 'id = ? AND is_deleted = 0',
          whereArgs: <Object?>[session.id],
        );
        batch.insert('recording_delete_logs', <String, Object?>{
          'file_path': session.filePath,
          'session_id': session.id,
          'tracking_number': session.displayCode,
          'file_size_bytes': fileSizes[normalized] ?? 0,
          'deleted_at': now,
          'reason': reason,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> recordAutomaticCleanup({
    required String eventId,
    required String filePath,
    required int fileSizeBytes,
    required DateTime deletedAt,
    required String reason,
  }) async {
    final String normalizedEventId = eventId.trim();
    if (normalizedEventId.isEmpty || filePath.trim().isEmpty) return;
    final Database db = await _db;
    final String metadataKey = 'cleanup_audit:$normalizedEventId';
    await db.transaction((Transaction txn) async {
      final List<Map<String, Object?>> audited = await txn.query(
        'recording_metadata',
        columns: <String>['value'],
        where: 'key = ?',
        whereArgs: <Object?>[metadataKey],
        limit: 1,
      );
      if (audited.isNotEmpty) return;
      final List<Map<String, Object?>> rows = await txn.query(
        'recording_sessions',
        columns: <String>['id', 'tracking_number'],
        where: 'is_deleted = 0 AND file_path = ?',
        whereArgs: <Object?>[filePath],
      );
      final int deletedAtMillis = deletedAt.millisecondsSinceEpoch;
      for (final Map<String, Object?> row in rows) {
        await txn.insert('recording_delete_logs', <String, Object?>{
          'file_path': filePath,
          'session_id': row['id']! as String,
          'tracking_number': row['tracking_number']! as String,
          'file_size_bytes': fileSizeBytes < 0 ? 0 : fileSizeBytes,
          'deleted_at': deletedAtMillis,
          'reason': reason,
        });
      }
      await txn.update(
        'recording_sessions',
        <String, Object?>{
          'missing_at': deletedAtMillis,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'is_deleted = 0 AND file_path = ?',
        whereArgs: <Object?>[filePath],
      );
      await txn.insert('recording_metadata', <String, Object?>{
        'key': metadataKey,
        'value': deletedAt.toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  Future<int> activeReferenceCount(String filePath) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COUNT(1) FROM recording_sessions '
      'WHERE is_deleted = 0 AND file_path = ?',
      <Object?>[filePath],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> refreshMissingState({
    Set<String> retainedMissingPaths = const <String>{},
    Map<String, String> resolvedPaths = const <String, String>{},
  }) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'recording_sessions',
      columns: <String>['id', 'file_path', 'missing_at'],
      where: 'is_deleted = 0',
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Batch batch = db.batch();
    for (final Map<String, Object?> row in rows) {
      final String filePath = row['file_path']! as String;
      final String workingPath = resolvedPaths[row['id']] ?? filePath;
      final bool missing = !File(workingPath).existsSync();
      final bool retained =
          retainedMissingPaths.contains(workingPath) ||
          retainedMissingPaths.contains(filePath);
      final Object? current = row['missing_at'];
      final bool pathChanged = workingPath != filePath;
      if (missing && current == null) {
        batch.update(
          'recording_sessions',
          <String, Object?>{
            if (pathChanged) 'file_path': workingPath,
            'missing_at': now,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: <Object?>[row['id']],
        );
      } else if (!missing && current != null) {
        batch.update(
          'recording_sessions',
          <String, Object?>{
            if (pathChanged) 'file_path': workingPath,
            'missing_at': null,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: <Object?>[row['id']],
        );
      } else if (pathChanged) {
        batch.update(
          'recording_sessions',
          <String, Object?>{'file_path': workingPath, 'updated_at': now},
          where: 'id = ?',
          whereArgs: <Object?>[row['id']],
        );
      } else if (missing && retained) {
        // Retained remote history remains active; missing_at records why local
        // playback is unavailable without discarding the audit trail.
      }
    }
    await batch.commit(noResult: true);
  }

  Future<void> repairFilePaths(Map<String, String> resolvedPaths) async {
    if (resolvedPaths.isEmpty) return;
    final Database db = await _db;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Batch batch = db.batch();
    resolvedPaths.forEach((String id, String path) {
      batch.update(
        'recording_sessions',
        <String, Object?>{
          'file_path': path,
          'missing_at': null,
          'updated_at': now,
        },
        where: 'id = ? AND file_path != ?',
        whereArgs: <Object?>[id, path],
      );
    });
    await batch.commit(noResult: true);
  }

  Future<List<RecordingDeleteLog>> loadDeleteLogs({int limit = 100}) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'recording_delete_logs',
      orderBy: 'deleted_at DESC, id DESC',
      limit: limit.clamp(1, 1000),
    );
    return rows
        .map(
          (Map<String, Object?> row) => RecordingDeleteLog(
            filePath: row['file_path']! as String,
            sessionId: row['session_id']! as String,
            trackingNumber: row['tracking_number']! as String,
            fileSizeBytes: row['file_size_bytes']! as int,
            deletedAt: DateTime.fromMillisecondsSinceEpoch(
              row['deleted_at']! as int,
            ),
            reason: row['reason']! as String,
          ),
        )
        .toList(growable: false);
  }

  Future<Map<String, Object?>> _sessionRow(
    RecordingSession session, {
    _RecordingFileMetadata? fileMetadata,
    int? now,
  }) async {
    final int timestamp = now ?? DateTime.now().millisecondsSinceEpoch;
    final _RecordingFileMetadata metadata =
        fileMetadata ?? await _readFileMetadata(File(session.filePath));
    final String orderId = session.orderInfo?.orderId ?? '';
    final String searchText = <String>[
      session.displayCode,
      orderId,
      session.orderInfo?.buyerMessage ?? '',
      session.orderInfo?.sellerMemo ?? '',
      session.orderInfo?.productInfo ?? '',
      session.startedAt.toIso8601String(),
    ].join(' ').toLowerCase();
    return <String, Object?>{
      'id': session.id,
      'file_path': session.filePath,
      'started_at': session.startedAt.millisecondsSinceEpoch,
      'ended_at': session.endedAt.millisecondsSinceEpoch,
      'tracking_number': session.displayCode,
      'order_id': orderId,
      'search_text': searchText,
      'payload_json': jsonEncode(session.toJson()),
      'file_size_bytes': metadata.size,
      'is_deleted': 0,
      'deleted_at': null,
      'delete_reason': '',
      'missing_at': metadata.exists ? null : timestamp,
      'created_at': timestamp,
      'updated_at': timestamp,
      'recording_orientation': session.recordingOrientation.storageValue,
      'watermark_status': session.watermarkStatus.storageValue,
      'watermark_attempt_count': session.watermarkAttemptCount,
    };
  }

  Future<_RecordingFileMetadata> _readFileMetadata(File file) async {
    try {
      final FileStat stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) {
        return const _RecordingFileMetadata(exists: false, size: 0);
      }
      return _RecordingFileMetadata(exists: true, size: stat.size);
    } on FileSystemException {
      return const _RecordingFileMetadata(exists: false, size: 0);
    }
  }

  static String _normalizedFilePath(String filePath) =>
      filePath.replaceAll('\\', '/');

  static RecordingSession _sessionFromRow(Map<String, Object?> row) {
    final Map<String, Object?> payload = Map<String, Object?>.from(
      jsonDecode(row['payload_json']! as String) as Map<Object?, Object?>,
    );
    if (row['file_path'] case final String filePath) {
      payload['filePath'] = filePath;
    }
    if (row['recording_orientation'] case final String orientation) {
      payload['recordingOrientation'] = orientation;
    }
    if (row['watermark_status'] case final String status) {
      payload['watermarkStatus'] = status;
    }
    if (row['watermark_attempt_count'] case final int attemptCount) {
      payload['watermarkAttemptCount'] = attemptCount;
    }
    return RecordingSession.fromJson(payload);
  }

  Future<void> _validateDistinctFileReferences(
    Database db,
    List<RecordingSession> sessions,
  ) async {
    final Map<String, String> requestedOwners = <String, String>{};
    for (final RecordingSession session in sessions) {
      final String normalized = session.filePath;
      final String? owner = requestedOwners[normalized];
      if (owner != null && owner != session.id) {
        throw StateError('一条录像文件只能对应一条录像记录');
      }
      requestedOwners[normalized] = session.id;
    }
    for (final MapEntry<String, String> entry in requestedOwners.entries) {
      final List<Map<String, Object?>> rows = await db.query(
        'recording_sessions',
        columns: <String>['id'],
        where: 'is_deleted = 0 AND file_path = ? AND id != ?',
        whereArgs: <Object?>[entry.key, entry.value],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        throw StateError('一条录像文件只能对应一条录像记录');
      }
    }
  }

  Future<void> _materializeSharedFileReferences(Database db) async {
    final List<Map<String, Object?>> rows = await db.query(
      'recording_sessions',
      columns: <String>['id', ..._sessionPayloadColumns],
      where: 'is_deleted = 0',
      orderBy: 'file_path ASC, started_at ASC, id ASC',
    );
    final Set<String> retainedPaths = <String>{};
    for (final Map<String, Object?> row in rows) {
      final String id = row['id']! as String;
      final String sourcePath = row['file_path']! as String;
      final String normalized = p.normalize(sourcePath);
      if (retainedPaths.add(normalized)) continue;

      final String distinctPath = await _copyToDistinctPath(
        sourcePath: sourcePath,
        sessionId: id,
        reservedPaths: retainedPaths,
      );
      final RecordingSession session = _sessionFromRow(
        row,
      ).copyWith(filePath: distinctPath);
      final _RecordingFileMetadata metadata = await _readFileMetadata(
        File(distinctPath),
      );
      final int now = DateTime.now().millisecondsSinceEpoch;
      await db.update(
        'recording_sessions',
        <String, Object?>{
          'file_path': distinctPath,
          'payload_json': jsonEncode(session.toJson()),
          'file_size_bytes': metadata.size,
          'missing_at': metadata.exists ? null : now,
          'updated_at': now,
        },
        where: 'id = ? AND is_deleted = 0',
        whereArgs: <Object?>[id],
      );
      retainedPaths.add(p.normalize(distinctPath));
    }
  }

  Future<String> _copyToDistinctPath({
    required String sourcePath,
    required String sessionId,
    required Set<String> reservedPaths,
  }) async {
    final File source = File(sourcePath);
    final String extension = p.extension(sourcePath);
    final String stem = p.basenameWithoutExtension(sourcePath);
    final String safeId = sessionId
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final String suffix = safeId.isEmpty ? 'recording' : safeId;
    var collision = 0;
    late String destinationPath;
    do {
      collision++;
      final String number = collision == 1 ? '' : '_$collision';
      destinationPath = p.join(
        p.dirname(sourcePath),
        '${stem}_独立_$suffix$number$extension',
      );
    } while (reservedPaths.contains(p.normalize(destinationPath)) ||
        await File(destinationPath).exists());

    if (await source.exists()) {
      final File temporary = File(
        '$destinationPath.migrating-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await source.copy(temporary.path);
        await temporary.rename(destinationPath);
      } on Object {
        try {
          if (await temporary.exists()) await temporary.delete();
        } on FileSystemException {
          // A partial migration copy is never referenced and can be retried later.
        }
        rethrow;
      }
    }
    return destinationPath;
  }
}

class _RecordingFileMetadata {
  const _RecordingFileMetadata({required this.exists, required this.size});

  final bool exists;
  final int size;
}
