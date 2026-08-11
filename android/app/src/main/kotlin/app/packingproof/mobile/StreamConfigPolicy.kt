package app.packingproof.mobile

import android.util.Size

/** 纯 JVM 可测的输出尺寸（避免本地单测依赖 android.util.Size）。 */
internal data class StreamSize(val width: Int, val height: Int)

/**
 * 摄像头会话输出组合策略。
 *
 * Camera2 没有公开 API 能提前查询“预览 + 录像编码器 + YUV 识别”等多路输出
 * 组合是否受支持；部分机型（如荣耀 X70 / Android 16）会在 createCaptureSession
 * 时直接 onConfigureFailed。因此按“画质优先、逐级降级”生成候选配置，
 * 由调用方在配置失败时依次重试。
 */
internal data class StreamConfig(
    val videoWidth: Int,
    val videoHeight: Int,
    val analysisWidth: Int,
    val analysisHeight: Int,
    val includeEncoder: Boolean,
) {
    /** 稳定诊断标识，例如 3_1920x1080_960x540。 */
    val label: String
        get() = "${if (includeEncoder) "3" else "2"}_" +
            "${videoWidth}x${videoHeight}_${analysisWidth}x${analysisHeight}"

    fun toVideoSize(): Size = Size(videoWidth, videoHeight)

    fun toAnalysisSize(): Size = Size(analysisWidth, analysisHeight)
}

internal class StreamConfigPolicy(
    private val preferredVideoWidth: Int,
    private val preferredVideoHeight: Int,
) {
    /**
     * 录像/预览尺寸候选：优先设定档位，其次 720p 保底档，最后补一个更小的
     * 支持尺寸。候选必须保持少量，否则会话配置失败时会遍历数百种组合并
     * 反复重建编码器，把相机拖入长时间重试。
     */
    fun videoCandidates(supportedSizes: List<StreamSize>): List<StreamSize> {
        if (supportedSizes.isEmpty()) {
            return listOf(StreamSize(preferredVideoWidth, preferredVideoHeight))
        }
        val candidates = mutableListOf<StreamSize>()
        supportedSizes.firstOrNull {
            it.width == preferredVideoWidth && it.height == preferredVideoHeight
        }?.let(candidates::add)
        if (preferredVideoWidth != 1280 || preferredVideoHeight != 720) {
            supportedSizes.firstOrNull { it.width == 1280 && it.height == 720 }
                ?.let { if (it !in candidates) candidates.add(it) }
        }
        val fallback = supportedSizes
            .filter {
                it.width <= preferredVideoWidth &&
                    it.height <= preferredVideoHeight &&
                    it.width > it.height &&
                    it !in candidates
            }
            .sortedByDescending { it.width.toLong() * it.height }
            .firstOrNull()
            ?: supportedSizes
                .filter { it !in candidates }
                .maxByOrNull { it.width.toLong() * it.height }
        fallback?.let { candidates.add(it) }
        return candidates
    }

    /** 识别流尺寸候选：优先 960x540，其次 640x480、320x240，最后补最小支持尺寸。 */
    fun analysisCandidates(supportedSizes: List<StreamSize>): List<StreamSize> {
        if (supportedSizes.isEmpty()) {
            return listOf(StreamSize(640, 480))
        }
        val preferred = supportedSizes.firstOrNull { it.width == 960 && it.height == 540 }
            ?: supportedSizes
                .filter { it.width <= 960 && it.height <= 540 && it.width > it.height }
                .maxByOrNull { it.width.toLong() * it.height }
            ?: supportedSizes.firstOrNull()
        val candidates = mutableListOf<StreamSize>()
        preferred?.let(candidates::add)
        for ((width, height) in listOf(640 to 480, 320 to 240)) {
            supportedSizes.firstOrNull { it.width == width && it.height == height }
                ?.let { if (it !in candidates) candidates.add(it) }
        }
        supportedSizes
            .filter { it.width <= 960 && it.height <= 540 }
            .minByOrNull { it.width.toLong() * it.height }
            ?.let { if (it !in candidates) candidates.add(it) }
        return candidates
    }

    /** 录像会话候选：始终包含编码器，按画质逐级降级。 */
    fun threeSurfaceCandidates(
        videoSizes: List<StreamSize>,
        analysisSizes: List<StreamSize>,
    ): List<StreamConfig> {
        val result = mutableListOf<StreamConfig>()
        for (video in videoSizes) {
            for (analysis in analysisSizes) {
                result += StreamConfig(
                    videoWidth = video.width,
                    videoHeight = video.height,
                    analysisWidth = analysis.width,
                    analysisHeight = analysis.height,
                    includeEncoder = true,
                )
            }
        }
        return result
    }

    /**
     * 初始化候选：只包含“预览 + 识别”两路（录像编码器在开始工作时
     * 重建会话才加入），按画质从高到低逐级降级，保证尽可能进入预览界面。
     */
    fun initializationCandidates(
        videoSizes: List<StreamSize>,
        analysisSizes: List<StreamSize>,
    ): List<StreamConfig> {
        val result = mutableListOf<StreamConfig>()
        for (video in videoSizes) {
            for (analysis in analysisSizes) {
                result += StreamConfig(
                    videoWidth = video.width,
                    videoHeight = video.height,
                    analysisWidth = analysis.width,
                    analysisHeight = analysis.height,
                    includeEncoder = false,
                )
            }
        }
        return result
    }
}
