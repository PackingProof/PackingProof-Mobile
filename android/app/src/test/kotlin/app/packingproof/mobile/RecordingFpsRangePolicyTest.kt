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
    fun `优先选择上界为目标帧率且下限最低的范围`() {
        assertEquals(
            15 to 30,
            policy.choose(listOf(15 to 30, 30 to 30, 24 to 30)),
        )
    }

    @Test
    fun `没有上界为目标帧率的范围时选择包含目标帧率且下限最低的范围`() {
        assertEquals(
            15 to 60,
            policy.choose(listOf(15 to 60, 24 to 60)),
        )
    }

    @Test
    fun `没有包含范围时选择最接近目标帧率的范围`() {
        assertEquals(
            15 to 24,
            policy.choose(listOf(15 to 24, 10 to 20)),
        )
    }
}
