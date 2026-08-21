package app.packingproof.mobile

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.provider.Settings
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID

internal data class LanBackupConnectionMigration(
    val computerId: String,
    val computerName: String,
)

internal data class LanBackupUpsertResult(
    val job: JSONObject,
    val recreated: Boolean,
)

internal fun planLanBackupConnectionMigration(
    schemaVersion: Int,
    computerId: String?,
    computerName: String?,
): LanBackupConnectionMigration? = if (schemaVersion >= 1) {
    null
} else {
    LanBackupConnectionMigration(
        computerId = computerId.orEmpty().trim(),
        computerName = computerName.orEmpty().trim(),
    )
}

internal class LanBackupStateStore(private val context: Context) {
    companion object {
        private const val CONNECTION_SCHEMA_VERSION = 1
        private const val PREFS = "lan_backup_connection"
        private const val RETENTION_PREFS = "lan_backup_retention"
        private const val DEVICE_PREFS = "lan_backup_device"
        private const val TAG = "PackingProofBackup"
        private val jobIoLock = Any()

        fun stableId(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

        fun stableDeviceId(androidId: String?, packageName: String): String? {
            val normalizedAndroidId = androidId?.trim()?.lowercase().orEmpty()
            if (normalizedAndroidId.isBlank() ||
                normalizedAndroidId == "9774d56d682e549c"
            ) {
                return null
            }
            return "android-${stableId("$packageName:$normalizedAndroidId")}"
        }

        fun deviceDisplayName(deviceId: String): String {
            return "本机"
        }

        fun <T> withJobLock(action: () -> T): T = synchronized(jobIoLock, action)
    }

    private val database = LanBackupJobDatabase(context)
    private val db: SQLiteDatabase
        get() = database.writableDatabase

    fun saveConnection(
        baseUrl: String,
        computerId: String,
        computerName: String,
        deviceName: String = "",
    ) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putInt("schemaVersion", CONNECTION_SCHEMA_VERSION)
            .putString("baseUrl", baseUrl)
            .putString("computerId", computerId)
            .putString("computerName", computerName)
            .putString("lastConnectedAt", Instant.now().toString())
            .apply()
        if (deviceName.isNotBlank()) {
            context.getSharedPreferences(DEVICE_PREFS, Context.MODE_PRIVATE).edit()
                .putString("name", deviceName.trim())
                .apply()
        }
    }

    fun connection(): JSONObject? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val baseUrl = prefs.getString("baseUrl", null) ?: return null
        return JSONObject()
            .put("baseUrl", baseUrl)
            .put("computerId", prefs.getString("computerId", "") ?: "")
            .put("computerName", prefs.getString("computerName", "已连接电脑") ?: "已连接电脑")
            .put("lastConnectedAt", prefs.getString("lastConnectedAt", "") ?: "")
    }

    fun clearConnection() {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }

    fun migrateLegacyConnection(): JSONObject? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val migration = planLanBackupConnectionMigration(
            prefs.getInt("schemaVersion", 0),
            prefs.getString("computerId", ""),
            prefs.getString("computerName", ""),
        ) ?: return null
        prefs.edit()
            .clear()
            .putInt("schemaVersion", CONNECTION_SCHEMA_VERSION)
            .putString("migrationComputerId", migration.computerId)
            .putString("migrationComputerName", migration.computerName)
            .apply()
        return JSONObject()
            .put("migrated", true)
            .put("computerId", migration.computerId)
            .put("computerName", migration.computerName)
    }

    fun migrationHint(): JSONObject? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val computerId = prefs.getString("migrationComputerId", "").orEmpty().trim()
        val computerName = prefs.getString("migrationComputerName", "").orEmpty().trim()
        if (computerId.isEmpty() && computerName.isEmpty()) return null
        return JSONObject().put("computerId", computerId).put("computerName", computerName)
    }

    fun clearMigrationHint() {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove("migrationComputerId")
            .remove("migrationComputerName")
            .apply()
    }

    fun retargetJobs(computerId: String) = withJobLock {
        jobsUnlocked().forEach { job ->
            if (job.optString("state") == "completed") return@forEach
            val sameComputer = job.optString("destinationComputerId") == computerId
            val repairsConnectionFailure = job.optString("failureKind") in setOf(
                LanBackupFailureKind.CREDENTIAL_INVALID.wireValue,
                LanBackupFailureKind.NOT_BACKUP_HOST.wireValue,
                LanBackupFailureKind.INCOMPATIBLE_VERSION.wireValue,
            )
            if (sameComputer && !repairsConnectionFailure) return@forEach
            val file = File(job.optString("filePath"))
            if (!file.exists()) return@forEach
            job.put("state", "pending")
                .put("generation", UUID.randomUUID().toString())
                .put("errorMessage", JSONObject.NULL)
                .put("failureKind", JSONObject.NULL)
            if (!sameComputer) {
                job.put("destinationComputerId", computerId)
                    .put("uploadedBytes", 0L)
                    .put("backupCompletedAt", JSONObject.NULL)
                    .put("contentSha256", JSONObject.NULL)
                    .put("remoteRecordId", JSONObject.NULL)
            }
            writeJobUnlocked(job)
        }
    }

    fun upsertJob(filePath: String, sessions: JSONArray): LanBackupUpsertResult = withJobLock {
        require(sessions.length() == 1) {
            "每个备份任务必须且只能包含一条录像记录"
        }
        val file = File(filePath)
        val id = stableId(file.canonicalPath)
        val existing = readJobUnlocked(id)
        val destinationComputerId = connection()?.optString("computerId").orEmpty()
        val sourceSessionId = sessions.getJSONObject(0).getString("id")
        val existingSessions = existing?.optJSONArray("sessions")
        val sameSession = existingSessions?.length() == 1 &&
            existingSessions.getJSONObject(0).optString("id") == sourceSessionId
        if (existing != null &&
            sameSession &&
            existing.optLong("totalBytes") == file.length() &&
            existing.optLong("lastModified") == file.lastModified() &&
            existing.optString("destinationComputerId") == destinationComputerId
        ) {
            existing.put("filePath", file.absolutePath)
            existing.put("sessions", sessions)
            if (!existing.has("fileCreatedAt")) {
                existing.put("fileCreatedAt", Instant.ofEpochMilli(file.lastModified()).toString())
            }
            if (!existing.has("backupCompletedAt")) existing.put("backupCompletedAt", JSONObject.NULL)
            if (!existing.has("scheduledCleanupAt")) existing.put("scheduledCleanupAt", JSONObject.NULL)
            if (!existing.has("localDeletedAt")) existing.put("localDeletedAt", JSONObject.NULL)
            if (!existing.has("waitingCleanup")) existing.put("waitingCleanup", false)
            if (!existing.has("remoteRecordId")) {
                val legacyRecordId = existing.optJSONArray("remoteRecordIds")
                    ?.optLong(0)
                    ?.takeIf { it > 0 }
                existing.put("remoteRecordId", legacyRecordId ?: JSONObject.NULL)
                existing.remove("remoteRecordIds")
            }
            if (!existing.has("contentSha256")) existing.put("contentSha256", JSONObject.NULL)
            if (!existing.has("verificationVersion")) existing.put("verificationVersion", 0)
            if (!existing.has("verificationReceipt")) existing.put("verificationReceipt", JSONObject.NULL)
            if (!existing.has("lastAttestedAt")) existing.put("lastAttestedAt", JSONObject.NULL)
            if (!existing.has("cleanupReason")) existing.put("cleanupReason", JSONObject.NULL)
            if (!existing.has("failureKind")) existing.put("failureKind", JSONObject.NULL)
            if (existing.optString("generation").isBlank()) {
                existing.put("generation", UUID.randomUUID().toString())
            }
            writeJobUnlocked(existing)
            return@withJobLock LanBackupUpsertResult(existing, recreated = false)
        }
        val job = JSONObject()
            .put("id", id)
            .put("generation", UUID.randomUUID().toString())
            .put("filePath", file.absolutePath)
            .put("fileName", file.name)
            .put("destinationComputerId", destinationComputerId)
            .put("state", "pending")
            .put("uploadedBytes", 0L)
            .put("totalBytes", file.length())
            .put("lastModified", file.lastModified())
            .put("fileCreatedAt", Instant.ofEpochMilli(file.lastModified()).toString())
            .put("backupCompletedAt", JSONObject.NULL)
            .put("scheduledCleanupAt", JSONObject.NULL)
            .put("localDeletedAt", JSONObject.NULL)
            .put("waitingCleanup", false)
            .put("remoteRecordId", JSONObject.NULL)
            .put("contentSha256", JSONObject.NULL)
            .put("verificationVersion", 0)
            .put("verificationReceipt", JSONObject.NULL)
            .put("lastAttestedAt", JSONObject.NULL)
            .put("cleanupReason", JSONObject.NULL)
            .put("errorMessage", JSONObject.NULL)
            .put("failureKind", JSONObject.NULL)
            .put("sessions", sessions)
        writeJobUnlocked(job)
        LanBackupUpsertResult(job, recreated = true)
    }

    fun readJob(id: String): JSONObject? = withJobLock { readJobUnlocked(id) }

    fun writeJob(job: JSONObject) = withJobLock { writeJobUnlocked(job) }

    fun updateJob(
        id: String,
        expectedGeneration: String? = null,
        update: (JSONObject) -> Boolean,
    ): JSONObject? = withJobLock {
        val job = readJobUnlocked(id) ?: return@withJobLock null
        if (expectedGeneration != null && job.optString("generation") != expectedGeneration) {
            return@withJobLock null
        }
        if (!update(job)) return@withJobLock null
        writeJobUnlocked(job)
        JSONObject(job.toString())
    }

    fun jobs(): List<JSONObject> = withJobLock { jobsUnlocked() }

    fun discardUnavailableJobs() = withJobLock {
        jobsUnlocked()
            .filter { it.optString("state") != "completed" }
            .forEach { job ->
                val status = sourceStatus(job)
                if (status == LanBackupSourceStatus.AVAILABLE) return@forEach
                if (deleteJobUnlocked(job.getString("id"), job.optString("generation"))) {
                    Log.w(
                        TAG,
                        "Discard unavailable backup job " +
                            "id=${job.getString("id").take(8)} " +
                            "path=${job.optString("filePath")} reason=${status.reason}",
                    )
                }
            }
    }

    fun discardJobIfUnavailable(id: String): LanBackupSourceStatus? = withJobLock {
        val job = readJobUnlocked(id) ?: return@withJobLock null
        if (job.optString("state") == "completed") {
            return@withJobLock LanBackupSourceStatus.AVAILABLE
        }
        val status = sourceStatus(job)
        if (status == LanBackupSourceStatus.AVAILABLE) return@withJobLock status
        if (deleteJobUnlocked(id, job.optString("generation"))) {
            Log.w(
                TAG,
                "Discard unavailable backup job " +
                    "id=${id.take(8)} path=${job.optString("filePath")} reason=${status.reason}",
            )
        }
        status
    }

    fun deleteJob(id: String, expectedGeneration: String): Boolean = withJobLock {
        deleteJobUnlocked(id, expectedGeneration)
    }

    private fun readJobUnlocked(id: String): JSONObject? {
        val columns = LanBackupJobDatabase.COLUMNS.toTypedArray()
        return db.query(
            LanBackupJobDatabase.TABLE,
            columns,
            "id = ?",
            arrayOf(id),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            if (cursor.moveToFirst()) {
                lanBackupRowToJob(cursor.toRowMap(LanBackupJobDatabase.COLUMNS))
            } else {
                null
            }
        }
    }

    private fun writeJobUnlocked(job: JSONObject) {
        db.insertWithOnConflict(
            LanBackupJobDatabase.TABLE,
            null,
            lanBackupJobToRow(job).toContentValues(),
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    private fun deleteJobUnlocked(id: String, expectedGeneration: String): Boolean {
        val current = readJobUnlocked(id) ?: return false
        if (current.optString("generation") != expectedGeneration) return false
        if (current.optString("state") == "completed") return false
        db.delete(LanBackupJobDatabase.TABLE, "id = ?", arrayOf(id))
        return true
    }

    private fun sourceStatus(job: JSONObject): LanBackupSourceStatus =
        LanBackupSourcePolicy.inspect(
            file = File(job.optString("filePath")),
            expectedBytes = job.optLong("totalBytes", -1L),
            expectedLastModified = job.optLong("lastModified", -1L),
        )

    private fun jobsUnlocked(): List<JSONObject> {
        val columns = LanBackupJobDatabase.COLUMNS
        return db.query(
            LanBackupJobDatabase.TABLE,
            columns.toTypedArray(),
            null,
            null,
            null,
            null,
            "last_modified DESC",
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(lanBackupRowToJob(cursor.toRowMap(columns)))
                }
            }
        }
    }

    fun saveRetentionPolicies(unbackedDays: Int?, backedDays: Int?) {
        context.getSharedPreferences(RETENTION_PREFS, Context.MODE_PRIVATE).edit()
            .putInt("unbackedDays", unbackedDays ?: -1)
            .putInt("backedDays", backedDays ?: -1)
            .apply()
    }

    fun unbackedRetentionDays(): Int = context
        .getSharedPreferences(RETENTION_PREFS, Context.MODE_PRIVATE)
        .getInt("unbackedDays", 30)

    fun backedRetentionDays(): Int = context
        .getSharedPreferences(RETENTION_PREFS, Context.MODE_PRIVATE)
        .getInt("backedDays", 7)

    fun deviceId(): String {
        val androidId = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ANDROID_ID,
        )
        stableDeviceId(androidId, context.packageName)?.let { return it }

        // Only obsolete or unavailable Android IDs use an installation-local
        // fallback. Normal devices keep the same ID after uninstall/reinstall.
        val prefs = context.getSharedPreferences(DEVICE_PREFS, Context.MODE_PRIVATE)
        prefs.getString("id", null)?.takeIf { it.isNotBlank() }?.let { return it }
        val value = UUID.randomUUID().toString()
        prefs.edit().putString("id", value).apply()
        return value
    }

    fun deviceName(): String {
        val savedName = context.getSharedPreferences(DEVICE_PREFS, Context.MODE_PRIVATE)
            .getString("name", null)
            ?.trim()
            .orEmpty()
        return savedName.ifBlank { deviceDisplayName(deviceId()) }
    }
}
