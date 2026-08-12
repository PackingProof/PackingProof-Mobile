package app.packingproof.mobile

import kotlin.math.abs
import kotlin.math.roundToInt

data class BackLensEntry(
    val cameraId: String,
    val focalLength: Float,
    val sensorWidthMm: Float,
)

/**
 * 后置镜头目录：按物理焦距排序、去重并换算相对主摄的变焦倍数。
 * 主摄取焦距最接近 4.5mm 的镜头；倍率按 35mm 等效焦距计算，
 * 超广角优先使用系统逻辑后摄的最小变焦档（如 0.7x），长焦吸附到常见的 0.5 步进（如 5x）。
 */
data class BackLensInfo(
    val cameraId: String,
    val focalLength: Float,
    val zoomRatio: Double,
    val isMain: Boolean,
)

object BackLensCatalog {
    const val MAIN_FOCAL_REFERENCE_MM = 4.5f
    const val DUPLICATE_FOCAL_TOLERANCE = 0.05f
    const val FULL_FRAME_WIDTH_MM = 36f

    fun build(
        entries: List<BackLensEntry>,
        mainCameraId: String? = null,
        wideZoomRatio: Double? = null,
    ): List<BackLensInfo> {
        val valid = entries.filter {
            it.focalLength > 0f && it.sensorWidthMm > 0f
        }
        val deduped = ArrayList<BackLensEntry>()
        for (entry in valid) {
            val duplicate = deduped.any {
                abs(it.focalLength - entry.focalLength) /
                    maxOf(it.focalLength, entry.focalLength) <=
                DUPLICATE_FOCAL_TOLERANCE
            }
            if (!duplicate) {
                deduped.add(entry)
            }
        }
        if (deduped.isEmpty()) return emptyList()
        val main = mainCameraId
            ?.let { id -> deduped.firstOrNull { it.cameraId == id } }
            ?: deduped.minByOrNull {
                abs(it.focalLength - MAIN_FOCAL_REFERENCE_MM)
            }
            ?: return emptyList()
        val mainEquivalent: Double =
            main.focalLength.toDouble() *
            FULL_FRAME_WIDTH_MM /
            main.sensorWidthMm
        return deduped
            .sortedBy { it.focalLength }
            .map { entry ->
                val equivalent: Double =
                    entry.focalLength.toDouble() *
                    FULL_FRAME_WIDTH_MM /
                    entry.sensorWidthMm
                val rawRatio = equivalent / mainEquivalent
                val zoomRatio = when {
                    entry.cameraId == main.cameraId -> 1.0
                    rawRatio < 1.0 -> wideZoomRatio ?: roundToOneDecimal(rawRatio)
                    else -> snapToHalfStep(rawRatio)
                }
                BackLensInfo(
                    cameraId = entry.cameraId,
                    focalLength = entry.focalLength,
                    zoomRatio = zoomRatio,
                    isMain = entry.cameraId == main.cameraId,
                )
            }
    }

    private fun roundToOneDecimal(value: Double): Double =
        (value * 10.0).roundToInt() / 10.0

    private fun snapToHalfStep(value: Double): Double {
        val snapped = (value * 2.0).roundToInt() / 2.0
        return if (snapped < 1.0) 1.0 else snapped
    }
}
