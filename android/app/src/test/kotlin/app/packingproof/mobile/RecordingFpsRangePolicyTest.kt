package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RecordingFpsRangePolicyTest {
    private val policy = RecordingFpsRangePolicy(targetFps = 30)

    @Test
    fun `没有可用范围时不设置 FPS`() {
        assertNull(policy.choose(null))
        assertNull(policy.choose(emptyList()))
    }

    @Test
    fun `优先选择与目标帧率完全一致的固定范围`() {
        assertEquals(
            30 to 30,
            policy.choose(listOf(15 to 30, 30 to 30, 24 to 30)),
        )
    }

    @Test
    fun `没有固定范围时选择包含目标帧率的最窄范围`() {
        assertEquals(
            15 to 30,
            policy.choose(listOf(15 to 60, 15 to 30, 24 to 60)),
        )
    }

    @Test
    fun `没有包含范围时选择最接近目标帧率的范围`() {
        assertEquals(
            24 to 30,
            policy.choose(listOf(24 to 30, 60 to 60)),
        )
    }
}
