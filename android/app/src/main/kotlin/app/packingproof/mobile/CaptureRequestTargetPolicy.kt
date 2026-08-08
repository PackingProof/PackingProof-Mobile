package app.packingproof.mobile

/**
 * 摄像头重复请求的目标集策略。
 *
 * 预览与分析表面必须从会话建立起保持常开：中途把识别流加入正在运行的
 * 重复请求在部分机型（如 vivo、Android 16）会导致预览停止出帧。编码器
 * 表面只在真正录像时加入，空闲时保持挂起以降低功耗。
 */
internal data class CaptureRequestTargets(
    val includeAnalysis: Boolean,
    val includeEncoder: Boolean,
)

internal class CaptureRequestTargetPolicy {
    fun targets(
        recordingRequested: Boolean,
        recordingActive: Boolean,
    ): CaptureRequestTargets = CaptureRequestTargets(
        includeAnalysis = true,
        includeEncoder = recordingRequested || recordingActive,
    )
}
