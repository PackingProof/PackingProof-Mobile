package app.packingproof.mobile

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** 空间回收阈值、确认时效与上限只由 Dart 端下发，这里守住下发链路的存取行为。 */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class BackupStoragePolicyStoreTest {
    private val context
        get() = RuntimeEnvironment.getApplication()

    @Before
    fun setUp() {
        context.getSharedPreferences("lan_backup_storage_policy", 0).edit().clear().commit()
    }

    @After
    fun tearDown() {
        context.getSharedPreferences("lan_backup_storage_policy", 0).edit().clear().commit()
    }

    @Test
    fun pushedPolicyReplacesFallbackNumbers() {
        BackupStoragePolicyStore.save(
            context,
            mapOf(
                "storageMinimumBytes" to 1L * 1024 * 1024 * 1024,
                "storageWarningBytes" to 4L * 1024 * 1024 * 1024,
                "storageTargetBytes" to 4L * 1024 * 1024 * 1024,
                "storageDeleteUnbackedOnPressure" to true,
            ),
        )

        val policy = BackupStoragePolicyStore.current(context)

        assertEquals(1L * 1024 * 1024 * 1024, policy.minimumBytes)
        assertEquals(4L * 1024 * 1024 * 1024, policy.warningBytes)
        assertEquals(4L * 1024 * 1024 * 1024, policy.targetBytes)
        assertTrue(policy.deleteUnbackedOnPressure)
    }

    @Test
    fun reclaimBoundaryFollowsPushedPolicy() {
        val availableBytes = 900L * 1024 * 1024
        assertTrue(
            RecordingStoragePolicy.needsReclaim(
                availableBytes,
                BackupStoragePolicyStore.current(context),
            ),
        )

        BackupStoragePolicyStore.save(
            context,
            mapOf("storageMinimumBytes" to 512L * 1024 * 1024),
        )
        val policy = BackupStoragePolicyStore.current(context)

        assertFalse(RecordingStoragePolicy.needsReclaim(availableBytes, policy))
        // 只下发一个键时，其余数值保持原本的兜底值。
        assertEquals(BackupStoragePolicy.FALLBACK.warningBytes, policy.warningBytes)
    }

    @Test
    fun missingRequestKeysKeepPreviousValues() {
        BackupStoragePolicyStore.save(
            context,
            mapOf("storageTargetBytes" to 5L * 1024 * 1024 * 1024),
        )

        val policy = BackupStoragePolicyStore.current(context)

        assertEquals(5L * 1024 * 1024 * 1024, policy.targetBytes)
        assertEquals(BackupStoragePolicy.FALLBACK.minimumBytes, policy.minimumBytes)
    }
}
