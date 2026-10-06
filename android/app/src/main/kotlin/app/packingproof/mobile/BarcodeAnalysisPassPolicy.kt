package app.packingproof.mobile

/** 一次条码识别使用的输入通道：按比例裁剪出的中心正方形。 */
internal data class BarcodeAnalysisPass(
    val label: String,
    val cropScale: Double?,
)

/**
 * 超广角识别实验的通道编排。
 *
 * 超广角只分析短边 70% 的中心正方形；主摄/长焦只分析短边 100% 的
 * 中心正方形（最大的居中正方形），都不再跑整帧。裁剪不会增加码元真实
 * 像素数，只影响 ML Kit 的输入范围与开销；Dart 侧识别框覆盖比例必须与
 * 这里的比例保持一致（见 lib/services/scan_guide_geometry.dart）。
 */
internal object BarcodeAnalysisPassPolicy {
    private const val ULTRA_WIDE_CROP_SCALE = 0.7
    private const val STANDARD_CROP_SCALE = 1.0

    fun passesForLens(zoomRatio: Double): List<BarcodeAnalysisPass> = listOf(
        if (zoomRatio < 1.0) {
            BarcodeAnalysisPass(label = "crop70", cropScale = ULTRA_WIDE_CROP_SCALE)
        } else {
            BarcodeAnalysisPass(label = "crop100", cropScale = STANDARD_CROP_SCALE)
        },
    )

    fun shouldRunNextPass(
        passIndex: Int,
        passCount: Int,
        foundPreferredBarcode: Boolean,
    ): Boolean = !foundPreferredBarcode && passIndex < passCount - 1

    /**
     * 识别间隔：默认 [standardMs]；发现候选码后进入提速窗口用 [boostMs]。
     * 与镜头无关，超广角、主摄、长焦共用同一套变速策略。
     */
    fun analysisIntervalMs(
        boosted: Boolean,
        standardMs: Long,
        boostMs: Long,
    ): Long = if (boosted) boostMs else standardMs
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
