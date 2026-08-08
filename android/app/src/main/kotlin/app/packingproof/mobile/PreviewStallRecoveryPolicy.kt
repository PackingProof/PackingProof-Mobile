package app.packingproof.mobile

internal enum class PreviewStallRecoveryAction {
    NONE,
    REAPPLY_REQUEST,
    RECREATE_SESSION,
    LOG_FAILURE,
}

/**
 * 预览停滞时的恢复策略。
 *
 * 仅在未录像时允许自动恢复，避免打断正在写入的文件；先重发当前
 * 重复请求，仍无帧再重建捕获会话。
 */
internal class PreviewStallRecoveryPolicy {
    fun nextAction(
        stage: Int,
        recording: Boolean,
        stallActive: Boolean,
    ): PreviewStallRecoveryAction {
        if (!stallActive || recording) return PreviewStallRecoveryAction.NONE
        return when (stage) {
            0 -> PreviewStallRecoveryAction.REAPPLY_REQUEST
            1 -> PreviewStallRecoveryAction.RECREATE_SESSION
            else -> PreviewStallRecoveryAction.LOG_FAILURE
        }
    }
}
