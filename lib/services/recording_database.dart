import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/recording_session.dart';
import '../models/backup_storage_policy.dart';
import '../models/recording_operation_mode.dart';
import '../models/recording_orientation.dart';

typedef AutomaticCleanupRecord = ({
  String eventId,
  String filePath,
  int fileSizeBytes,
  DateTime deletedAt,
  String reason,
});

class LocalRecordingPage {
  const LocalRecordingPage({
    required this.data,
    required this.page,
    required this.pageSize,
    required this.total,
    this.firstCursor,
    this.lastCursor,
    this.availableFileBytesById,
  });

  final List<RecordingSession> data;
  final int page;
  final int pageSize;
  final int total;
  final LocalRecordingCursor? firstCursor;
  final LocalRecordingCursor? lastCursor;
  final Map<String, int>? availableFileBytesById;

  int get pageCount => total <= 0 ? 0 : (total + pageSize - 1) ~/ pageSize;
}

class LocalRecordingCursor {
  const LocalRecordingCursor({required this.startedAt, required this.id});

  final int startedAt;
  final String id;
}

enum LocalRecordingPageDirection { older, newer }

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
    this.ownerId,
    this.operationId,
  });

  final RecordingSession session;
  final bool claimed;
  final bool exhausted;
  final String? ownerId;
  final String? operationId;
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
  RecordingDatabase({
    required this.path,
    this.startSharedFileMigrationWorker = true,
    this.sharedFileMigrationAllowed,
    this.availableStorageBytesForMigration,
    this.sharedFileMigrationDelay = const Duration(milliseconds: 250),
    this.beforeSharedFileMigrationRowForTesting,
    this.beforeExclusiveMaterializationCreateForTesting,
    this.beforeSharedFileCopyChunkForTesting,
    this.afterDatabaseOpenForTesting,
    this.watermarkOwnerIdForTesting,
    this.beforeInterruptedWatermarkRecoveryForTesting,
    this.localStatisticsNowForTesting,
  });

  final String path;
  @visibleForTesting
  final bool startSharedFileMigrationWorker;
  final bool Function()? sharedFileMigrationAllowed;
  final Future<int?> Function(String path)? availableStorageBytesForMigration;
  @visibleForTesting
  final Duration sharedFileMigrationDelay;
  @visibleForTesting
  final Future<void> Function(String sessionId)?
  beforeSharedFileMigrationRowForTesting;
  @visibleForTesting
  final Future<void> Function(String destinationPath)?
  beforeExclusiveMaterializationCreateForTesting;
  @visibleForTesting
  final Future<void> Function()? beforeSharedFileCopyChunkForTesting;
  @visibleForTesting
  final Future<void> Function()? afterDatabaseOpenForTesting;
  @visibleForTesting
  final String? watermarkOwnerIdForTesting;
  @visibleForTesting
  final Future<void> Function(Database database)?
  beforeInterruptedWatermarkRecoveryForTesting;
  @visibleForTesting
  final DateTime Function()? localStatisticsNowForTesting;
  Database? _database;
  Future<Database>? _databaseOpenInFlight;
  Future<void>? _initializationInFlight;
  Future<void>? _sharedFileMigrationWorker;
  Future<void>? _closeInFlight;
  final _AsyncMutex _sharedFileMigrationMutex = _AsyncMutex();
  Completer<void> _sharedFileMigrationCancellation = Completer<void>();
  Completer<void> _sharedFileMigrationPause = Completer<void>();
  bool _closing = false;
  bool _watermarkRecoveryCompleted = false;

  static const int _schemaVersion = 6;
  static final String _watermarkProcessOwnerId =
      '${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}';
  static const String _sharedFileMigrationKey =
      'shared_file_materialization_v1';
  static const String _recordingFileOwnersReadyKey =
      'recording_file_owners_ready_v1';
  static const String _sharedFileMigrationIntentPrefix =
      'shared_file_materialization_intent_v1:';
  static const String _sharedFileMigrationCursorKey =
      'shared_file_materialization_cursor_v1';
  static const String _recordingFileOwnersTable = 'recording_file_owners';
  static const int _sharedFileMigrationBatchSize = 1;
  static const int _sharedFileCopyChunkSize = 1024 * 1024;
  static const String _backupCursorIndex = 'idx_recording_backup_cursor';
  static const String _pendingWatermarkIndex =
      'idx_recording_pending_watermark';
  static const String _recordingStatisticsTable = 'recording_statistics';
  static const String _recordingStatisticsTodayIndex =
      'idx_recording_statistics_today';
  static const String _recordingStatisticsInsertTrigger =
      'trg_recording_statistics_insert';
  static const String _recordingStatisticsDeleteTrigger =
      'trg_recording_statistics_delete';
  static const String _recordingStatisticsUpdateTrigger =
      'trg_recording_statistics_update';

  static const List<String> _sessionPayloadColumns = <String>[
    'payload_json',
    'file_path',
    'recording_orientation',
    'watermark_status',
    'watermark_attempt_count',
  ];

  Future<Database> get _db {
    final Database? current = _database;
    if (current != null) return Future<Database>.value(current);
    if (_closing) {
      return Future<Database>.error(StateError('录像数据库正在关闭'));
    }
    final Future<Database>? active = _databaseOpenInFlight;
    if (active != null) return active;
    late final Future<Database> opening;
    opening = _openAndPublishDatabase().whenComplete(() {
      if (identical(_databaseOpenInFlight, opening)) {
        _databaseOpenInFlight = null;
      }
    });
    _databaseOpenInFlight = opening;
    return opening;
  }

  Future<Database> _openAndPublishDatabase() async {
    if (_sharedFileMigrationCancellation.isCompleted) {
      _sharedFileMigrationCancellation = Completer<void>();
    }
    final Database opened = await _openDatabase();
    await afterDatabaseOpenForTesting?.call();
    if (_closing) {
      await opened.close();
      throw StateError('录像数据库在打开期间被关闭');
    }
    _database = opened;
    _watermarkRecoveryCompleted = false;
    return opened;
  }

  Future<Database> _openDatabase() => openDatabase(
    path,
    version: _schemaVersion,
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
          operation_mode TEXT NOT NULL DEFAULT 'shipping',
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
          watermark_attempt_count INTEGER NOT NULL DEFAULT 0,
          watermark_owner_id TEXT NOT NULL DEFAULT '',
          watermark_operation_id TEXT NOT NULL DEFAULT '',
          watermark_claimed_at INTEGER
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
        'CREATE INDEX idx_recording_active_mode_time ON recording_sessions(is_deleted, operation_mode, started_at DESC, id DESC)',
      );
      await _createRecordingFileOwnersTable(db);
      await _markSharedFileMigrationComplete(db);
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
      await _createBackupCursorIndex(db);
      await _createPendingWatermarkIndex(db);
      await _rebuildRecordingStatistics(
        db,
        todayStart: _todayStartMilliseconds(DateTime.now()),
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
      if (oldVersion < 3) {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS recording_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await _createRecordingFileOwnersTable(db);
        await _createActiveTimeIndex(db);
        await _createBackupCursorIndex(db);
        await _createPendingWatermarkIndex(db);
      }
      if (oldVersion < 4) {
        await db.execute(
          "ALTER TABLE recording_sessions ADD COLUMN watermark_owner_id "
          "TEXT NOT NULL DEFAULT ''",
        );
        await db.execute(
          "ALTER TABLE recording_sessions ADD COLUMN watermark_operation_id "
          "TEXT NOT NULL DEFAULT ''",
        );
        await db.execute(
          'ALTER TABLE recording_sessions ADD COLUMN watermark_claimed_at INTEGER',
        );
        // schema v3 databases already skipped the oldVersion < 3 block. Both
        // indexes are therefore unconditional parts of the v4 contract.
        await _createBackupCursorIndex(db);
        await _createPendingWatermarkIndex(db);
      }
      if (oldVersion < 5) {
        await _rebuildRecordingStatistics(
          db,
          todayStart: _todayStartMilliseconds(DateTime.now()),
        );
      }
      if (oldVersion < 6) {
        await db.execute(
          "ALTER TABLE recording_sessions ADD COLUMN operation_mode TEXT NOT NULL DEFAULT 'shipping'",
        );
        String? lastId;
        while (true) {
          final rows = await db.query(
            'recording_sessions',
            columns: ['id', 'payload_json'],
            where: lastId == null ? null : 'id > ?',
            whereArgs: lastId == null ? null : [lastId],
            orderBy: 'id',
            limit: 200,
          );
          if (rows.isEmpty) break;
          final batch = db.batch();
          for (final row in rows) {
            final payload =
                jsonDecode(row['payload_json']! as String)
                    as Map<String, dynamic>;
            batch.update(
              'recording_sessions',
              {
                'operation_mode': recordingOperationModeFromStorage(
                  payload['operationMode'],
                ).storageValue,
              },
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }
          await batch.commit(noResult: true);
          lastId = rows.last['id']! as String;
        }
        await db.execute(
          'CREATE INDEX idx_recording_active_mode_time ON recording_sessions(is_deleted, operation_mode, started_at DESC, id DESC)',
        );
      }
    },
  );

  Future<void> initialize() async {
    if (_closing) throw StateError('录像数据库正在关闭');
    final Future<void>? active = _initializationInFlight;
    if (active != null) return active;
    final Future<void> initialization = _initializeOnce();
    _initializationInFlight = initialization;
    try {
      await initialization;
    } finally {
      if (identical(_initializationInFlight, initialization)) {
        _initializationInFlight = null;
      }
    }
  }

  Future<void> _initializeOnce() async {
    final Database db = await _db;
    // Also repairs databases created by an unreleased development build that
    // already reports schema v3 but predates the bounded migration table.
    await _createRecordingFileOwnersTable(db);
    await _createActiveTimeIndex(db);
    await _createBackupCursorIndex(db);
    await _createPendingWatermarkIndex(db);
    await _repairRecordingStatisticsIfNeeded(db);
    if (!_watermarkRecoveryCompleted) {
      await beforeInterruptedWatermarkRecoveryForTesting?.call(db);
      await _recoverInterruptedWatermarkClaims(db);
      _watermarkRecoveryCompleted = true;
    }
    if (!await _sharedFileMigrationCompleted(db)) {
      _startSharedFileMigrationWorker(db);
    }
  }

  static Future<void> _createRecordingFileOwnersTable(DatabaseExecutor db) =>
      db.execute('''
    CREATE TABLE IF NOT EXISTS $_recordingFileOwnersTable (
      normalized_path TEXT PRIMARY KEY,
      retained_session_id TEXT NOT NULL UNIQUE
    )
  ''');

  static Future<void> _createActiveTimeIndex(DatabaseExecutor db) => db.execute(
    'CREATE INDEX IF NOT EXISTS idx_recording_active_time '
    'ON recording_sessions(is_deleted, started_at DESC, id DESC)',
  );

  static Future<void> _createBackupCursorIndex(DatabaseExecutor db) =>
      db.execute(
        'CREATE INDEX IF NOT EXISTS $_backupCursorIndex '
        'ON recording_sessions(updated_at ASC, id ASC) '
        "WHERE is_deleted = 0 AND watermark_status IN ('completed', 'failed')",
      );

  static Future<void> _createPendingWatermarkIndex(DatabaseExecutor db) =>
      db.execute(
        'CREATE INDEX IF NOT EXISTS $_pendingWatermarkIndex '
        'ON recording_sessions(watermark_status, is_deleted, started_at, id)',
      );

  static int _todayStartMilliseconds(DateTime now) =>
      DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;

  Future<void> _repairRecordingStatisticsIfNeeded(Database db) async {
    const Set<String> requiredObjects = <String>{
      _recordingStatisticsTable,
      _recordingStatisticsTodayIndex,
      _recordingStatisticsInsertTrigger,
      _recordingStatisticsDeleteTrigger,
      _recordingStatisticsUpdateTrigger,
    };
    final List<Map<String, Object?>> objects = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE name IN (?, ?, ?, ?, ?)",
      requiredObjects.toList(growable: false),
    );
    final Set<String> existing = objects
        .map((Map<String, Object?> row) => row['name']! as String)
        .toSet();
    var hasSummaryRow = false;
    if (existing.contains(_recordingStatisticsTable)) {
      hasSummaryRow =
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM $_recordingStatisticsTable WHERE id = 1',
            ),
          ) ==
          1;
    }
    if (existing.containsAll(requiredObjects) && hasSummaryRow) return;
    await db.transaction((Transaction txn) async {
      await _rebuildRecordingStatistics(
        txn,
        todayStart: _todayStartMilliseconds(
          localStatisticsNowForTesting?.call() ?? DateTime.now(),
        ),
      );
    });
  }

  static Future<void> _rebuildRecordingStatistics(
    DatabaseExecutor db, {
    required int todayStart,
  }) async {
    await db.execute(
      'DROP TRIGGER IF EXISTS $_recordingStatisticsInsertTrigger',
    );
    await db.execute(
      'DROP TRIGGER IF EXISTS $_recordingStatisticsDeleteTrigger',
    );
    await db.execute(
      'DROP TRIGGER IF EXISTS $_recordingStatisticsUpdateTrigger',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_recordingStatisticsTable (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        total_count INTEGER NOT NULL,
        today_count INTEGER NOT NULL,
        total_bytes INTEGER NOT NULL,
        today_start_ms INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS $_recordingStatisticsTodayIndex '
      'ON recording_sessions(started_at) '
      'WHERE is_deleted = 0 AND missing_at IS NULL',
    );
    await db.delete(_recordingStatisticsTable);
    await db.rawInsert(
      '''
      INSERT INTO $_recordingStatisticsTable (
        id, total_count, today_count, total_bytes, today_start_ms
      )
      SELECT
        1,
        COUNT(*),
        COALESCE(SUM(CASE WHEN started_at >= ? THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(file_size_bytes), 0),
        ?
      FROM recording_sessions
      WHERE is_deleted = 0 AND missing_at IS NULL
    ''',
      <Object?>[todayStart, todayStart],
    );
    await db.execute('''
      CREATE TRIGGER $_recordingStatisticsInsertTrigger
      AFTER INSERT ON recording_sessions
      BEGIN
        UPDATE $_recordingStatisticsTable SET
          total_count = total_count +
            CASE WHEN NEW.is_deleted = 0 AND NEW.missing_at IS NULL
              THEN 1 ELSE 0 END,
          today_count = today_count +
            CASE WHEN NEW.is_deleted = 0 AND NEW.missing_at IS NULL
              AND NEW.started_at >= today_start_ms THEN 1 ELSE 0 END,
          total_bytes = total_bytes +
            CASE WHEN NEW.is_deleted = 0 AND NEW.missing_at IS NULL
              THEN NEW.file_size_bytes ELSE 0 END
        WHERE id = 1;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER $_recordingStatisticsDeleteTrigger
      AFTER DELETE ON recording_sessions
      BEGIN
        UPDATE $_recordingStatisticsTable SET
          total_count = total_count -
            CASE WHEN OLD.is_deleted = 0 AND OLD.missing_at IS NULL
              THEN 1 ELSE 0 END,
          today_count = today_count -
            CASE WHEN OLD.is_deleted = 0 AND OLD.missing_at IS NULL
              AND OLD.started_at >= today_start_ms THEN 1 ELSE 0 END,
          total_bytes = total_bytes -
            CASE WHEN OLD.is_deleted = 0 AND OLD.missing_at IS NULL
              THEN OLD.file_size_bytes ELSE 0 END
        WHERE id = 1;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER $_recordingStatisticsUpdateTrigger
      AFTER UPDATE OF is_deleted, missing_at, file_size_bytes, started_at
      ON recording_sessions
      BEGIN
        UPDATE $_recordingStatisticsTable SET
          total_count = total_count
            - CASE WHEN OLD.is_deleted = 0 AND OLD.missing_at IS NULL
                THEN 1 ELSE 0 END
            + CASE WHEN NEW.is_deleted = 0 AND NEW.missing_at IS NULL
                THEN 1 ELSE 0 END,
          today_count = today_count
            - CASE WHEN OLD.is_deleted = 0 AND OLD.missing_at IS NULL
                AND OLD.started_at >= today_start_ms THEN 1 ELSE 0 END
            + CASE WHEN NEW.is_deleted = 0 AND NEW.missing_at IS NULL
                AND NEW.started_at >= today_start_ms THEN 1 ELSE 0 END,
          total_bytes = total_bytes
            - CASE WHEN OLD.is_deleted = 0 AND OLD.missing_at IS NULL
                THEN OLD.file_size_bytes ELSE 0 END
            + CASE WHEN NEW.is_deleted = 0 AND NEW.missing_at IS NULL
                THEN NEW.file_size_bytes ELSE 0 END
        WHERE id = 1;
      END
    ''');
  }

  String get _watermarkOwnerId =>
      watermarkOwnerIdForTesting ?? _watermarkProcessOwnerId;

  Future<void> _recoverInterruptedWatermarkClaims(Database db) async {
    await db.update(
      'recording_sessions',
      <String, Object?>{
        'watermark_status': WatermarkProcessingStatus.failed.storageValue,
        'watermark_owner_id': '',
        'watermark_operation_id': '',
        'watermark_claimed_at': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where:
          "is_deleted = 0 AND watermark_status = 'processing' "
          'AND watermark_owner_id != ?',
      whereArgs: <Object?>[_watermarkOwnerId],
    );
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

  Future<void> close() {
    final Future<void>? active = _closeInFlight;
    if (active != null) return active;
    late final Future<void> closing;
    closing = _closeOnce().whenComplete(() {
      if (identical(_closeInFlight, closing)) _closeInFlight = null;
    });
    _closeInFlight = closing;
    return closing;
  }

  Future<void> _closeOnce() async {
    _closing = true;
    if (!_sharedFileMigrationCancellation.isCompleted) {
      _sharedFileMigrationCancellation.complete();
    }
    try {
      try {
        await _initializationInFlight;
      } on Object {
        // broad-catch: Opening interrupted by close is expected to fail before publishing.
      }
      try {
        await _databaseOpenInFlight;
      } on Object {
        // broad-catch: The open path closes its unpublished handle when close wins the race.
      }
      await _sharedFileMigrationWorker;
      await _sharedFileMigrationMutex.drained;
      final Database? database = _database;
      _database = null;
      await database?.close();
    } finally {
      _closing = false;
    }
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
      if (sessions.isNotEmpty) {
        await _resetSharedFileMigration(txn);
      }
    });

    if (sessions.isNotEmpty) _startSharedFileMigrationWorker(db);

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

  Future<LocalRecordingPage> queryActiveSessions({
    required int page,
    required int pageSize,
    String keyword = '',
    RecordingOperationMode? operationMode,
    DateTime? start,
    DateTime? end,
  }) async {
    if (page != 1) {
      throw ArgumentError.value(
        page,
        'page',
        '首屏查询只能请求第 1 页，后续页必须使用 keyset 游标',
      );
    }
    return _queryActiveSessions(
      page: page,
      pageSize: pageSize,
      keyword: keyword,
      operationMode: operationMode,
      start: start,
      end: end,
    );
  }

  Future<LocalRecordingPage> queryAdjacentActiveSessions({
    required int page,
    required int pageSize,
    required LocalRecordingCursor cursor,
    required LocalRecordingPageDirection direction,
    required int knownTotal,
    String keyword = '',
    RecordingOperationMode? operationMode,
    DateTime? start,
    DateTime? end,
  }) => _queryActiveSessions(
    page: page,
    pageSize: pageSize,
    keyword: keyword,
    operationMode: operationMode,
    start: start,
    end: end,
    cursor: cursor,
    direction: direction,
    knownTotal: knownTotal,
  );

  Future<LocalRecordingPage> _queryActiveSessions({
    required int page,
    required int pageSize,
    required String keyword,
    RecordingOperationMode? operationMode,
    required DateTime? start,
    required DateTime? end,
    LocalRecordingCursor? cursor,
    LocalRecordingPageDirection? direction,
    int? knownTotal,
  }) async {
    final Database db = await _db;
    final int normalizedPage = page < 1 ? 1 : page;
    final int normalizedSize = pageSize.clamp(1, 100);
    final String query = keyword.trim().toLowerCase();
    final List<String> conditions = <String>['is_deleted = 0'];
    final List<Object?> args = <Object?>[];
    if (operationMode != null) {
      conditions.add('operation_mode = ?');
      args.add(operationMode.storageValue);
    }
    if (query.isNotEmpty) {
      conditions.add('instr(search_text, ?) > 0');
      args.add(query);
    }
    if (start != null) {
      conditions.add('started_at >= ?');
      args.add(start.millisecondsSinceEpoch);
    }
    if (end != null) {
      conditions.add('started_at < ?');
      args.add(end.millisecondsSinceEpoch);
    }
    final String countWhere = conditions.join(' AND ');
    final List<Object?> countArgs = List<Object?>.of(args, growable: false);
    if (cursor != null && direction != null) {
      final ({String primary, String tieBreak}) comparisons =
          switch (direction) {
            LocalRecordingPageDirection.older => (primary: '<', tieBreak: '<'),
            LocalRecordingPageDirection.newer => (primary: '>', tieBreak: '>'),
          };
      // Android 7.0/7.1 ship SQLite 3.9.2; row-value comparisons were not
      // supported until SQLite 3.15. Keep the compound keyset predicate scalar.
      conditions.add(
        '(started_at ${comparisons.primary} ? OR '
        '(started_at = ? AND id ${comparisons.tieBreak} ?))',
      );
      args.addAll(<Object?>[cursor.startedAt, cursor.startedAt, cursor.id]);
    }
    final String where = conditions.join(' AND ');
    final int total;
    if (knownTotal == null) {
      final List<Map<String, Object?>> countRows = await db.rawQuery(
        'SELECT COUNT(1) AS total FROM recording_sessions '
        'WHERE $countWhere',
        countArgs,
      );
      total = Sqflite.firstIntValue(countRows) ?? 0;
    } else {
      total = knownTotal;
    }
    final bool ascending = direction == LocalRecordingPageDirection.newer;
    List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT ${<String>[..._sessionPayloadColumns, 'started_at', 'id', 'file_size_bytes', 'missing_at'].join(', ')} '
      'FROM recording_sessions INDEXED BY idx_recording_active_time '
      'WHERE $where '
      'ORDER BY started_at ${ascending ? 'ASC' : 'DESC'}, '
      'id ${ascending ? 'ASC' : 'DESC'} LIMIT ?',
      <Object?>[...args, normalizedSize],
    );
    if (ascending) rows = rows.reversed.toList(growable: false);
    LocalRecordingCursor? cursorFor(Map<String, Object?> row) =>
        LocalRecordingCursor(
          startedAt: row['started_at']! as int,
          id: row['id']! as String,
        );
    final Map<String, int> availableFileBytesById = <String, int>{};
    for (final Map<String, Object?> row in rows) {
      if (row['missing_at'] != null) continue;
      final int size = (row['file_size_bytes'] as num?)?.toInt() ?? 0;
      availableFileBytesById[row['id']! as String] = size < 0 ? 0 : size;
    }
    return LocalRecordingPage(
      data: rows.map(_sessionFromRow).toList(growable: false),
      page: normalizedPage,
      pageSize: normalizedSize,
      total: total,
      firstCursor: rows.isEmpty ? null : cursorFor(rows.first),
      lastCursor: rows.isEmpty ? null : cursorFor(rows.last),
      availableFileBytesById: availableFileBytesById,
    );
  }

  @visibleForTesting
  Future<List<String>> explainActiveSessionCursorQueryForTesting({
    required LocalRecordingCursor cursor,
    LocalRecordingPageDirection direction = LocalRecordingPageDirection.older,
  }) async {
    final Database db = await _db;
    final String comparison = direction == LocalRecordingPageDirection.older
        ? '<'
        : '>';
    final String order = direction == LocalRecordingPageDirection.older
        ? 'DESC'
        : 'ASC';
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT id FROM recording_sessions '
      'INDEXED BY idx_recording_active_time '
      'WHERE is_deleted = 0 AND '
      '(started_at $comparison ? OR '
      '(started_at = ? AND id $comparison ?)) '
      'ORDER BY started_at $order, id $order LIMIT ?',
      <Object?>[cursor.startedAt, cursor.startedAt, cursor.id, 100],
    );
    return rows
        .map((Map<String, Object?> row) => row.values.join(' '))
        .toList(growable: false);
  }

  /// 录像写入热路径只需要刷新界面最近记录，不计算随总量增长的完整总数。
  Future<List<RecordingSession>> loadRecentActiveSessions({
    int limit = 50,
  }) async {
    final Database db = await _db;
    final int normalizedLimit = limit.clamp(1, 100);
    final List<Map<String, Object?>> rows = await db.query(
      'recording_sessions',
      columns: _sessionPayloadColumns,
      where: 'is_deleted = 0',
      orderBy: 'started_at DESC, id DESC',
      limit: normalizedLimit,
    );
    return rows.map(_sessionFromRow).toList(growable: false);
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
      'SELECT 1 FROM recording_sessions '
      'WHERE is_deleted = 0 AND tracking_number = ? AND started_at >= ? '
      'LIMIT 1',
      <Object?>[normalized, since],
    );
    return rows.isNotEmpty;
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
      // Keep an explicit range anchor so SQLite can seek the composite index;
      // row-value comparisons are unavailable on Android API 24 SQLite 3.9.
      conditions.add('updated_at >= ?');
      conditions.add('(updated_at > ? OR id > ?)');
      args.addAll(<Object?>[afterUpdatedAt, afterUpdatedAt, afterId]);
    }
    if (highUpdatedAt != null && highId != null) {
      conditions.add('updated_at <= ?');
      conditions.add('(updated_at < ? OR id <= ?)');
      args.addAll(<Object?>[highUpdatedAt, highUpdatedAt, highId]);
    }
    final String where = conditions.join(' AND ');
    final int normalizedSize = pageSize.clamp(1, 1000);
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT ${<String>[..._sessionPayloadColumns, 'updated_at', 'id'].join(', ')} '
      'FROM recording_sessions INDEXED BY $_backupCursorIndex '
      'WHERE $where ORDER BY updated_at ASC, id ASC LIMIT ?',
      <Object?>[...args, normalizedSize],
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
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT updated_at, id '
      'FROM recording_sessions INDEXED BY $_backupCursorIndex '
      "WHERE is_deleted = 0 AND watermark_status IN ('completed', 'failed') "
      'ORDER BY updated_at DESC, id DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    return (
      updatedAt: rows.first['updated_at']! as int,
      id: rows.first['id']! as String,
    );
  }

  @visibleForTesting
  Future<List<String>> explainBackupCursorQueryForTesting({
    int? afterUpdatedAt,
    String? afterId,
  }) async {
    final Database db = await _db;
    final bool hasCursor = afterUpdatedAt != null && afterId != null;
    final String cursorClause = hasCursor
        ? ' AND updated_at >= ? AND (updated_at > ? OR id > ?)'
        : '';
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT updated_at, id FROM recording_sessions '
      'INDEXED BY $_backupCursorIndex '
      "WHERE is_deleted = 0 AND watermark_status IN ('completed', 'failed')"
      '$cursorClause ORDER BY updated_at ASC, id ASC LIMIT 100',
      hasCursor
          ? <Object?>[afterUpdatedAt, afterUpdatedAt, afterId]
          : const <Object?>[],
    );
    return rows
        .map((Map<String, Object?> row) => row['detail']?.toString() ?? '')
        .toList(growable: false);
  }

  @visibleForTesting
  Future<List<String>> explainWatermarkRecoveryQueryForTesting() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT id FROM recording_sessions '
      'INDEXED BY $_pendingWatermarkIndex '
      "WHERE is_deleted = 0 AND watermark_status = 'processing' "
      'AND watermark_owner_id != ? LIMIT 1',
      <Object?>[_watermarkOwnerId],
    );
    return rows
        .map((Map<String, Object?> row) => row['detail']?.toString() ?? '')
        .toList(growable: false);
  }

  Future<LocalRecordingStatistics> loadLocalRecordingStatistics() async {
    final Database db = await _db;
    final int todayStart = _todayStartMilliseconds(
      localStatisticsNowForTesting?.call() ?? DateTime.now(),
    );
    return db.transaction((Transaction txn) async {
      List<Map<String, Object?>> rows = await txn.query(
        _recordingStatisticsTable,
        where: 'id = 1',
        limit: 1,
      );
      if (rows.isEmpty) return const LocalRecordingStatistics();
      if ((rows.single['today_start_ms'] as num).toInt() != todayStart) {
        await txn.rawUpdate(
          '''
          UPDATE $_recordingStatisticsTable SET
            today_count = (
              SELECT COUNT(*) FROM recording_sessions
              INDEXED BY $_recordingStatisticsTodayIndex
              WHERE is_deleted = 0 AND missing_at IS NULL
                AND started_at >= ?
            ),
            today_start_ms = ?
          WHERE id = 1
        ''',
          <Object?>[todayStart, todayStart],
        );
        rows = await txn.query(
          _recordingStatisticsTable,
          where: 'id = 1',
          limit: 1,
        );
      }
      return LocalRecordingStatistics(
        total: (rows.single['total_count'] as num).toInt(),
        today: (rows.single['today_count'] as num).toInt(),
        totalBytes: (rows.single['total_bytes'] as num).toInt(),
      );
    });
  }

  @visibleForTesting
  Future<List<String>> explainLocalStatisticsQueryForTesting() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT total_count, today_count, total_bytes '
      'FROM $_recordingStatisticsTable WHERE id = 1',
    );
    return rows
        .map((Map<String, Object?> row) => row['detail']?.toString() ?? '')
        .toList(growable: false);
  }

  @visibleForTesting
  Future<List<String>> explainTodayStatisticsRebuildForTesting(
    int todayStart,
  ) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT COUNT(*) FROM recording_sessions '
      'INDEXED BY $_recordingStatisticsTodayIndex '
      'WHERE is_deleted = 0 AND missing_at IS NULL AND started_at >= ?',
      <Object?>[todayStart],
    );
    return rows
        .map((Map<String, Object?> row) => row['detail']?.toString() ?? '')
        .toList(growable: false);
  }

  @visibleForTesting
  Future<void> runTransactionForTesting(
    Future<void> Function(Transaction transaction) action,
  ) async {
    final Database db = await _db;
    await db.transaction(action);
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
    final Map<String, String> requestedOwners = _validateDistinctFileReferences(
      sessions,
    );
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
      final List<String> normalizedPaths = requestedOwners.keys.toList(
        growable: false,
      );
      const int ownerQueryBatchSize = 500;
      for (
        var start = 0;
        start < normalizedPaths.length;
        start += ownerQueryBatchSize
      ) {
        final int end = (start + ownerQueryBatchSize).clamp(
          0,
          normalizedPaths.length,
        );
        final List<String> paths = normalizedPaths.sublist(start, end);
        final String placeholders = List<String>.filled(
          paths.length,
          '?',
        ).join(',');
        final List<Map<String, Object?>> conflicts = await txn.query(
          _recordingFileOwnersTable,
          columns: const <String>['normalized_path', 'retained_session_id'],
          where: 'normalized_path IN ($placeholders)',
          whereArgs: paths,
        );
        for (final Map<String, Object?> conflict in conflicts) {
          final String normalizedPath = conflict['normalized_path']! as String;
          if (conflict['retained_session_id'] !=
              requestedOwners[normalizedPath]) {
            throw StateError('一条录像文件只能对应一条录像记录');
          }
        }
      }
      final Batch batch = txn.batch();
      for (final RecordingSession session in sessions) {
        batch.delete(
          _recordingFileOwnersTable,
          where: 'retained_session_id = ?',
          whereArgs: <Object?>[session.id],
        );
      }
      for (var index = 0; index < rows.length; index++) {
        final RecordingSession session = sessions[index];
        batch.insert(_recordingFileOwnersTable, <String, Object?>{
          'normalized_path': _normalizedFilePath(session.filePath),
          'retained_session_id': session.id,
        }, conflictAlgorithm: ConflictAlgorithm.abort);
        batch.update(
          'recording_sessions',
          rows[index],
          where: 'id = ?',
          whereArgs: <Object?>[session.id],
        );
        batch.insert(
          'recording_sessions',
          rows[index],
          conflictAlgorithm: ConflictAlgorithm.ignore,
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

  Future<List<RecordingSession>> loadPendingWatermarkSessions({
    int limit = 1,
    int? afterStartedAt,
    String? afterId,
  }) async {
    if ((afterStartedAt == null) != (afterId == null)) {
      throw ArgumentError('水印游标时间与 ID 必须同时提供');
    }
    final Database db = await _db;
    final int normalizedLimit = limit.clamp(1, 100);
    final bool hasCursor = afterStartedAt != null;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT ${_sessionPayloadColumns.join(', ')} FROM recording_sessions '
      'INDEXED BY $_pendingWatermarkIndex '
      "WHERE watermark_status = 'pending' AND is_deleted = 0 "
      '${hasCursor ? 'AND (started_at > ? OR (started_at = ? AND id > ?)) ' : ''}'
      'ORDER BY started_at ASC, id ASC LIMIT ?',
      <Object?>[
        if (hasCursor) afterStartedAt,
        if (hasCursor) afterStartedAt,
        if (hasCursor) afterId,
        normalizedLimit,
      ],
    );
    return rows.map(_sessionFromRow).toList(growable: false);
  }

  @visibleForTesting
  Future<List<String>> explainPendingWatermarkQueryForTesting() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT id FROM recording_sessions '
      'INDEXED BY $_pendingWatermarkIndex '
      "WHERE watermark_status = 'pending' AND is_deleted = 0 "
      'ORDER BY started_at ASC, id ASC LIMIT 1',
    );
    return rows
        .map((Map<String, Object?> row) => row.values.join(' '))
        .toList(growable: false);
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
        watermarkStatus: WatermarkProcessingStatus.processing,
        watermarkAttemptCount: current.watermarkAttemptCount + 1,
      );
      final String operationId =
          '$_watermarkOwnerId:$sessionId:${DateTime.now().microsecondsSinceEpoch}';
      final int updated = await txn.update(
        'recording_sessions',
        <String, Object?>{
          'payload_json': jsonEncode(claimed.toJson()),
          'watermark_status': claimed.watermarkStatus.storageValue,
          'watermark_attempt_count': claimed.watermarkAttemptCount,
          'watermark_owner_id': _watermarkOwnerId,
          'watermark_operation_id': operationId,
          'watermark_claimed_at': now,
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
          ownerId: _watermarkOwnerId,
          operationId: operationId,
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

  Future<RecordingSession?> finalizeWatermarkClaim({
    required RecordingSession session,
    required String ownerId,
    required String operationId,
  }) async {
    final Database db = await _db;
    final _RecordingFileMetadata metadata = await _readFileMetadata(
      File(session.filePath),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Map<String, Object?> row = await _sessionRow(
      session,
      fileMetadata: metadata,
      now: now,
    );
    return db.transaction((Transaction txn) async {
      final List<Map<String, Object?>> current = await txn.query(
        'recording_sessions',
        columns: const <String>['id'],
        where:
            "id = ? AND is_deleted = 0 AND watermark_status = 'processing' "
            'AND watermark_owner_id = ? AND watermark_operation_id = ?',
        whereArgs: <Object?>[session.id, ownerId, operationId],
        limit: 1,
      );
      if (current.isEmpty) return null;
      await _claimFileOwnership(
        txn,
        sessionId: session.id,
        filePath: session.filePath,
      );
      final int updated = await txn.update(
        'recording_sessions',
        <String, Object?>{
          'file_path': row['file_path'],
          'started_at': row['started_at'],
          'ended_at': row['ended_at'],
          'tracking_number': row['tracking_number'],
          'order_id': row['order_id'],
          'search_text': row['search_text'],
          'payload_json': row['payload_json'],
          'file_size_bytes': row['file_size_bytes'],
          'missing_at': row['missing_at'],
          'updated_at': now,
          'recording_orientation': row['recording_orientation'],
          'watermark_status': row['watermark_status'],
          'watermark_attempt_count': row['watermark_attempt_count'],
          'watermark_owner_id': '',
          'watermark_operation_id': '',
          'watermark_claimed_at': null,
        },
        where:
            "id = ? AND is_deleted = 0 AND watermark_status = 'processing' "
            'AND watermark_owner_id = ? AND watermark_operation_id = ?',
        whereArgs: <Object?>[session.id, ownerId, operationId],
      );
      return updated == 1 ? session : null;
    });
  }

  Future<RecordingSession?> failProcessingWatermark({
    required String sessionId,
    required String ownerId,
    required String operationId,
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
          current.watermarkStatus != WatermarkProcessingStatus.processing) {
        return current;
      }
      final RecordingSession failed = current.copyWith(
        watermarkStatus: WatermarkProcessingStatus.failed,
      );
      final int updated = await txn.update(
        'recording_sessions',
        <String, Object?>{
          'payload_json': jsonEncode(failed.toJson()),
          'watermark_status': failed.watermarkStatus.storageValue,
          'watermark_owner_id': '',
          'watermark_operation_id': '',
          'watermark_claimed_at': null,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where:
            "id = ? AND is_deleted = 0 AND watermark_status = 'processing' "
            'AND watermark_owner_id = ? AND watermark_operation_id = ?',
        whereArgs: <Object?>[sessionId, ownerId, operationId],
      );
      if (updated != 1) return null;
      return loadCurrent();
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
        batch.delete(
          _recordingFileOwnersTable,
          where: 'retained_session_id = ?',
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
    await db.transaction((Transaction txn) async {
      await _recordAutomaticCleanup(txn, (
        eventId: normalizedEventId,
        filePath: filePath,
        fileSizeBytes: fileSizeBytes,
        deletedAt: deletedAt,
        reason: reason,
      ));
    });
  }

  Future<void> recordAutomaticCleanupPage({
    required List<AutomaticCleanupRecord> events,
    required int nextAfterRevision,
    required String cursorMetadataKey,
  }) async {
    if (events.length > 100) {
      throw ArgumentError.value(events.length, 'events', '单页不能超过 100 条');
    }
    if (nextAfterRevision < 0) {
      throw ArgumentError.value(
        nextAfterRevision,
        'nextAfterRevision',
        '不能小于 0',
      );
    }
    final Database db = await _db;
    await db.transaction((Transaction txn) async {
      for (final AutomaticCleanupRecord event in events) {
        if (event.eventId.trim().isEmpty || event.filePath.trim().isEmpty) {
          continue;
        }
        await _recordAutomaticCleanup(txn, event);
      }
      await txn.insert('recording_metadata', <String, Object?>{
        'key': cursorMetadataKey,
        'value': nextAfterRevision.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> _recordAutomaticCleanup(
    Transaction txn,
    AutomaticCleanupRecord event,
  ) async {
    final String metadataKey = 'cleanup_audit:${event.eventId.trim()}';
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
      whereArgs: <Object?>[event.filePath],
    );
    final int deletedAtMillis = event.deletedAt.millisecondsSinceEpoch;
    for (final Map<String, Object?> row in rows) {
      await txn.insert('recording_delete_logs', <String, Object?>{
        'file_path': event.filePath,
        'session_id': row['id']! as String,
        'tracking_number': row['tracking_number']! as String,
        'file_size_bytes': event.fileSizeBytes < 0 ? 0 : event.fileSizeBytes,
        'deleted_at': deletedAtMillis,
        'reason': event.reason,
      });
    }
    await txn.update(
      'recording_sessions',
      <String, Object?>{
        'missing_at': deletedAtMillis,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'is_deleted = 0 AND file_path = ?',
      whereArgs: <Object?>[event.filePath],
    );
    await txn.insert('recording_metadata', <String, Object?>{
      'key': metadataKey,
      'value': event.deletedAt.toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<int> activeReferenceCount(String filePath) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COUNT(1) FROM $_recordingFileOwnersTable owners '
      'INNER JOIN recording_sessions sessions '
      'ON sessions.id = owners.retained_session_id '
      'WHERE sessions.is_deleted = 0 AND owners.normalized_path = ?',
      <Object?>[_normalizedFilePath(filePath)],
    );
    final int owned = Sqflite.firstIntValue(rows) ?? 0;
    if (owned > 0) return owned;
    final List<Map<String, Object?>> exact = await db.rawQuery(
      'SELECT COUNT(1) FROM recording_sessions '
      'WHERE is_deleted = 0 AND file_path = ?',
      <Object?>[filePath],
    );
    final int exactReferences = Sqflite.firstIntValue(exact) ?? 0;
    if (exactReferences > 0) return exactReferences;
    // 旧数据库的 owner 索引尚未完整建立时，规范化等价的路径别名可能
    // 仍引用同一物理文件。删除路径必须 fail-closed，不能为了确认引用
    // 而在 UI isolate 扫描上万条 file_path。
    if (!await _sharedFileMigrationCompleted(db)) return 1;
    return 0;
  }

  Future<void> repairFilePaths(Map<String, String> resolvedPaths) async {
    if (resolvedPaths.isEmpty) return;
    final Database db = await _db;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((Transaction txn) async {
      for (final MapEntry<String, String> entry in resolvedPaths.entries) {
        final List<Map<String, Object?>> current = await txn.query(
          'recording_sessions',
          columns: const <String>['file_path'],
          where: 'id = ? AND is_deleted = 0 AND file_path != ?',
          whereArgs: <Object?>[entry.key, entry.value],
          limit: 1,
        );
        if (current.isEmpty) continue;
        await _claimFileOwnership(
          txn,
          sessionId: entry.key,
          filePath: entry.value,
        );
        await txn.update(
          'recording_sessions',
          <String, Object?>{
            'file_path': entry.value,
            'missing_at': null,
            'updated_at': now,
          },
          where: 'id = ? AND file_path != ?',
          whereArgs: <Object?>[entry.key, entry.value],
        );
      }
    });
  }

  static Future<void> _claimFileOwnership(
    DatabaseExecutor db, {
    required String sessionId,
    required String filePath,
  }) async {
    await db.delete(
      _recordingFileOwnersTable,
      where: 'retained_session_id = ?',
      whereArgs: <Object?>[sessionId],
    );
    await db.insert(_recordingFileOwnersTable, <String, Object?>{
      'normalized_path': _normalizedFilePath(filePath),
      'retained_session_id': sessionId,
    }, conflictAlgorithm: ConflictAlgorithm.abort);
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
      'operation_mode': session.operationMode.storageValue,
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
      p.posix.normalize(filePath.replaceAll('\\', '/'));

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

  Map<String, String> _validateDistinctFileReferences(
    List<RecordingSession> sessions,
  ) {
    final Map<String, String> requestedOwners = <String, String>{};
    for (final RecordingSession session in sessions) {
      final String normalized = _normalizedFilePath(session.filePath);
      final String? owner = requestedOwners[normalized];
      if (owner != null && owner != session.id) {
        throw StateError('一条录像文件只能对应一条录像记录');
      }
      requestedOwners[normalized] = session.id;
    }
    return requestedOwners;
  }

  Future<_SharedFileMigrationBatchResult>
  _materializeSharedFileReferencesIfNeeded(Database db) async {
    if (await _sharedFileMigrationCompleted(db)) {
      return const _SharedFileMigrationBatchResult(
        completed: true,
        progressed: false,
      );
    }

    final ({int startedAt, String id})? after =
        await _loadSharedFileMigrationCursor(db);
    final List<Map<String, Object?>> rows = await _loadSharedFileMigrationBatch(
      db,
      after: after,
    );
    if (rows.isEmpty) {
      await _completeSharedFileMigration(db);
      return const _SharedFileMigrationBatchResult(
        completed: true,
        progressed: false,
      );
    }

    final Map<String, Object?> row = rows.single;
    if (!await _materializeSharedFileReference(db, row)) {
      return const _SharedFileMigrationBatchResult(
        completed: false,
        progressed: false,
      );
    }
    final ({int startedAt, String id}) processedThrough = (
      startedAt: row['started_at']! as int,
      id: row['id']! as String,
    );
    await _saveSharedFileMigrationCursor(db, processedThrough);

    final bool hasMore = await _hasSharedFileMigrationRowsAfter(
      db,
      processedThrough,
    );
    if (!hasMore) {
      await _completeSharedFileMigration(db);
      return const _SharedFileMigrationBatchResult(
        completed: true,
        progressed: true,
      );
    }
    return const _SharedFileMigrationBatchResult(
      completed: false,
      progressed: true,
    );
  }

  Future<bool> _sharedFileMigrationCompleted(Database db) async {
    final List<Map<String, Object?>> completed = await db.query(
      'recording_metadata',
      columns: const <String>['key'],
      where: 'key IN (?, ?)',
      whereArgs: <Object?>[
        _sharedFileMigrationKey,
        _recordingFileOwnersReadyKey,
      ],
    );
    return completed.length == 2;
  }

  void _startSharedFileMigrationWorker(Database db) {
    if (!startSharedFileMigrationWorker ||
        _closing ||
        _sharedFileMigrationWorker != null) {
      return;
    }
    late final Future<void> worker;
    worker = _runSharedFileMigrationWorker(db).whenComplete(() {
      if (identical(_sharedFileMigrationWorker, worker)) {
        _sharedFileMigrationWorker = null;
      }
    });
    _sharedFileMigrationWorker = worker;
    unawaited(worker);
  }

  Future<void> _runSharedFileMigrationWorker(Database db) async {
    try {
      while (!_closing && identical(_database, db)) {
        if (sharedFileMigrationAllowed?.call() == false) return;
        if (!await _waitForSharedFileMigrationDelay()) return;
        if (sharedFileMigrationAllowed?.call() == false) return;
        final _SharedFileMigrationBatchResult result =
            await _sharedFileMigrationMutex.run(
              () => _materializeSharedFileReferencesIfNeeded(db),
            );
        if (result.completed || !result.progressed) return;
      }
    } on Object {
      // broad-catch: Migration remains checkpointed and will retry on the next initialize.
    }
  }

  Future<bool> _waitForSharedFileMigrationDelay() async {
    if (_closing || _sharedFileMigrationCancellation.isCompleted) return false;
    if (sharedFileMigrationDelay > Duration.zero) {
      await Future.any<void>(<Future<void>>[
        Future<void>.delayed(sharedFileMigrationDelay),
        _sharedFileMigrationCancellation.future,
        _sharedFileMigrationPause.future,
      ]);
    }
    return !_closing && !_sharedFileMigrationCancellation.isCompleted;
  }

  /// 当工作录像结束或系统转为空闲后，显式请求继续低优先迁移。
  Future<void> resumeSharedFileMigration() async {
    final Database db = await _db;
    if (_sharedFileMigrationPause.isCompleted) {
      _sharedFileMigrationPause = Completer<void>();
    }
    if (!await _sharedFileMigrationCompleted(db)) {
      _startSharedFileMigrationWorker(db);
    }
  }

  /// 请求当前复制在最多一个分块后退出，并有界等待迁移互斥区静止。
  Future<void> pauseSharedFileMigration({
    Duration maximumWait = const Duration(milliseconds: 400),
  }) async {
    if (!_sharedFileMigrationPause.isCompleted) {
      _sharedFileMigrationPause.complete();
    }
    await Future.any<void>(<Future<void>>[
      _sharedFileMigrationMutex.drained.catchError((Object _) {}),
      Future<void>.delayed(maximumWait),
    ]);
  }

  /// 播放、备份或删除前可优先物化一条旧共享记录，不扫描其他录像。
  Future<bool> materializeSharedFileForSession(String sessionId) async {
    if (_closing ||
        _sharedFileMigrationPause.isCompleted ||
        sharedFileMigrationAllowed?.call() == false) {
      return false;
    }
    final Database db = await _db;
    return _sharedFileMigrationMutex.run(() async {
      if (_closing ||
          _sharedFileMigrationPause.isCompleted ||
          sharedFileMigrationAllowed?.call() == false ||
          !identical(_database, db)) {
        return false;
      }
      final List<Map<String, Object?>> rows = await db.query(
        'recording_sessions',
        columns: <String>['id', 'started_at', ..._sessionPayloadColumns],
        where: 'id = ? AND is_deleted = 0',
        whereArgs: <Object?>[sessionId],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      return _materializeSharedFileReference(db, rows.single);
    });
  }

  @visibleForTesting
  Future<void> drainSharedFileMigrationForTesting() async {
    await _sharedFileMigrationWorker;
    final Database db = await _db;
    while (true) {
      final _SharedFileMigrationBatchResult result =
          await _sharedFileMigrationMutex.run(
            () => _materializeSharedFileReferencesIfNeeded(db),
          );
      if (result.completed || !result.progressed) return;
      await Future<void>.delayed(Duration.zero);
    }
  }

  @visibleForTesting
  Future<bool> runSharedFileMigrationBatchForTesting() async {
    final Database db = await _db;
    final _SharedFileMigrationBatchResult result =
        await _sharedFileMigrationMutex.run(
          () => _materializeSharedFileReferencesIfNeeded(db),
        );
    return result.progressed;
  }

  Future<List<Map<String, Object?>>> _loadSharedFileMigrationBatch(
    Database db, {
    required ({int startedAt, String id})? after,
  }) {
    final String cursorClause = after == null
        ? ''
        : ' AND (started_at > ? OR (started_at = ? AND id > ?))';
    return db.rawQuery(
      'SELECT id, started_at, ${_sessionPayloadColumns.join(', ')} '
      'FROM recording_sessions INDEXED BY idx_recording_active_time '
      'WHERE is_deleted = 0$cursorClause '
      'ORDER BY started_at ASC, id ASC LIMIT ?',
      <Object?>[
        if (after != null) after.startedAt,
        if (after != null) after.startedAt,
        if (after != null) after.id,
        _sharedFileMigrationBatchSize,
      ],
    );
  }

  Future<bool> _hasSharedFileMigrationRowsAfter(
    Database db,
    ({int startedAt, String id}) after,
  ) async {
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT id FROM recording_sessions INDEXED BY idx_recording_active_time '
      'WHERE is_deleted = 0 AND '
      '(started_at > ? OR (started_at = ? AND id > ?)) '
      'ORDER BY started_at ASC, id ASC LIMIT 1',
      <Object?>[after.startedAt, after.startedAt, after.id],
    );
    return rows.isNotEmpty;
  }

  Future<bool> _materializeSharedFileReference(
    Database db,
    Map<String, Object?> row,
  ) async {
    final String id = row['id']! as String;
    final String sourcePath = row['file_path']! as String;
    final String normalized = _normalizedFilePath(sourcePath);
    await beforeSharedFileMigrationRowForTesting?.call(id);
    final ({bool current, bool retained}) ownership = await db.transaction((
      Transaction txn,
    ) async {
      final List<Map<String, Object?>> current = await txn.query(
        'recording_sessions',
        columns: const <String>['id'],
        where: 'id = ? AND is_deleted = 0 AND file_path = ?',
        whereArgs: <Object?>[id, sourcePath],
        limit: 1,
      );
      if (current.isEmpty) {
        await txn.delete(
          _recordingFileOwnersTable,
          where: 'normalized_path = ? AND retained_session_id = ?',
          whereArgs: <Object?>[normalized, id],
        );
        return (current: false, retained: false);
      }
      final List<Map<String, Object?>> owners = await txn.query(
        _recordingFileOwnersTable,
        columns: const <String>['retained_session_id'],
        where: 'normalized_path = ?',
        whereArgs: <Object?>[normalized],
        limit: 1,
      );
      if (owners.isEmpty) {
        await txn.delete(
          _recordingFileOwnersTable,
          where: 'retained_session_id = ?',
          whereArgs: <Object?>[id],
        );
        await txn.insert(_recordingFileOwnersTable, <String, Object?>{
          'normalized_path': normalized,
          'retained_session_id': id,
        }, conflictAlgorithm: ConflictAlgorithm.abort);
        return (current: true, retained: true);
      }
      return (
        current: true,
        retained: owners.single['retained_session_id'] == id,
      );
    });
    if (!ownership.current || ownership.retained) return true;

    final String? distinctPath = await _copyToDistinctPath(
      db: db,
      sourcePath: sourcePath,
      sessionId: id,
    );
    // 缺失的旧源文件不能凭元数据推断为已删除，也不能把记录改指向
    // 一个不存在的副本。游标停在前一条，源文件恢复后从该记录重试。
    if (distinctPath == null) return false;
    final RecordingSession session = _sessionFromRow(
      row,
    ).copyWith(filePath: distinctPath);
    final _RecordingFileMetadata metadata = await _readFileMetadata(
      File(distinctPath),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((Transaction txn) async {
      final int affected = await txn.update(
        'recording_sessions',
        <String, Object?>{
          'file_path': distinctPath,
          'payload_json': jsonEncode(session.toJson()),
          'file_size_bytes': metadata.size,
          'missing_at': metadata.exists ? null : now,
          'updated_at': now,
        },
        where: 'id = ? AND is_deleted = 0 AND file_path = ?',
        whereArgs: <Object?>[id, sourcePath],
      );
      if (affected != 1) {
        final List<Map<String, Object?>> current = await txn.query(
          'recording_sessions',
          columns: const <String>['id'],
          where: 'id = ? AND is_deleted = 0 AND file_path = ?',
          whereArgs: <Object?>[id, sourcePath],
          limit: 1,
        );
        if (current.isNotEmpty) return false;
        await txn.delete(
          'recording_metadata',
          where: 'key = ?',
          whereArgs: <Object?>[_materializationIntentKey(id)],
        );
        return true;
      }
      await txn.insert(_recordingFileOwnersTable, <String, Object?>{
        'normalized_path': _normalizedFilePath(distinctPath),
        'retained_session_id': id,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
      await txn.delete(
        'recording_metadata',
        where: 'key = ?',
        whereArgs: <Object?>[_materializationIntentKey(id)],
      );
      return true;
    });
  }

  Future<String?> _copyToDistinctPath({
    required Database db,
    required String sourcePath,
    required String sessionId,
  }) async {
    final File source = File(sourcePath);
    if (!await source.exists()) return null;
    if (_closing || _sharedFileMigrationCancellation.isCompleted) return null;
    final FileStat sourceBefore = await source.stat();
    final String intentKey = _materializationIntentKey(sessionId);
    final List<Map<String, Object?>> storedIntent = await db.query(
      'recording_metadata',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[intentKey],
      limit: 1,
    );
    String? destinationPath;
    var storedCopyStarted = false;
    final Object? intentValue = storedIntent.isEmpty
        ? null
        : storedIntent.first['value'];
    if (intentValue is String) {
      final Map<String, Object?>? decoded = _decodeMaterializationIntent(
        intentValue,
      );
      final Object? storedPath = decoded?['destinationPath'];
      if (decoded?['sourcePath'] == sourcePath && storedPath is String) {
        storedCopyStarted = decoded?['copyStarted'] == true;
        final String normalizedStoredPath = _normalizedFilePath(storedPath);
        final bool conflictsWithReservedPath =
            await _isNormalizedPathReservedByAnotherSession(
              db,
              normalizedPath: normalizedStoredPath,
              sessionId: sessionId,
            );
        final bool conflictsWithSource =
            normalizedStoredPath == _normalizedFilePath(sourcePath);
        final bool ownedByAnotherSession =
            await _isFilePathOwnedByAnotherSession(
              db,
              filePath: storedPath,
              sessionId: sessionId,
            );
        final File storedDestination = File(storedPath);
        final bool existingDestinationMatchesSource =
            !await storedDestination.exists() ||
            await _filesHaveSameContents(source, storedDestination);
        if (!conflictsWithReservedPath &&
            !conflictsWithSource &&
            !ownedByAnotherSession &&
            existingDestinationMatchesSource) {
          destinationPath = storedPath;
        }
      }
    }

    final String extension = p.extension(sourcePath);
    final String stem = p.basenameWithoutExtension(sourcePath);
    final String safeId = sessionId
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final String suffix = safeId.isEmpty ? 'recording' : safeId;
    var collision = 0;
    while (true) {
      if (destinationPath == null) {
        while (destinationPath == null) {
          collision++;
          final String number = collision == 1 ? '' : '_$collision';
          final String candidate = p.join(
            p.dirname(sourcePath),
            '${stem}_独立_$suffix$number$extension',
          );
          if (await File(candidate).exists() ||
              await _isNormalizedPathReservedByAnotherSession(
                db,
                normalizedPath: _normalizedFilePath(candidate),
                sessionId: sessionId,
              ) ||
              await _isFilePathOwnedByAnotherSession(
                db,
                filePath: candidate,
                sessionId: sessionId,
              )) {
            continue;
          }
          destinationPath = candidate;
        }
        await db.insert('recording_metadata', <String, Object?>{
          'key': intentKey,
          'value': jsonEncode(<String, Object?>{
            'sourcePath': sourcePath,
            'destinationPath': destinationPath,
            'copyStarted': false,
          }),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      final File destination = File(destinationPath);
      if (await destination.exists()) {
        if (await _filesHaveSameContents(source, destination)) {
          return destination.path;
        }
        if (storedCopyStarted) {
          try {
            await destination.delete();
          } on FileSystemException {
            return null;
          }
        }
        destinationPath = null;
        storedCopyStarted = false;
        continue;
      }

      if (!await _hasSpaceForSharedFileCopy(
        sourceSize: sourceBefore.size,
        sourcePath: sourcePath,
      )) {
        return null;
      }
      if (_closing || _sharedFileMigrationCancellation.isCompleted) {
        return null;
      }

      if (!await _awaitExclusiveMaterializationHook(destination.path)) {
        return null;
      }
      try {
        await destination.create(exclusive: true);
      } on PathExistsException {
        destinationPath = null;
        continue;
      }
      try {
        await db.insert('recording_metadata', <String, Object?>{
          'key': intentKey,
          'value': jsonEncode(<String, Object?>{
            'sourcePath': sourcePath,
            'destinationPath': destinationPath,
            'copyStarted': true,
          }),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        final bool copied = await _copySharedFileInChunks(
          source: source,
          destination: destination,
          expectedSource: sourceBefore,
        );
        if (!copied) {
          if (await destination.exists()) await destination.delete();
          return null;
        }
        return destination.path;
      } on Object {
        try {
          if (await destination.exists()) await destination.delete();
        } on FileSystemException {
          // 只清理由本次独占创建的未完成副本，唯一原片始终只读。
        }
        rethrow;
      }
    }
  }

  Future<bool> _hasSpaceForSharedFileCopy({
    required int sourceSize,
    required String sourcePath,
  }) async {
    final Future<int?> Function(String path)? provider =
        availableStorageBytesForMigration;
    if (provider == null) return false;
    try {
      final int? available = await Future.any<int?>(<Future<int?>>[
        provider(sourcePath),
        _sharedFileMigrationCancellation.future.then<int?>((_) => null),
      ]);
      if (_closing || _sharedFileMigrationCancellation.isCompleted) {
        return false;
      }
      if (available == null) return false;
      final int availableBytes = available;
      if (availableBytes < 0) return false;
      return availableBytes >= sourceSize + BackupStoragePolicy.minimumBytes;
    } on Object {
      // broad-catch: 无法确认剩余空间时安全拒绝复制，不触碰源录像
      return false;
    }
  }

  Future<bool> _copySharedFileInChunks({
    required File source,
    required File destination,
    required FileStat expectedSource,
  }) async {
    final RandomAccessFile reader = await source.open();
    final RandomAccessFile writer = await destination.open(
      mode: FileMode.writeOnly,
    );
    var copiedBytes = 0;
    try {
      while (copiedBytes < expectedSource.size) {
        if (_closing ||
            _sharedFileMigrationCancellation.isCompleted ||
            _sharedFileMigrationPause.isCompleted ||
            sharedFileMigrationAllowed?.call() == false) {
          return false;
        }
        if (!await _awaitSharedFileCopyHook()) return false;
        final int remaining = expectedSource.size - copiedBytes;
        final List<int> bytes = await reader.read(
          remaining < _sharedFileCopyChunkSize
              ? remaining
              : _sharedFileCopyChunkSize,
        );
        if (bytes.isEmpty) return false;
        await writer.writeFrom(bytes);
        copiedBytes += bytes.length;
      }
      await writer.flush();
      final FileStat sourceAfter = await source.stat();
      return copiedBytes == expectedSource.size &&
          sourceAfter.size == expectedSource.size &&
          sourceAfter.modified == expectedSource.modified;
    } finally {
      await reader.close();
      await writer.close();
    }
  }

  Future<bool> _awaitSharedFileCopyHook() async {
    final Future<void> Function()? hook = beforeSharedFileCopyChunkForTesting;
    if (hook == null) return true;
    await Future.any<void>(<Future<void>>[
      hook(),
      _sharedFileMigrationCancellation.future,
      _sharedFileMigrationPause.future,
    ]);
    return !_closing &&
        !_sharedFileMigrationCancellation.isCompleted &&
        !_sharedFileMigrationPause.isCompleted;
  }

  Future<bool> _awaitExclusiveMaterializationHook(String path) async {
    final Future<void> Function(String destinationPath)? hook =
        beforeExclusiveMaterializationCreateForTesting;
    if (hook == null) return true;
    await Future.any<void>(<Future<void>>[
      hook(path),
      _sharedFileMigrationCancellation.future,
      _sharedFileMigrationPause.future,
    ]);
    return !_closing &&
        !_sharedFileMigrationCancellation.isCompleted &&
        !_sharedFileMigrationPause.isCompleted;
  }

  Future<bool> _isNormalizedPathReservedByAnotherSession(
    Database db, {
    required String normalizedPath,
    required String sessionId,
  }) async {
    final List<Map<String, Object?>> rows = await db.query(
      _recordingFileOwnersTable,
      columns: const <String>['retained_session_id'],
      where: 'normalized_path = ? AND retained_session_id != ?',
      whereArgs: <Object?>[normalizedPath, sessionId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> _isFilePathOwnedByAnotherSession(
    Database db, {
    required String filePath,
    required String sessionId,
  }) async {
    final List<Map<String, Object?>> rows = await db.query(
      'recording_sessions',
      columns: const <String>['id'],
      where: 'is_deleted = 0 AND file_path = ? AND id != ?',
      whereArgs: <Object?>[filePath, sessionId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> _filesHaveSameContents(File first, File second) async {
    if (await first.length() != await second.length()) return false;
    final RandomAccessFile firstReader = await first.open();
    final RandomAccessFile secondReader = await second.open();
    try {
      const int chunkSize = 1024 * 1024;
      while (true) {
        if (_closing || _sharedFileMigrationCancellation.isCompleted) {
          throw _SharedFileMigrationCancelled();
        }
        final List<int> firstBytes = await firstReader.read(chunkSize);
        final List<int> secondBytes = await secondReader.read(chunkSize);
        if (firstBytes.length != secondBytes.length) return false;
        for (var index = 0; index < firstBytes.length; index++) {
          if (firstBytes[index] != secondBytes[index]) return false;
        }
        if (firstBytes.length < chunkSize) return true;
      }
    } finally {
      await firstReader.close();
      await secondReader.close();
    }
  }

  static String _materializationIntentKey(String sessionId) =>
      '$_sharedFileMigrationIntentPrefix${base64Url.encode(utf8.encode(sessionId))}';

  Future<({int startedAt, String id})?> _loadSharedFileMigrationCursor(
    Database db,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      'recording_metadata',
      columns: const <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[_sharedFileMigrationCursorKey],
      limit: 1,
    );
    if (rows.isEmpty || rows.single['value'] is! String) return null;
    final Map<String, Object?>? value = _decodeMaterializationIntent(
      rows.single['value']! as String,
    );
    final Object? startedAt = value?['startedAt'];
    final Object? id = value?['id'];
    if (startedAt is! num || id is! String) return null;
    return (startedAt: startedAt.toInt(), id: id);
  }

  Future<void> _saveSharedFileMigrationCursor(
    Database db,
    ({int startedAt, String id}) cursor,
  ) => db.insert('recording_metadata', <String, Object?>{
    'key': _sharedFileMigrationCursorKey,
    'value': jsonEncode(<String, Object?>{
      'startedAt': cursor.startedAt,
      'id': cursor.id,
    }),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> _completeSharedFileMigration(Database db) =>
      db.transaction((Transaction txn) async {
        await _markSharedFileMigrationComplete(txn);
      });

  static Future<void> _markSharedFileMigrationComplete(
    DatabaseExecutor db,
  ) async {
    final String completedAt = DateTime.now().toUtc().toIso8601String();
    await db.insert('recording_metadata', <String, Object?>{
      'key': _sharedFileMigrationKey,
      'value': completedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('recording_metadata', <String, Object?>{
      'key': _recordingFileOwnersReadyKey,
      'value': completedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.delete(
      'recording_metadata',
      where: 'key = ?',
      whereArgs: <Object?>[_sharedFileMigrationCursorKey],
    );
  }

  static Future<void> _resetSharedFileMigration(DatabaseExecutor db) async {
    await db.delete(
      'recording_metadata',
      where: 'key IN (?, ?, ?)',
      whereArgs: <Object?>[
        _sharedFileMigrationKey,
        _sharedFileMigrationCursorKey,
        _recordingFileOwnersReadyKey,
      ],
    );
    await db.delete(_recordingFileOwnersTable);
  }

  static Map<String, Object?>? _decodeMaterializationIntent(String value) {
    try {
      final Object? decoded = jsonDecode(value);
      return decoded is Map<Object?, Object?>
          ? Map<String, Object?>.from(decoded)
          : null;
    } on FormatException {
      return null;
    }
  }
}

class _RecordingFileMetadata {
  const _RecordingFileMetadata({required this.exists, required this.size});

  final bool exists;
  final int size;
}

class _SharedFileMigrationBatchResult {
  const _SharedFileMigrationBatchResult({
    required this.completed,
    required this.progressed,
  });

  final bool completed;
  final bool progressed;
}

class _SharedFileMigrationCancelled implements Exception {
  const _SharedFileMigrationCancelled();
}

class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<void> get drained => _tail;

  Future<T> run<T>(Future<T> Function() action) {
    final Completer<void> released = Completer<void>();
    final Future<void> previous = _tail;
    _tail = released.future;
    return (() async {
      await previous;
      try {
        return await action();
      } finally {
        released.complete();
      }
    })();
  }
}
