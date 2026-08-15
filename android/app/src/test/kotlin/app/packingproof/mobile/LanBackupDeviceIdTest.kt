package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LanBackupDeviceIdTest {
    @Test
    fun `device backup credentials use v3 token without web access key`() {
        val credential = BackupRequestAuthentication.parse("device-token-value")

        assertEquals(3, BackupRequestAuthentication.VERSION)
        assertEquals(3, credential.version)
        assertEquals("device-token-value", credential.backupCredential)
    }

    @Test
    fun samePhysicalDeviceProducesStableAnonymousId() {
        val first = LanBackupStateStore.stableDeviceId(
            androidId = "a1b2c3d4e5f60718",
            packageName = "app.packingproof.mobile",
        )
        val second = LanBackupStateStore.stableDeviceId(
            androidId = "A1B2C3D4E5F60718",
            packageName = "app.packingproof.mobile",
        )

        assertEquals(first, second)
        assertTrue(first!!.startsWith("android-"))
        assertEquals(72, first.length)
        assertFalse(first.contains("a1b2c3d4e5f60718"))
    }

    @Test
    fun differentPhysicalDevicesProduceDifferentIds() {
        val first = LanBackupStateStore.stableDeviceId(
            androidId = "a1b2c3d4e5f60718",
            packageName = "app.packingproof.mobile",
        )
        val second = LanBackupStateStore.stableDeviceId(
            androidId = "1122334455667788",
            packageName = "app.packingproof.mobile",
        )

        assertNotEquals(first, second)
    }

    @Test
    fun unavailableOrKnownBrokenAndroidIdUsesFallback() {
        assertNull(LanBackupStateStore.stableDeviceId(null, "app.packingproof.mobile"))
        assertNull(LanBackupStateStore.stableDeviceId("", "app.packingproof.mobile"))
        assertNull(
            LanBackupStateStore.stableDeviceId(
                "9774d56d682e549c",
                "app.packingproof.mobile",
            ),
        )
    }

    @Test
    fun deviceDisplayNameUsesStableShortId() {
        assertEquals(
            "本机",
            LanBackupStateStore.deviceDisplayName("android-1234567890a1b2c3"),
        )
        assertEquals("本机", LanBackupStateStore.deviceDisplayName("phone-1"))
        assertEquals("本机", LanBackupStateStore.deviceDisplayName("---"))
    }
}
