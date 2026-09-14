package app.packingproof.mobile

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class BackupRequestAuthenticationTest {
    private val credentialValue = "authentication-test-credential"
    private val credential = BackupRequestAuthentication.parse(credentialValue)

    @Test
    fun persistedReceiptCanBeReverifiedAfterNetworkFreshnessWindow() {
        val receipt = signedReceipt(Instant.now().minusSeconds(86_400).epochSecond)

        assertFalse(verifyNetwork(receipt))
        assertTrue(verifyPersisted(receipt))
    }

    @Test
    fun persistedReceiptRejectsForgedSignatureAndBoundFieldChanges() {
        val receipt = signedReceipt(Instant.now().epochSecond)
        assertFalse(
            verifyPersisted(
                JSONObject(receipt.toString()).put("receiptSignature", "f".repeat(64)),
            ),
        )
        listOf(
            "hostNodeId" to "other-host",
            "sourceDeviceId" to "other-device",
            "sourceSessionId" to "other-session",
            "fileSha256" to "c".repeat(64),
            "fileSizeBytes" to 124L,
            "recordId" to 43L,
        ).forEach { (field, value) ->
            assertFalse(field, verifyPersisted(JSONObject(receipt.toString()).put(field, value)))
        }
    }

    @Test
    fun signatureHeadersAnnounceAndroidPlatformSoHostCanAssignNickname() {
        val url = "http://192.168.1.20:5280/api/mobile-backup/capabilities"
        val connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection

        BackupRequestAuthentication.apply(
            connection,
            url,
            "GET",
            credential,
            "device-1",
            ByteArray(0),
        )

        // 主机按 X-EPM-Device-Platform 分配"安卓N"，缺了它只能落到"从机N"。
        assertEquals("android", connection.getRequestProperty("X-EPM-Device-Platform"))
        assertEquals("mobile", connection.getRequestProperty("X-EPM-Device-Kind"))
    }

    private fun verifyNetwork(receipt: JSONObject) = BackupRequestAuthentication.verifyReceipt(
        receipt,
        credential,
        "host-1",
        "device-1",
        "session-1",
        "a".repeat(64),
        123L,
        42L,
    )

    private fun verifyPersisted(receipt: JSONObject) =
        BackupRequestAuthentication.verifyPersistedReceipt(
            receipt,
            credential,
            "host-1",
            "device-1",
            "session-1",
            "a".repeat(64),
            123L,
            42L,
        )

    private fun signedReceipt(verifiedAt: Long): JSONObject {
        val canonical = listOf(
            "packingproof-verified-receipt-v3",
            "host-1",
            "device-1",
            "session-1",
            "a".repeat(64),
            "123",
            "42",
            verifiedAt.toString(),
        ).joinToString("\n")
        val mac = Mac.getInstance("HmacSHA256").apply {
            init(SecretKeySpec(credentialValue.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        }
        val signature = mac.doFinal(canonical.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return JSONObject()
            .put("authVersion", BackupRequestAuthentication.VERSION)
            .put("verifiedAtUnixSeconds", verifiedAt)
            .put("hostNodeId", "host-1")
            .put("sourceDeviceId", "device-1")
            .put("sourceSessionId", "session-1")
            .put("fileSha256", "a".repeat(64))
            .put("fileSizeBytes", 123L)
            .put("recordId", 42L)
            .put("receiptSignature", signature)
    }
}
