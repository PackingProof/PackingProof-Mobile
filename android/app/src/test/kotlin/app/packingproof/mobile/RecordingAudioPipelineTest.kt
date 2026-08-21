package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class RecordingAudioPipelineTest {
    @Test
    fun `输入 PTS 使用单一纳秒基准和已提交 PCM 帧数`() {
        val clock = AudioInputFrameClock(
            basePtsUs = 1_000_000L,
            sampleRate = 48_000,
            channelCount = 1,
        )

        assertEquals(1_000_000L, clock.nextInputPtsUs())
        clock.advance(96_000)
        assertEquals(2_000_000L, clock.nextInputPtsUs())
        clock.advance(4_800)
        assertEquals(2_050_000L, clock.nextInputPtsUs())
    }

    @Test
    fun `双声道 PCM 字节数按通道数换算提交帧数`() {
        val clock = AudioInputFrameClock(
            basePtsUs = 500L,
            sampleRate = 1_000,
            channelCount = 2,
        )

        clock.advance(400)

        assertEquals(100_500L, clock.nextInputPtsUs())
    }

    @Test
    fun `资源始终按 recorder stop release 再 encoder stop release 清理`() {
        val events = mutableListOf<String>()

        releaseRecordingAudioResources(
            stopRecorder = {
                events += "recorder.stop"
                error("already stopped")
            },
            releaseRecorder = { events += "recorder.release" },
            afterRecorderRelease = { events += "recorder.clear" },
            stopEncoder = {
                events += "encoder.stop"
                error("codec failed")
            },
            releaseEncoder = { events += "encoder.release" },
        )

        assertEquals(
            listOf(
                "recorder.stop",
                "recorder.release",
                "recorder.clear",
                "encoder.stop",
                "encoder.release",
            ),
            events,
        )
    }

    @Test
    fun `禁用录音时不创建 worker`() {
        val pipeline = RecordingAudioPipeline(
            onSample = {},
            onOutputFormat = {},
            onFailure = {},
            onStopped = {},
        )

        pipeline.start(enabled = false)
        pipeline.stop()

        assertFalse(pipeline.hasActiveThread)
    }
}
