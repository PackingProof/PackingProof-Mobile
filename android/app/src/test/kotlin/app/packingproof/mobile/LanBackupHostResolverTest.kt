package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LanBackupHostResolverTest {
    @Test
    fun comparesNormalizedVersions() {
        assertEquals(0, compareLanBackupVersions("v0.5.11+11011", "0.5.11"))
        assertTrue(compareLanBackupVersions("0.5.12", "0.5.11") > 0)
        assertTrue(compareLanBackupVersions("0.5.10", "0.5.11") < 0)
        assertTrue(compareLanBackupVersions("invalid", "0.5.11") < 0)
    }
}
