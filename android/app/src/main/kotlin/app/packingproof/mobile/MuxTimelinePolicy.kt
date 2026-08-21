package app.packingproof.mobile

import kotlin.math.max

/**
 * 录像分段的纯时间线状态。
 *
 * 负责把编码器源时间戳映射为每段从零开始且严格递增的轨道时间戳，
 * 不持有 MediaMuxer、MediaCodec 或缓冲区资源。
 */
internal class MuxTimelinePolicy {
    private var segmentBasePtsUs = 0L
    private var lastVideoPtsUs = -1L
    private var lastAudioPtsUs = -1L
    private var lastMediaPtsUs = 0L
    private var audioToVideoPtsOffsetUs: Long? = null

    fun beginRecording() {
        audioToVideoPtsOffsetUs = null
    }

    fun openSegment(basePtsUs: Long) {
        segmentBasePtsUs = basePtsUs
        lastVideoPtsUs = -1L
        lastAudioPtsUs = -1L
        lastMediaPtsUs = basePtsUs
    }

    fun videoPtsUs(sourcePtsUs: Long): Long {
        var ptsUs = max(0L, sourcePtsUs - segmentBasePtsUs)
        if (ptsUs <= lastVideoPtsUs) ptsUs = lastVideoPtsUs + 1L
        lastVideoPtsUs = ptsUs
        lastMediaPtsUs = max(lastMediaPtsUs, sourcePtsUs)
        return ptsUs
    }

    fun audioSourcePtsUs(presentationTimeUs: Long): Long {
        val offsetUs = audioToVideoPtsOffsetUs
            ?: (segmentBasePtsUs - presentationTimeUs).also {
                audioToVideoPtsOffsetUs = it
            }
        return presentationTimeUs + offsetUs
    }

    fun audioPtsUs(presentationTimeUs: Long): Long? {
        val sourcePtsUs = audioSourcePtsUs(presentationTimeUs)
        if (sourcePtsUs < segmentBasePtsUs) return null
        var ptsUs = sourcePtsUs - segmentBasePtsUs
        if (ptsUs <= lastAudioPtsUs) ptsUs = lastAudioPtsUs + 1L
        lastAudioPtsUs = ptsUs
        lastMediaPtsUs = max(lastMediaPtsUs, sourcePtsUs)
        return ptsUs
    }

    fun boundaryAtMs(segmentStartedAtMs: Long, boundaryPtsUs: Long): Long =
        segmentStartedAtMs + max(0L, boundaryPtsUs - segmentBasePtsUs) / 1_000L

    fun endedAtMs(segmentStartedAtMs: Long, fallbackNowMs: Long): Long =
        if (lastMediaPtsUs >= segmentBasePtsUs) {
            segmentStartedAtMs + (lastMediaPtsUs - segmentBasePtsUs) / 1_000L
        } else {
            fallbackNowMs
        }
}
