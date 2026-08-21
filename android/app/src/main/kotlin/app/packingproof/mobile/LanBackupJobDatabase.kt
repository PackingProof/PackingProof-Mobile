package app.packingproof.mobile

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File

/**
 * 备份任务的 SQLite 存储：一个任务一行，替代旧版“一录像一个 JSON 文件”的目录存储。
 * 首次打开时把旧版 `lan_backup/jobs` 目录下的任务文件一次性导入，导入完成后删除旧文件。
 */
internal class LanBackupJobDatabase(private val context: Context) :
    SQLiteOpenHelper(context.applicationContext, DATABASE_NAME, null, DATABASE_VERSION) {

    companion object {
        private const val DATABASE_NAME = "lan_backup.db"
        private const val DATABASE_VERSION = 2
        const val TABLE = "backup_jobs"
        private const val MIGRATION_PREFS = "lan_backup_migration"
        private const val MIGRATION_DONE_KEY = "legacy_files_migrated"

        val COLUMNS = listOf(
            "id",
            "generation",
            "file_path",
            "file_name",
            "destination_computer_id",
            "state",
            "uploaded_bytes",
            "total_bytes",
            "last_modified",
            "file_created_at",
            "backup_completed_at",
            "scheduled_cleanup_at",
            "local_deleted_at",
            "waiting_cleanup",
            "remote_record_id",
            "content_sha256",
            "verification_version",
            "verification_receipt",
            "last_attested_at",
            "cleanup_reason",
            "error_message",
            "failure_kind",
            "sessions",
        )

        private val migrationLock = Any()

        private const val CREATE_TABLE = """
            CREATE TABLE backup_jobs (
                id TEXT PRIMARY KEY,
                generation TEXT NOT NULL,
                file_path TEXT NOT NULL,
                file_name TEXT,
                destination_computer_id TEXT,
                state TEXT NOT NULL,
                uploaded_bytes INTEGER NOT NULL DEFAULT 0,
                total_bytes INTEGER NOT NULL DEFAULT 0,
                last_modified INTEGER NOT NULL DEFAULT 0,
                file_created_at TEXT,
                backup_completed_at TEXT,
                scheduled_cleanup_at TEXT,
                local_deleted_at TEXT,
                waiting_cleanup INTEGER NOT NULL DEFAULT 0,
                remote_record_id INTEGER,
                content_sha256 TEXT,
                verification_version INTEGER NOT NULL DEFAULT 0,
                verification_receipt TEXT,
                last_attested_at TEXT,
                cleanup_reason TEXT,
                error_message TEXT,
                failure_kind TEXT,
                sessions TEXT
            )
        """
    }

    override fun onConfigure(db: SQLiteDatabase) {
        super.onConfigure(db)
        db.setForeignKeyConstraintsEnabled(true)
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(CREATE_TABLE)
    }

    override fun onOpen(db: SQLiteDatabase) {
        super.onOpen(db)
        db.enableWriteAheadLogging()
        migrateLegacyFilesIfNeeded(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE $TABLE ADD COLUMN remote_record_id INTEGER")
            db.rawQuery("SELECT id, remote_record_ids FROM $TABLE", null).use { cursor ->
                while (cursor.moveToNext()) {
                    val legacy = cursor.getString(1)?.let {
                        runCatching { org.json.JSONArray(it) }.getOrNull()
                    }
                    val recordId = legacy?.optLong(0)?.takeIf { it > 0 } ?: continue
                    db.execSQL(
                        "UPDATE $TABLE SET remote_record_id = ? WHERE id = ?",
                        arrayOf(recordId, cursor.getString(0)),
                    )
                }
            }
        }
    }

    /** 旧版任务文件一次性导入；带锁且以 SharedPreferences 标记保证只执行一次。 */
    private fun migrateLegacyFilesIfNeeded(db: SQLiteDatabase) {
        val prefs = context.getSharedPreferences(MIGRATION_PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(MIGRATION_DONE_KEY, false)) return
        synchronized(migrationLock) {
            if (prefs.getBoolean(MIGRATION_DONE_KEY, false)) return
            val legacyDir = File(context.filesDir, "lan_backup/jobs")
            val files = legacyDir.listFiles { file ->
                file.name.endsWith(".json") || file.name.endsWith(".json.bak")
            }?.toList().orEmpty()
            if (files.isEmpty()) {
                prefs.edit().putBoolean(MIGRATION_DONE_KEY, true).apply()
                return
            }
            var imported = 0
            for (file in files.sortedBy { it.name }) {
                val id = file.name.removeSuffix(".bak").removeSuffix(".json")
                if (db.query(
                        TABLE,
                        arrayOf("id"),
                        "id = ?",
                        arrayOf(id),
                        null,
                        null,
                        null,
                        "1",
                    ).use { cursor ->
                        cursor.moveToFirst()
                    }
                ) {
                    continue
                }
                val job = runCatching {
                    AtomicFile(file).openRead().bufferedReader(Charsets.UTF_8).use { reader ->
                        JSONObject(reader.readText())
                    }
                }.getOrNull() ?: continue
                db.insertWithOnConflict(
                    TABLE,
                    null,
                    lanBackupJobToRow(job).toContentValues(),
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
                imported++
            }
            if (imported > 0) {
                runCatching { legacyDir.deleteRecursively() }
            }
            prefs.edit().putBoolean(MIGRATION_DONE_KEY, true).apply()
        }
    }
}
