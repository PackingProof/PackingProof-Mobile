package app.packingproof.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraSwitchResourcePolicyTest {
    @Test
    fun `same recording size reuses encoder`() {
        assertFalse(
            CameraSwitchResourcePolicy.shouldRestartEncoder(
                previousWidth = 1080,
                previousHeight = 1920,
                nextWidth = 1080,
                nextHeight = 1920,
            ),
        )
    }

    @Test
    fun `recording size change restarts encoder`() {
        assertTrue(
            CameraSwitchResourcePolicy.shouldRestartEncoder(
                previousWidth = 1080,
                previousHeight = 1920,
                nextWidth = 720,
                nextHeight = 1280,
            ),
        )
    }
}
