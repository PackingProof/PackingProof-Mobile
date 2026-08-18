package app.packingproof.mobile

object CameraSwitchResourcePolicy {
    fun shouldRestartEncoder(
        previousWidth: Int,
        previousHeight: Int,
        nextWidth: Int,
        nextHeight: Int,
    ): Boolean = previousWidth != nextWidth || previousHeight != nextHeight
}
