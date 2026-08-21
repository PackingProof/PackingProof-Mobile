package app.packingproof.mobile

internal data class ProbeConfig(
    val name: String,
    val videoSize: StreamSize,
    val analysisSize: StreamSize?,
    val includeEncoder: Boolean,
)

internal enum class ProbePhaseKind(
    val includePreview: Boolean,
    val includeAnalysis: Boolean,
    val includeEncoder: Boolean,
) {
    IDLE(true, true, false),
    RECORD_FULL(true, true, true),
    RECORD_ENCODER_ANALYSIS(false, true, true),
    RECORD_ALTERNATING(true, false, true),
}

internal data class ProbeStreamConfig(
    val videoWidth: Int,
    val videoHeight: Int,
    val analysisWidth: Int?,
    val analysisHeight: Int?,
    val candidateLabel: String,
)

/** 纯 JVM 可测的 Camera2 初始化与持续出帧能力探针计划。 */
internal object CameraProbePlanPolicy {
    private const val MAX_CAPABILITY_CANDIDATES = 4
    private val supportedCapabilitySequences = setOf(
        "full",
        "encoder_analysis",
        "alternating",
    )

    fun supportsCapabilitySequence(sequence: String): Boolean =
        sequence in supportedCapabilitySequences

    fun initializationConfigs(
        videoCandidates: List<StreamSize>,
        analysisCandidates: List<StreamSize>,
    ): List<ProbeConfig> {
        val video = videoCandidates.firstOrNull() ?: return emptyList()
        val current = analysisCandidates.firstOrNull() ?: return emptyList()
        val smaller = analysisCandidates.drop(1).firstOrNull()
        return buildList {
            add(ProbeConfig("preview_only", video, null, includeEncoder = false))
            add(ProbeConfig("preview_analysis", video, current, includeEncoder = false))
            if (smaller != null) {
                add(ProbeConfig("preview_analysis_small", video, smaller, includeEncoder = false))
                add(
                    ProbeConfig(
                        "preview_encoder_analysis_small",
                        video,
                        smaller,
                        includeEncoder = true,
                    ),
                )
            }
        }
    }

    fun capabilitySpecs(sequence: String): List<Pair<String, ProbePhaseKind>> {
        val record = when (sequence) {
            "full" -> ProbePhaseKind.RECORD_FULL
            "encoder_analysis" -> ProbePhaseKind.RECORD_ENCODER_ANALYSIS
            else -> ProbePhaseKind.RECORD_ALTERNATING
        }
        return listOf(
            "idle" to ProbePhaseKind.IDLE,
            "record" to record,
            "idle" to ProbePhaseKind.IDLE,
            "record" to record,
            "idle" to ProbePhaseKind.IDLE,
        )
    }

    fun capabilityConfigs(
        kind: ProbePhaseKind,
        streamConfigPolicy: StreamConfigPolicy,
        videoCandidates: List<StreamSize>,
        analysisCandidates: List<StreamSize>,
        alternatingAnalysisSize: StreamSize,
    ): List<ProbeStreamConfig> {
        val candidates = when (kind) {
            ProbePhaseKind.IDLE ->
                streamConfigPolicy.initializationCandidates(videoCandidates, analysisCandidates)
            ProbePhaseKind.RECORD_FULL, ProbePhaseKind.RECORD_ENCODER_ANALYSIS ->
                streamConfigPolicy.threeSurfaceCandidates(videoCandidates, analysisCandidates)
            ProbePhaseKind.RECORD_ALTERNATING -> videoCandidates.take(2).map { video ->
                StreamConfig(
                    videoWidth = video.width,
                    videoHeight = video.height,
                    analysisWidth = alternatingAnalysisSize.width,
                    analysisHeight = alternatingAnalysisSize.height,
                    includeEncoder = true,
                )
            }
        }
        return candidates.take(MAX_CAPABILITY_CANDIDATES).map { config ->
            ProbeStreamConfig(
                videoWidth = config.videoWidth,
                videoHeight = config.videoHeight,
                analysisWidth = if (kind.includeAnalysis) config.analysisWidth else null,
                analysisHeight = if (kind.includeAnalysis) config.analysisHeight else null,
                candidateLabel = if (kind == ProbePhaseKind.RECORD_ALTERNATING) {
                    "${config.videoWidth}x${config.videoHeight}"
                } else {
                    config.label
                },
            )
        }
    }
}
