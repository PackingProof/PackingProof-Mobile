package app.packingproof.mobile

import com.google.mlkit.vision.barcode.common.Barcode

/**
 * 识别帧的调度与结果校验策略：与相机会话状态无关的纯函数，
 * 供 ContinuousSegmentCamera 的识别回调与原生单测共用。
 */
internal fun shouldAnalyzeBarcodeFrame(
    previewActive: Boolean,
    pairingScanEnabled: Boolean,
    workScanEnabled: Boolean,
    scannerBusy: Boolean,
    elapsedSinceLastAnalysisMs: Long,
    analysisIntervalMs: Long,
): Boolean = previewActive &&
    (pairingScanEnabled || workScanEnabled) &&
    !scannerBusy &&
    elapsedSinceLastAnalysisMs >= analysisIntervalMs

internal fun shouldAcceptBarcodeAnalysisResult(
    resultGeneration: Long,
    activeGeneration: Long,
    previewActive: Boolean,
): Boolean = previewActive && resultGeneration == activeGeneration

internal fun barcodeFormatName(format: Int): String? = when (format) {
    Barcode.FORMAT_EAN_13 -> "ean13"
    Barcode.FORMAT_EAN_8 -> "ean8"
    Barcode.FORMAT_UPC_A -> "upca"
    Barcode.FORMAT_UPC_E -> "upce"
    Barcode.FORMAT_ITF -> "itf"
    Barcode.FORMAT_CODE_128 -> "code128"
    Barcode.FORMAT_CODE_39 -> "code39"
    Barcode.FORMAT_CODE_93 -> "code93"
    Barcode.FORMAT_CODABAR -> "codabar"
    Barcode.FORMAT_QR_CODE -> "qr"
    Barcode.FORMAT_DATA_MATRIX -> "dataMatrix"
    Barcode.FORMAT_PDF417 -> "pdf417"
    Barcode.FORMAT_AZTEC -> "aztec"
    else -> null
}
