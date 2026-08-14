package app.packingproof.mobile

/**
 * 摄像头工作能力模式。
 *
 * FULL：预览 + 识别 + 录像三路持续可用。
 * ENCODER_ANALYSIS：录像时使用“编码器 + 识别”两路，预览画面暂停。
 * ALTERNATING：录像时使用“预览 + 编码器”两路，识别关闭，录完一单后
 * 由用户点击“完成本单”恢复识别。
 * UNSUPPORTED：连“预览 + 识别”待机会话都无法持续出帧。
 * UNVERIFIED：尚未完成有效探测（探针自身失败或缺少缓存），沿用现有
 * 三路 + 运行时降级行为，并保留旧版持久化降级兼容。
 */
internal enum class CameraCapabilityMode {
    FULL,
    ENCODER_ANALYSIS,
    ALTERNATING,
    UNSUPPORTED,
    UNVERIFIED,
    ;

    companion object {
        fun fromWire(value: String?): CameraCapabilityMode = when (value?.trim()?.lowercase()) {
            "full" -> FULL
            "encoder_analysis" -> ENCODER_ANALYSIS
            "alternating" -> ALTERNATING
            "unsupported" -> UNSUPPORTED
            else -> UNVERIFIED
        }
    }
}
