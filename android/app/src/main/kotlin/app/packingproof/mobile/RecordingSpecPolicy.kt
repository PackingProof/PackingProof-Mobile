package app.packingproof.mobile

/**
 * 录制清晰度规格策略。默认保持高清档，未知值一律回退到高清档。
 */
internal data class RecordingSpec(
    val videoWidth: Int,
    val videoHeight: Int,
    val fps: Int,
    val avcBitRate: Int,
    val hevcBitRate: Int,
)

internal object RecordingSpecPolicy {
    const val DEFAULT_SPEC_NAME = "hd1080p30"
    const val SMOOTH_SPEC_NAME = "smooth720p30"

    val HD = RecordingSpec(
        videoWidth = 1920,
        videoHeight = 1080,
        fps = 30,
        avcBitRate = 10_000_000,
        hevcBitRate = 7_000_000,
    )
    val SMOOTH = RecordingSpec(
        videoWidth = 1280,
        videoHeight = 720,
        fps = 30,
        avcBitRate = 6_000_000,
        hevcBitRate = 4_500_000,
    )

    fun resolveName(name: String?): String =
        if (name?.trim()?.lowercase() in setOf(SMOOTH_SPEC_NAME, "720p30", "smooth")) {
            SMOOTH_SPEC_NAME
        } else {
            DEFAULT_SPEC_NAME
        }

    fun resolve(name: String?): RecordingSpec =
        if (resolveName(name) == SMOOTH_SPEC_NAME) SMOOTH else HD
}
