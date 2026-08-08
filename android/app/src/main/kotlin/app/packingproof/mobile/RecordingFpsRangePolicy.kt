package app.packingproof.mobile

/**
 * 录像请求的 FPS 范围策略。
 *
 * 仅在真正录像时设置 CONTROL_AE_TARGET_FPS_RANGE；预览阶段不写 FPS 范围，
 * 避免固定 min=max 帧率限制自动曝光，导致部分设备预览变暗或异常
 * （参考 flutter/packages#8891、flutter/flutter#165491）。
 *
 * 录像阶段同样避免选择 min=max 的固定范围：固定范围会把自动曝光锁死在
 * 短曝光时间上，扫码识别后开始录像时画面会突然变暗。这里参照 CameraX
 * AeFpsRangeLegacyQuirk 的做法，优先选择“上界等于目标帧率、下限最低”
 * 的范围，既保证录像帧率上限，又允许暗光环境下降帧拉长曝光
 * （参考 flutter/flutter#179469）。
 */
internal class RecordingFpsRangePolicy(
    private val targetFps: Int,
) {
    fun choose(ranges: List<Pair<Int, Int>>?): Pair<Int, Int>? {
        val available = ranges ?: return null
        val upperFixed = available.filter { it.second == targetFps }
        if (upperFixed.isNotEmpty()) {
            return upperFixed.minByOrNull { it.first }
        }
        val containing = available.filter {
            it.first <= targetFps && it.second >= targetFps
        }
        if (containing.isNotEmpty()) {
            return containing.minByOrNull { it.first }
        }
        return available.minByOrNull {
            kotlin.math.abs(it.second - targetFps) + kotlin.math.abs(it.first - targetFps)
        }
    }
}
