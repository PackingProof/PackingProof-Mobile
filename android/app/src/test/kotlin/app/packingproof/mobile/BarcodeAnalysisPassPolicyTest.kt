package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BarcodeAnalysisPassPolicyTest {
    @Test
    fun `主摄与长焦只跑短边100%的中心正方形`() {
        assertEquals(
            listOf("crop100"),
            BarcodeAnalysisPassPolicy.passesForLens(1.0).map { it.label },
        )
        assertEquals(
            listOf("crop100"),
            BarcodeAnalysisPassPolicy.passesForLens(2.0).map { it.label },
        )
    }

    @Test
    fun `超广角只跑短边70%的中心正方形`() {
        val passes = BarcodeAnalysisPassPolicy.passesForLens(0.5)
        assertEquals(listOf("crop70"), passes.map { it.label })
        assertEquals(listOf(0.7), passes.map { it.cropScale })
    }

    @Test
    fun `单通道识别链不会再往后继续`() {
        val passes = BarcodeAnalysisPassPolicy.passesForLens(0.5)
        assertFalse(
            BarcodeAnalysisPassPolicy.shouldRunNextPass(
                passIndex = 0,
                passCount = passes.size,
                foundPreferredBarcode = false,
            ),
        )
    }

    @Test
    fun `面单码制与 Dart 工作识别保持一致`() {
        assertTrue(BarcodeAnalysisFormatPolicy.isPreferredFormat("code128"))
        assertTrue(BarcodeAnalysisFormatPolicy.isPreferredFormat("code39"))
        assertTrue(BarcodeAnalysisFormatPolicy.isPreferredFormat("code93"))
        assertTrue(BarcodeAnalysisFormatPolicy.isPreferredFormat("codabar"))
        assertFalse(BarcodeAnalysisFormatPolicy.isPreferredFormat("ean13"))
        assertFalse(BarcodeAnalysisFormatPolicy.isPreferredFormat("qr"))
        assertFalse(BarcodeAnalysisFormatPolicy.isPreferredFormat(null))
    }
}
