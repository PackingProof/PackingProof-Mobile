package app.packingproof.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraSwitchResourcePolicyTest {
    @Test
    fun `待机识别开启时仍可切换镜头`() {
        // 待机扫码不参与判定：会话重建会一并重建识别流，
        // 现场反馈的「切换摄像头失败」正是识别开启被当成忙碌状态导致的。
        assertTrue(switchReady())
    }

    @Test
    fun `录像请求或录像进行中不可切换镜头`() {
        assertFalse(switchReady(recordingRequested = true))
        assertFalse(switchReady(recordingActive = true))
    }

    @Test
    fun `分段操作未完成不可切换镜头`() {
        assertFalse(switchReady(segmentOperationPending = true))
    }

    @Test
    fun `配对扫码与未就绪状态不可切换镜头`() {
        assertFalse(switchReady(pairingScanEnabled = true))
        assertFalse(switchReady(initialized = false))
        assertFalse(switchReady(canSwitchCamera = false))
    }

    private fun switchReady(
        initialized: Boolean = true,
        canSwitchCamera: Boolean = true,
        recordingRequested: Boolean = false,
        recordingActive: Boolean = false,
        segmentOperationPending: Boolean = false,
        pairingScanEnabled: Boolean = false,
    ): Boolean = CameraSwitchResourcePolicy.canSwitch(
        initialized = initialized,
        canSwitchCamera = canSwitchCamera,
        recordingRequested = recordingRequested,
        recordingActive = recordingActive,
        segmentOperationPending = segmentOperationPending,
        pairingScanEnabled = pairingScanEnabled,
    )

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
