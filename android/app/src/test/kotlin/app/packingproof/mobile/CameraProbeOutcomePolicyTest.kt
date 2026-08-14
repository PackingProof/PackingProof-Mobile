package app.packingproof.mobile

import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraDevice
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraProbeOutcomePolicyTest {
    @Test
    fun `camera disabled is classified as infra`() {
        val error = CameraAccessException(CameraAccessException.CAMERA_DISABLED)
        assertEquals(
            CameraProbeOutcome.CAMERA_DISABLED,
            CameraProbeOutcomePolicy.cameraOpenError(error),
        )
    }

    @Test
    fun `camera in use is classified as infra`() {
        val error = CameraAccessException(CameraAccessException.MAX_CAMERAS_IN_USE)
        assertEquals(
            CameraProbeOutcome.CAMERA_ACCESS_ERROR,
            CameraProbeOutcomePolicy.cameraOpenError(error),
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
