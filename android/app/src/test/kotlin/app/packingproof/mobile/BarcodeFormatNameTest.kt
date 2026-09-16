package app.packingproof.mobile

import com.google.mlkit.vision.barcode.common.Barcode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BarcodeFormatNameTest {
    @Test
    fun `maps supported ML Kit barcode formats to stable names`() {
        assertEquals("code128", barcodeFormatName(Barcode.FORMAT_CODE_128))
        assertEquals("qr", barcodeFormatName(Barcode.FORMAT_QR_CODE))
        assertEquals("ean13", barcodeFormatName(Barcode.FORMAT_EAN_13))
        assertEquals("code39", barcodeFormatName(Barcode.FORMAT_CODE_39))
        assertEquals("pdf417", barcodeFormatName(Barcode.FORMAT_PDF417))
        assertNull(barcodeFormatName(Barcode.FORMAT_UNKNOWN))
    }

    /**
     * Dart 侧的 BarcodeCandidatePolicy 按这些名字判断码制：一维码才参与面单识别，
     * 二维码与商品码完全静默。名字一旦漂移，二维码就会重新弹出"非面单条码"提示，
     * 因此这里把两端共用的全部名字都钉死。
     */
    @Test
    fun `keeps every format name the Dart policy depends on`() {
        // 面单识别放行的一维码制。
        assertEquals("code128", barcodeFormatName(Barcode.FORMAT_CODE_128))
        assertEquals("code39", barcodeFormatName(Barcode.FORMAT_CODE_39))
        assertEquals("code93", barcodeFormatName(Barcode.FORMAT_CODE_93))
        assertEquals("codabar", barcodeFormatName(Barcode.FORMAT_CODABAR))
        // 必须静默的二维码制。
        assertEquals("qr", barcodeFormatName(Barcode.FORMAT_QR_CODE))
        assertEquals("dataMatrix", barcodeFormatName(Barcode.FORMAT_DATA_MATRIX))
        assertEquals("pdf417", barcodeFormatName(Barcode.FORMAT_PDF417))
        assertEquals("aztec", barcodeFormatName(Barcode.FORMAT_AZTEC))
        // 必须静默的商品码制。
        assertEquals("ean13", barcodeFormatName(Barcode.FORMAT_EAN_13))
        assertEquals("ean8", barcodeFormatName(Barcode.FORMAT_EAN_8))
        assertEquals("upca", barcodeFormatName(Barcode.FORMAT_UPC_A))
        assertEquals("upce", barcodeFormatName(Barcode.FORMAT_UPC_E))
        assertEquals("itf", barcodeFormatName(Barcode.FORMAT_ITF))
    }
}
