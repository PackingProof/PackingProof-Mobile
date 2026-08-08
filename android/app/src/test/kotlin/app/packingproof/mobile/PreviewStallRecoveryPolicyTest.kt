package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class PreviewStallRecoveryPolicyTest {
    private val policy = PreviewStallRecoveryPolicy()

    @Test
    fun `未录像时按阶段依次重发请求、重建会话、记录失败`() {
        assertEquals(
            PreviewStallRecoveryAction.REAPPLY_REQUEST,
            policy.nextAction(stage = 0, recording = false, stallActive = true),
        )
        assertEquals(
            PreviewStallRecoveryAction.RECREATE_SESSION,
            policy.nextAction(stage = 1, recording = false, stallActive = true),
        )
        assertEquals(
            PreviewStallRecoveryAction.LOG_FAILURE,
            policy.nextAction(stage = 2, recording = false, stallActive = true),
        )
    }

    @Test
    fun `录像中或未停滞时不自动恢复`() {
        assertEquals(
            PreviewStallRecoveryAction.NONE,
            policy.nextAction(stage = 0, recording = true, stallActive = true),
        )
        assertEquals(
            PreviewStallRecoveryAction.NONE,
            policy.nextAction(stage = 0, recording = false, stallActive = false),
        )
    }
}
