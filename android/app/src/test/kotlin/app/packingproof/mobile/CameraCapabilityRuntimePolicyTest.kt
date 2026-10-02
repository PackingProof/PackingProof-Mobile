package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraCapabilityRuntimePolicyTest {
    @Test
    fun `session fallback only degrades full and unverified modes`() {
        assertEquals(
            CameraCapabilityMode.ENCODER_ANALYSIS,
            CameraCapabilityRuntimePolicy.effectiveRecordingMode(
                CameraCapabilityMode.FULL,
                sessionFallback = true,
            ),
        )
        assertEquals(
            CameraCapabilityMode.ENCODER_ANALYSIS,
            CameraCapabilityRuntimePolicy.effectiveRecordingMode(
                CameraCapabilityMode.UNVERIFIED,
                sessionFallback = true,
            ),
        )
        assertEquals(
            CameraCapabilityMode.ALTERNATING,
            CameraCapabilityRuntimePolicy.effectiveRecordingMode(
                CameraCapabilityMode.ALTERNATING,
                sessionFallback = true,
            ),
        )
        assertEquals(
            CameraCapabilityMode.FULL,
            CameraCapabilityRuntimePolicy.effectiveRecordingMode(
                CameraCapabilityMode.FULL,
                sessionFallback = false,
            ),
        )
    }

    @Test
    fun `preview pauses only while recording in encoder analysis mode`() {
        assertTrue(
            CameraPreviewOutputPolicy.pausePreview(
                recording = true,
                mode = CameraCapabilityMode.ENCODER_ANALYSIS,
            ),
        )
        assertFalse(
            CameraPreviewOutputPolicy.pausePreview(
                recording = false,
                mode = CameraCapabilityMode.ENCODER_ANALYSIS,
            ),
        )
        assertFalse(
            CameraPreviewOutputPolicy.pausePreview(
                recording = true,
                mode = CameraCapabilityMode.FULL,
            ),
        )
    }
}
