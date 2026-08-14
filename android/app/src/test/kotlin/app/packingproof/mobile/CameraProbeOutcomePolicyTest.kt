package app.packingproof.mobile

import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraDevice
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraProbeOutcomePolicyTest {
    @Test
    fun `camera disabled is classified as infra`() {
        assertEquals(
            CameraProbeOutcome.CAMERA_DISABLED,
            CameraProbeOutcomePolicy.cameraOpenErrorReason(
                CameraAccessException.CAMERA_DISABLED,
            ),
        )
    }

    @Test
    fun `camera in use is classified as infra`() {
        assertEquals(
            CameraProbeOutcome.CAMERA_ACCESS_ERROR,
            CameraProbeOutcomePolicy.cameraOpenErrorReason(
                CameraAccessException.MAX_CAMERAS_IN_USE,
            ),
        )
    }

    @Test
    fun `illegal argument from session create is capability evidence`() {
        assertEquals(
            CameraProbeOutcome.UNSUPPORTED_COMBINATION,
            CameraProbeOutcomePolicy.sessionCreateError(IllegalArgumentException("bad")),
        )
    }

    @Test
    fun `camera state error disabled maps to disabled`() {
        assertEquals(
            CameraProbeOutcome.CAMERA_DISABLED,
            CameraProbeOutcomePolicy.cameraStateError(
                CameraDevice.StateCallback.ERROR_CAMERA_DISABLED,
            ),
        )
        assertEquals(
            CameraProbeOutcome.CAMERA_ERROR,
            CameraProbeOutcomePolicy.cameraStateError(
                CameraDevice.StateCallback.ERROR_CAMERA_SERVICE,
            ),
        )
    }
}
