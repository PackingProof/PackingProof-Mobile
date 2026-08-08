package app.packingproof.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingCodecPolicyTest {
    @Test
    fun `鸿蒙与华为机型优先 H264`() {
        assertTrue(RecordingCodecPolicy("HUAWEI").preferH264OverHevc())
        assertTrue(RecordingCodecPolicy("huawei").preferH264OverHevc())
        assertTrue(RecordingCodecPolicy("HONOR").preferH264OverHevc())
        assertTrue(RecordingCodecPolicy(" Honor ").preferH264OverHevc())
    }

    @Test
    fun `其他机型保持偏好编码`() {
        assertFalse(RecordingCodecPolicy("vivo").preferH264OverHevc())
        assertFalse(RecordingCodecPolicy("Xiaomi").preferH264OverHevc())
        assertFalse(RecordingCodecPolicy("samsung").preferH264OverHevc())
        assertFalse(RecordingCodecPolicy("").preferH264OverHevc())
    }
}
