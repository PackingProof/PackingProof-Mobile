package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingStoragePolicyTest {
    private val policy = BackupStoragePolicy.FALLBACK

    @Test
    fun fixedWatermarksAreAppliedAtExactBoundaries() {
        assertTrue(RecordingStoragePolicy.needsWarning(policy.warningBytes - 1, policy))
        assertFalse(RecordingStoragePolicy.needsWarning(policy.warningBytes, policy))
        assertTrue(RecordingStoragePolicy.needsReclaim(policy.minimumBytes - 1, policy))
        assertFalse(RecordingStoragePolicy.needsReclaim(policy.minimumBytes, policy))
    }

    @Test
    fun onlyVerifiedBackupsAreEligibleAndOldestComesFirst() {
        val old = verified("old", "2026-07-01T00:00:00Z")
        val recent = verified("recent", "2026-07-20T00:00:00Z")
        val unbacked = verified("unbacked", "2026-06-01T00:00:00Z")
            .copy(backupCompletedAt = null)
        val uploading = verified("uploading", "2026-06-02T00:00:00Z")
            .copy(state = "uploading")
        val unverified = verified("unverified", "2026-06-03T00:00:00Z")
            .copy(contentSha256 = null)
        val deleted = verified("deleted", "2026-06-04T00:00:00Z")
            .copy(localDeletedAt = "2026-07-21T00:00:00Z")
        val legacyUnsigned = verified("legacy", "2026-06-05T00:00:00Z")
            .copy(verificationVersion = 0)
        val missingReceipt = verified("missing-receipt", "2026-06-06T00:00:00Z")
            .copy(verificationReceipt = null)
        val multipleSessions = verified("multiple-sessions", "2026-06-07T00:00:00Z")
            .copy(sessionIds = listOf("one", "two"))

        val candidates = RecordingStoragePolicy.verifiedCandidates(
            listOf(
                recent,
                unbacked,
                uploading,
                old,
                unverified,
                deleted,
                legacyUnsigned,
                missingReceipt,
                multipleSessions,
            ),
            policy,
        )

        assertEquals(listOf("old", "recent"), candidates.map { it.id })
    }

    private fun verified(id: String, createdAt: String) = RecordingStorageCandidate(
        id = id,
        generation = "generation-$id",
        filePath = "/data/user/0/app.packingproof.mobile/$id.mp4",
        destinationComputerId = "host-1",
        state = "completed",
        fileCreatedAt = createdAt,
        backupCompletedAt = "2026-07-22T00:00:00Z",
        contentSha256 = "a".repeat(64),
        verificationVersion = BackupRequestAuthentication.VERSION,
        verificationReceipt = RecordingStorageReceipt(
            authVersion = BackupRequestAuthentication.VERSION,
            verifiedAtUnixSeconds = 1L,
            hostNodeId = "host-1",
            sourceDeviceId = "device-1",
            sourceSessionId = "session-$id",
            fileSha256 = "a".repeat(64),
            fileSizeBytes = 1024L,
            recordId = 1L,
            receiptSignature = "b".repeat(64),
        ),
        remoteRecordId = 1L,
        sessionIds = listOf("session-$id"),
        totalBytes = 1024L,
        lastModified = 1L,
        lastAttestedAt = java.time.Instant.now().toString(),
        localDeletedAt = null,
    )
}
