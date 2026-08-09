package app.packingproof.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingCodecPolicyTest {
    @Test
    fun `华为与荣耀 API 30 以上播放端优先软件解码`() {
        assertTrue(
            RecordingCodecPolicy("HUAWEI", sdkInt = 31)
                .forceSoftwareDecoderPreferenceForPlayback(),
        )
        assertTrue(
            RecordingCodecPolicy("huawei", sdkInt = 30)
                .forceSoftwareDecoderPreferenceForPlayback(),
        )
        assertTrue(
            RecordingCodecPolicy("HONOR", sdkInt = 31)
                .forceSoftwareDecoderPreferenceForPlayback(),
        )
        assertTrue(
            RecordingCodecPolicy(" Honor ", sdkInt = 32)
                .forceSoftwareDecoderPreferenceForPlayback(),
        )
    }

    @Test
    fun `API 29 及以下或其他机型不强制软件解码`() {
        assertFalse(
            RecordingCodecPolicy("HUAWEI", sdkInt = 29)
                .forceSoftwareDecoderPreferenceForPlayback(),
        )
        assertFalse(
            RecordingCodecPolicy("HONOR", sdkInt = 29)
                .forceSoftwareDecoderPreferenceForPlayback(),
        )
        assertFalse(
            RecordingCodecPolicy("vivo", sdkInt = 34)
                .forceSoftwareDecoderPreferenceForPlayback(),
        )
        assertFalse(
            RecordingCodecPolicy("", sdkInt = 34)
                .forceSoftwareDecoderPreferenceForPlayback(),
        )
    }
}
