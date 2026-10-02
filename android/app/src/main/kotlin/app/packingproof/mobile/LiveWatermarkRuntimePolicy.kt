package app.packingproof.mobile

import java.util.TreeMap

internal data class CameraGlPoint(
    val x: Float,
    val y: Float,
)

internal data class LiveWatermarkFrameKey(
    val epochSecond: Long,
    val trackingNumber: String,
)

internal data class LiveWatermarkCacheDecision(
    val current: LiveWatermarkFrameKey,
    val next: LiveWatermarkFrameKey,
    val changed: Boolean,
)

internal data class LiveWatermarkFrameSelection(
    val keyToActivate: LiveWatermarkFrameKey?,
    val canRender: Boolean,
)

/**
 * Keeps a complete texture visible while the exact-second replacement is still being rasterized.
 * A texture from another tracking number is never reused across a segment boundary.
 */
internal object LiveWatermarkFrameSelectionPolicy {
    fun select(
        target: LiveWatermarkFrameKey,
        active: LiveWatermarkFrameKey?,
        available: Collection<LiveWatermarkFrameKey>,
    ): LiveWatermarkFrameSelection {
        if (target in available) {
            return LiveWatermarkFrameSelection(keyToActivate = target, canRender = true)
        }
        if (active?.trackingNumber == target.trackingNumber) {
            return LiveWatermarkFrameSelection(keyToActivate = null, canRender = true)
        }
        val prepared = available
            .asSequence()
            .filter { it.trackingNumber == target.trackingNumber }
            .sortedWith(
                compareByDescending<LiveWatermarkFrameKey> {
                    it.epochSecond <= target.epochSecond
                }.thenBy { kotlin.math.abs(it.epochSecond - target.epochSecond) },
            )
            .firstOrNull()
        return LiveWatermarkFrameSelection(
            keyToActivate = prepared,
            canRender = prepared != null,
        )
    }
}

/** Decides when the current/next-second watermark textures need regeneration. */
internal class LiveWatermarkTextureCachePolicy {
    private var lastCurrent: LiveWatermarkFrameKey? = null

    fun update(
        frameTimeMs: Long,
        trackingNumber: String,
    ): LiveWatermarkCacheDecision {
        val current = LiveWatermarkFrameKey(
            epochSecond = Math.floorDiv(frameTimeMs, 1_000L),
            trackingNumber = trackingNumber,
        )
        val decision = LiveWatermarkCacheDecision(
            current = current,
            next = current.copy(epochSecond = current.epochSecond + 1L),
            changed = current != lastCurrent,
        )
        lastCurrent = current
        return decision
    }

    fun reset() {
        lastCurrent = null
    }
}

internal enum class LiveWatermarkSegmentDisposition {
    COMPLETED,
    FAILED_PARTIAL,
}

/** Sticky fail-open state: a watermark error never makes the underlying recording unusable. */
internal class LiveWatermarkSegmentState {
    private var renderedFrameCount = 0L
    private var watermarkFailed = false

    @Synchronized
    fun markWatermarkRendered() {
        renderedFrameCount++
    }

    @Synchronized
    fun markWatermarkFailure() {
        watermarkFailed = true
    }

    /** Only muxed video samples are allowed to affect the published segment disposition. */
    @Synchronized
    fun markMuxedWatermarkSample(rendered: Boolean?) {
        if (rendered == true) {
            renderedFrameCount++
        } else {
            watermarkFailed = true
        }
    }

    @Synchronized
    fun disposition(): LiveWatermarkSegmentDisposition =
        if (renderedFrameCount > 0L && !watermarkFailed) {
            LiveWatermarkSegmentDisposition.COMPLETED
        } else {
            LiveWatermarkSegmentDisposition.FAILED_PARTIAL
        }

    @Synchronized
    fun reset() {
        renderedFrameCount = 0L
        watermarkFailed = false
    }
}

/**
 * Correlates a frame submitted to the encoder surface with the MediaCodec output carrying the
 * same presentation timestamp. A GL submission is deliberately not treated as durable until the
 * caller has successfully written the matching encoded sample to its current muxer.
 */
internal class EncodedWatermarkFrameTracker(
    private val maxPendingFrames: Int = 300,
    private val maxPendingAgeUs: Long = 5_000_000L,
    private val matchToleranceUs: Long = 2_000L,
) {
    private val submittedFrames = TreeMap<Long, Boolean>()

    init {
        require(maxPendingFrames > 0)
        require(maxPendingAgeUs > 0L)
        require(matchToleranceUs >= 0L)
    }

    @Synchronized
    fun recordSubmitted(presentationTimeUs: Long, watermarkRendered: Boolean): Boolean {
        submittedFrames[presentationTimeUs] = watermarkRendered
        var evicted = false
        val oldestAllowedPtsUs = presentationTimeUs - maxPendingAgeUs
        while (submittedFrames.isNotEmpty() &&
            (submittedFrames.size > maxPendingFrames ||
                submittedFrames.firstKey() < oldestAllowedPtsUs)
        ) {
            submittedFrames.pollFirstEntry()
            evicted = true
        }
        return evicted
    }

    @Synchronized
    fun takeForEncodedSample(presentationTimeUs: Long): Boolean? {
        val oldestMatchPtsUs = presentationTimeUs - matchToleranceUs
        submittedFrames.headMap(oldestMatchPtsUs, false).clear()
        val floor = submittedFrames.floorEntry(presentationTimeUs)
        val ceiling = submittedFrames.ceilingEntry(presentationTimeUs)
        val nearest = listOfNotNull(floor, ceiling)
            .minByOrNull { kotlin.math.abs(it.key - presentationTimeUs) }
            ?: return null
        if (kotlin.math.abs(nearest.key - presentationTimeUs) > matchToleranceUs) {
            return null
        }
        submittedFrames.headMap(nearest.key, true).clear()
        return nearest.value
    }

    @Synchronized
    fun reset() {
        submittedFrames.clear()
    }

    @Synchronized
    internal fun pendingCountForTesting(): Int = submittedFrames.size
}

internal enum class CameraSurfacePipeline {
    GL_COMPOSITOR,
    DIRECT,
}

internal data class CameraSurfaceTopology(
    val cameraUsesFrameSurface: Boolean,
    val cameraUsesPreviewSurface: Boolean,
    val cameraUsesEncoderSurface: Boolean,
    val cameraUsesAnalysisSurface: Boolean,
    val compositorEncoderEnabled: Boolean,
) {
    val cameraSurfaceCount: Int
        get() = listOf(
            cameraUsesFrameSurface,
            cameraUsesPreviewSurface,
            cameraUsesEncoderSurface,
            cameraUsesAnalysisSurface,
        ).count { it }
}

/** Pure Surface topology shared by regular sessions, fallbacks, and capability probes. */
internal object CameraSurfaceTopologyPolicy {
    fun create(
        pipeline: CameraSurfacePipeline,
        includePreview: Boolean,
        includeEncoder: Boolean,
        includeAnalysis: Boolean,
    ): CameraSurfaceTopology = when (pipeline) {
        CameraSurfacePipeline.GL_COMPOSITOR -> CameraSurfaceTopology(
            cameraUsesFrameSurface = includePreview || includeEncoder,
            cameraUsesPreviewSurface = false,
            cameraUsesEncoderSurface = false,
            cameraUsesAnalysisSurface = includeAnalysis,
            compositorEncoderEnabled = includeEncoder,
        )
        CameraSurfacePipeline.DIRECT -> CameraSurfaceTopology(
            cameraUsesFrameSurface = false,
            cameraUsesPreviewSurface = includePreview,
            cameraUsesEncoderSurface = includeEncoder,
            cameraUsesAnalysisSurface = includeAnalysis,
            compositorEncoderEnabled = false,
        )
    }
}

internal object CameraSurfaceLifecyclePolicy {
    fun shouldRebuildCompositor(
        pipeline: CameraSurfacePipeline,
        compositorReady: Boolean,
        videoSizeChanged: Boolean,
        encoderSurfaceChanged: Boolean,
    ): Boolean = pipeline == CameraSurfacePipeline.GL_COMPOSITOR &&
        (!compositorReady || videoSizeChanged || encoderSurfaceChanged)

    fun failureFallback(current: CameraSurfacePipeline): CameraSurfacePipeline =
        if (current == CameraSurfacePipeline.GL_COMPOSITOR) {
            CameraSurfacePipeline.DIRECT
        } else {
            current
        }
}

/**
 * 工作模式在运行期的取值：本次会话的停摆降级只是临时结论，不改写已探明的能力模式。
 */
internal object CameraCapabilityRuntimePolicy {
    private val degradableModes = setOf(
        CameraCapabilityMode.FULL,
        CameraCapabilityMode.UNVERIFIED,
    )

    fun effectiveRecordingMode(
        mode: CameraCapabilityMode,
        sessionFallback: Boolean,
    ): CameraCapabilityMode =
        if (sessionFallback && mode in degradableModes) {
            CameraCapabilityMode.ENCODER_ANALYSIS
        } else {
            mode
        }
}

/**
 * 可见预览输出策略：只有「录像中 + 仅扫码」才停住预览画面，空闲时始终显示。
 *
 * GL 管线下相机必须继续喂合成器（编码要它出帧），这里停的是合成器向预览纹理的出帧，
 * 不是拆掉相机输出；非 GL 管线的该模式本来就不包含预览表面。
 */
internal object CameraPreviewOutputPolicy {
    fun pausePreview(recording: Boolean, mode: CameraCapabilityMode): Boolean =
        recording && mode == CameraCapabilityMode.ENCODER_ANALYSIS

    fun apply(
        compositor: CameraGlCompositor?,
        recording: Boolean,
        mode: CameraCapabilityMode,
    ) {
        compositor?.setPreviewEnabled(!pausePreview(recording, mode))
    }
}

internal data class LiveWatermarkQuad(
    val topLeft: CameraGlPoint,
    val topRight: CameraGlPoint,
    val bottomLeft: CameraGlPoint,
    val bottomRight: CameraGlPoint,
)

/** Maps a top-centered final-video watermark back into the encoder's raw frame coordinates. */
internal object LiveWatermarkQuadPolicy {
    private const val PORTRAIT_TOP_FRACTION = 0.10f
    private const val LANDSCAPE_TOP_FRACTION = 0.04f

    fun create(
        videoWidth: Int,
        videoHeight: Int,
        bitmapWidth: Int,
        bitmapHeight: Int,
        recordingOrientation: String,
    ): LiveWatermarkQuad {
        require(videoWidth > 0 && videoHeight > 0)
        require(bitmapWidth > 0 && bitmapHeight > 0)
        val rotated = recordingOrientation == "landscapeLeft" ||
            recordingOrientation == "landscapeRight"
        val outputWidth = if (rotated) videoHeight else videoWidth
        val outputHeight = if (rotated) videoWidth else videoHeight
        val width = bitmapWidth.coerceAtMost(outputWidth).toFloat()
        val height = bitmapHeight.coerceAtMost(outputHeight).toFloat()
        val left = ((outputWidth - width) / 2f).coerceAtLeast(0f)
        val topFraction = if (recordingOrientation == "portrait") {
            PORTRAIT_TOP_FRACTION
        } else {
            LANDSCAPE_TOP_FRACTION
        }
        val top = (outputHeight * topFraction).coerceIn(0f, outputHeight - height)

        fun inverse(x: Float, y: Float): CameraGlPoint = when (recordingOrientation) {
            "landscapeLeft" -> CameraGlPoint(y, videoHeight - x)
            "landscapeRight" -> CameraGlPoint(videoWidth - y, x)
            else -> CameraGlPoint(x, y)
        }
        return LiveWatermarkQuad(
            topLeft = inverse(left, top),
            topRight = inverse(left + width, top),
            bottomLeft = inverse(left, top + height),
            bottomRight = inverse(left + width, top + height),
        )
    }

    fun outputHeight(videoWidth: Int, videoHeight: Int, recordingOrientation: String): Int =
        if (recordingOrientation == "landscapeLeft" ||
            recordingOrientation == "landscapeRight"
        ) {
            videoWidth
        } else {
            videoHeight
        }
}

internal data class CameraGlOutputGeometry(
    val width: Int,
    val height: Int,
    val inputQuarterTurns: Int,
)

/** Keeps preview, encoder and watermark in one portrait pixel coordinate system. */
internal object CameraGlOutputGeometryPolicy {
    fun create(inputWidth: Int, inputHeight: Int, sensorOrientation: Int): CameraGlOutputGeometry {
        require(inputWidth > 0 && inputHeight > 0)
        val normalizedOrientation = ((sensorOrientation % 360) + 360) % 360
        val swapsDimensions = normalizedOrientation == 90 || normalizedOrientation == 270
        return CameraGlOutputGeometry(
            width = if (swapsDimensions) inputHeight else inputWidth,
            height = if (swapsDimensions) inputWidth else inputHeight,
            // SurfaceTexture's transform matrix already includes the camera buffer transform.
            // Applying the sensor angle again rotates the composed preview and encoder output twice.
            inputQuarterTurns = 0,
        )
    }
}
