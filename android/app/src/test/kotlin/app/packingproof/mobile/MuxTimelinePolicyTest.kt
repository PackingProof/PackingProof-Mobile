package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MuxTimelinePolicyTest {
    private val timeline = MuxTimelinePolicy()

    @Test
    fun `视频时间戳按分段基点归零并保持严格递增`() {
        timeline.beginRecording()
        timeline.openSegment(basePtsUs = 1_000_000L)

        assertEquals(100L, timeline.videoPtsUs(1_000_100L))
        assertEquals(101L, timeline.videoPtsUs(1_000_100L))
        assertEquals(102L, timeline.videoPtsUs(999_000L))
    }

    @Test
    fun `首个音频样本对齐当前视频分段基点`() {
        timeline.beginRecording()
        timeline.openSegment(basePtsUs = 1_000_000L)

        assertEquals(1_000_000L, timeline.audioSourcePtsUs(50_000L))
        assertEquals(0L, timeline.audioPtsUs(50_000L))
        assertEquals(1L, timeline.audioPtsUs(50_000L))
    }

    @Test
    fun `切换分段保留音视频时钟偏移并重置轨道时间戳`() {
        timeline.beginRecording()
        timeline.openSegment(basePtsUs = 1_000_000L)
        assertEquals(0L, timeline.audioPtsUs(100_000L))

        timeline.openSegment(basePtsUs = 2_000_000L)

        assertEquals(2_000_000L, timeline.audioSourcePtsUs(1_100_000L))
        assertEquals(0L, timeline.audioPtsUs(1_100_000L))
        assertEquals(0L, timeline.videoPtsUs(2_000_000L))
    }

    @Test
    fun `早于当前分段的音频样本不生成轨道时间戳`() {
        timeline.beginRecording()
        timeline.openSegment(basePtsUs = 1_000_000L)
        timeline.audioSourcePtsUs(100_000L)
        timeline.openSegment(basePtsUs = 2_000_000L)

        assertNull(timeline.audioPtsUs(1_099_999L))
        assertEquals(0L, timeline.audioPtsUs(1_100_000L))
    }

    @Test
    fun `分段边界时间不早于当前段开始时间`() {
        timeline.openSegment(basePtsUs = 2_000_000L)

        assertEquals(5_000L, timeline.boundaryAtMs(5_000L, 1_999_000L))
        assertEquals(5_250L, timeline.boundaryAtMs(5_000L, 2_250_000L))
    }

    @Test
    fun `结束时间使用当前段收到的最大源时间戳`() {
        timeline.openSegment(basePtsUs = 2_000_000L)
        assertEquals(5_000L, timeline.endedAtMs(5_000L, fallbackNowMs = 9_000L))

        timeline.videoPtsUs(2_400_000L)
        timeline.videoPtsUs(2_100_000L)

        assertEquals(5_400L, timeline.endedAtMs(5_000L, fallbackNowMs = 9_000L))
    }
}
