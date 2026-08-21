package app.packingproof.mobile

import android.media.MediaCodecInfo
import android.media.MediaFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingVideoEncoderTest {
    @Test
    fun `HEVC 可解码时按首选编码再回退 AVC 两种 profile`() {
        val plan = VideoEncoderPlanPolicy.create(
            MediaFormat.MIMETYPE_VIDEO_HEVC,
            hevcDecodable = true,
        )

        assertNull(plan.fallbackReason)
        assertEquals(
            listOf(
                VideoEncoderCandidate(
                    MediaFormat.MIMETYPE_VIDEO_HEVC,
                    useAvcMainProfile = false,
                ),
                VideoEncoderCandidate(
                    MediaFormat.MIMETYPE_VIDEO_AVC,
                    useAvcMainProfile = true,
                ),
                VideoEncoderCandidate(
                    MediaFormat.MIMETYPE_VIDEO_AVC,
                    useAvcMainProfile = false,
                ),
            ),
            plan.candidates,
        )
    }

    @Test
    fun `缺少 HEVC 解码器时直接回退 AVC 并保留原因`() {
        val plan = VideoEncoderPlanPolicy.create(
            MediaFormat.MIMETYPE_VIDEO_HEVC,
            hevcDecodable = false,
        )

        assertEquals(RecordingCodecPolicy.FALLBACK_NO_HEVC_DECODER, plan.fallbackReason)
        assertEquals(
            listOf(true, false),
            plan.candidates.map(VideoEncoderCandidate::useAvcMainProfile),
        )
        assertTrue(plan.candidates.all { it.mime == MediaFormat.MIMETYPE_VIDEO_AVC })
    }

    @Test
    fun `AVC 首选仍先尝试 Main profile 再尝试默认 profile`() {
        val plan = VideoEncoderPlanPolicy.create(
            MediaFormat.MIMETYPE_VIDEO_AVC,
            hevcDecodable = true,
        )

        assertNull(plan.fallbackReason)
        assertEquals(MediaFormat.MIMETYPE_VIDEO_AVC, plan.candidates[0].mime)
        assertTrue(plan.candidates[0].useAvcMainProfile)
        assertFalse(plan.candidates[1].useAvcMainProfile)
        assertEquals(MediaFormat.MIMETYPE_VIDEO_HEVC, plan.candidates[2].mime)
    }

    @Test
    fun `格式策略保留规格码率 VBR 关键帧间隔与 B frame 门槛`() {
        val spec = RecordingSpecPolicy.HD
        val avc = VideoEncoderFormatPolicy.create(
            MediaFormat.MIMETYPE_VIDEO_AVC,
            spec,
            sdkInt = 28,
        )
        val hevc = VideoEncoderFormatPolicy.create(
            MediaFormat.MIMETYPE_VIDEO_HEVC,
            spec,
            sdkInt = 29,
        )

        assertEquals(spec.avcBitRate, avc.bitRate)
        assertEquals(spec.hevcBitRate, hevc.bitRate)
        assertEquals(spec.fps, hevc.framesPerSecond)
        assertEquals(1, hevc.iFrameIntervalSeconds)
        assertEquals(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR, hevc.bitRateMode)
        assertFalse(avc.disableBFrames)
        assertTrue(hevc.disableBFrames)
    }

    @Test
    fun `释放顺序固定为 codec stop release 再释放 surface`() {
        val events = mutableListOf<String>()

        releaseRecordingVideoEncoderResources(
            stopCodec = {
                events += "codec.stop"
                error("already stopped")
            },
            releaseCodec = {
                events += "codec.release"
                error("release failed")
            },
            afterCodecRelease = { events += "codec.clear" },
            releaseSurface = { events += "surface.release" },
            afterSurfaceRelease = { events += "surface.clear" },
        )

        assertEquals(
            listOf(
                "codec.stop",
                "codec.release",
                "codec.clear",
                "surface.release",
                "surface.clear",
            ),
            events,
        )
    }
}
