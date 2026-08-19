package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject
import java.time.Instant
import java.nio.file.Files
import java.security.MessageDigest

class LanBackupCleanupSchedulerTest {
    @Test
    fun jsonNullIsNotTreatedAsDeletedTimestamp() {
        assertNull(LanBackupCleanupScheduler.normalizeNullableText(null))
        assertNull(LanBackupCleanupScheduler.normalizeNullableText("null"))
    }

    @Test
    fun realTimestampRemainsAvailable() {
        val value = "2026-07-20T03:21:56Z"
        assertEquals(value, LanBackupCleanupScheduler.normalizeNullableText(value))
    }

    @Test
    fun pendingAndUploadingJobsAreNeverCleanedWhileBackupCanOwnTheFile() {
        assertTrue(LanBackupCleanupScheduler.shouldDeferForBackupState("pending"))
        assertTrue(LanBackupCleanupScheduler.shouldDeferForBackupState("uploading"))
        assertFalse(LanBackupCleanupScheduler.shouldDeferForBackupState("paused"))
    }

    @Test
    fun rescheduleIsSkippedWhenDueAtAlreadyScheduled() {
        val dueAt = Instant.parse("2026-08-20T03:00:00Z")
        val job = JSONObject().put("scheduledCleanupAt", dueAt.toString())
        assertTrue(LanBackupCleanupScheduler.shouldSkipReschedule(job, dueAt))
    }

    @Test
    fun rescheduleIsNeededWhenDueAtChangedOrNotScheduled() {
        val dueAt = Instant.parse("2026-08-20T03:00:00Z")
        assertFalse(
            LanBackupCleanupScheduler.shouldSkipReschedule(
                JSONObject().put("scheduledCleanupAt", "2026-08-19T03:00:00Z"),
                dueAt,
            ),
        )
        assertFalse(
            LanBackupCleanupScheduler.shouldSkipReschedule(
                JSONObject().put("scheduledCleanupAt", org.json.JSONObject.NULL),
                dueAt,
            ),
        )
    }

    @Test
    fun staleCleanupPreservesReplacementPublishedByAnotherTask() {
        val root = Files.createTempDirectory("packing-proof-cleanup-race").toFile()
        try {
            val target = root.resolve("recording.mp4")
            target.writeText("old-a", Charsets.UTF_8)
            val expectedBytes = target.length()
            val expectedModified = target.lastModified()
            val expectedSha256 = sha256("old-a")

            target.writeText("new-b", Charsets.UTF_8)
            assertTrue(target.setLastModified(expectedModified))

            val result = LanBackupFileCleanup.deleteExpected(
                file = target,
                expectedBytes = expectedBytes,
                expectedLastModified = expectedModified,
                expectedSha256 = expectedSha256,
            )

            assertEquals(LanBackupFileCleanupResult.stale, result)
            assertTrue(target.exists())
            assertEquals("new-b", target.readText(Charsets.UTF_8))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun matchingFileIsRemovedOnlyAfterItIsClaimed() {
        val root = Files.createTempDirectory("packing-proof-cleanup-match").toFile()
        try {
            val target = root.resolve("recording.mp4")
            target.writeText("verified", Charsets.UTF_8)

            val result = LanBackupFileCleanup.deleteExpected(
                file = target,
                expectedBytes = target.length(),
                expectedLastModified = target.lastModified(),
                expectedSha256 = sha256("verified"),
            )

            assertEquals(LanBackupFileCleanupResult.deleted, result)
            assertFalse(target.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun interruptedClaimIsRecoveredBeforeCleanupContinues() {
        val root = Files.createTempDirectory("packing-proof-cleanup-recovery").toFile()
        try {
            val target = root.resolve("recording.mp4")
            val claim = root.resolve(".recording.mp4.cleanup-interrupted.pending")
            claim.writeText("verified", Charsets.UTF_8)

            val result = LanBackupFileCleanup.deleteExpected(
                file = target,
                expectedBytes = claim.length(),
                expectedLastModified = claim.lastModified(),
                expectedSha256 = sha256("verified"),
            )

            assertEquals(LanBackupFileCleanupResult.deleted, result)
            assertFalse(target.exists())
            assertFalse(claim.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun interruptedStaleClaimIsRestoredInsteadOfDeleted() {
        val root = Files.createTempDirectory("packing-proof-cleanup-stale-recovery").toFile()
        try {
            val target = root.resolve("recording.mp4")
            val claim = root.resolve(".recording.mp4.cleanup-interrupted.pending")
            claim.writeText("replacement", Charsets.UTF_8)

            val result = LanBackupFileCleanup.deleteExpected(
                file = target,
                expectedBytes = claim.length(),
                expectedLastModified = claim.lastModified(),
                expectedSha256 = sha256("expected"),
            )

            assertEquals(LanBackupFileCleanupResult.stale, result)
            assertTrue(target.exists())
            assertEquals("replacement", target.readText(Charsets.UTF_8))
            assertFalse(claim.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
}
