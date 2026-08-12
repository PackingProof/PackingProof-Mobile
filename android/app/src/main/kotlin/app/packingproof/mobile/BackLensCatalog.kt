package app.packingproof.mobile

import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * 后置镜头目录：按物理焦距排序、去重并换算相对主摄的变焦倍数。
 * 主摄取焦距最接近 4.5mm 的镜头；Android 不提供镜头文本标签，只提供焦距数字。
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

    fun build(
        entries: List<Pair<String, Float>>,
        mainCameraId: String? = null,
    ): List<BackLensInfo> {
        val valid = entries.filter { it.second > 0f }
        val deduped = ArrayList<Pair<String, Float>>()
        for (entry in valid) {
            val duplicate = deduped.any {
                abs(it.second - entry.second) /
                    maxOf(it.second, entry.second) <= DUPLICATE_FOCAL_TOLERANCE
            }
            if (!duplicate) {
                deduped.add(entry)
            }
        }
        if (deduped.isEmpty()) return emptyList()
        val main = mainCameraId
            ?.let { id -> deduped.firstOrNull { it.first == id } }
            ?: deduped.minByOrNull {
                abs(it.second - MAIN_FOCAL_REFERENCE_MM)
            }
            ?: return emptyList()
        return deduped
            .sortedBy { it.second }
            .map { entry ->
                val rawRatio: Double =
                    if (main.second > 0f) {
                        entry.second.toDouble() / main.second.toDouble()
                    } else {
                        1.0
                    }
                BackLensInfo(
                    cameraId = entry.first,
                    focalLength = entry.second,
                    zoomRatio = (rawRatio * 10.0).roundToInt() / 10.0,
                    isMain = entry.first == main.first,
                )
            }
    }
}
