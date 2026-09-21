package app.packingproof.mobile

import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class RecordingStorageManagerTest {
    private companion object {
        const val TEST_CREDENTIAL = "storage-manager-test-credential"
    }

    private val context
        get() = RuntimeEnvironment.getApplication()
    private lateinit var source: File
    private lateinit var store: LanBackupStateStore
    private var credentialValue: String? = TEST_CREDENTIAL

    @Before
    fun setUp() {
        context.deleteDatabase("lan_backup.db")
        source = File(context.cacheDir, "storage-manager-test.mp4").apply {
            writeText("test-video", Charsets.UTF_8)
        }
        credentialValue = TEST_CREDENTIAL
        store = LanBackupStateStore(context, backupCredential = { credentialValue })
    }

    @After
    fun tearDown() {
        store.close()
        source.delete()
        context.deleteDatabase("lan_backup.db")
    }

    @Test
    fun sufficientStorageDoesNotReportJobChanges() {
        val manager = RecordingStorageManager(
            context,
            store,
            availableBytes = { BackupStoragePolicy.FALLBACK.targetBytes },
        )

        val result = manager.checkAndReclaim()

        assertFalse(result.jobsChanged)
        assertEquals(0, result.values["deletedCount"])
    }

    @Test
    fun reclaimThresholdFollowsPolicyPushedFromDart() {
        val availableBytes = 1500L * 1024 * 1024
        val manager = RecordingStorageManager(
            context,
            store,
            availableBytes = { availableBytes },
        )

        // 未下发策略时使用兜底阈值（2GB），1.5GB 判为空间不足。
        assertTrue(manager.checkAndReclaim().values["insufficient"] as Boolean)

        BackupStoragePolicyStore.save(
            context,
            mapOf("storageMinimumBytes" to 1L * 1024 * 1024 * 1024),
        )

        // 阈值改由下发值决定后，同一剩余空间不再算不足。
        assertFalse(manager.checkAndReclaim().values["insufficient"] as Boolean)
    }

    @Test
    fun deletionReportsOneChangeAndSubsequentCheckDoesNotRepeatIt() {
        val job = verifiedJob()
        val manager = RecordingStorageManager(context, store, availableBytes = { 0 })

        val first = manager.checkAndReclaim()
        val second = manager.checkAndReclaim()
        val deleted = store.readJob(job.getString("id"))!!
        val event = store.cleanupEvents(0, 100).events.single()

        assertTrue(first.jobsChanged)
        assertEquals(1, first.values["deletedCount"])
        assertFalse(second.jobsChanged)
        assertEquals(0, second.values["deletedCount"])
        assertFalse(source.exists())
        assertNotNull(LanBackupCleanupScheduler.nullableText(deleted, "localDeletedAt"))
        assertEquals(job.getString("generation"), deleted.getString("generation"))
        assertEquals(job.getString("id"), event.jobId)
        assertEquals("存储空间不足提前清理", event.reason)
        assertEquals(
            Instant.parse(deleted.getString("localDeletedAt")).toEpochMilli(),
            event.deletedAtMs,
        )
    }

    @Test
    fun missingReceiptPreservesSource() {
        val job = verifiedJob(receipt = { JSONObject.NULL })

        val result = manager().checkAndReclaim()

        assertPreserved(job, result)
    }

    @Test
    fun freshConfirmationReclaimsWithoutAskingTheComputerAgain() {
        verifiedJob()
        var confirmations = 0
        val manager = RecordingStorageManager(
            context,
            store,
            availableBytes = { 0 },
            confirmRemoteRecording = {
                confirmations++
                RemoteRecordAttestation.Unreachable
            },
        )

        val result = manager.checkAndReclaim()

        assertEquals(0, confirmations)
        assertEquals(1, result.values["deletedCount"])
        assertFalse(source.exists())
    }

    @Test
    fun expiredConfirmationIsRenewedWithTheComputerBeforeReclaim() {
        val staleAttestedAt = Instant.now().minusSeconds(3_600).toString()
        val expectedBytes = source.length()
        val job = verifiedJob(lastAttestedAt = staleAttestedAt)
        val manager = RecordingStorageManager(
            context,
            store,
            availableBytes = { 0 },
            confirmRemoteRecording = { RemoteRecordAttestation.Confirmed },
        )

        val result = manager.checkAndReclaim()
        val deleted = store.readJob(job.getString("id"))!!

        assertEquals(1, result.values["deletedCount"])
        assertEquals(expectedBytes, result.values["freedBytes"])
        assertFalse(source.exists())
        assertNotNull(LanBackupCleanupScheduler.nullableText(deleted, "localDeletedAt"))
        val renewedAttestedAt =
            LanBackupCleanupScheduler.nullableText(deleted, "lastAttestedAt")!!
        assertNotEquals(staleAttestedAt, renewedAttestedAt)
        assertTrue(
            RecordingStoragePolicy.isFreshAttestation(
                renewedAttestedAt,
                BackupStoragePolicy.FALLBACK,
            ),
        )
    }

    @Test
    fun expiredConfirmationWithoutComputerAnswerPreservesSource() {
        val staleAttestedAt = Instant.now().minusSeconds(3_600).toString()
        val job = verifiedJob(lastAttestedAt = staleAttestedAt)
        val manager = RecordingStorageManager(
            context,
            store,
            availableBytes = { 0 },
            confirmRemoteRecording = { RemoteRecordAttestation.Unreachable },
        )

        val result = manager.checkAndReclaim()

        assertPreserved(job, result)
        assertEquals(
            staleAttestedAt,
            LanBackupCleanupScheduler.nullableText(
                store.readJob(job.getString("id"))!!,
                "lastAttestedAt",
            ),
        )
    }

    @Test
    fun incompleteProofIsNeverSentForRemoteConfirmation() {
        val staleAttestedAt = Instant.now().minusSeconds(3_600).toString()
        verifiedJob(receipt = { JSONObject.NULL }, lastAttestedAt = staleAttestedAt)
        var confirmations = 0
        val manager = RecordingStorageManager(
            context,
            store,
            availableBytes = { 0 },
            confirmRemoteRecording = {
                confirmations++
                RemoteRecordAttestation.Confirmed
            },
        )

        val result = manager.checkAndReclaim()

        assertEquals(0, confirmations)
        assertEquals(0, result.values["deletedCount"])
        assertTrue(source.exists())
    }

    @Test
    fun unreachableComputerStopsFurtherConfirmationAttempts() {
        val secondSource = File(context.cacheDir, "storage-manager-test-second.mp4").apply {
            writeText("second-test-video", Charsets.UTF_8)
        }
        try {
            val staleAttestedAt = Instant.now().minusSeconds(3_600).toString()
            verifiedJob(lastAttestedAt = staleAttestedAt)
            verifiedJob(
                file = secondSource,
                sessionId = "storage-manager-second-session",
                lastAttestedAt = staleAttestedAt,
            )
            var confirmations = 0
            val manager = RecordingStorageManager(
                context,
                store,
                availableBytes = { 0 },
                confirmRemoteRecording = {
                    confirmations++
                    RemoteRecordAttestation.Unreachable
                },
            )

            val result = manager.checkAndReclaim()

            assertEquals(1, confirmations)
            assertEquals(0, result.values["deletedCount"])
            assertTrue(source.exists())
            assertTrue(secondSource.exists())
        } finally {
            secondSource.delete()
        }
    }

    @Test
    fun remoteConfirmationAttemptsAreBoundedPerRun() {
        val secondSource = File(context.cacheDir, "storage-manager-test-bounded.mp4").apply {
            writeText("bounded-test-video", Charsets.UTF_8)
        }
        try {
            val staleAttestedAt = Instant.now().minusSeconds(3_600).toString()
            verifiedJob(lastAttestedAt = staleAttestedAt)
            verifiedJob(
                file = secondSource,
                sessionId = "storage-manager-bounded-session",
                lastAttestedAt = staleAttestedAt,
            )
            var confirmations = 0
            val manager = RecordingStorageManager(
                context,
                store,
                availableBytes = { 0 },
                confirmRemoteRecording = {
                    confirmations++
                    RemoteRecordAttestation.Confirmed
                },
                maxRemoteConfirmationsPerRun = 1,
            )

            val result = manager.checkAndReclaim()

            assertEquals(1, confirmations)
            assertEquals(1, result.values["deletedCount"])
        } finally {
            secondSource.delete()
        }
    }

    @Test
    fun receiptObjectWithPlausibleFieldPreservesSource() {
        val job = verifiedJob(
            receipt = { JSONObject().put("signature", "a".repeat(64)) },
        )

        val result = manager().checkAndReclaim()

        assertPreserved(job, result)
    }

    @Test
    fun blankOrNonHexReceiptPreservesSource() {
        val job = verifiedJob(receipt = { "   " })
        assertPreserved(job, manager().checkAndReclaim())
        store.updateJob(job.getString("id"), job.getString("generation")) { current ->
            current.put("verificationReceipt", "not-a-signed-receipt")
            true
        }

        assertPreserved(job, manager().checkAndReclaim())
    }

    @Test
    fun legacy64HexStringReceiptPreservesSource() {
        val job = verifiedJob(receipt = { "b".repeat(64) })

        assertPreserved(job, manager().checkAndReclaim())
    }

    @Test
    fun forged64HexSignatureWithCompleteFieldsPreservesSource() {
        val job = verifiedJob(receipt = { current ->
            signedReceipt(current).put("receiptSignature", "f".repeat(64))
        })

        assertPreserved(job, manager().checkAndReclaim())
    }

    @Test
    fun missingRemoteRecordIdPreservesSource() {
        val job = verifiedJob(remoteRecordId = null)

        val result = manager().checkAndReclaim()

        assertPreserved(job, result)
    }

    @Test
    fun zeroOrTwoSessionsPreserveSource() {
        val job = verifiedJob(sessionValues = JSONArray())
        assertPreserved(job, manager().checkAndReclaim())
        store.updateJob(job.getString("id"), job.getString("generation")) { current ->
            current.put(
                "sessions",
                JSONArray()
                    .put(JSONObject().put("id", "session-one"))
                    .put(JSONObject().put("id", "session-two")),
            )
            true
        }

        assertPreserved(job, manager().checkAndReclaim())
    }

    @Test
    fun changedGenerationRejectsOldCandidateWithoutOverwritingCurrentState() {
        val job = verifiedJob()
        val expected = recordingStorageCandidate(store.readJob(job.getString("id"))!!)
        store.updateJob(job.getString("id"), job.getString("generation")) { current ->
            current.put("generation", "new-generation")
                .put("state", "pending")
                .put("errorMessage", "新任务状态")
            true
        }

        val outcome = store.reclaimVerifiedRecording(expected)
        val current = store.readJob(job.getString("id"))!!

        assertEquals(RecordingStorageReclaimResult.rejected, outcome.result)
        assertFalse(outcome.jobChanged)
        assertTrue(source.exists())
        assertEquals("new-generation", current.getString("generation"))
        assertEquals("pending", current.getString("state"))
        assertEquals("新任务状态", current.getString("errorMessage"))
        assertNull(LanBackupCleanupScheduler.nullableText(current, "localDeletedAt"))
    }

    @Test
    fun credentialMissingOrChangedAfterCandidateSnapshotPreservesSourceAndState() {
        val job = verifiedJob()
        val id = job.getString("id")
        val expected = recordingStorageCandidate(store.readJob(id)!!)
        listOf<String?>(null, "different-credential").forEachIndexed { index, credential ->
            credentialValue = credential
            store.updateJob(id, job.getString("generation")) { current ->
                current.put("errorMessage", "新凭据状态-$index")
                true
            }

            val outcome = store.reclaimVerifiedRecording(expected)
            val current = store.readJob(id)!!

            assertEquals(RecordingStorageReclaimResult.rejected, outcome.result)
            assertFalse(outcome.jobChanged)
            assertTrue(source.exists())
            assertEquals("新凭据状态-$index", current.getString("errorMessage"))
            assertNull(LanBackupCleanupScheduler.nullableText(current, "localDeletedAt"))
        }
    }

    @Test
    fun requeueAndSamePathReplacementBetweenPageAndDeletePreserveNewGeneration() {
        val job = verifiedJob()
        val originalModified = source.lastModified()
        val manager = RecordingStorageManager(
            context,
            store,
            availableBytes = { 0 },
            beforeGuardedDeleteForTesting = { snapshot ->
                source.writeText("test-video", Charsets.UTF_8)
                assertTrue(source.setLastModified(originalModified))
                store.updateJob(
                    snapshot.getString("id"),
                    snapshot.getString("generation"),
                ) { current ->
                    current.put("generation", "replacement-generation")
                        .put("state", "pending")
                        .put("errorMessage", "替换后的任务")
                    true
                }
            },
        )

        val result = manager.checkAndReclaim()
        val current = store.readJob(job.getString("id"))!!

        assertFalse(result.jobsChanged)
        assertEquals(0, result.values["deletedCount"])
        assertTrue(source.exists())
        assertEquals("test-video", source.readText(Charsets.UTF_8))
        assertEquals("replacement-generation", current.getString("generation"))
        assertEquals("pending", current.getString("state"))
        assertEquals("替换后的任务", current.getString("errorMessage"))
    }

    @Test
    fun proofFieldsChangedAfterCandidateSnapshotAreRejectedWithoutOverwriting() {
        val job = verifiedJob()
        val id = job.getString("id")
        val generation = job.getString("generation")
        val baseline = store.readJob(id)!!
        val expected = recordingStorageCandidate(baseline)
        val mutations = listOf<Pair<String, (JSONObject) -> Unit>>(
            "path" to { it.put("filePath", source.path + ".replacement") },
            "mtime" to { it.put("lastModified", it.getLong("lastModified") + 1L) },
            "host" to { it.put("destinationComputerId", "other-host") },
            "session" to {
                it.put("sessions", JSONArray().put(JSONObject().put("id", "other-session")))
            },
            "sha" to { it.put("contentSha256", "c".repeat(64)) },
            "size" to { it.put("totalBytes", it.getLong("totalBytes") + 1L) },
            "record" to { it.put("remoteRecordId", it.getLong("remoteRecordId") + 1L) },
            "receipt-source-device" to {
                mutateReceipt(it, "sourceDeviceId", "other-device")
            },
            "receipt-verified-at" to {
                mutateReceipt(
                    it,
                    "verifiedAtUnixSeconds",
                    it.getJSONObject("verificationReceipt")
                        .getLong("verifiedAtUnixSeconds") + 1L,
                )
            },
            "receipt-host" to { mutateReceipt(it, "hostNodeId", "other-host") },
            "receipt-session" to { mutateReceipt(it, "sourceSessionId", "other-session") },
            "receipt-sha" to { mutateReceipt(it, "fileSha256", "d".repeat(64)) },
            "receipt-size" to { mutateReceipt(it, "fileSizeBytes", 999L) },
            "receipt-record" to { mutateReceipt(it, "recordId", 999L) },
            "receipt-signature" to {
                mutateReceipt(it, "receiptSignature", "e".repeat(64))
            },
        )
        mutations.forEach { (name, mutate) ->
            store.updateJob(id, generation) { current ->
                mutate(current)
                current.put("errorMessage", "新证明状态-$name")
                true
            }

            val outcome = store.reclaimVerifiedRecording(expected)
            val current = store.readJob(id)!!

            assertEquals(name, RecordingStorageReclaimResult.rejected, outcome.result)
            assertFalse(name, outcome.jobChanged)
            assertTrue(name, source.exists())
            assertEquals(name, "新证明状态-$name", current.getString("errorMessage"))
            assertNull(
                name,
                LanBackupCleanupScheduler.nullableText(current, "localDeletedAt"),
            )
            store.updateJob(id, generation) { value ->
                restoreProofFields(value, baseline)
                true
            }
        }
    }

    @Test
    fun changedFileIdentityIsRestoredAndNotMarkedDeleted() {
        val job = verifiedJob()
        val manager = RecordingStorageManager(
            context,
            store,
            availableBytes = { 0 },
            beforeGuardedDeleteForTesting = {
                source.writeText("replacement-video-content", Charsets.UTF_8)
            },
        )

        val result = manager.checkAndReclaim()
        val current = store.readJob(job.getString("id"))!!

        assertTrue(result.jobsChanged)
        assertEquals(0, result.values["deletedCount"])
        assertTrue(source.exists())
        assertEquals("replacement-video-content", source.readText(Charsets.UTF_8))
        assertNull(LanBackupCleanupScheduler.nullableText(current, "localDeletedAt"))
        assertEquals("录像文件已被替换，已取消空间清理", current.getString("errorMessage"))
    }

    private fun manager() = RecordingStorageManager(context, store, availableBytes = { 0 })

    private fun verifiedJob(
        receipt: (JSONObject) -> Any = ::signedReceipt,
        remoteRecordId: Long? = 7L,
        file: File = source,
        sessionId: String = "storage-manager-session",
        lastAttestedAt: String = Instant.now().toString(),
        sessionValues: JSONArray = sessions(sessionId),
    ): JSONObject {
        val job = store.upsertJob(file.path, sessions(sessionId)).job
        return store.updateJob(job.getString("id"), job.getString("generation")) { current ->
            current.put("state", "completed")
                .put("destinationComputerId", "host-1")
                .put("backupCompletedAt", Instant.now().toString())
                .put("contentSha256", sha256(file))
                .put("verificationVersion", BackupRequestAuthentication.VERSION)
                .put("remoteRecordId", 7L)
                .put("sessions", sessions(sessionId))
                .put("lastAttestedAt", lastAttestedAt)
                .put("totalBytes", file.length())
                .put("lastModified", file.lastModified())
            current.put("verificationReceipt", receipt(current))
                .put("remoteRecordId", remoteRecordId ?: JSONObject.NULL)
                .put("sessions", sessionValues)
            true
        }!!
    }

    private fun restoreProofFields(target: JSONObject, source: JSONObject) {
        target.put("filePath", source.getString("filePath"))
            .put("lastModified", source.getLong("lastModified"))
            .put("destinationComputerId", source.getString("destinationComputerId"))
            .put("sessions", JSONArray(source.getJSONArray("sessions").toString()))
            .put("contentSha256", source.getString("contentSha256"))
            .put("totalBytes", source.getLong("totalBytes"))
            .put("remoteRecordId", source.getLong("remoteRecordId"))
            .put(
                "verificationReceipt",
                JSONObject(source.getJSONObject("verificationReceipt").toString()),
            )
    }

    private fun mutateReceipt(job: JSONObject, field: String, value: Any) {
        job.put(
            "verificationReceipt",
            JSONObject(job.getJSONObject("verificationReceipt").toString()).put(field, value),
        )
    }

    private fun signedReceipt(job: JSONObject): JSONObject {
        val verifiedAt = Instant.now().minusSeconds(86_400).epochSecond
        val hostNodeId = job.getString("destinationComputerId")
        val sourceDeviceId = store.deviceId()
        val sourceSessionId = job.getJSONArray("sessions").getJSONObject(0).getString("id")
        val fileSha256 = job.getString("contentSha256")
        val fileSizeBytes = job.getLong("totalBytes")
        val recordId = job.getLong("remoteRecordId")
        val canonical = listOf(
            "packingproof-verified-receipt-v3",
            hostNodeId.lowercase(),
            sourceDeviceId.lowercase(),
            sourceSessionId,
            fileSha256.lowercase(),
            fileSizeBytes.toString(),
            recordId.toString(),
            verifiedAt.toString(),
        ).joinToString("\n")
        val mac = Mac.getInstance("HmacSHA256").apply {
            init(SecretKeySpec(TEST_CREDENTIAL.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        }
        val signature = mac.doFinal(canonical.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return JSONObject()
            .put("authVersion", BackupRequestAuthentication.VERSION)
            .put("verifiedAtUnixSeconds", verifiedAt)
            .put("hostNodeId", hostNodeId)
            .put("sourceDeviceId", sourceDeviceId)
            .put("sourceSessionId", sourceSessionId)
            .put("fileSha256", fileSha256)
            .put("fileSizeBytes", fileSizeBytes)
            .put("recordId", recordId)
            .put("receiptSignature", signature)
    }

    private fun assertPreserved(job: JSONObject, result: RecordingStorageCheckResult) {
        assertFalse(result.jobsChanged)
        assertEquals(0, result.values["deletedCount"])
        assertTrue(source.exists())
        assertNull(
            LanBackupCleanupScheduler.nullableText(
                store.readJob(job.getString("id"))!!,
                "localDeletedAt",
            ),
        )
    }

    private fun sessions(id: String = "storage-manager-session"): JSONArray = JSONArray().put(
        JSONObject()
            .put("id", id)
            .put("startedAt", "2026-08-23T09:30:00Z")
            .put("endedAt", "2026-08-23T09:30:01Z"),
    )

    private fun sha256(file: File): String = MessageDigest.getInstance("SHA-256")
        .digest(file.readBytes())
        .joinToString("") { "%02x".format(it) }
}
