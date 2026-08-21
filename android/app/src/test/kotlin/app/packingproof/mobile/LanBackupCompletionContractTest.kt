package app.packingproof.mobile

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class LanBackupCompletionContractTest {
    @Test
    fun canonicalRequestKeepsExactlyOneDocumentedSession() {
        val source = JSONObject()
            .put("id", "session-1")
            .put("trackingNumber", "TRACK-1")
            .put("startedAt", "2026-08-21T01:00:00Z")
            .put("endedAt", "2026-08-21T01:00:05Z")
            .put("mediaStartMs", 0L)
            .put("mediaEndMs", 5_000L)
            .put("mode", "return")
            .put("markers", JSONArray())
            .put("orderInfo", JSONObject().put("buyerMessage", "private"))

        val result = canonicalCompletionSessions(JSONArray().put(source))

        assertEquals(1, result.length())
        assertEquals("session-1", result.getJSONObject(0).getString("id"))
        assertEquals(5_000L, result.getJSONObject(0).getLong("mediaEndMs"))
        assertEquals("return", result.getJSONObject(0).getString("mode"))
        assertFalse(result.getJSONObject(0).has("sessionId"))
        assertFalse(result.getJSONObject(0).has("durationMilliseconds"))
        assertFalse(result.getJSONObject(0).has("orderInfo"))
    }

    @Test
    fun canonicalRequestRejectsZeroOrMultipleSessions() {
        assertThrows(IllegalArgumentException::class.java) {
            canonicalCompletionSessions(JSONArray())
        }
        val session = JSONObject()
            .put("id", "session-1")
            .put("startedAt", "2026-08-21T01:00:00Z")
            .put("endedAt", "2026-08-21T01:00:05Z")
            .put("mediaStartMs", 0L)
            .put("mediaEndMs", 5_000L)
        assertThrows(IllegalArgumentException::class.java) {
            canonicalCompletionSessions(JSONArray().put(session).put(session))
        }
    }

    @Test
    fun verifiedResponseAcceptsOnlySingularRecordId() {
        val sha256 = "a".repeat(64)
        val valid = JSONObject()
            .put("status", "verified")
            .put("fileSha256", sha256)
            .put("recordId", 42L)
        assertEquals(42L, verifiedCompletionRecordId(valid, sha256))

        val legacy = JSONObject(valid.toString()).put("recordIds", JSONArray().put(42L))
        assertNull(verifiedCompletionRecordId(legacy, sha256))
        assertNull(verifiedCompletionRecordId(JSONObject(valid.toString()).remove("recordId"), sha256))
    }
}
