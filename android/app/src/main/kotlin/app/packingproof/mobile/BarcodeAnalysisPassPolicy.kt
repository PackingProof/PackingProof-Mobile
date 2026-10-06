package app.packingproof.mobile

/** 一次条码识别使用的输入通道：整帧，或按比例中心裁剪。 */
internal data class BarcodeAnalysisPass(
    val label: String,
    val cropScale: Double?,
)

/**
 * 超广角识别实验的通道编排。
 *
 * 主摄/长焦只跑整帧；超广角先跑整帧，整帧没有结果时再依次尝试中心裁剪，
 * 用于判断 ML Kit 在整帧输入上是否受到内部缩放影响。裁剪不会增加码元真实
 * 像素数，因此这里的结果只用于评估是否值得继续，不改变录像与预览。
 */
internal object BarcodeAnalysisPassPolicy {
    private val fullFrameOnly = listOf(
        BarcodeAnalysisPass(label = "full", cropScale = null),
    )
    private val ultraWide = listOf(
        BarcodeAnalysisPass(label = "full", cropScale = null),
        BarcodeAnalysisPass(label = "crop85", cropScale = 0.85),
        BarcodeAnalysisPass(label = "crop50", cropScale = 0.5),
    )

    fun passesForLens(zoomRatio: Double): List<BarcodeAnalysisPass> =
        if (zoomRatio < 1.0) ultraWide else fullFrameOnly

    fun shouldRunNextPass(
        passIndex: Int,
        passCount: Int,
        foundPreferredBarcode: Boolean,
    ): Boolean = !foundPreferredBarcode && passIndex < passCount - 1
}

/**
 * 面单码制判定：与 Dart `BarcodeCandidatePolicy.workScanFormats` 保持一致。
 *
 * 只有命中这些码制才停止超广角的中心裁剪回退，避免面单二维码先被识别后
 * 直接结束识别链、掩盖裁剪通道的效果。商品码与二维码仍会作为兜底结果
 * 上报，由 Dart 侧现有策略决定是否接受。
 */
internal object BarcodeAnalysisFormatPolicy {
    private val preferredFormats = setOf("code128", "code39", "code93", "codabar")

    fun isPreferredFormat(formatName: String?): Boolean =
        formatName != null && formatName in preferredFormats
}
