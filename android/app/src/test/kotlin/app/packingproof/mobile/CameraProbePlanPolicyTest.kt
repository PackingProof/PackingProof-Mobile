package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraProbePlanPolicyTest {
    private val streamConfigPolicy = StreamConfigPolicy(
        preferredVideoWidth = 1920,
        preferredVideoHeight = 1080,
    )

    @Test
    fun `初始化探针使用首选尺寸并按既有顺序生成降级组合`() {
        val video = StreamSize(1920, 1080)
        val analysis = StreamSize(960, 540)
        val smallerAnalysis = StreamSize(640, 480)

        assertEquals(
            listOf(
                ProbeConfig("preview_only", video, null, includeEncoder = false),
                ProbeConfig("preview_analysis", video, analysis, includeEncoder = false),
                ProbeConfig(
                    "preview_analysis_small",
                    video,
                    smallerAnalysis,
                    includeEncoder = false,
                ),
                ProbeConfig(
                    "preview_encoder_analysis_small",
                    video,
                    smallerAnalysis,
                    includeEncoder = true,
                ),
            ),
            CameraProbePlanPolicy.initializationConfigs(
                videoCandidates = listOf(video, StreamSize(1280, 720)),
                analysisCandidates = listOf(analysis, smallerAnalysis, StreamSize(320, 240)),
            ),
        )
    }

    @Test
    fun `初始化探针缺少任一尺寸列表时不生成组合`() {
        assertEquals(
            emptyList<ProbeConfig>(),
            CameraProbePlanPolicy.initializationConfigs(emptyList(), listOf(StreamSize(960, 540))),
        )
        assertEquals(
            emptyList<ProbeConfig>(),
            CameraProbePlanPolicy.initializationConfigs(listOf(StreamSize(1920, 1080)), emptyList()),
        )
    }

    @Test
    fun `能力探针只接受三个协议序列`() {
        assertTrue(CameraProbePlanPolicy.supportsCapabilitySequence("full"))
        assertTrue(CameraProbePlanPolicy.supportsCapabilitySequence("encoder_analysis"))
        assertTrue(CameraProbePlanPolicy.supportsCapabilitySequence("alternating"))
        assertFalse(CameraProbePlanPolicy.supportsCapabilitySequence("FULL"))
        assertFalse(CameraProbePlanPolicy.supportsCapabilitySequence("unknown"))
    }

    @Test
    fun `能力探针保持闲置录像交替五阶段`() {
        assertEquals(
            listOf(
                "idle" to ProbePhaseKind.IDLE,
                "record" to ProbePhaseKind.RECORD_ENCODER_ANALYSIS,
                "idle" to ProbePhaseKind.IDLE,
                "record" to ProbePhaseKind.RECORD_ENCODER_ANALYSIS,
                "idle" to ProbePhaseKind.IDLE,
            ),
            CameraProbePlanPolicy.capabilitySpecs("encoder_analysis"),
        )
    }

    @Test
    fun `完整录像探针保留候选顺序并限制为四组`() {
        val configs = CameraProbePlanPolicy.capabilityConfigs(
            kind = ProbePhaseKind.RECORD_FULL,
            streamConfigPolicy = streamConfigPolicy,
            videoCandidates = listOf(StreamSize(1920, 1080), StreamSize(1280, 720)),
            analysisCandidates = listOf(
                StreamSize(960, 540),
                StreamSize(640, 480),
                StreamSize(320, 240),
            ),
            alternatingAnalysisSize = StreamSize(960, 540),
        )

        assertEquals(4, configs.size)
        assertEquals(
            listOf(
                "3_1920x1080_960x540",
                "3_1920x1080_640x480",
                "3_1920x1080_320x240",
                "3_1280x720_960x540",
            ),
            configs.map { it.candidateLabel },
        )
        assertTrue(ProbePhaseKind.RECORD_FULL.includePreview)
        assertTrue(ProbePhaseKind.RECORD_FULL.includeAnalysis)
        assertTrue(ProbePhaseKind.RECORD_FULL.includeEncoder)
    }

    @Test
    fun `轮换录像探针只保留预览和编码器尺寸`() {
        val configs = CameraProbePlanPolicy.capabilityConfigs(
            kind = ProbePhaseKind.RECORD_ALTERNATING,
            streamConfigPolicy = streamConfigPolicy,
            videoCandidates = listOf(
                StreamSize(1920, 1080),
                StreamSize(1280, 720),
                StreamSize(640, 480),
            ),
            analysisCandidates = listOf(StreamSize(960, 540)),
            alternatingAnalysisSize = StreamSize(960, 540),
        )

        assertEquals(listOf("1920x1080", "1280x720"), configs.map { it.candidateLabel })
        assertTrue(configs.all { it.analysisWidth == null && it.analysisHeight == null })
        assertTrue(ProbePhaseKind.RECORD_ALTERNATING.includePreview)
        assertFalse(ProbePhaseKind.RECORD_ALTERNATING.includeAnalysis)
        assertTrue(ProbePhaseKind.RECORD_ALTERNATING.includeEncoder)
    }
}
