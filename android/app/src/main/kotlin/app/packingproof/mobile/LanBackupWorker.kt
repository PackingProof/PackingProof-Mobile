package app.packingproof.mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.media.MediaExtractor
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import java.io.EOFException
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import kotlin.math.min

internal class LanBackupWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    companion object {
        private const val CHANNEL_ID = "packing_proof_backup"
        private const val DEFAULT_CHUNK_SIZE = 4 * 1024 * 1024
        private const val TAG = "PackingProofBackup"
    }

    private val store = LanBackupStateStore(appContext)
    private val credentials = LanBackupCredentialStore(appContext)
    private val hostResolver = LanBackupHostResolver(appContext)

    override suspend fun doWork(): Result {
        val id = inputData.getString("jobId") ?: return Result.failure()
        val initialJob = store.readJob(id) ?: return Result.failure()
        val generation = initialJob.optString("generation")
        val connection = store.connection()
        val accessKey = credentials.load()
        val initialSourceStatus = sourceStatus(initialJob)
        if (initialSourceStatus != LanBackupSourceStatus.AVAILABLE) {
            return discard(initialJob, generation, initialSourceStatus)
        }
        if (connection == null || accessKey.isNullOrBlank()) {
            return fail(
                initialJob,
                generation,
                "设备连接已失效，请重新申请并在电脑上允许连接",
                LanBackupFailureKind.CREDENTIAL_INVALID,
            )
        }
        if (initialJob.optString("destinationComputerId") != connection.optString("computerId")) {
            return Result.failure()
        }
        val job = store.updateJob(id, generation) { current ->
            val currentFile = File(current.optString("filePath"))
            if (LanBackupCleanupScheduler.nullableText(current, "localDeletedAt") != null ||
                !currentFile.exists()
            ) {
                false
            } else {
                current.put("state", "uploading")
                    .put("errorMessage", JSONObject.NULL)
                    .put("failureKind", JSONObject.NULL)
                true
            }
        } ?: run {
            val status = sourceStatus(initialJob)
            return if (status == LanBackupSourceStatus.AVAILABLE) {
                Result.success()
            } else {
                discard(initialJob, generation, status)
            }
        }
        val file = File(job.optString("filePath"))
        var baseUrl = connection.getString("baseUrl").trimEnd('/')
        resolveChangedBaseUrl(baseUrl, connection)?.let { baseUrl = it }
        val storedCredential = BackupRequestAuthentication.parse(accessKey)

        return try {
            Log.i(TAG, "Backup started id=${id.take(8)} file=${file.name} bytes=${file.length()}")

            requireAvailable(job)
            val sha256 = try {
                file.sha256()
            } catch (error: IOException) {
                throw BackupSourceUnavailableException("无法读取录像文件", error)
            }
            requireAvailable(job)
            val createBody = JSONObject()
                .put("fileSha256", sha256)
                .put("totalBytes", file.length())
                .put("mimeType", "video/mp4")
            val createResponse = try {
                postJson("$baseUrl/api/mobile-backup/uploads", accessKey, createBody)
            } catch (error: IOException) {
                baseUrl = resolveChangedBaseUrl(baseUrl, connection) ?: throw error
                postJson("$baseUrl/api/mobile-backup/uploads", accessKey, createBody)
            }
            Log.i(TAG, "Upload session ready id=${id.take(8)}")
            setForeground(foreground(job, 0))
            val uploadId = createResponse.getString("uploadId")
            val encodedUploadId = URLEncoder.encode(uploadId, Charsets.UTF_8.name())
            var offset = resolveInitialUploadOffset(
                createResponse.optLong("offset", 0L),
                file.length(),
            )
            val chunkSize = createResponse.optInt("chunkSize", DEFAULT_CHUNK_SIZE)
                .coerceIn(256 * 1024, 8 * 1024 * 1024)

            var offsetResyncAttempts = 0
            RandomAccessFile(file, "r").use { input ->
                while (offset < file.length()) {
                    if (isStopped) {
                        Log.i(TAG, "Backup paused by stop id=${id.take(8)}")
                        clearBackupNotification(job)
                        return pause(
                            job,
                            generation,
                            "备份已暂停",
                            LanBackupFailureKind.OFFLINE_OR_TIMEOUT,
                            autoRetry = true,
                        )
                    }
                    val size = min(chunkSize.toLong(), file.length() - offset).toInt()
                    val bytes = ByteArray(size)
                    requireAvailable(job)
                    try {
                        input.seek(offset)
                        input.readFully(bytes)
                    } catch (error: EOFException) {
                        throw BackupSourceUnavailableException("录像文件读取不完整", error)
                    } catch (error: IOException) {
                        throw BackupSourceUnavailableException("无法读取录像文件", error)
                    }
                    requireAvailable(job)
                    val nextOffset = try {
                        try {
                            putChunk(
                                "$baseUrl/api/mobile-backup/uploads/$encodedUploadId/chunks",
                                accessKey,
                                bytes,
                                offset,
                                file.length(),
                            )
                        } catch (error: IOException) {
                            baseUrl = resolveChangedBaseUrl(baseUrl, connection) ?: throw error
                            putChunk(
                                "$baseUrl/api/mobile-backup/uploads/$encodedUploadId/chunks",
                                accessKey,
                                bytes,
                                offset,
                                file.length(),
                            )
                        }
                    } catch (error: BackupHttpException) {
                        if (error.statusCode != 409 || error.errorCode != "offset_mismatch") throw error
                        val expected = error.expectedOffset
                            ?.takeIf { it in 0L..file.length() }
                            ?: throw error
                        offsetResyncAttempts++
                        if (offsetResyncAttempts > 3) {
                            throw IOException("上传进度多次不同步，请重新备份")
                        }
                        Log.i(TAG, "Upload offset resynced id=${id.take(8)} from=$offset to=$expected")
                        offset = expected
                        job.put("uploadedBytes", offset)
                        if (!updateUploadedBytes(job, generation, offset)) {
                            clearBackupNotification(job)
                            return Result.success()
                        }
                        continue
                    }
                    if (nextOffset <= offset || nextOffset > file.length()) {
                        throw IOException("电脑返回的上传进度无效，请重新备份")
                    }
                    offsetResyncAttempts = 0
                    offset = nextOffset
                    Log.d(TAG, "Chunk accepted id=${id.take(8)} offset=$offset total=${file.length()}")
                    job.put("uploadedBytes", offset)
                    if (!updateUploadedBytes(job, generation, offset)) {
                        clearBackupNotification(job)
                        return Result.success()
                    }
                    setForeground(foreground(job, ((offset * 100) / file.length()).toInt()))
                }
            }
            requireAvailable(job)
            val completionBody = JSONObject()
                .put("fileSha256", sha256)
                .put("sourceDeviceId", store.deviceId())
                .put("sourceDeviceName", store.deviceName())
                .put("sessions", completionSessions(job.getJSONArray("sessions")))
            val completion = try {
                postJson(
                    "$baseUrl/api/mobile-backup/uploads/$encodedUploadId/complete",
                    accessKey,
                    completionBody,
                )
            } catch (error: IOException) {
                baseUrl = resolveChangedBaseUrl(baseUrl, connection) ?: throw error
                postJson(
                    "$baseUrl/api/mobile-backup/uploads/$encodedUploadId/complete",
                    accessKey,
                    completionBody,
                )
            }
            val recordIds = completion.optJSONArray("recordIds") ?: JSONArray()
            if (completion.optString("status") != "verified" ||
                completion.optString("fileSha256") != sha256 ||
                recordIds.length() == 0
            ) {
                return fail(
                    job,
                    generation,
                    "电脑未确认录像校验结果",
                    LanBackupFailureKind.VERIFICATION_FAILED,
                )
            }
            val firstSessionId = job.getJSONArray("sessions").getJSONObject(0).getString("id")
            val firstRecordId = recordIds.getLong(0)
            val signedVerification = BackupRequestAuthentication.verifyReceipt(
                response = completion,
                credential = storedCredential,
                hostNodeId = connection.optString("computerId"),
                sourceDeviceId = store.deviceId(),
                sourceSessionId = firstSessionId,
                fileSha256 = sha256,
                fileSizeBytes = file.length(),
                recordId = firstRecordId,
            )
            complete(
                job,
                generation,
                file.length(),
                recordIds,
                sha256,
                if (signedVerification) BackupRequestAuthentication.VERSION else 0,
                completion.optString("receiptSignature"),
            )
        } catch (error: BackupSourceUnavailableException) {
            Log.w(TAG, "Backup source unavailable id=${id.take(8)}", error)
            val status = sourceStatus(job).takeIf {
                it != LanBackupSourceStatus.AVAILABLE
            } ?: LanBackupSourceStatus.UNREADABLE
            discard(job, generation, status)
        } catch (error: BackupHttpException) {
            Log.w(TAG, "Backup HTTP failure id=${id.take(8)} status=${error.statusCode}", error)
            val failureKind = if (
                error.statusCode == 404 && isPackingProofNodeWithoutBackup(baseUrl)
            ) {
                LanBackupFailureKind.NOT_BACKUP_HOST
            } else {
                LanBackupFailurePolicy.classifyHttp(error.statusCode, error.errorCode)
            }
            if (failureKind in setOf(
                    LanBackupFailureKind.CREDENTIAL_INVALID,
                    LanBackupFailureKind.UPLOAD_EXPIRED,
                    LanBackupFailureKind.VERIFICATION_FAILED,
                    LanBackupFailureKind.NOT_BACKUP_HOST,
                    LanBackupFailureKind.INCOMPATIBLE_VERSION,
                )
            ) {
                fail(
                    job,
                    generation,
                    if (failureKind == LanBackupFailureKind.NOT_BACKUP_HOST) {
                        "连接的电脑当前不是录像备份主机，请切换电脑用途或重新搜索"
                    } else {
                        friendlyError(error)
                    },
                    failureKind,
                )
            } else {
                pause(
                    job,
                    generation,
                    friendlyError(error),
                    failureKind,
                    autoRetry = LanBackupFailurePolicy.shouldAutoRetry(failureKind),
                )
            }
        } catch (error: IOException) {
            Log.w(TAG, "Backup network failure id=${id.take(8)}", error)
            pause(
                job,
                generation,
                "电脑离线或连接超时，备份已暂停",
                LanBackupFailureKind.OFFLINE_OR_TIMEOUT,
                autoRetry = true,
            )
        } catch (error: Throwable) {
            Log.e(TAG, "Backup failed id=${id.take(8)}", error)
            fail(
                job,
                generation,
                error.message ?: "备份失败",
                LanBackupFailureKind.UNKNOWN,
            )
        }
    }

    private fun complete(
        job: JSONObject,
        generation: String,
        total: Long,
        recordIds: JSONArray,
        contentSha256: String,
        verificationVersion: Int,
        verificationReceipt: String,
    ): Result {
        val current = store.updateJob(job.getString("id"), generation) { value ->
            value.put("state", "completed")
                .put("uploadedBytes", total)
                .put("backupCompletedAt", java.time.Instant.now().toString())
                .put("contentSha256", contentSha256)
                .put("remoteRecordIds", recordIds)
                .put("verificationVersion", verificationVersion)
                .put("verificationReceipt", verificationReceipt.takeIf { verificationVersion > 0 } ?: JSONObject.NULL)
                .put("lastAttestedAt", if (verificationVersion > 0) java.time.Instant.now().toString() else JSONObject.NULL)
                .put("errorMessage", JSONObject.NULL)
                .put("failureKind", JSONObject.NULL)
            true
        }
        clearBackupNotification(job)
        Log.i(
            TAG,
            "Backup completed id=${job.getString("id").take(8)} " +
                "bytes=$total records=${recordIds.length()}",
        )
        if (current != null) {
            LanBackupCleanupScheduler.reschedule(applicationContext, store, current)
        }
        return Result.success()
    }

    private fun completionSessions(sessions: JSONArray): JSONArray {
        val result = JSONArray()
        for (index in 0 until sessions.length()) {
            val source = sessions.getJSONObject(index)
            val duration = (source.optLong("mediaEndMs") - source.optLong("mediaStartMs"))
                .takeIf { it > 0 }
                ?: runCatching {
                    java.time.Duration.between(
                        java.time.Instant.parse(source.getString("startedAt")),
                        java.time.Instant.parse(source.getString("endedAt")),
                    ).toMillis()
                }.getOrDefault(1L)
            val completed = JSONObject()
                    .put("sessionId", source.getString("id"))
                    .put("trackingNumber", source.optString("trackingNumber"))
                    .put("startedAt", source.getString("startedAt"))
                    .put("durationMilliseconds", duration.coerceAtLeast(1L))
                    .put("mode", source.optString("mode", "shipping"))
            source.optJSONObject("orderInfo")?.let { completed.put("orderInfo", it) }
            result.put(completed)
        }
        return result
    }

    private fun fail(
        job: JSONObject,
        generation: String,
        message: String,
        failureKind: LanBackupFailureKind,
    ): Result {
        store.updateJob(job.getString("id"), generation) { value ->
            value.put("state", "failed")
                .put("errorMessage", message)
                .put("failureKind", failureKind.wireValue)
            true
        }
        clearBackupNotification(job)
        return Result.failure()
    }

    private fun discard(
        job: JSONObject,
        generation: String,
        status: LanBackupSourceStatus,
    ): Result {
        if (store.deleteJob(job.getString("id"), generation)) {
            Log.w(
                TAG,
                "Discard unavailable backup job " +
                    "id=${job.getString("id").take(8)} " +
                    "path=${job.optString("filePath")} reason=${status.reason}",
            )
        }
        clearBackupNotification(job)
        return Result.success()
    }

    private fun sourceStatus(job: JSONObject): LanBackupSourceStatus =
        LanBackupSourcePolicy.inspect(
            file = File(job.optString("filePath")),
            expectedBytes = job.optLong("totalBytes", -1L),
            expectedLastModified = job.optLong("lastModified", -1L),
        )

    private fun requireAvailable(job: JSONObject) {
        val status = sourceStatus(job)
        if (status != LanBackupSourceStatus.AVAILABLE) {
            throw BackupSourceUnavailableException(status.reason)
        }
    }

    private fun pause(
        job: JSONObject,
        generation: String,
        message: String,
        failureKind: LanBackupFailureKind,
        autoRetry: Boolean = false,
    ): Result {
        store.updateJob(job.getString("id"), generation) { value ->
            value.put("state", "paused")
                .put("errorMessage", message)
                .put("failureKind", failureKind.wireValue)
            true
        }
        clearBackupNotification(job)
        return if (autoRetry) Result.retry() else Result.success()
    }

    private fun updateUploadedBytes(
        job: JSONObject,
        generation: String,
        uploadedBytes: Long,
    ): Boolean = store.updateJob(job.getString("id"), generation) { value ->
        value.put("uploadedBytes", uploadedBytes)
        true
    } != null

    private fun clearBackupNotification(job: JSONObject) {
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(notificationId(job))
    }

    private suspend fun resolveChangedBaseUrl(
        failedBaseUrl: String,
        connection: JSONObject,
    ): String? {
        val computerId = connection.optString("computerId").trim()
        if (computerId.isEmpty()) return null
        val resolved = hostResolver.resolve(failedBaseUrl, computerId)?.trimEnd('/') ?: return null
        if (resolved.equals(failedBaseUrl.trimEnd('/'), ignoreCase = true)) return null
        store.saveConnection(
            baseUrl = resolved,
            computerId = computerId,
            computerName = connection.optString("computerName", "已连接电脑"),
            deviceName = store.deviceName(),
        )
        connection.put("baseUrl", resolved)
        Log.i(TAG, "Backup host address updated id=${computerId.take(8)} address=${URL(resolved).authority}")
        return resolved
    }

    private fun postJson(url: String, key: String, body: JSONObject): JSONObject {
        val bytes = body.toString().toByteArray(Charsets.UTF_8)
        val connection = open(url, "POST", key, bytes)
        connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
        connection.doOutput = true
        connection.outputStream.use { it.write(bytes) }
        return readJson(connection)
    }

    private fun putChunk(
        url: String,
        key: String,
        bytes: ByteArray,
        offset: Long,
        total: Long,
    ): Long {
        val connection = open(url, "PUT", key, bytes)
        connection.setRequestProperty("Content-Type", "application/octet-stream")
        connection.setRequestProperty("Content-Range", "bytes $offset-${offset + bytes.size - 1}/$total")
        connection.setRequestProperty("X-Chunk-SHA256", bytes.sha256())
        connection.setFixedLengthStreamingMode(bytes.size)
        connection.doOutput = true
        connection.outputStream.use { it.write(bytes) }
        return readJson(connection).getLong("offset")
    }

    private fun open(url: String, method: String, key: String, body: ByteArray): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 10_000
            readTimeout = 30_000
            useCaches = false
            instanceFollowRedirects = false
            BackupRequestAuthentication.apply(
                this,
                url,
                method,
                BackupRequestAuthentication.parse(key),
                store.deviceId(),
                body,
            )
        }

    private fun readJson(connection: HttpURLConnection): JSONObject {
        val status = connection.responseCode
        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
        val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
        if (status !in 200..299) {
            val payload = runCatching { JSONObject(body) }.getOrNull()
            throw BackupHttpException(
                statusCode = status,
                errorCode = payload?.optString("errorCode").orEmpty(),
                expectedOffset = payload
                    ?.takeIf { it.has("expectedOffset") }
                    ?.optLong("expectedOffset"),
                message = payload?.optString("error")?.takeIf { it.isNotBlank() }
                    ?: body.takeIf { it.isNotBlank() }
                    ?: "HTTP $status",
            )
        }
        return if (body.isBlank()) JSONObject() else JSONObject(body)
    }

    private fun friendlyError(error: BackupHttpException): String = when (error.errorCode) {
        "offset_mismatch" -> "上传进度不同步，请重试"
        "sha256_mismatch" -> "录像校验失败，请重试"
        "upload_not_found" -> "电脑上的续传任务已失效，请重新备份"
        "storage_unavailable" -> "电脑存储暂不可用"
        "invalid_content_range", "invalid_request", "invalid_json" -> "备份数据格式异常，请更新应用后重试"
        "mobile_backup_failed" -> "电脑处理备份失败，请稍后重试"
        else -> when (error.statusCode) {
            401, 403 -> "设备连接已失效，请重新申请并在电脑上允许连接"
            404 -> "电脑端暂不支持此备份任务"
            in 500..599 -> "电脑暂时无法处理备份"
            else -> "备份失败，请稍后重试"
        }
    }

    private fun isPackingProofNodeWithoutBackup(baseUrl: String): Boolean {
        val connection = (URL("$baseUrl/api/node-info").openConnection() as HttpURLConnection)
        return try {
            connection.requestMethod = "GET"
            connection.connectTimeout = 1500
            connection.readTimeout = 1500
            if (connection.responseCode != 200) return false
            val payload = connection.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                JSONObject(reader.readText())
            }
            if (payload.optString("protocol") != "packingproof") return false
            val capabilities = payload.optJSONArray("capabilities") ?: return false
            (0 until capabilities.length()).none { index ->
                capabilities.optString(index).equals("mobile-backup", ignoreCase = true)
            }
        } catch (_: Throwable) {
            false
        } finally {
            connection.disconnect()
        }
    }

    private fun foreground(job: JSONObject, progress: Int): ForegroundInfo {
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "录像备份", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(applicationContext.applicationInfo.icon)
            .setContentTitle("正在备份录像")
            .setContentText(job.optString("fileName"))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, progress.coerceIn(0, 100), false)
            .build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(
                notificationId(job),
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            ForegroundInfo(notificationId(job), notification)
        }
    }

    private fun notificationId(job: JSONObject): Int =
        job.getString("id").take(8).hashCode()
}

/** 上传续传起点只以主机 create 响应为准，job.uploadedBytes 仅用于展示。 */
internal fun resolveInitialUploadOffset(hostOffset: Long, fileLength: Long): Long =
    hostOffset.coerceIn(0L, fileLength)

private class BackupHttpException(
    val statusCode: Int,
    val errorCode: String = "",
    val expectedOffset: Long? = null,
    message: String,
) : IOException(message)

private class BackupSourceUnavailableException(
    message: String,
    cause: Throwable? = null,
) : IOException(message, cause)

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

private fun ByteArray.sha256(): String = MessageDigest.getInstance("SHA-256")
    .digest(this)
    .joinToString("") { "%02x".format(it) }

private fun File.videoCodec(): String {
    val extractor = MediaExtractor()
    return try {
        extractor.setDataSource(path)
        for (index in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(index)
                .getString(android.media.MediaFormat.KEY_MIME)
                .orEmpty()
            if (mime.startsWith("video/")) {
                return if (mime == "video/hevc") "h265" else "h264"
            }
        }
        "h265"
    } finally {
        extractor.release()
    }
}
