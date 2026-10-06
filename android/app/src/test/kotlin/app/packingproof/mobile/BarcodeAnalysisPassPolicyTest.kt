package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BarcodeAnalysisPassPolicyTest {
    @Test
    fun `主摄与长焦只跑整帧`() {
        assertEquals(
            listOf("full"),
            BarcodeAnalysisPassPolicy.passesForLens(1.0).map { it.label },
        )
        assertEquals(
            listOf("full"),
            BarcodeAnalysisPassPolicy.passesForLens(2.0).map { it.label },
        )
    }

    @Test
    fun `超广角按整帧到中心裁剪依次回退`() {
        val passes = BarcodeAnalysisPassPolicy.passesForLens(0.5)
        assertEquals(listOf("full", "crop85", "crop50"), passes.map { it.label })
        assertEquals(listOf(null, 0.85, 0.5), passes.map { it.cropScale })
    }

    @Test
    fun `已有面单码制或已是最后一档时不再继续`() {
        val passes = BarcodeAnalysisPassPolicy.passesForLens(0.5)
        assertTrue(
            BarcodeAnalysisPassPolicy.shouldRunNextPass(
                passIndex = 0,
                passCount = passes.size,
                foundPreferredBarcode = false,
            ),
        )
        assertFalse(
            BarcodeAnalysisPassPolicy.shouldRunNextPass(
                passIndex = 0,
                passCount = passes.size,
                foundPreferredBarcode = true,
            ),
        )
        assertFalse(
            BarcodeAnalysisPassPolicy.shouldRunNextPass(
                passIndex = passes.lastIndex,
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
