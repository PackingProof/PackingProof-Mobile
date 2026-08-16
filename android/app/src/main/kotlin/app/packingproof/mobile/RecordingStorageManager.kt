package app.packingproof.mobile

import android.content.Context
import android.os.StatFs
import org.json.JSONObject
import java.io.File
import java.time.Instant

internal object RecordingStoragePolicy {
    const val WARNING_BYTES = 3L * 1024 * 1024 * 1024
    const val MINIMUM_BYTES = 2L * 1024 * 1024 * 1024
    const val TARGET_BYTES = 3L * 1024 * 1024 * 1024
    val STORAGE_ATTESTATION_FRESHNESS = java.time.Duration.ofMinutes(5)

    fun needsWarning(availableBytes: Long): Boolean = availableBytes < WARNING_BYTES
    fun needsReclaim(availableBytes: Long): Boolean = availableBytes < MINIMUM_BYTES

    fun isFreshAttestation(value: String): Boolean = runCatching {
        val age = java.time.Duration.between(Instant.parse(value), Instant.now()).abs()
        age <= STORAGE_ATTESTATION_FRESHNESS
    }.getOrDefault(false)

    fun verifiedCandidates(
        candidates: List<RecordingStorageCandidate>,
    ): List<RecordingStorageCandidate> = candidates
        .filter {
            it.state == "completed" &&
                it.backupCompletedAt != null &&
                it.contentSha256 != null &&
                it.verificationVersion >= BackupRequestAuthentication.VERSION &&
                it.lastAttestedAt?.let(RecordingStoragePolicy::isFreshAttestation) == true &&
                it.localDeletedAt == null
        }
        .sortedBy { runCatching { Instant.parse(it.fileCreatedAt) }.getOrDefault(Instant.MAX) }
}

internal data class RecordingStorageCandidate(
    val id: String,
    val state: String,
    val fileCreatedAt: String?,
    val backupCompletedAt: String?,
    val contentSha256: String?,
    val verificationVersion: Int,
    val lastAttestedAt: String?,
    val localDeletedAt: String?,
)

internal class RecordingStorageManager(
    private val context: Context,
    private val store: LanBackupStateStore,
    private val availableBytes: () -> Long = {
        StatFs(context.filesDir.path).availableBytes
    },
) {
    fun checkAndReclaim(): Map<String, Any> = LanBackupStateStore.withJobLock {
        val before = availableBytes()
        var current = before
        var deletedCount = 0
        var freedBytes = 0L
        if (RecordingStoragePolicy.needsReclaim(current)) {
            val allJobs = store.jobs().associateBy { it.getString("id") }
            val jobs = RecordingStoragePolicy.verifiedCandidates(
                allJobs.values.map(::candidate),
            ).mapNotNull { allJobs[it.id] }
            for (job in jobs) {
                if (current >= RecordingStoragePolicy.TARGET_BYTES) break
                val file = File(job.optString("filePath"))
                if (!isManaged(file)) continue
                val expectedBytes = job.optLong("totalBytes", -1L)
                when (
                    LanBackupFileCleanup.deleteExpected(
                        file = file,
                        expectedBytes = expectedBytes,
                        expectedLastModified = job.optLong("lastModified", -1L),
                        expectedSha256 = LanBackupCleanupScheduler.nullableText(
                            job,
                            "contentSha256",
                        ),
                    )
                ) {
                    LanBackupFileCleanupResult.deleted -> {
                        deletedCount++
                        freedBytes += expectedBytes.coerceAtLeast(0)
                        markDeleted(job)
                    }
                    LanBackupFileCleanupResult.missing -> markDeleted(job)
                    LanBackupFileCleanupResult.stale -> {
                        job.put("errorMessage", "录像文件已被替换，已取消空间清理")
                        store.writeJob(job)
                    }
                    LanBackupFileCleanupResult.failed -> {
                        job.put("errorMessage", "空间清理失败，已保留本机录像")
                        store.writeJob(job)
                    }
                }
                current = availableBytes()
            }
        }
        mapOf(
            "availableBytes" to current,
            "availableBytesBefore" to before,
            "freedBytes" to freedBytes,
            "deletedCount" to deletedCount,
            "warning" to RecordingStoragePolicy.needsWarning(current),
            "insufficient" to RecordingStoragePolicy.needsReclaim(current),
        )
    }

    private fun isManaged(file: File): Boolean = runCatching {
        file.canonicalFile.path.startsWith(
            context.dataDir.canonicalPath + File.separator,
        )
    }.getOrDefault(false)

    private fun candidate(job: JSONObject) = RecordingStorageCandidate(
        id = job.getString("id"),
        state = job.optString("state"),
        fileCreatedAt = LanBackupCleanupScheduler.nullableText(job, "fileCreatedAt"),
        backupCompletedAt = LanBackupCleanupScheduler.nullableText(job, "backupCompletedAt"),
        contentSha256 = LanBackupCleanupScheduler.nullableText(job, "contentSha256"),
        verificationVersion = job.optInt("verificationVersion"),
        lastAttestedAt = LanBackupCleanupScheduler.nullableText(job, "lastAttestedAt"),
        localDeletedAt = LanBackupCleanupScheduler.nullableText(job, "localDeletedAt"),
    )

    private fun markDeleted(job: JSONObject) {
        job.put("localDeletedAt", Instant.now().toString())
            .put("scheduledCleanupAt", JSONObject.NULL)
            .put("waitingCleanup", false)
            .put("cleanupReason", "存储空间不足提前清理")
            .put("errorMessage", JSONObject.NULL)
        store.writeJob(job)
    }
}
