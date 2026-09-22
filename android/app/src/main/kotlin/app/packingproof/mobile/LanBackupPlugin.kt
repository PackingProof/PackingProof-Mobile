package app.packingproof.mobile

import android.app.Activity
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.util.Log
import androidx.work.WorkManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import app.packingproof.mobile.generated.BackupCleanupPageDto
import app.packingproof.mobile.generated.BackupJobsByPathsDto
import app.packingproof.mobile.generated.BackupSummaryDto
import app.packingproof.mobile.generated.FlutterError

internal fun availableRecordingStorageBytes(
    context: Context,
    availableBytesForPath: (String) -> Long = { path -> StatFs(path).availableBytes },
): Long? = runCatching {
    availableBytesForPath(context.filesDir.path)
}.getOrNull()

internal class LanBackupPlugin(
    private val activity: Activity,
) {
    companion object {
        private const val WORK_PREFIX = "lan-backup-"
        private const val TAG = "PackingProofBackup"
        private const val INVALID_RSSI = -127
        private const val SUMMARY_PROGRESS_THROTTLE_MS = 1_000L
    }

    private val context: Context = activity.applicationContext
    private val store = LanBackupStateStore(context)
    private val storageManager = RecordingStorageManager(context, store)
    private val credentials = LanBackupCredentialStore(context)
    private val summaryListeners = mutableListOf<(BackupSummaryDto) -> Unit>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val serialExecutor = LanBackupSerialExecutor()
    private var summaryPushPending = false
    private var summaryPushScheduled = false
    private var requestedSummaryRevision = 0L
    private var requestedImmediateRevision = 0L
    private val summaryPushRunnable = Runnable {
        pushSummaryNow()
    }
    private val revisionListener: (LanBackupRevisionNotifier.Notice) -> Unit = { notice ->
        notifySummaryChanged(notice.revision, immediate = notice.immediate)
    }

    init {
        LanBackupRevisionNotifier.addListener(revisionListener)
    }

    fun initialize(request: Map<String?, Any?>): BackupSummaryDto {
        val unbackedDays = (request["unbackedRetentionDays"] as? Number)?.toInt()
        val backedDays = (request["backedRetentionDays"] as? Number)?.toInt()
        val returnUnbackedDays = (request["returnUnbackedRetentionDays"] as? Number)?.toInt()
        val returnBackedDays = (request["returnBackedRetentionDays"] as? Number)?.toInt()
        WorkManager.getInstance(context).cancelAllWorkByTag("lan-backup").result.get()
        if (store.migrateLegacyConnection() != null) credentials.clear()
        store.reconcileUnavailableJobs()
        val retentionChanged = store.saveRetentionPolicies(
            unbackedDays, backedDays, returnUnbackedDays, returnBackedDays,
        )
        BackupStoragePolicyStore.save(context, request)
        setAutoEnabled(request["autoEnabled"] as? Boolean ?: false)
        if (retentionChanged) {
            LanBackupCleanupScheduler.rescheduleAll(context, store)
        } else {
            LanBackupCleanupScheduler.resumeRefreshOrScheduleNext(context, store)
        }
        return summary()
    }

    /** 记录宿主 Activity 是否在前台，供上传 Worker 避免后台启动前台服务。 */
    fun onHostForeground() {
        context.getSharedPreferences("lan_backup_runtime", Context.MODE_PRIVATE)
            .edit().putBoolean("host_foreground", true).commit()
        schedulePending()
    }

    fun onHostBackground() {
        context.getSharedPreferences("lan_backup_runtime", Context.MODE_PRIVATE)
            .edit().putBoolean("host_foreground", false).commit()
    }

    fun setAutoEnabled(enabled: Boolean) {
        context.getSharedPreferences("lan_backup_runtime", Context.MODE_PRIVATE)
            .edit().putBoolean("auto_enabled", enabled).commit()
        if (!enabled) {
            WorkManager.getInstance(context).cancelAllWorkByTag("lan-backup").result.get()
        }
        store.setUploadsEnabled(enabled)
        if (enabled) schedulePending()
    }

    fun loadAccessKey(): String = credentials.load() ?: ""

    fun saveConnection(connection: Map<String?, Any?>) {
        val baseUrl = connection["baseUrl"] as? String ?: error("缺少电脑地址")
        val accessKey = connection["accessKey"] as? String ?: error("缺少设备令牌")
        val computerId = connection["computerId"] as? String ?: ""
        WorkManager.getInstance(context).cancelAllWorkByTag("lan-backup")
        store.saveConnection(
            baseUrl,
            computerId,
            connection["computerName"] as? String ?: "已连接电脑",
            connection["deviceName"] as? String ?: "",
            connection["supportsUploadVideoCodec"] as? Boolean ?: false,
        )
        credentials.save(accessKey)
        if (connection["recoverIncompatibleFailuresOnly"] as? Boolean == true) {
            store.recoverIncompatibleFailures(computerId)
        } else {
            store.retargetJobs(computerId)
        }
        store.clearMigrationHint()
        schedulePending()
        LanBackupCleanupScheduler.resumeRefreshOrScheduleNext(context, store)
    }

    fun disconnect() {
        WorkManager.getInstance(context).cancelAllWorkByTag("lan-backup")
        store.clearConnection()
        credentials.clear()
        LanBackupCleanupScheduler.resumeRefreshOrScheduleNext(context, store)
    }

    fun enqueueJob(request: Map<String?, Any?>) {
        enqueueJobStored(request)?.let { enqueued ->
            scheduleEnqueuedJob(enqueued)
            Log.i(
                TAG,
                "Enqueue path=${enqueued.job.optString("filePath")} sessions=1 " +
                    "state=${enqueued.job.optString("state")}",
            )
        }
    }

    private data class EnqueuedJob(
        val job: JSONObject,
        val startUpload: Boolean,
        val replace: Boolean,
    )

    private fun enqueueJobStored(request: Map<String?, Any?>): EnqueuedJob? {
        val path = request["filePath"] as? String ?: error("缺少录像路径")
        @Suppress("UNCHECKED_CAST")
        val sessions = JSONArray(
            request["sessions"] as? List<Map<String, Any?>> ?: emptyList<Map<String, Any?>>(),
        )
        require(sessions.length() == 1) { "每个备份任务必须且只能包含一条录像记录" }
        val source = File(path)
        if (LanBackupSourcePolicy.inspect(source, -1L, -1L) != LanBackupSourceStatus.AVAILABLE) {
            store.reconcileJobSource(LanBackupStateStore.stableId(source.canonicalPath))
            return null
        }
        val upsert = store.upsertJob(path, sessions)
        var job = upsert.job
        val forceRestart = request["forceRestart"] == true
        val startUpload = request["startUpload"] != false && isAutoEnabled()
        if (forceRestart &&
            (job.optString("state") != "completed" ||
                LanBackupCleanupScheduler.nullableText(job, "contentSha256") == null)
        ) {
            job = store.updateJob(
                job.getString("id"),
                LanBackupCleanupScheduler.nullableText(job, "generation"),
            ) { current ->
                current.put("generation", UUID.randomUUID().toString())
                    .put("state", "pending")
                    .put("uploadedBytes", 0L)
                    .put("backupCompletedAt", JSONObject.NULL)
                    .put("contentSha256", JSONObject.NULL)
                    .put("remoteRecordId", JSONObject.NULL)
                    .put("errorMessage", JSONObject.NULL)
                    .put("failureKind", JSONObject.NULL)
                true
            } ?: job
        } else if (!startUpload && job.optString("state") == "pending") {
            job = store.updateJob(
                job.getString("id"),
                LanBackupCleanupScheduler.nullableText(job, "generation"),
            ) { current -> current.put("state", "paused"); true } ?: job
        }
        return EnqueuedJob(
            job = job,
            startUpload = startUpload,
            replace = forceRestart || upsert.recreated,
        )
    }

    private fun scheduleEnqueuedJob(enqueued: EnqueuedJob) {
        LanBackupCleanupScheduler.reschedule(context, store, enqueued.job)
        if (enqueued.startUpload) {
            schedule(enqueued.job.getString("id"), replace = enqueued.replace)
        }
    }

    fun enqueueJobs(requests: List<Map<String?, Any?>>) {
        require(requests.size <= 100) { "单次最多入队 100 个备份任务" }
        val enqueued = store.writeBatch { requests.mapNotNull(::enqueueJobStored) }
        enqueued.forEach(::scheduleEnqueuedJob)
        Log.i(TAG, "Enqueue batch requested=${requests.size} enqueued=${enqueued.size}")
    }

    fun updateRetentionSchedule(request: Map<String?, Any?>) {
        BackupStoragePolicyStore.save(context, request)
        val changed = store.saveRetentionPolicies(
            (request["unbackedRetentionDays"] as? Number)?.toInt(),
            (request["backedRetentionDays"] as? Number)?.toInt(),
            (request["returnUnbackedRetentionDays"] as? Number)?.toInt(),
            (request["returnBackedRetentionDays"] as? Number)?.toInt(),
        )
        if (changed) {
            LanBackupCleanupScheduler.rescheduleAll(context, store)
        } else {
            LanBackupCleanupScheduler.resumeRefreshOrScheduleNext(context, store)
        }
    }

    fun reclaimStorageIfNeeded(): Map<String?, Any?> =
        storageManager.checkAndReclaim().values.mapKeys { it.key as String? }

    fun availableRecordingStorageBytes(): Long? = availableRecordingStorageBytes(context)

    /**
     * 重新排队备份任务。[manual] 为 true 表示操作员手动上传：这一条不受
     * 「暂停上传」总闸限制，直接排到上传链上。
     */
    fun requeueJob(id: String, manual: Boolean) {
        val sourceStatus = store.reconcileJobSource(id)
        if (sourceStatus != null && sourceStatus != LanBackupSourceStatus.AVAILABLE) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_PREFIX + id)
            return
        }
        store.updateJob(id) { job ->
            job.put("generation", UUID.randomUUID().toString())
                .put("state", "pending")
                .put("errorMessage", JSONObject.NULL)
                .put("failureKind", JSONObject.NULL)
            true
        } ?: error("找不到备份任务")
        if (manual) {
            scheduleManual(id)
        } else {
            schedule(id, replace = true)
        }
    }

    fun cancelJob(id: String) {
        WorkManager.getInstance(context).cancelUniqueWork(WORK_PREFIX + id)
        store.updateJob(id) { job ->
            job.put("generation", UUID.randomUUID().toString()).put("state", "paused")
            true
        }
    }

    fun isWifiConnected(): Boolean {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        return connectivity.allNetworks.any { network ->
            connectivity.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }

    fun networkDiagnostics(): Map<String?, Any?> {
        val wifiConnected = isWifiConnected()
        var rssiDbm: Int? = null
        var linkSpeedMbps: Int? = null
        if (wifiConnected) {
            runCatching {
                val wifiManager =
                    context.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val info = wifiManager.connectionInfo
                if (info != null) {
                    if (info.rssi != INVALID_RSSI) {
                        rssiDbm = info.rssi
                    }
                    linkSpeedMbps = info.linkSpeed.takeIf { it > 0 }
                }
            }
        }
        return mapOf<String?, Any?>(
            "wifiConnected" to wifiConnected,
            "rssiDbm" to rssiDbm,
            "linkSpeedMbps" to linkSpeedMbps,
        )
    }

    private fun schedulePending() {
        if (!isAutoEnabled()) return
        if (store.connection() == null || credentials.load().isNullOrBlank()) return
        LanBackupDispatcher.schedule(context)
        Log.i(TAG, "Backup dispatcher scheduled")
    }

    private fun schedule(id: String, replace: Boolean) {
        if (!isAutoEnabled()) return
        if (store.connection() == null) {
            Log.w(TAG, "Upload schedule skipped job=$id reason=no_connection")
            return
        }
        if (credentials.load().isNullOrBlank()) {
            Log.w(TAG, "Upload schedule skipped job=$id reason=no_credential")
            return
        }
        LanBackupDispatcher.schedule(context)
        Log.i(TAG, "Upload dispatcher requested job=$id replace=$replace")
    }

    /**
     * 手动上传：操作员的点按要真的把这一条传到电脑，所以不看「暂停上传」开关；
     * 只要求已经配对并持有设备令牌，否则任务留在队列里等下次连接。
     */
    private fun scheduleManual(id: String) {
        if (store.connection() == null) {
            Log.w(TAG, "Manual upload queued job=$id reason=no_connection")
            return
        }
        if (credentials.load().isNullOrBlank()) {
            Log.w(TAG, "Manual upload queued job=$id reason=no_credential")
            return
        }
        LanBackupDispatcher.schedule(context, jobId = id)
        Log.i(TAG, "Manual upload requested job=$id")
    }

    private fun isAutoEnabled(): Boolean = context
        .getSharedPreferences("lan_backup_runtime", Context.MODE_PRIVATE)
        .getBoolean("auto_enabled", false)

    fun summary(): BackupSummaryDto = store.summary()

    fun jobsForPaths(paths: List<String>): BackupJobsByPathsDto = store.jobsForPaths(paths)

    fun cleanupEvents(afterRevision: Long, limit: Int): BackupCleanupPageDto =
        store.cleanupEvents(afterRevision, limit)

    fun acknowledgeCleanupEvents(throughRevision: Long) =
        store.acknowledgeCleanupEvents(throughRevision)

    fun hasPendingJobsOutsideDestination(computerId: String): Boolean =
        store.hasPendingJobsOutsideDestination(computerId)

    /**
     * 所有 Pigeon host 调用都进入插件自有的唯一串行执行器。Pigeon TaskQueue
     * 负责让消息解码离开平台线程；这里负责数据库所有权和 dispose 生命周期。
     */
    fun <T> submit(callback: (Result<T>) -> Unit, action: () -> T) {
        val accepted = serialExecutor.execute {
            val result = runCatching(action)
            mainHandler.post { callback(result) }
        }
        if (!accepted) {
            mainHandler.post {
                callback(
                    Result.failure(
                        FlutterError("lan_backup_disposed", "局域网备份服务已关闭", null),
                    ),
                )
            }
        }
    }

    fun notifySummaryChanged() {
        notifySummaryChanged(0L, immediate = true)
    }

    /** 字节进度按一秒 latest-wins 合并；状态、失败和完成边沿立即推送。 */
    private fun notifySummaryChanged(revision: Long, immediate: Boolean) {
        mainHandler.post {
            requestedSummaryRevision = maxOf(requestedSummaryRevision, revision)
            if (immediate) {
                requestedImmediateRevision = maxOf(requestedImmediateRevision, revision)
            }
            if (summaryPushPending) {
                if (immediate && summaryPushScheduled) {
                    mainHandler.removeCallbacks(summaryPushRunnable)
                    mainHandler.post(summaryPushRunnable)
                }
                return@post
            }
            summaryPushPending = true
            summaryPushScheduled = true
            if (immediate) {
                mainHandler.post(summaryPushRunnable)
            } else {
                mainHandler.postDelayed(summaryPushRunnable, SUMMARY_PROGRESS_THROTTLE_MS)
            }
        }
    }

    private fun pushSummaryNow() {
        summaryPushScheduled = false
        serialExecutor.execute {
            val value = runCatching(::summary).getOrNull()
            mainHandler.post {
                summaryPushPending = false
                if (value != null) {
                    summaryListeners.toList().forEach { it(value) }
                }
                val deliveredRevision = value?.revision ?: -1L
                if (requestedSummaryRevision > deliveredRevision) {
                    notifySummaryChanged(
                        requestedSummaryRevision,
                        immediate = requestedImmediateRevision > deliveredRevision,
                    )
                }
            }
        }.also { accepted ->
            if (!accepted) {
                summaryPushPending = false
            }
        }
    }

    fun addSummaryListener(listener: (BackupSummaryDto) -> Unit) {
        summaryListeners.add(listener)
    }

    fun removeSummaryListener(listener: (BackupSummaryDto) -> Unit) {
        summaryListeners.remove(listener)
    }

    fun dispose() {
        LanBackupRevisionNotifier.removeListener(revisionListener)
        mainHandler.removeCallbacks(summaryPushRunnable)
        summaryPushPending = false
        summaryPushScheduled = false
        requestedSummaryRevision = 0L
        requestedImmediateRevision = 0L
        summaryListeners.clear()
        serialExecutor.disposeAfterDraining(store::close)
    }
}
