package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class VideoWatermarkOrientationTest {
    @Test
    fun `rotates overlay after bitmap layout for each recording orientation`() {
        assertEquals(0f, watermarkOverlayRotationDegrees("portrait"))
        assertEquals(-90f, watermarkOverlayRotationDegrees("landscapeLeft"))
        assertEquals(90f, watermarkOverlayRotationDegrees("landscapeRight"))
    }
}
