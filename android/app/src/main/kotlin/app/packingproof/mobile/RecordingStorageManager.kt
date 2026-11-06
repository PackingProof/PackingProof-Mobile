package app.packingproof.mobile

import android.content.Context
import android.os.StatFs
import org.json.JSONObject
import java.time.Instant

private const val STORAGE_LOG_TAG = "RecordingStorage"

internal object RecordingStoragePolicy {
    private val HEX_64 = Regex("^[0-9a-fA-F]{64}$")

    fun needsWarning(availableBytes: Long, policy: BackupStoragePolicy): Boolean =
        availableBytes < policy.warningBytes

    fun needsReclaim(availableBytes: Long, policy: BackupStoragePolicy): Boolean =
        availableBytes < policy.minimumBytes

    /**
     * 证明字段齐备，只差“刚向电脑确认过”这一步。空间回收用它挑出值得重新向电脑
     * 确认的录像，避免对证明不完整的录像发起网络确认。
     */
    fun hasCompleteProof(candidate: RecordingStorageCandidate): Boolean =
        candidate.generation.isNotBlank() &&
            candidate.filePath.isNotBlank() &&
            candidate.destinationComputerId.isNotBlank() &&
            candidate.state == "completed" &&
            candidate.backupCompletedAt != null &&
            candidate.contentSha256?.matches(HEX_64) == true &&
            candidate.verificationVersion >= BackupRequestAuthentication.VERSION &&
            candidate.verificationReceipt?.let { receipt ->
                receipt.authVersion == BackupRequestAuthentication.VERSION &&
                    receipt.verifiedAtUnixSeconds > 0 &&
                    receipt.hostNodeId.equals(candidate.destinationComputerId, ignoreCase = true) &&
                    receipt.sourceDeviceId.isNotBlank() &&
                    receipt.sourceSessionId == candidate.sessionIds.singleOrNull() &&
                    receipt.fileSha256.equals(candidate.contentSha256, ignoreCase = true) &&
                    receipt.fileSizeBytes == candidate.totalBytes &&
                    receipt.recordId == candidate.remoteRecordId &&
                    receipt.receiptSignature.matches(HEX_64)
            } == true &&
            candidate.remoteRecordId > 0 &&
            candidate.sessionIds.size == 1 &&
            candidate.sessionIds.single().isNotBlank() &&
            candidate.totalBytes > 0 &&
            candidate.lastModified > 0 &&
            candidate.localDeletedAt == null

    fun isVerifiedCandidate(
        candidate: RecordingStorageCandidate,
    ): Boolean =
        hasCompleteProof(candidate) &&
            candidate.lastAttestedAt != null

    /**
     * 「优先继续录制」兜底删除的准入条件：允许没有电脑回执，但只碰已经落盘、不在上传
     * 或等待上传中的单会话录像，避免删掉正在写或正在传的文件。
     */
    fun canReclaimWithoutProof(candidate: RecordingStorageCandidate): Boolean =
        candidate.generation.isNotBlank() &&
            candidate.filePath.isNotBlank() &&
            candidate.state in UNBACKED_RECLAIMABLE_STATES &&
            candidate.sessionIds.size == 1 &&
            candidate.sessionIds.single().isNotBlank() &&
            candidate.totalBytes > 0 &&
            candidate.lastModified > 0 &&
            candidate.localDeletedAt == null

    private val UNBACKED_RECLAIMABLE_STATES =
        setOf("completed", "failed", "paused", "pending")

    fun verifiedCandidates(
        candidates: List<RecordingStorageCandidate>,
    ): List<RecordingStorageCandidate> = candidates
        .filter { isVerifiedCandidate(it) }
        .sortedBy { runCatching { Instant.parse(it.fileCreatedAt) }.getOrDefault(Instant.MAX) }
}

internal data class RecordingStorageReceipt(
    val authVersion: Int,
    val verifiedAtUnixSeconds: Long,
    val hostNodeId: String,
    val sourceDeviceId: String,
    val sourceSessionId: String,
    val fileSha256: String,
    val fileSizeBytes: Long,
    val recordId: Long,
    val receiptSignature: String,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("authVersion", authVersion)
        .put("verifiedAtUnixSeconds", verifiedAtUnixSeconds)
        .put("hostNodeId", hostNodeId)
        .put("sourceDeviceId", sourceDeviceId)
        .put("sourceSessionId", sourceSessionId)
        .put("fileSha256", fileSha256)
        .put("fileSizeBytes", fileSizeBytes)
        .put("recordId", recordId)
        .put("receiptSignature", receiptSignature)
}

internal data class RecordingStorageCandidate(
    val id: String,
    val generation: String,
    val filePath: String,
    val destinationComputerId: String,
    val state: String,
    val fileCreatedAt: String?,
    val backupCompletedAt: String?,
    val contentSha256: String?,
    val verificationVersion: Int,
    val verificationReceipt: RecordingStorageReceipt?,
    val remoteRecordId: Long,
    val sessionIds: List<String>,
    val totalBytes: Long,
    val lastModified: Long,
    val lastAttestedAt: String?,
    val localDeletedAt: String?,
)

internal fun recordingStorageCandidate(job: JSONObject): RecordingStorageCandidate {
    val sessions = job.optJSONArray("sessions")
    return RecordingStorageCandidate(
        id = job.optString("id"),
        generation = job.optString("generation"),
        filePath = job.optString("filePath"),
        destinationComputerId = job.optString("destinationComputerId"),
        state = job.optString("state"),
        fileCreatedAt = LanBackupCleanupScheduler.nullableText(job, "fileCreatedAt"),
        backupCompletedAt = LanBackupCleanupScheduler.nullableText(job, "backupCompletedAt"),
        contentSha256 = LanBackupCleanupScheduler.nullableText(job, "contentSha256"),
        verificationVersion = job.optInt("verificationVersion"),
        verificationReceipt = parseRecordingStorageReceipt(job.optJSONObject("verificationReceipt")),
        remoteRecordId = job.optLong("remoteRecordId", -1L),
        sessionIds = if (sessions == null) {
            emptyList()
        } else {
            List(sessions.length()) { index ->
                sessions.optJSONObject(index)?.optString("id")?.trim().orEmpty()
            }
        },
        totalBytes = job.optLong("totalBytes", -1L),
        lastModified = job.optLong("lastModified", -1L),
        lastAttestedAt = LanBackupCleanupScheduler.nullableText(job, "lastAttestedAt"),
        localDeletedAt = LanBackupCleanupScheduler.nullableText(job, "localDeletedAt"),
    )
}

private fun parseRecordingStorageReceipt(value: JSONObject?): RecordingStorageReceipt? {
    value ?: return null
    return runCatching {
        RecordingStorageReceipt(
            authVersion = value.getInt("authVersion"),
            verifiedAtUnixSeconds = value.getLong("verifiedAtUnixSeconds"),
            hostNodeId = value.getString("hostNodeId").trim(),
            sourceDeviceId = value.getString("sourceDeviceId").trim(),
            sourceSessionId = value.getString("sourceSessionId").trim(),
            fileSha256 = value.getString("fileSha256").trim(),
            fileSizeBytes = value.getLong("fileSizeBytes"),
            recordId = value.getLong("recordId"),
            receiptSignature = value.getString("receiptSignature").trim(),
        )
    }.getOrNull()
}

internal data class RecordingStorageCheckResult(
    val values: Map<String, Any>,
    val jobsChanged: Boolean,
)

internal class RecordingStorageManager(
    private val context: Context,
    private val store: LanBackupStateStore,
    private val availableBytes: () -> Long = {
        StatFs(context.filesDir.path).availableBytes
    },
    private val beforeGuardedDeleteForTesting: ((JSONObject) -> Unit)? = null,
) {
    /**
     * 空间充足时只读取磁盘，不触碰备份数据库，也不进入备份串行执行器。
     * 手机启动录像不应被历史录像的电脑确认或保留期清理排队阻塞。
     */
    fun checkWithoutReclaimIfSufficient(): RecordingStorageCheckResult? {
        val policy = BackupStoragePolicyStore.current(context)
        val available = availableBytes()
        if (RecordingStoragePolicy.needsReclaim(available, policy)) return null
        return RecordingStorageCheckResult(
            values = mapOf(
                "availableBytes" to available,
                "availableBytesBefore" to available,
                "freedBytes" to 0L,
                "deletedCount" to 0,
                "warning" to RecordingStoragePolicy.needsWarning(available, policy),
                "insufficient" to false,
            ),
            jobsChanged = false,
        )
    }

    fun checkAndReclaim(): RecordingStorageCheckResult {
        val policy = BackupStoragePolicyStore.current(context)
        val before = availableBytes()
        var current = before
        var deletedCount = 0
        var freedBytes = 0L
        var jobsChanged = false
        if (RecordingStoragePolicy.needsReclaim(current, policy)) {
            var afterCreatedAtKey: String? = null
            var afterId: String? = null
            var page: LanBackupStorageJobPage
            do {
                page = store.storageRecoveryJobsPage(afterCreatedAtKey, afterId)
                for (job in page.jobs) {
                    if (current >= policy.targetBytes) break
                    val expected = recordingStorageCandidate(job)
                    if (!RecordingStoragePolicy.isVerifiedCandidate(expected)) continue
                    beforeGuardedDeleteForTesting?.invoke(JSONObject(job.toString()))
                    val outcome = store.reclaimVerifiedRecording(expected)
                    when (outcome.result) {
                        RecordingStorageReclaimResult.deleted -> {
                            deletedCount++
                            freedBytes += expected.totalBytes
                        }
                        RecordingStorageReclaimResult.missing,
                        RecordingStorageReclaimResult.stale,
                        RecordingStorageReclaimResult.failed,
                        RecordingStorageReclaimResult.rejected,
                        -> Unit
                    }
                    jobsChanged = jobsChanged || outcome.jobChanged
                    current = availableBytes()
                }
                afterCreatedAtKey = page.nextCreatedAtKey
                afterId = page.nextId
            } while (
                current < policy.targetBytes && page.jobs.size == 100
            )
        }
        if (policy.deleteUnbackedOnPressure &&
            RecordingStoragePolicy.needsReclaim(current, policy)
        ) {
            var fallbackCreatedAtKey: String? = null
            var fallbackId: String? = null
            var fallbackPage: LanBackupStorageJobPage
            do {
                fallbackPage = store.storageFallbackJobsPage(
                    fallbackCreatedAtKey,
                    fallbackId,
                )
                for (job in fallbackPage.jobs) {
                    if (current >= policy.targetBytes) break
                    val expected = recordingStorageCandidate(job)
                    if (!RecordingStoragePolicy.canReclaimWithoutProof(expected)) continue
                    val outcome = store.reclaimUnbackedRecording(
                        expected,
                        reason = if (expected.backupCompletedAt != null) {
                            "空间不足删除未确认备份"
                        } else {
                            "空间不足删除未备份录像"
                        },
                    )
                    when (outcome.result) {
                        RecordingStorageReclaimResult.deleted -> {
                            deletedCount++
                            freedBytes += expected.totalBytes
                        }
                        RecordingStorageReclaimResult.missing,
                        RecordingStorageReclaimResult.stale,
                        RecordingStorageReclaimResult.failed,
                        RecordingStorageReclaimResult.rejected,
                        -> Unit
                    }
                    jobsChanged = jobsChanged || outcome.jobChanged
                    current = availableBytes()
                }
                fallbackCreatedAtKey = fallbackPage.nextCreatedAtKey
                fallbackId = fallbackPage.nextId
            } while (
                current < policy.targetBytes && fallbackPage.jobs.size == 100
            )
        }
        return RecordingStorageCheckResult(
            values = mapOf(
                "availableBytes" to current,
                "availableBytesBefore" to before,
                "freedBytes" to freedBytes,
                "deletedCount" to deletedCount,
                "warning" to RecordingStoragePolicy.needsWarning(current, policy),
                "insufficient" to RecordingStoragePolicy.needsReclaim(current, policy),
            ),
            jobsChanged = jobsChanged,
        )
    }

}
