package app.packingproof.mobile

import android.graphics.Bitmap
import android.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class VideoWatermarkOrientationTest {
    @Test
    fun `uses the final overlay anchor and rotation for each recording orientation`() {
        val expected = mapOf(
            "portrait" to WatermarkOverlayPlacement(1f, 1f, 0f),
            "landscapeLeft" to WatermarkOverlayPlacement(-1f, 1f, -90f),
            "landscapeRight" to WatermarkOverlayPlacement(1f, -1f, 90f),
        )

        for ((orientation, placement) in expected) {
            assertEquals(placement, watermarkOverlayPlacement(orientation))
            val settings = watermarkOverlaySettings(orientation)
            assertEquals(placement.anchorX, settings.overlayFrameAnchor.first)
            assertEquals(placement.anchorY, settings.overlayFrameAnchor.second)
            assertEquals(placement.anchorX, settings.backgroundFrameAnchor.first)
            assertEquals(placement.anchorY, settings.backgroundFrameAnchor.second)
            assertEquals(placement.rotationDegrees, settings.rotationDegrees)
        }
    }

    @Test
    fun `renders transparent outlined text without clipping bitmap edges`() {
        val bitmap = renderWatermarkTextBitmap(
            videoHeight = 1920,
            lines = listOf("2026/08/21 12:34:56", "Order:TRACK123456789"),
        )

        assertEquals(Bitmap.Config.ARGB_8888, bitmap.config)
        assertEquals(Bitmap.DENSITY_NONE, bitmap.density)
        assertTrue(bitmap.width > 1)
        assertTrue(bitmap.height > 1)

        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val visiblePixels = pixels.withIndex().filter { Color.alpha(it.value) > 0 }
        assertTrue("watermark must contain rendered text", visiblePixels.isNotEmpty())
        assertTrue("transparent background must remain transparent", pixels.any { Color.alpha(it) == 0 })
        assertTrue("outlined text must contain white fill", pixels.any { it == Color.WHITE })
        assertTrue("outlined text must contain black stroke", pixels.any { it == Color.BLACK })

        val left = visiblePixels.minOf { it.index % bitmap.width }
        val right = visiblePixels.maxOf { it.index % bitmap.width }
        val top = visiblePixels.minOf { it.index / bitmap.width }
        val bottom = visiblePixels.maxOf { it.index / bitmap.width }
        assertTrue("text must not touch the left bitmap edge", left > 0)
        assertTrue("text must not touch the right bitmap edge", right < bitmap.width - 1)
        assertTrue("text must not touch the top bitmap edge", top > 0)
        assertTrue("text must not touch the bottom bitmap edge", bottom < bitmap.height - 1)
    }

    @Test
    fun `allocates additional bitmap height for a second watermark line`() {
        val timestamp = "2026/08/21 12:34:56"
        val oneLine = renderWatermarkTextBitmap(1080, listOf(timestamp))
        val twoLines = renderWatermarkTextBitmap(1080, listOf(timestamp, "Order:TRACK123456789"))

        assertTrue(twoLines.height > oneLine.height)
        assertTrue(twoLines.width >= oneLine.width)
    }
}
