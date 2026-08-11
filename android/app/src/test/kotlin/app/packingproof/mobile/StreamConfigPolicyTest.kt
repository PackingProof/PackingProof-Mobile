package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class StreamConfigPolicyTest {
    private val policy = StreamConfigPolicy(preferredVideoWidth = 1920, preferredVideoHeight = 1080)

    @Test
    fun `视频候选优先设定档位再保底720p`() {
        val sizes = listOf(
            StreamSize(640, 480),
            StreamSize(1280, 720),
            StreamSize(1920, 1080),
            StreamSize(3840, 2160),
        )
        assertEquals(
            listOf(
                StreamSize(1920, 1080),
                StreamSize(1280, 720),
                StreamSize(640, 480),
            ),
            policy.videoCandidates(sizes),
        )
    }

    @Test
    fun `视频候选为空时回退设定档位`() {
        assertEquals(
            listOf(StreamSize(1920, 1080)),
            policy.videoCandidates(emptyList()),
        )
    }

    @Test
    fun `识别候选优先960x540再降级到640x480`() {
        val sizes = listOf(
            StreamSize(320, 240),
            StreamSize(640, 480),
            StreamSize(960, 540),
            StreamSize(1280, 720),
        )
        assertEquals(
            listOf(
                StreamSize(960, 540),
                StreamSize(640, 480),
                StreamSize(320, 240),
            ),
            policy.analysisCandidates(sizes),
        )
    }

    @Test
    fun `录像候选包含全部三路组合且按视频优先排序`() {
        val candidates = policy.threeSurfaceCandidates(
            videoSizes = listOf(StreamSize(1920, 1080), StreamSize(1280, 720)),
            analysisSizes = listOf(StreamSize(960, 540), StreamSize(640, 480)),
        )
        assertEquals(
            listOf(
                StreamConfig(1920, 1080, 960, 540, includeEncoder = true),
                StreamConfig(1920, 1080, 640, 480, includeEncoder = true),
                StreamConfig(1280, 720, 960, 540, includeEncoder = true),
                StreamConfig(1280, 720, 640, 480, includeEncoder = true),
            ),
            candidates,
        )
        assertEquals("3_1920x1080_960x540", candidates.first().label)
    }

    @Test
    fun `初始化候选只包含预览加识别两路并按视频优先排序`() {
        val candidates = policy.initializationCandidates(
            videoSizes = listOf(StreamSize(1920, 1080), StreamSize(1280, 720)),
            analysisSizes = listOf(StreamSize(960, 540), StreamSize(640, 480)),
        )
        assertEquals(
            listOf(
                StreamConfig(1920, 1080, 960, 540, includeEncoder = false),
                StreamConfig(1920, 1080, 640, 480, includeEncoder = false),
                StreamConfig(1280, 720, 960, 540, includeEncoder = false),
                StreamConfig(1280, 720, 640, 480, includeEncoder = false),
            ),
            candidates,
        )
        assertEquals(false, candidates.first().includeEncoder)
        assertEquals("2_1920x1080_960x540", candidates.first().label)
    }
}
