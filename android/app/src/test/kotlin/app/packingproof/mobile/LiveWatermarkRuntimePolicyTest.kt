package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveWatermarkRuntimePolicyTest {
    private fun assertPoint(
        expectedX: Float,
        expectedY: Float,
        actual: CameraGlPoint,
    ) {
        assertEquals(expectedX, actual.x, 0.001f)
        assertEquals(expectedY, actual.y, 0.001f)
    }

    @Test
    fun `regenerates current and next textures only across second or tracking changes`() {
        val policy = LiveWatermarkTextureCachePolicy()
        val first = policy.update(1_234L, "SF123")
        val sameSecond = policy.update(1_999L, "SF123")
        val nextSecond = policy.update(2_000L, "SF123")
        val nextTracking = policy.update(2_001L, "SF456")

        assertTrue(first.changed)
        assertEquals(1L, first.current.epochSecond)
        assertEquals(2L, first.next.epochSecond)
        assertFalse(sameSecond.changed)
        assertTrue(nextSecond.changed)
        assertEquals(2L, nextSecond.current.epochSecond)
        assertTrue(nextTracking.changed)
        assertEquals("SF456", nextTracking.current.trackingNumber)
    }

    @Test
    fun `reset invalidates an otherwise reusable texture key`() {
        val policy = LiveWatermarkTextureCachePolicy()
        policy.update(1_234L, "SF123")
        policy.reset()

        assertTrue(policy.update(1_234L, "SF123").changed)
    }

    @Test
    fun `keeps the last complete same-tracking texture while exact second is pending`() {
        val active = LiveWatermarkFrameKey(10L, "SF123")
        val selection = LiveWatermarkFrameSelectionPolicy.select(
            target = LiveWatermarkFrameKey(11L, "SF123"),
            active = active,
            available = emptyList(),
        )

        assertTrue(selection.canRender)
        assertEquals(null, selection.keyToActivate)
    }

    @Test
    fun `activates nearest complete transition texture when prepared second has elapsed`() {
        val prepared = listOf(
            LiveWatermarkFrameKey(20L, "SF456"),
            LiveWatermarkFrameKey(21L, "SF456"),
        )
        val selection = LiveWatermarkFrameSelectionPolicy.select(
            target = LiveWatermarkFrameKey(22L, "SF456"),
            active = null,
            available = prepared,
        )

        assertTrue(selection.canRender)
        assertEquals(prepared.last(), selection.keyToActivate)
    }

    @Test
    fun `never reuses a complete texture from the previous tracking number`() {
        val selection = LiveWatermarkFrameSelectionPolicy.select(
            target = LiveWatermarkFrameKey(11L, "SF456"),
            active = LiveWatermarkFrameKey(10L, "SF123"),
            available = listOf(LiveWatermarkFrameKey(11L, "SF123")),
        )

        assertFalse(selection.canRender)
        assertEquals(null, selection.keyToActivate)
    }

    @Test
    fun `exact complete texture replaces the retained texture atomically`() {
        val target = LiveWatermarkFrameKey(11L, "SF123")
        val selection = LiveWatermarkFrameSelectionPolicy.select(
            target = target,
            active = LiveWatermarkFrameKey(10L, "SF123"),
            available = listOf(target),
        )

        assertTrue(selection.canRender)
        assertEquals(target, selection.keyToActivate)
    }

    @Test
    fun `watermark failure is sticky but recording remains publishable as partial`() {
        val state = LiveWatermarkSegmentState()
        state.markWatermarkRendered()
        assertEquals(LiveWatermarkSegmentDisposition.COMPLETED, state.disposition())

        state.markWatermarkFailure()
        state.markWatermarkRendered()
        assertEquals(LiveWatermarkSegmentDisposition.FAILED_PARTIAL, state.disposition())

        state.reset()
        assertEquals(LiveWatermarkSegmentDisposition.FAILED_PARTIAL, state.disposition())
    }

    @Test
    fun `GL submission is not completed until matching encoded sample is muxed`() {
        val tracker = EncodedWatermarkFrameTracker()
        val state = LiveWatermarkSegmentState()
        tracker.recordSubmitted(1_000L, true)

        assertEquals(LiveWatermarkSegmentDisposition.FAILED_PARTIAL, state.disposition())

        state.markMuxedWatermarkSample(tracker.takeForEncodedSample(1_000L))
        assertEquals(LiveWatermarkSegmentDisposition.COMPLETED, state.disposition())
    }

    @Test
    fun `unwritten submitted frame cannot make segment completed`() {
        val tracker = EncodedWatermarkFrameTracker()
        val state = LiveWatermarkSegmentState()
        tracker.recordSubmitted(2_000L, true)

        assertEquals(LiveWatermarkSegmentDisposition.FAILED_PARTIAL, state.disposition())
    }

    @Test
    fun `late old frame cannot satisfy a newer encoded sample`() {
        val tracker = EncodedWatermarkFrameTracker()
        tracker.recordSubmitted(1_000L, true)
        tracker.recordSubmitted(2_000L, true)

        assertEquals(true, tracker.takeForEncodedSample(2_000L))
        assertEquals(null, tracker.takeForEncodedSample(1_000L))
    }

    @Test
    fun `small vendor timestamp quantization still matches submitted frame`() {
        val tracker = EncodedWatermarkFrameTracker(matchToleranceUs = 2_000L)
        tracker.recordSubmitted(100_000L, true)
        tracker.recordSubmitted(133_333L, false)

        assertEquals(true, tracker.takeForEncodedSample(101_500L))
        assertEquals(false, tracker.takeForEncodedSample(132_000L))
    }

    @Test
    fun `timestamp outside bounded tolerance remains unmatched`() {
        val tracker = EncodedWatermarkFrameTracker(matchToleranceUs = 2_000L)
        tracker.recordSubmitted(100_000L, true)

        assertEquals(null, tracker.takeForEncodedSample(102_001L))
    }

    @Test
    fun `ten thousand submitted frames without encoder output remain bounded`() {
        val tracker = EncodedWatermarkFrameTracker(
            maxPendingFrames = 120,
            maxPendingAgeUs = 5_000_000L,
        )
        var evicted = false

        repeat(10_000) { index ->
            evicted = tracker.recordSubmitted(index * 33_333L, true) || evicted
        }

        assertTrue(evicted)
        assertTrue(tracker.pendingCountForTesting() <= 120)
    }

    @Test
    fun `missing encoder correlation or failed watermark keeps segment partial`() {
        val missing = LiveWatermarkSegmentState()
        missing.markMuxedWatermarkSample(null)
        assertEquals(LiveWatermarkSegmentDisposition.FAILED_PARTIAL, missing.disposition())

        val failed = LiveWatermarkSegmentState()
        failed.markMuxedWatermarkSample(false)
        failed.markMuxedWatermarkSample(true)
        assertEquals(LiveWatermarkSegmentDisposition.FAILED_PARTIAL, failed.disposition())
    }

    @Test
    fun `segment reset requires a muxed watermarked sample in the new file`() {
        val tracker = EncodedWatermarkFrameTracker()
        val state = LiveWatermarkSegmentState()
        tracker.recordSubmitted(1_000L, true)
        state.markMuxedWatermarkSample(tracker.takeForEncodedSample(1_000L))
        assertEquals(LiveWatermarkSegmentDisposition.COMPLETED, state.disposition())

        state.reset()
        tracker.recordSubmitted(2_000L, true)
        assertEquals(LiveWatermarkSegmentDisposition.FAILED_PARTIAL, state.disposition())

        state.markMuxedWatermarkSample(tracker.takeForEncodedSample(2_000L))
        assertEquals(LiveWatermarkSegmentDisposition.COMPLETED, state.disposition())
    }

    @Test
    fun `GL full recording keeps barcode direct and collapses preview encoder to one camera surface`() {
        val topology = CameraSurfaceTopologyPolicy.create(
            pipeline = CameraSurfacePipeline.GL_COMPOSITOR,
            includePreview = true,
            includeEncoder = true,
            includeAnalysis = true,
        )

        assertTrue(topology.cameraUsesFrameSurface)
        assertTrue(topology.cameraUsesAnalysisSurface)
        assertTrue(topology.compositorEncoderEnabled)
        assertFalse(topology.cameraUsesPreviewSurface)
        assertFalse(topology.cameraUsesEncoderSurface)
        assertEquals(2, topology.cameraSurfaceCount)
    }

    @Test
    fun `GL alternating recording keeps preview while omitting barcode surface`() {
        val topology = CameraSurfaceTopologyPolicy.create(
            pipeline = CameraSurfacePipeline.GL_COMPOSITOR,
            includePreview = true,
            includeEncoder = true,
            includeAnalysis = false,
        )

        assertTrue(topology.cameraUsesFrameSurface)
        assertFalse(topology.cameraUsesAnalysisSurface)
        assertEquals(1, topology.cameraSurfaceCount)
    }

    @Test
    fun `direct fallback preserves original three surface recording topology`() {
        val topology = CameraSurfaceTopologyPolicy.create(
            pipeline = CameraSurfacePipeline.DIRECT,
            includePreview = true,
            includeEncoder = true,
            includeAnalysis = true,
        )

        assertFalse(topology.cameraUsesFrameSurface)
        assertTrue(topology.cameraUsesPreviewSurface)
        assertTrue(topology.cameraUsesEncoderSurface)
        assertTrue(topology.cameraUsesAnalysisSurface)
        assertEquals(3, topology.cameraSurfaceCount)
    }

    @Test
    fun `encoder surface replacement rebuilds GL but never rebuilds direct fallback`() {
        assertTrue(
            CameraSurfaceLifecyclePolicy.shouldRebuildCompositor(
                pipeline = CameraSurfacePipeline.GL_COMPOSITOR,
                compositorReady = true,
                videoSizeChanged = false,
                encoderSurfaceChanged = true,
            ),
        )
        assertFalse(
            CameraSurfaceLifecyclePolicy.shouldRebuildCompositor(
                pipeline = CameraSurfacePipeline.DIRECT,
                compositorReady = false,
                videoSizeChanged = true,
                encoderSurfaceChanged = true,
            ),
        )
        assertEquals(
            CameraSurfacePipeline.DIRECT,
            CameraSurfaceLifecyclePolicy.failureFallback(
                CameraSurfacePipeline.GL_COMPOSITOR,
            ),
        )
        assertEquals(
            CameraSurfacePipeline.DIRECT,
            CameraSurfaceLifecyclePolicy.failureFallback(CameraSurfacePipeline.DIRECT),
        )
    }

    @Test
    fun `watermark quad is top centered in portrait final coordinates`() {
        val quad = LiveWatermarkQuadPolicy.create(1080, 1920, 300, 100, "portrait")

        assertPoint(390f, 192f, quad.topLeft)
        assertPoint(690f, 192f, quad.topRight)
        assertPoint(390f, 292f, quad.bottomLeft)
    }

    @Test
    fun `GL output rotates landscape camera input once into portrait coordinates`() {
        assertEquals(
            CameraGlOutputGeometry(1080, 1920, 0),
            CameraGlOutputGeometryPolicy.create(1920, 1080, 90),
        )
        assertEquals(
            CameraGlOutputGeometry(1080, 1920, 0),
            CameraGlOutputGeometryPolicy.create(1920, 1080, 270),
        )
        assertEquals(
            CameraGlOutputGeometry(1080, 1920, 0),
            CameraGlOutputGeometryPolicy.create(1080, 1920, 0),
        )
    }

    @Test
    fun `landscape directions map the same final placement to opposite raw edges`() {
        val left = LiveWatermarkQuadPolicy.create(1920, 1080, 300, 100, "landscapeLeft")
        val right = LiveWatermarkQuadPolicy.create(1920, 1080, 300, 100, "landscapeRight")

        assertPoint(76.8f, 690f, left.topLeft)
        assertPoint(1843.2f, 390f, right.topLeft)
        assertEquals(1080, LiveWatermarkQuadPolicy.outputHeight(1920, 1080, "portrait"))
        assertEquals(1920, LiveWatermarkQuadPolicy.outputHeight(1920, 1080, "landscapeLeft"))
    }

    @Test
    fun `watermark switch off keeps the compositor free of watermark`() {
        assertFalse(
            LiveWatermarkActivationPolicy.useCompositorWatermark(
                watermarkEnabled = false,
                glPipeline = true,
                hasCompositor = true,
            ),
        )
        assertTrue(
            LiveWatermarkActivationPolicy.useCompositorWatermark(
                watermarkEnabled = true,
                glPipeline = true,
                hasCompositor = true,
            ),
        )
        assertFalse(
            LiveWatermarkActivationPolicy.useCompositorWatermark(
                watermarkEnabled = true,
                glPipeline = false,
                hasCompositor = true,
            ),
        )
    }

    @Test
    fun `watermark switch off reports every segment as final cut`() {
        assertEquals(
            LiveWatermarkSegmentDisposition.COMPLETED,
            LiveWatermarkActivationPolicy.effectiveDisposition(
                watermarkEnabled = false,
                disposition = LiveWatermarkSegmentDisposition.FAILED_PARTIAL,
            ),
        )
        assertEquals(
            LiveWatermarkSegmentDisposition.FAILED_PARTIAL,
            LiveWatermarkActivationPolicy.effectiveDisposition(
                watermarkEnabled = true,
                disposition = LiveWatermarkSegmentDisposition.FAILED_PARTIAL,
            ),
        )
        assertEquals(
            LiveWatermarkSegmentDisposition.COMPLETED,
            LiveWatermarkActivationPolicy.effectiveDisposition(
                watermarkEnabled = true,
                disposition = LiveWatermarkSegmentDisposition.COMPLETED,
            ),
        )
    }

    @Test
    fun `idle preview clears the watermark whenever the switch is off`() {
        assertEquals(
            LiveWatermarkIdleAction.SHOW_TIMESTAMP,
            LiveWatermarkActivationPolicy.idleAction(watermarkEnabled = true),
        )
        // 结束工作、重建会话都会回到空闲水印：关掉开关时必须清空，
        // 否则预览会重新出现只有时间的水印。
        assertEquals(
            LiveWatermarkIdleAction.CLEAR,
            LiveWatermarkActivationPolicy.idleAction(watermarkEnabled = false),
        )
    }
}
