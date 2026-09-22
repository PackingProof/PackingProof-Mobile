package app.packingproof.mobile

import app.packingproof.mobile.generated.BackupNativeHostApi
import app.packingproof.mobile.generated.BackupCleanupPageDto
import app.packingproof.mobile.generated.BackupJobsByPathsDto
import app.packingproof.mobile.generated.BackupSummaryDto

internal class PigeonBackupHostApi(
    private val plugin: LanBackupPlugin,
) : BackupNativeHostApi {
    override fun summary(callback: (Result<BackupSummaryDto>) -> Unit) {
        plugin.submit(callback) { plugin.summary() }
    }

    override fun initialize(
        request: Map<String?, Any?>,
        callback: (Result<BackupSummaryDto>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.initialize(request) }
    }

    override fun setAutoEnabled(enabled: Boolean, callback: (Result<Unit>) -> Unit) {
        plugin.submit(callback) { plugin.setAutoEnabled(enabled) }
    }

    override fun jobsForPaths(
        paths: List<String>,
        callback: (Result<BackupJobsByPathsDto>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.jobsForPaths(paths) }
    }

    override fun cleanupEvents(
        afterRevision: Long,
        limit: Long,
        callback: (Result<BackupCleanupPageDto>) -> Unit,
    ) {
        plugin.submit(callback) {
            require(limit in 1..100) { "清理事件单页数量必须为 1 到 100" }
            plugin.cleanupEvents(afterRevision, limit.toInt())
        }
    }

    override fun acknowledgeCleanupEvents(
        throughRevision: Long,
        callback: (Result<Unit>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.acknowledgeCleanupEvents(throughRevision) }
    }

    override fun hasPendingJobsOutsideDestination(
        computerId: String,
        callback: (Result<Boolean>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.hasPendingJobsOutsideDestination(computerId) }
    }

    override fun loadAccessKey(callback: (Result<String?>) -> Unit) {
        plugin.submit(callback) { plugin.loadAccessKey() }
    }

    override fun isWifiConnected(callback: (Result<Boolean>) -> Unit) {
        plugin.submit(callback) { plugin.isWifiConnected() }
    }

    override fun saveConnection(
        connection: Map<String?, Any?>,
        callback: (Result<Unit>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.saveConnection(connection) }
    }

    override fun disconnect(callback: (Result<Unit>) -> Unit) {
        plugin.submit(callback) { plugin.disconnect() }
    }

    override fun enqueueJob(
        request: Map<String?, Any?>,
        callback: (Result<Unit>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.enqueueJob(request) }
    }

    override fun enqueueJobs(
        requests: List<Map<String?, Any?>>,
        callback: (Result<Unit>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.enqueueJobs(requests) }
    }

    override fun requeueJob(
        jobId: String,
        manual: Boolean,
        callback: (Result<Unit>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.requeueJob(jobId, manual) }
    }

    override fun cancelJob(
        jobId: String,
        callback: (Result<Unit>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.cancelJob(jobId) }
    }

    override fun updateRetentionSchedule(
        request: Map<String?, Any?>,
        callback: (Result<Unit>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.updateRetentionSchedule(request) }
    }

    override fun reclaimStorageIfNeeded(
        callback: (Result<Map<String?, Any?>>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.reclaimStorageIfNeeded() }
    }

    override fun availableRecordingStorageBytes(
        callback: (Result<Long?>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.availableRecordingStorageBytes() }
    }

    override fun getNetworkDiagnostics(
        callback: (Result<Map<String?, Any?>?>) -> Unit,
    ) {
        plugin.submit(callback) { plugin.networkDiagnostics() }
    }
}
