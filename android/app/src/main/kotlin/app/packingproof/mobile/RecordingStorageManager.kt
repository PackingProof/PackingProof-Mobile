package app.packingproof.mobile

import android.content.Context
import android.os.StatFs
import android.util.Log
import org.json.JSONObject
import java.time.Instant

private const val STORAGE_LOG_TAG = "RecordingStorage"

internal object RecordingStoragePolicy {
    private val HEX_64 = Regex("^[0-9a-fA-F]{64}$")

    fun needsWarning(availableBytes: Long, policy: BackupStoragePolicy): Boolean =
        availableBytes < policy.warningBytes

    fun needsReclaim(availableBytes: Long, policy: BackupStoragePolicy): Boolean =
        availableBytes < policy.minimumBytes

    fun isFreshAttestation(value: String, policy: BackupStoragePolicy): Boolean = runCatching {
        val age = java.time.Duration.between(Instant.parse(value), Instant.now()).abs()
        age <= policy.attestationFreshness
    }.getOrDefault(false)

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
        policy: BackupStoragePolicy,
    ): Boolean =
        hasCompleteProof(candidate) &&
            candidate.lastAttestedAt?.let { isFreshAttestation(it, policy) } == true

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
        policy: BackupStoragePolicy,
    ): List<RecordingStorageCandidate> = candidates
        .filter { isVerifiedCandidate(it, policy) }
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
    private val confirmRemoteRecording: ((RecordingStorageCandidate) -> RemoteRecordAttestation)? = null,
    private val maxRemoteConfirmationsPerRun: Int? = null,
) {
    fun checkAndReclaim(): RecordingStorageCheckResult {
        val policy = BackupStoragePolicyStore.current(context)
        val before = availableBytes()
        var current = before
        var deletedCount = 0
        var freedBytes = 0L
        var jobsChanged = false
        var remoteConfirmations = 0
        var remoteUnreachable = false
        val confirmationLimit = maxRemoteConfirmationsPerRun ?: policy.confirmationLimit
        if (RecordingStoragePolicy.needsReclaim(current, policy)) {
            var afterCreatedAtKey: String? = null
            var afterId: String? = null
            var page: LanBackupStorageJobPage
            do {
                page = store.storageRecoveryJobsPage(afterCreatedAtKey, afterId)
                for (job in page.jobs) {
                    if (current >= policy.targetBytes) break
                    var expected = recordingStorageCandidate(job)
                    if (!RecordingStoragePolicy.isVerifiedCandidate(expected, policy)) {
                        // 电脑确认会过期。过期后先补一次确认，否则空间不足时永远没有可
                        // 回收的录像，只能停止录像或拒绝开始录像。
                        if (remoteUnreachable ||
                            remoteConfirmations >= confirmationLimit ||
                            !RecordingStoragePolicy.hasCompleteProof(expected)
                        ) {
                            continue
                        }
                        remoteConfirmations++
                        when (confirmWithComputer(expected)) {
                            RemoteRecordAttestation.Confirmed -> Unit
                            RemoteRecordAttestation.Unreachable -> {
                                remoteUnreachable = true
                                continue
                            }
                            RemoteRecordAttestation.Missing,
                            RemoteRecordAttestation.Unauthorized,
                            RemoteRecordAttestation.NotReady,
                            -> continue
                        }
                        expected = markAttestedNow(expected) ?: continue
                    }
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

    /**
     * 向电脑确认这条录像仍然存在且校验通过，确认成功后写回确认时间，使候选重新满
     * 足删除所需的“新鲜确认”条件。
     */
    private fun confirmWithComputer(
        candidate: RecordingStorageCandidate,
    ): RemoteRecordAttestation {
        val injected = confirmRemoteRecording
        if (injected != null) return injected(candidate)
        val connection = store.connection()
            ?: return RemoteRecordAttestation.Unreachable
        val credential = LanBackupCredentialStore(context).load()
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return RemoteRecordAttestation.Unauthorized
        val sessionId = candidate.sessionIds.singleOrNull()
            ?: return RemoteRecordAttestation.NotReady
        val fileSha256 = candidate.contentSha256
            ?: return RemoteRecordAttestation.NotReady
        val attestation = BackupRequestAuthentication.verifyRemoteRecord(
            connection,
            credential,
            store.deviceId(),
            candidate.remoteRecordId,
            sessionId,
            fileSha256,
            candidate.totalBytes,
        )
        if (attestation != RemoteRecordAttestation.Confirmed) {
            Log.w(
                STORAGE_LOG_TAG,
                "Storage reclaim preserved recording: attestation=$attestation",
            )
        }
        return attestation
    }

    private fun markAttestedNow(
        candidate: RecordingStorageCandidate,
    ): RecordingStorageCandidate? {
        val attestedAt = Instant.now().toString()
        store.updateJob(candidate.id, candidate.generation) { job ->
            job.put("lastAttestedAt", attestedAt)
            true
        } ?: return null
        return candidate.copy(lastAttestedAt = attestedAt)
    }
}
