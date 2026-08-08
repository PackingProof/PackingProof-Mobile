package app.packingproof.mobile

/**
 * 录像编码选择策略。
 *
 * 鸿蒙/华为等部分机型虽然声明支持 H.265 解码，但 ExoPlayer 在应用内
 * 播放 H.265 时仍可能失败或黑屏，而系统播放器可以正常播放
 * （参考 flutter/flutter#163420、androidx/media#2711/#2765）。
 * 这类机型自动优先 H.264，保证 App 内可以直接回放新录像。
 */
internal class RecordingCodecPolicy(
    private val manufacturer: String,
) {
    fun preferH264OverHevc(): Boolean {
        val normalized = manufacturer.trim().uppercase()
        return normalized == "HUAWEI" || normalized == "HONOR"
    }

    companion object {
        const val FALLBACK_NO_HEVC_DECODER = "no_hevc_decoder"
        const val FALLBACK_VENDOR_HEVC_RISK = "vendor_hevc_playback_risk"
    }
}
