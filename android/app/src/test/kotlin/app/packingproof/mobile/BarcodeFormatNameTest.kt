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
}
