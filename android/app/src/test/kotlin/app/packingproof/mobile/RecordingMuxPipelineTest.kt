package app.packingproof.mobile

import android.media.MediaCodec
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingMuxPipelineTest {
    @Test
    fun `分段只在关键帧边界切换并按边界分配 pending 音频`() {
        val events = mutableListOf<String>()
        val pipeline = pipeline(events)
        pipeline.beginRecording()
        pipeline.openSegment("first.mp4", 1_000_000L, 10_000L, 0, true)
        pipeline.acceptAudio(audio(100_000L), true, true, false)
        pipeline.beginSplit()
        pipeline.acceptAudio(audio(1_099_999L), true, true, true)
        pipeline.acceptAudio(audio(1_100_000L), true, true, true)

        val rotation = pipeline.rotateAtKeyFrame(
            "second.mp4",
            ByteBuffer.wrap(byteArrayOf(1)),
            2_000_000L,
            MediaCodec.BUFFER_FLAG_KEY_FRAME,
            0,
            true,
        )

        assertEquals(
            listOf(
                "open:first.mp4",
                "audio:first.mp4:0",
                "audio:first.mp4:999999",
                "close:first.mp4:false",
                "open:second.mp4",
                "audio:second.mp4:0",
                "video:second.mp4:0:${MediaCodec.BUFFER_FLAG_KEY_FRAME}",
            ),
            events,
        )
        assertEquals("first.mp4", rotation.completedPath)
        assertEquals("second.mp4", rotation.nextPath)
        assertEquals(10_000L, rotation.completedStartedAtMs)
        assertEquals(11_000L, rotation.boundaryAtMs)
    }

    @Test
    fun `开始前音频保留且停止时先清空 pending 再关闭 muxer`() {
        val events = mutableListOf<String>()
        val pipeline = pipeline(events)
        pipeline.beginRecording()
        pipeline.acceptAudio(audio(50_000L), true, false, false)
        pipeline.openSegment("only.mp4", 5_000_000L, 20_000L, 0, true)
        pipeline.flushPendingAudio()
        pipeline.acceptAudio(audio(50_100L), true, true, true)

        val summary = pipeline.finishStop(99_000L)

        assertEquals(
            listOf(
                "open:only.mp4",
                "audio:only.mp4:0",
                "audio:only.mp4:100",
                "close:only.mp4:false",
            ),
            events,
        )
        assertEquals("only.mp4", summary.path)
        assertEquals(20_000L, summary.startedAtMs)
        assertEquals(20_000L, summary.endedAtMs)
        assertFalse(pipeline.hasActiveMuxer)
    }

    @Test
    fun `未请求录像时丢弃音频且新 split 清除旧 pending`() {
        val events = mutableListOf<String>()
        val pipeline = pipeline(events)
        pipeline.beginRecording()
        pipeline.acceptAudio(audio(1L), false, false, false)
        pipeline.acceptAudio(audio(2L), true, false, false)
        pipeline.beginSplit()
        pipeline.openSegment("only.mp4", 10L, 1_000L, 0, true)
        pipeline.flushPendingAudio()

        assertEquals(listOf("open:only.mp4"), events)
    }

    @Test
    fun `framework muxer 即使 stop 失败也按 stop 后 release 的顺序释放`() {
        val events = mutableListOf<String>()
        val muxer = FrameworkSegmentMuxer(
            backend = object : FrameworkMuxerBackend {
                override fun writeSampleData(
                    track: Int,
                    buffer: ByteBuffer,
                    info: MediaCodec.BufferInfo,
                ) = Unit

                override fun stop() {
                    events += "stop"
                    error("stop failed")
                }

                override fun release() {
                    events += "release"
                }
            },
            path = "unused.mp4",
            videoTrack = 0,
            audioTrack = 1,
            elapsedRealtimeMs = { 0L },
            onWriteCompleted = {},
        )

        val failed = runCatching { muxer.close(deleteOutput = false) }.isFailure

        assertTrue(failed)
        assertEquals(listOf("stop", "release"), events)
    }

    private fun pipeline(events: MutableList<String>): RecordingMuxPipeline =
        RecordingMuxPipeline(
            muxerFactory = SegmentMuxerFactory { path, _, _ ->
                events += "open:$path"
                object : SegmentMuxer {
                    override fun writeVideo(
                        buffer: ByteBuffer,
                        presentationTimeUs: Long,
                        flags: Int,
                    ) {
                        events += "video:$path:$presentationTimeUs:$flags"
                    }

                    override fun writeAudio(
                        sample: EncodedMuxSample,
                        presentationTimeUs: Long,
                    ) {
                        events += "audio:$path:$presentationTimeUs"
                    }

                    override fun close(deleteOutput: Boolean) {
                        events += "close:$path:$deleteOutput"
                    }
                }
            },
        )

    private fun audio(presentationTimeUs: Long): EncodedMuxSample =
        EncodedMuxSample(byteArrayOf(1), presentationTimeUs, 0)
}
