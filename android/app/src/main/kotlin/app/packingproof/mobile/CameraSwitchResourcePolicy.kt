package app.packingproof.mobile

object CameraSwitchResourcePolicy {
    /**
     * 切换镜头是否可以立刻执行。
     *
     * 面单识别（待机扫码）不参与判定：预览与识别表面本来就常开，会话重建会
     * 一并重建识别流，切换后识别状态继续有效。历史上把识别开启当成忙碌状态，
     * 导致待机扫码开启后每次切换都被拒绝并回落到主摄。
     */
    fun canSwitch(
        initialized: Boolean,
        canSwitchCamera: Boolean,
        recordingRequested: Boolean,
        recordingActive: Boolean,
        segmentOperationPending: Boolean,
        pairingScanEnabled: Boolean,
    ): Boolean = initialized &&
        canSwitchCamera &&
        !recordingRequested &&
        !recordingActive &&
        !segmentOperationPending &&
        !pairingScanEnabled

    fun shouldRestartEncoder(
        previousWidth: Int,
        previousHeight: Int,
        nextWidth: Int,
        nextHeight: Int,
    ): Boolean = previousWidth != nextWidth || previousHeight != nextHeight
}
