package app.packingproof.mobile

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import java.security.MessageDigest
import java.time.Duration
import java.time.Instant
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.TimeUnit

private const val CLEANUP_TAG = "PackingProofCleanup"

internal object LanBackupCleanupScheduler {
    private const val WORK_PREFIX = "lan-backup-cleanup-"
    internal const val UNIQUE_WORK = "lan-backup-cleanup-dispatcher"
    internal const val WORK_TAG = "lan-backup-cleanup"
    internal const val SCHEDULE_REFRESH_UNIQUE_WORK =
        "lan-backup-cleanup-schedule-refresh"
    internal const val SCHEDULE_REFRESH_WORK_TAG =
        "lan-backup-cleanup-schedule-refresh"
    val RETENTION_CONFIRMATION_GRACE: Duration = Duration.ofHours(24)

    fun reschedule(context: Context, store: LanBackupStateStore, job: JSONObject) {
        LanBackupStateStore.withJobLock {
            val id = job.getString("id")
            val expectedGeneration = nullableText(job, "generation") ?: return@withJobLock
            val current = store.readJob(id)
                ?.takeIf { nullableText(it, "generation") == expectedGeneration }
                ?: return@withJobLock
            val workManager = WorkManager.getInstance(context)
            val dueAt = dueAt(store, current)
            if (dueAt == null || nullableText(current, "localDeletedAt") != null) {
                if (nullableText(current, "scheduledCleanupAt") != null ||
                    current.optBoolean("waitingCleanup")
                ) {
                    store.updateJob(id, expectedGeneration) { value ->
                        value.put("scheduledCleanupAt", JSONObject.NULL)
                            .put("waitingCleanup", false)
                        true
                    } ?: return@withJobLock
                }
                workManager.cancelUniqueWork(WORK_PREFIX + id)
                return@withJobLock
            }
            if (shouldSkipReschedule(current, dueAt)) {
                return@withJobLock
            }
            store.updateJob(id, expectedGeneration) { value ->
                value.put("scheduledCleanupAt", dueAt.toString())
                true
            } ?: return@withJobLock
            workManager.cancelUniqueWork(WORK_PREFIX + id)
        }
        scheduleNext(context, store)
    }

    /** 已按同一 dueAt 排程过且未到期的清理任务不重复入队，保证启动与竞态下幂等。 */
    internal fun shouldSkipReschedule(current: JSONObject, dueAt: Instant): Boolean =
        nullableText(current, "scheduledCleanupAt") == dueAt.toString()

    fun rescheduleAll(context: Context, store: LanBackupStateStore) {
        val refresh = store.restartCleanupScheduleRefresh()
        WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_WORK)
        scheduleRefresh(context, refresh.generation)
    }

    fun resumeRefreshOrScheduleNext(context: Context, store: LanBackupStateStore) {
        val refresh = store.ensureCleanupScheduleRefresh()
        if (refresh != null) {
            WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_WORK)
            scheduleRefresh(context, refresh.generation)
        } else {
            scheduleNext(context, store)
        }
    }

    internal fun scheduleRefresh(
        context: Context,
        generation: Long,
        append: Boolean = false,
    ) {
        val request = OneTimeWorkRequestBuilder<LanBackupCleanupScheduleWorker>()
            .setInputData(workDataOf("generation" to generation))
            .addTag("lan-backup")
            .addTag(SCHEDULE_REFRESH_WORK_TAG)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            SCHEDULE_REFRESH_UNIQUE_WORK,
            schedulingPolicy(append),
            request,
        )
    }

    fun scheduleNext(context: Context, store: LanBackupStateStore, append: Boolean = false) {
        if (store.cleanupScheduleRefresh().active) return
        val next = store.nextScheduledCleanupJob() ?: return
        val id = next.getString("id")
        val generation = nullableText(next, "generation") ?: return
        val scheduledAt = nullableText(next, "scheduledCleanupAt")
            ?.let { value -> runCatching { Instant.parse(value) }.getOrNull() }
            ?: return
        val delay = Duration.between(Instant.now(), scheduledAt).toMillis().coerceAtLeast(0)
        val request = OneTimeWorkRequestBuilder<LanBackupCleanupWorker>()
            .setInputData(workDataOf("jobId" to id, "generation" to generation))
            .setInitialDelay(delay, TimeUnit.MILLISECONDS)
            .addTag("lan-backup")
            .addTag(WORK_TAG)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            UNIQUE_WORK,
            schedulingPolicy(append),
            request,
        )
    }

    /**
     * 外部重排必须替换旧的延迟请求，否则 KEEP 会让新出现的更早截止时间
     * 被已有的较晚请求吞掉。worker 完成后的续接仍追加到当前串行链尾。
     */
    internal fun schedulingPolicy(append: Boolean): ExistingWorkPolicy =
        if (append) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.REPLACE

    fun dueAt(store: LanBackupStateStore, job: JSONObject): Instant? {
        return dueAt(
            state = job.optString("state"),
            fileCreatedAt = nullableText(job, "fileCreatedAt"),
            backupCompletedAt = nullableText(job, "backupCompletedAt"),
            unbackedDays = store.unbackedRetentionDays(),
            backedDays = store.backedRetentionDays(),
            returnUnbackedDays = store.returnUnbackedRetentionDays(),
            returnBackedDays = store.returnBackedRetentionDays(),
            returnGoods = isReturnGoods(job),
        )
    }

    internal fun dueAt(
        state: String,
        fileCreatedAt: String?,
        backupCompletedAt: String?,
        unbackedDays: Int,
        backedDays: Int,
        returnUnbackedDays: Int = unbackedDays,
        returnBackedDays: Int = 1,
        returnGoods: Boolean = false,
    ): Instant? {
        if (state == "completed" && backupCompletedAt == null) return null
        val days = if (backupCompletedAt != null) {
            if (returnGoods) returnBackedDays else backedDays
        } else {
            if (returnGoods) returnUnbackedDays else unbackedDays
        }
        if (days < 0) return null
        val base = runCatching {
            Instant.parse(backupCompletedAt ?: fileCreatedAt ?: return null)
        }.getOrNull() ?: return null
        return base.plus(Duration.ofDays(days.toLong()))
    }

    internal fun isReturnGoods(job: JSONObject): Boolean {
        val directMode = nullableText(job, "mode")
        if (directMode != null) return directMode.equals("return", ignoreCase = true)
        val sessions = when (val value = job.opt("sessions")) {
            is JSONArray -> value
            is String -> runCatching { JSONArray(value) }.getOrNull()
            else -> null
        } ?: return false
        return sessions.optJSONObject(0)?.optString("mode", "shipping")
            ?.equals("return", ignoreCase = true) == true
    }

    internal fun nullableText(value: JSONObject, key: String): String? {
        if (!value.has(key) || value.isNull(key)) return null
        return normalizeNullableText(value.opt(key))
    }

    internal fun normalizeNullableText(value: Any?): String? = value
        ?.takeUnless { it == JSONObject.NULL }
        ?.toString()
        ?.trim()
        ?.takeIf { it.isNotEmpty() && it != "null" }

    internal fun shouldDeferForBackupState(state: String): Boolean =
        state == "pending" || state == "uploading"

    internal fun isConfirmationFresh(
        lastAttestedAt: String?,
        now: Instant = Instant.now(),
    ): Boolean {
        val attested = lastAttestedAt ?: return false
        return runCatching {
            !now.isAfter(Instant.parse(attested).plus(RETENTION_CONFIRMATION_GRACE))
        }.getOrDefault(false)
    }
}

internal class LanBackupCleanupScheduleWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    private val store = LanBackupStateStore(appContext)

    override suspend fun doWork(): Result = try {
        val generation = inputData.getLong("generation", -1L)
        if (generation < 0L) return Result.success()
        val slice = store.refreshCleanupScheduleSlice(generation)
        if (slice.hasMore) {
            LanBackupCleanupScheduler.scheduleRefresh(
                applicationContext,
                generation,
                append = true,
            )
        } else {
            LanBackupCleanupScheduler.scheduleNext(applicationContext, store)
        }
        Result.success()
    } catch (error: Throwable) {
        Log.e(CLEANUP_TAG, "Cleanup schedule refresh failed", error)
        Result.retry()
    } finally {
        store.close()
    }
}

internal enum class LanBackupFileCleanupResult { deleted, missing, stale, failed }

internal fun remoteAttestationAllowsLocalDeletion(
    attestation: RemoteRecordAttestation,
): Boolean = attestation == RemoteRecordAttestation.Confirmed

internal object LanBackupFileCleanup {
    fun deleteExpected(
        file: File,
        expectedBytes: Long,
        expectedLastModified: Long,
        expectedSha256: String?,
    ): LanBackupFileCleanupResult {
        val pendingClaims = file.parentFile?.listFiles { candidate ->
            candidate.name.startsWith(".${file.name}.cleanup-") &&
                candidate.name.endsWith(".pending")
        }.orEmpty()
        if (pendingClaims.isNotEmpty()) {
            if (file.exists() || pendingClaims.size != 1) {
                return LanBackupFileCleanupResult.stale
            }
            return finishClaim(
                claim = pendingClaims.single(),
                original = file,
                expectedBytes = expectedBytes,
                expectedLastModified = expectedLastModified,
                expectedSha256 = expectedSha256,
            )
        }
        if (!file.exists()) return LanBackupFileCleanupResult.missing
        val quarantine = File(
            file.parentFile,
            ".${file.name}.cleanup-${UUID.randomUUID()}.pending",
        )
        if (!file.renameTo(quarantine)) return LanBackupFileCleanupResult.failed
        return finishClaim(
            claim = quarantine,
            original = file,
            expectedBytes = expectedBytes,
            expectedLastModified = expectedLastModified,
            expectedSha256 = expectedSha256,
        )
    }

    private fun finishClaim(
        claim: File,
        original: File,
        expectedBytes: Long,
        expectedLastModified: Long,
        expectedSha256: String?,
    ): LanBackupFileCleanupResult {
        val matches = claim.length() == expectedBytes &&
            claim.lastModified() == expectedLastModified &&
            (expectedSha256 == null || claim.sha256() == expectedSha256)
        if (!matches) {
            if (original.exists()) return LanBackupFileCleanupResult.stale
            return if (claim.renameTo(original)) {
                LanBackupFileCleanupResult.stale
            } else {
                LanBackupFileCleanupResult.failed
            }
        }
        if (!claim.delete()) return LanBackupFileCleanupResult.failed
        return LanBackupFileCleanupResult.deleted
    }

    private fun File.sha256(): String {
        val digest = MessageDigest.getInstance("SHA-256")
        inputStream().use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count <= 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

internal class LanBackupCleanupWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    private val store = LanBackupStateStore(appContext)
    private val credentials = LanBackupCredentialStore(appContext)
    private var requestedRetry = false

    override suspend fun doWork(): Result = try {
        runWork()
    } finally {
        store.close()
    }

    private suspend fun runWork(): Result {
        requestedRetry = false
        val id = inputData.getString("jobId")
        val generation = inputData.getString("generation")
        val result = try {
            if (id == null) {
                Result.success()
            } else if (generation == null) {
                Result.success()
            } else {
                process(id, generation)
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            Log.e(CLEANUP_TAG, "Cleanup dispatcher failed id=${id?.take(8)}", error)
            if (id != null && generation != null) {
                store.updateJob(id, generation) { job ->
                    job.put("waitingCleanup", true)
                        .put(
                            "scheduledCleanupAt",
                            Instant.now().plus(Duration.ofMinutes(15)).toString(),
                        )
                        .put("errorMessage", "自动清理暂时失败，已保留本地录像等待重试")
                    true
                }
            }
            Result.success()
        }
        if (!requestedRetry) {
            LanBackupCleanupScheduler.scheduleNext(applicationContext, store, append = true)
            // 清理结果已经持久化到任务行；dispatcher 需要保持成功，
            // 避免单条异常记录取消整条 unique-work 后继链。
            return Result.success()
        }
        return result
    }

    private suspend fun process(id: String, generation: String): Result {
        store.updateJob(id, generation) { job ->
            if (LanBackupCleanupScheduler.nullableText(job, "scheduledCleanupAt") == null) {
                false
            } else {
                job.put("scheduledCleanupAt", JSONObject.NULL)
                true
            }
        }

        // 预计算远端确认结果（网络调用不持有 job 锁，避免阻塞 snapshot/enqueue）。
        val snapshot = store.readJob(id) ?: return Result.success()
        val snapshotCompletedAt =
            LanBackupCleanupScheduler.nullableText(snapshot, "backupCompletedAt")
        val precomputedAttestation: RemoteRecordAttestation? =
            if (snapshotCompletedAt != null) {
                if (
                    LanBackupCleanupScheduler.isConfirmationFresh(
                        LanBackupCleanupScheduler.nullableText(snapshot, "lastAttestedAt"),
                    )
                ) {
                    RemoteRecordAttestation.Confirmed
                } else {
                    val connection = store.connection()
                    val credential = credentials.load()
                    val recordId = snapshot.optLong("remoteRecordId").takeIf { it > 0 }
                    val sessions = snapshot.optJSONArray("sessions")
                    val sha256 =
                        LanBackupCleanupScheduler.nullableText(snapshot, "contentSha256")
                    if (
                        connection == null || credential.isNullOrBlank() ||
                        recordId == null ||
                        sessions == null || sessions.length() != 1 ||
                        sha256 == null
                    ) {
                        null
                    } else {
                        BackupRequestAuthentication.verifyRemoteRecord(
                            connection,
                            credential,
                            store.deviceId(),
                            recordId,
                            sessions.getJSONObject(0).getString("id"),
                            sha256,
                            snapshot.optLong("totalBytes", -1L),
                        )
                    }
                }
            } else {
                null
            }

        return LanBackupStateStore.withJobLock {
            val job = store.readJob(id) ?: return@withJobLock Result.success()
            if (LanBackupCleanupScheduler.nullableText(job, "generation") != generation) {
                return@withJobLock Result.success()
            }
            if (LanBackupCleanupScheduler.nullableText(job, "localDeletedAt") != null) {
                return@withJobLock Result.success()
            }
            val dueAt = LanBackupCleanupScheduler.dueAt(store, job)
                ?: return@withJobLock Result.success()
            if (Instant.now().isBefore(dueAt)) {
                // worker 自身提前运行时（如系统时间回拨）需要重新排程：
                // 先清掉已排期时间，避免被幂等跳过逻辑当作“已排程”而不重建。
                job.put("scheduledCleanupAt", JSONObject.NULL)
                store.writeJob(job)
                LanBackupCleanupScheduler.reschedule(applicationContext, store, job)
                return@withJobLock Result.success()
            }
            if (
                LanBackupCleanupScheduler.shouldDeferForBackupState(job.optString("state"))
            ) {
                job.put("waitingCleanup", true)
                store.writeJob(job)
                return@withJobLock retry()
            }

            val file = File(job.optString("filePath"))
            val appDataRoot = applicationContext.dataDir.canonicalFile
            val managed = runCatching {
                file.canonicalFile.path.startsWith(appDataRoot.path + File.separator)
            }.getOrDefault(false)
            if (!managed) {
                Log.w(CLEANUP_TAG, "Cleanup rejected unmanaged path=${file.absolutePath}")
                job.put("waitingCleanup", false)
                    .put("errorMessage", "录像不在应用目录内，已取消自动清理")
                store.writeJob(job)
                return@withJobLock Result.failure()
            }

            val completedAt =
                LanBackupCleanupScheduler.nullableText(job, "backupCompletedAt")
            val contentSha256 =
                LanBackupCleanupScheduler.nullableText(job, "contentSha256")

            if (completedAt != null) {
                val recordId = job.optLong("remoteRecordId").takeIf { it > 0 }
                val sessions = job.optJSONArray("sessions")
                val hasTrustedEvidence =
                    job.optInt("verificationVersion") >= BackupRequestAuthentication.VERSION &&
                        contentSha256 != null && contentSha256.length == 64 &&
                        job.optLong("totalBytes", -1L) > 0 &&
                        recordId != null &&
                        sessions != null && sessions.length() == 1
                if (!hasTrustedEvidence) {
                    Log.w(
                        CLEANUP_TAG,
                        "Cleanup preserved legacy/unverified backup path=${file.absolutePath}",
                    )
                    job.put("waitingCleanup", false)
                        .put("errorMessage", "备份记录缺少安全校验信息，需重新备份后才能自动清理")
                    store.writeJob(job)
                    return@withJobLock Result.success()
                }

                val attestation =
                    if (
                        LanBackupCleanupScheduler.isConfirmationFresh(
                            LanBackupCleanupScheduler.nullableText(job, "lastAttestedAt"),
                        )
                    ) {
                        RemoteRecordAttestation.Confirmed
                    } else {
                        precomputedAttestation ?: RemoteRecordAttestation.Unreachable
                    }
                if (!remoteAttestationAllowsLocalDeletion(attestation)) {
                    when (attestation) {
                        RemoteRecordAttestation.Confirmed -> error("已确认的远端记录不应阻止清理")
                        RemoteRecordAttestation.Missing -> {
                            Log.w(CLEANUP_TAG, "Cleanup preserved missing remote record path=${file.absolutePath}")
                            job.put("waitingCleanup", false)
                                .put("errorMessage", "远端缺失，待重新备份")
                            store.writeJob(job)
                            return@withJobLock Result.success()
                        }
                        RemoteRecordAttestation.Unauthorized -> {
                            Log.w(CLEANUP_TAG, "Cleanup preserved unauthorized attestation path=${file.absolutePath}")
                            job.put("waitingCleanup", false)
                                .put("errorMessage", "需要重新扫码授权")
                            store.writeJob(job)
                            return@withJobLock Result.success()
                        }
                        RemoteRecordAttestation.NotReady -> {
                            Log.w(CLEANUP_TAG, "Cleanup preserved not-ready remote record path=${file.absolutePath}")
                            job.put("waitingCleanup", true)
                                .put("errorMessage", "电脑端尚未完成校验")
                            store.writeJob(job)
                            return@withJobLock retry()
                        }
                        RemoteRecordAttestation.Unreachable -> {
                            Log.w(CLEANUP_TAG, "Cleanup preserved unreachable backup path=${file.absolutePath}")
                            job.put("waitingCleanup", true)
                                .put("errorMessage", "暂时无法向电脑确认备份，已保留本地录像")
                            store.writeJob(job)
                            return@withJobLock retry()
                        }
                    }
                }
                job.put("lastAttestedAt", Instant.now().toString())
            }

            when (
                LanBackupFileCleanup.deleteExpected(
                    file = file,
                    expectedBytes = job.optLong("totalBytes", -1L),
                    expectedLastModified = job.optLong("lastModified", -1L),
                    expectedSha256 = contentSha256,
                )
            ) {
                LanBackupFileCleanupResult.stale -> {
                    Log.w(CLEANUP_TAG, "Cleanup preserved replaced recording path=${file.absolutePath}")
                    job.put("waitingCleanup", false)
                        .put("errorMessage", "录像文件已被替换，已取消本次自动清理")
                    store.writeJob(job)
                    return@withJobLock Result.success()
                }
                LanBackupFileCleanupResult.failed -> {
                    Log.w(CLEANUP_TAG, "Cleanup failed and will retry path=${file.absolutePath}")
                    job.put("waitingCleanup", true)
                    store.writeJob(job)
                    return@withJobLock retry()
                }
                LanBackupFileCleanupResult.deleted -> Log.i(
                    CLEANUP_TAG,
                    "Cleanup deleted ${if (completedAt == null) "unbacked" else "verified backup"} " +
                        "recording path=${file.absolutePath}",
                )
                LanBackupFileCleanupResult.missing -> Log.i(
                    CLEANUP_TAG,
                    "Cleanup found recording already missing path=${file.absolutePath}",
                )
            }
            job.put("localDeletedAt", Instant.now().toString())
                .put("scheduledCleanupAt", JSONObject.NULL)
                .put("waitingCleanup", false)
                .put(
                    "cleanupReason",
                    when {
                        completedAt == null -> "未备份录像保留策略清理"
                        else -> "已备份录像保留策略清理"
                    },
                )
            if (completedAt == null) {
                job.put("state", "expired")
                    .put("errorMessage", "未备份录像已按保留策略清理")
            }
            store.writeJob(job)
            Result.success()
        }
    }

    private fun retry(): Result {
        requestedRetry = true
        return Result.retry()
    }
}
