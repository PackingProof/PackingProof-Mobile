package app.packingproof.mobile

import android.graphics.Bitmap
import android.graphics.Color
import androidx.media3.transformer.ExportResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
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
    fun `places every final orientation at horizontal center and ten percent from top`() {
        val overlayWidth = 400
        val overlayHeight = 100
        val expected = mapOf(
            "portrait" to WatermarkOverlayPlacement(0f, 1f, 0f, 0.8f, 0f),
            "landscapeLeft" to WatermarkOverlayPlacement(-0.25f, 0f, -0.8f, 0f, -90f),
            "landscapeRight" to WatermarkOverlayPlacement(0.25f, 0f, 0.8f, 0f, 90f),
        )

        for ((orientation, placement) in expected) {
            assertEquals(
                placement,
                watermarkOverlayPlacement(
                    orientation,
                    overlayWidth,
                    overlayHeight,
                ),
            )
            val settings = watermarkOverlaySettings(
                orientation,
                overlayWidth,
                overlayHeight,
            )
            assertEquals(placement.overlayAnchorX, settings.overlayFrameAnchor.first)
            assertEquals(placement.overlayAnchorY, settings.overlayFrameAnchor.second)
            assertEquals(placement.backgroundAnchorX, settings.backgroundFrameAnchor.first)
            assertEquals(placement.backgroundAnchorY, settings.backgroundFrameAnchor.second)
            assertEquals(placement.rotationDegrees, settings.rotationDegrees)

            val finalCenterX = when (orientation) {
                "portrait" -> (placement.backgroundAnchorX + 1f) / 2f
                else -> (1f - placement.backgroundAnchorY) / 2f
            }
            val finalTop = when (orientation) {
                "landscapeLeft" -> (placement.backgroundAnchorX + 1f) / 2f
                "landscapeRight" -> (1f - placement.backgroundAnchorX) / 2f
                else -> (1f - placement.backgroundAnchorY) / 2f
            }
            assertEquals(0.5f, finalCenterX, 0.0001f)
            assertEquals(0.1f, finalTop, 0.0001f)

            if (orientation != "portrait") {
                val rotatedMinX = -overlayHeight.toFloat() / overlayWidth
                val rotatedMaxX = overlayHeight.toFloat() / overlayWidth
                val rotatedTopEdge = if (orientation == "landscapeLeft") {
                    rotatedMinX
                } else {
                    rotatedMaxX
                }
                assertEquals(rotatedTopEdge, placement.overlayAnchorX, 0.0001f)
            }
        }
    }

    @Test
    fun `uses tracking number as the second line without an order prefix`() {
        assertEquals(
            listOf("2026/08/22 01:02:03", "TRACK123456789"),
            watermarkTextLines("2026/08/22 01:02:03", "TRACK123456789"),
        )
        assertEquals(
            listOf("2026/08/22 01:02:03"),
            watermarkTextLines("2026/08/22 01:02:03", ""),
        )
    }

    @Test
    fun `renders transparent outlined text without clipping bitmap edges`() {
        val bitmap = renderWatermarkTextBitmap(
            videoHeight = 1920,
            lines = listOf("2026/08/21 12:34:56", "TRACK123456789"),
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

        val whitePixels = pixels.withIndex().filter { it.value == Color.WHITE }
        val blackPixels = pixels.withIndex().filter { it.value == Color.BLACK }
        assertTrue(
            "black stroke must extend outside the white fill horizontally",
            blackPixels.minOf { it.index % bitmap.width } <
                whitePixels.minOf { it.index % bitmap.width } &&
                blackPixels.maxOf { it.index % bitmap.width } >
                whitePixels.maxOf { it.index % bitmap.width },
        )

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
        val twoLines = renderWatermarkTextBitmap(1080, listOf(timestamp, "TRACK123456789"))

        assertTrue(twoLines.height > oneLine.height)
        assertTrue(twoLines.width >= oneLine.width)
        val textSize = (1080 * 0.032f).coerceIn(35f, 61f)
        val expectedLineHeight = textSize * 1.25f
        assertTrue(
            kotlin.math.abs((twoLines.height - oneLine.height) - expectedLineHeight) < 1.1f,
        )
    }

    @Test
    fun `reuses one bitmap and updates its generation when the second changes`() {
        val renderer = ReusableWatermarkBitmap(
            videoHeight = 1920,
            maximumLines = listOf(
                "8888/88/88 88:88:88",
                "TRACK123456789",
            ),
        )

        val first = renderer.redraw(
            listOf("2026/08/21 12:34:56", "TRACK123456789"),
        )
        val firstGenerationId = first.generationId
        val second = renderer.redraw(
            listOf("2026/08/21 12:34:57", "TRACK123456789"),
        )

        assertSame(first, second)
        assertNotEquals(firstGenerationId, second.generationId)
        assertSame(second, renderer.current())
        renderer.release()
        assertTrue(second.isRecycled)
        assertTrue(
            isSuccessfulWatermarkExport(
                overlayConfigured = true,
                bitmapRequestCount = 2,
                videoFrameCount = 2,
                videoConversionProcess = ExportResult.CONVERSION_PROCESS_TRANSCODED,
                outputExists = true,
                outputBytes = 1024,
            ),
        )
    }

    @Test
    fun `accepts only exports that processed overlay frames and wrote output`() {
        assertTrue(
            isSuccessfulWatermarkExport(
                overlayConfigured = true,
                bitmapRequestCount = 60,
                videoFrameCount = 60,
                videoConversionProcess = ExportResult.CONVERSION_PROCESS_TRANSCODED,
                outputExists = true,
                outputBytes = 1024,
            ),
        )
        assertFalse(
            isSuccessfulWatermarkExport(
                overlayConfigured = false,
                bitmapRequestCount = 0,
                videoFrameCount = 60,
                videoConversionProcess = ExportResult.CONVERSION_PROCESS_TRANSCODED,
                outputExists = true,
                outputBytes = 1024,
            ),
        )
        assertFalse(
            isSuccessfulWatermarkExport(
                overlayConfigured = true,
                bitmapRequestCount = 60,
                videoFrameCount = 0,
                videoConversionProcess = ExportResult.CONVERSION_PROCESS_TRANSCODED,
                outputExists = true,
                outputBytes = 1024,
            ),
        )
        assertFalse(
            isSuccessfulWatermarkExport(
                overlayConfigured = true,
                bitmapRequestCount = 60,
                videoFrameCount = 60,
                videoConversionProcess = ExportResult.CONVERSION_PROCESS_TRANSMUXED,
                outputExists = true,
                outputBytes = 1024,
            ),
        )
        assertFalse(
            isSuccessfulWatermarkExport(
                overlayConfigured = true,
                bitmapRequestCount = 60,
                videoFrameCount = 60,
                videoConversionProcess = ExportResult.CONVERSION_PROCESS_TRANSCODED,
                outputExists = true,
                outputBytes = 0,
            ),
        )
    }
}
