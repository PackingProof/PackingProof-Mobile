package app.packingproof.mobile

import android.os.Build

/**
 * 鸿蒙/华为机型播放兼容策略。
 *
 * 华为/荣耀 API 30+（HarmonyOS 3/4）机型的厂商硬解在应用内播放
 * AVC/HEVC 都可能失败（flutter/flutter#185674、#177912、#166481），
 * 因此播放端优先使用软件解码。录像编码不再按厂商强制 H.264，用户可
 * 自由选择；仅在设备完全没有 HEVC 解码器时才回退（见 CodecCapabilities）。
 */
internal class RecordingCodecPolicy(
    private val manufacturer: String,
    private val sdkInt: Int = Build.VERSION.SDK_INT,
) {
    fun forceSoftwareDecoderPreferenceForPlayback(): Boolean {
        val normalized = manufacturer.trim().uppercase()
        return (normalized == "HUAWEI" || normalized == "HONOR") && sdkInt >= 30
    }

    companion object {
        const val FALLBACK_NO_HEVC_DECODER = "no_hevc_decoder"
    }
}
