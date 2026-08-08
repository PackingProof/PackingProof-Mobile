package app.packingproof.mobile

/**
 * 录像请求的 FPS 范围策略。
 *
 * 仅在真正录像时设置 CONTROL_AE_TARGET_FPS_RANGE；预览阶段不写 FPS 范围，
 * 避免固定 min=max 帧率限制自动曝光，导致部分设备预览变暗或异常
 * （参考 flutter/packages#8891、flutter/flutter#165491）。
 */
internal class RecordingFpsRangePolicy(
    private val targetFps: Int,
) {
    fun choose(ranges: List<Pair<Int, Int>>?): Pair<Int, Int>? {
        val available = ranges ?: return null
        return available.firstOrNull { it.first == targetFps && it.second == targetFps }
            ?: available.filter { it.first <= targetFps && it.second >= targetFps }
                .minByOrNull { it.second - it.first }
            ?: available.minByOrNull {
                kotlin.math.abs(it.second - targetFps) + kotlin.math.abs(it.first - targetFps)
            }
    }
}
