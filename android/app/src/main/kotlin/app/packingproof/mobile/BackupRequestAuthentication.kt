package app.packingproof.mobile

import java.net.URL
import java.net.HttpURLConnection
import java.security.MessageDigest
import java.time.Instant
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal data class StoredBackupCredential(
    val backupCredential: String,
    val version: Int,
)

internal object BackupRequestAuthentication {
    const val VERSION = 3

    fun parse(value: String): StoredBackupCredential =
        StoredBackupCredential(value.trim(), VERSION)

    fun apply(
        connection: java.net.HttpURLConnection,
        url: String,
        method: String,
        credential: StoredBackupCredential,
        deviceId: String,
        body: ByteArray,
    ) {
        val timestamp = Instant.now().epochSecond
        val nonce = java.security.SecureRandom().generateSeed(16).hex()
        val contentHash = body.sha256Hex()
        val path = URL(url).path.ifBlank { "/" }
        val canonical = listOf(
            method.uppercase(Locale.ROOT),
            path,
            timestamp.toString(),
            nonce,
            contentHash,
            deviceId.trim().lowercase(Locale.ROOT),
        ).joinToString("\n")
        val signature = hmac(credential.backupCredential, canonical)
        connection.setRequestProperty("X-EPM-Auth-Version", VERSION.toString())
        connection.setRequestProperty("X-EPM-Timestamp", timestamp.toString())
        connection.setRequestProperty("X-EPM-Nonce", nonce)
        connection.setRequestProperty("X-EPM-Content-SHA256", contentHash)
        connection.setRequestProperty("X-EPM-Signature", signature)
        connection.setRequestProperty("X-EPM-Device-Id", deviceId)
        connection.setRequestProperty("X-EPM-Device-Kind", "mobile")
        // 主机按平台分配"安卓N/苹果N"昵称，缺了这个头只能落到"从机N"。
        connection.setRequestProperty("X-EPM-Device-Platform", "android")
    }

    fun verifyReceipt(
        response: org.json.JSONObject,
        credential: StoredBackupCredential,
        hostNodeId: String,
        sourceDeviceId: String,
        sourceSessionId: String,
        fileSha256: String,
        fileSizeBytes: Long,
        recordId: Long,
    ): Boolean {
        val verifiedAt = response.optLong("verifiedAtUnixSeconds")
        if (kotlin.math.abs(Instant.now().epochSecond - verifiedAt) > 300) return false
        return verifyPersistedReceipt(
            response,
            credential,
            hostNodeId,
            sourceDeviceId,
            sourceSessionId,
            fileSha256,
            fileSizeBytes,
            recordId,
        )
    }

    /**
     * 持久化回执可在后续远端 attestation 刷新后继续使用，因此不重复限制签发时间；
     * 调用方必须另外要求 lastAttestedAt 新鲜。网络刚收到的回执仍使用 [verifyReceipt]。
     */
    fun verifyPersistedReceipt(
        response: org.json.JSONObject,
        credential: StoredBackupCredential,
        hostNodeId: String,
        sourceDeviceId: String,
        sourceSessionId: String,
        fileSha256: String,
        fileSizeBytes: Long,
        recordId: Long,
    ): Boolean {
        if (credential.version < VERSION || response.optInt("authVersion") != VERSION) return false
        val verifiedAt = response.optLong("verifiedAtUnixSeconds").takeIf { it > 0 } ?: return false
        if (!response.optString("hostNodeId").equals(hostNodeId, ignoreCase = true) ||
            !response.optString("sourceDeviceId").equals(sourceDeviceId, ignoreCase = true) ||
            response.optString("sourceSessionId") != sourceSessionId ||
            !response.optString("fileSha256").equals(fileSha256, ignoreCase = true) ||
            response.optLong("fileSizeBytes") != fileSizeBytes ||
            response.optLong("recordId") != recordId
        ) return false
        val canonical = listOf(
            "packingproof-verified-receipt-v3",
            hostNodeId.trim().lowercase(Locale.ROOT),
            sourceDeviceId.trim().lowercase(Locale.ROOT),
            sourceSessionId.trim(),
            fileSha256.trim().lowercase(Locale.ROOT),
            fileSizeBytes.toString(),
            recordId.toString(),
            verifiedAt.toString(),
        ).joinToString("\n")
        val expected = hmac(credential.backupCredential, canonical)
        return constantTimeEquals(expected, response.optString("receiptSignature"))
    }

    private fun hmac(secret: String, value: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret.hexOrUtf8(), "HmacSHA256"))
        return mac.doFinal(value.toByteArray(Charsets.UTF_8)).hex()
    }

    private fun constantTimeEquals(left: String, right: String): Boolean = runCatching {
        MessageDigest.isEqual(left.hexOrUtf8(), right.hexOrUtf8())
    }.getOrDefault(false)

    private fun String.hexOrUtf8(): ByteArray = if (length >= 32 && length % 2 == 0) {
        runCatching { chunked(2).map { it.toInt(16).toByte() }.toByteArray() }
            .getOrElse { toByteArray(Charsets.UTF_8) }
    } else {
        toByteArray(Charsets.UTF_8)
    }

    private fun ByteArray.sha256Hex(): String = MessageDigest.getInstance("SHA-256").digest(this).hex()
    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }
}
