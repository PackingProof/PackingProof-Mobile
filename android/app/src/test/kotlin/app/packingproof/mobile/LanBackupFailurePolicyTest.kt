package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LanBackupFailurePolicyTest {
    @Test
    fun `credential failures always require a new scan`() {
        assertEquals(
            LanBackupFailureKind.CREDENTIAL_INVALID,
            LanBackupFailurePolicy.classifyHttp(401, ""),
        )
        assertEquals(
            LanBackupFailureKind.CREDENTIAL_INVALID,
            LanBackupFailurePolicy.classifyHttp(403, "mobile_backup_failed"),
        )
    }

    @Test
    fun `server failures are classified for one matching recovery action`() {
        val cases = mapOf(
            Pair(404, "upload_not_found") to LanBackupFailureKind.UPLOAD_EXPIRED,
            Pair(409, "sha256_mismatch") to LanBackupFailureKind.VERIFICATION_FAILED,
            Pair(503, "storage_unavailable") to LanBackupFailureKind.STORAGE_UNAVAILABLE,
            Pair(400, "invalid_json") to LanBackupFailureKind.INCOMPATIBLE_VERSION,
            Pair(404, "") to LanBackupFailureKind.INCOMPATIBLE_VERSION,
            Pair(503, "mobile_backup_failed") to LanBackupFailureKind.TEMPORARY_SERVICE,
            Pair(418, "") to LanBackupFailureKind.UNKNOWN,
        )

        cases.forEach { (input, expected) ->
            assertEquals(expected, LanBackupFailurePolicy.classifyHttp(input.first, input.second))
        }
    }

    @Test
    fun `shared classification table matches ios`() {
        val shared = mapOf(
            Pair(401, "") to LanBackupFailureKind.CREDENTIAL_INVALID,
            Pair(400, "device_token_invalid") to LanBackupFailureKind.CREDENTIAL_INVALID,
            Pair(404, "") to LanBackupFailureKind.INCOMPATIBLE_VERSION,
            Pair(400, "backup_protocol_upgrade_required") to LanBackupFailureKind.INCOMPATIBLE_VERSION,
            Pair(426, "") to LanBackupFailureKind.INCOMPATIBLE_VERSION,
            Pair(408, "") to LanBackupFailureKind.OFFLINE_OR_TIMEOUT,
            Pair(409, "") to LanBackupFailureKind.TEMPORARY_SERVICE,
            Pair(400, "offset_mismatch") to LanBackupFailureKind.TEMPORARY_SERVICE,
            Pair(425, "") to LanBackupFailureKind.TEMPORARY_SERVICE,
            Pair(429, "") to LanBackupFailureKind.TEMPORARY_SERVICE,
            Pair(422, "") to LanBackupFailureKind.VERIFICATION_FAILED,
            Pair(503, "") to LanBackupFailureKind.TEMPORARY_SERVICE,
        )

        shared.forEach { (input, expected) ->
            assertEquals(expected, LanBackupFailurePolicy.classifyHttp(input.first, input.second))
        }
    }

    @Test
    fun `only transient backup failures are automatically retried`() {
        assertTrue(LanBackupFailurePolicy.shouldAutoRetry(LanBackupFailureKind.OFFLINE_OR_TIMEOUT))
        assertTrue(LanBackupFailurePolicy.shouldAutoRetry(LanBackupFailureKind.TEMPORARY_SERVICE))
        assertTrue(LanBackupFailurePolicy.shouldAutoRetry(LanBackupFailureKind.STORAGE_UNAVAILABLE))

        val permanentFailures = listOf(
            LanBackupFailureKind.CREDENTIAL_INVALID,
            LanBackupFailureKind.UPLOAD_EXPIRED,
            LanBackupFailureKind.VERIFICATION_FAILED,
            LanBackupFailureKind.NOT_BACKUP_HOST,
            LanBackupFailureKind.INCOMPATIBLE_VERSION,
            LanBackupFailureKind.UNKNOWN,
        )
        permanentFailures.forEach { failureKind ->
            assertFalse(LanBackupFailurePolicy.shouldAutoRetry(failureKind))
        }
    }
}
