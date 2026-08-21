package app.packingproof.mobile

import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.SystemClock
import android.view.Surface

internal data class CameraCapabilityProbeResult(
    val status: String,
    val reason: String?,
    val phases: List<Map<String, Any?>>,
)

internal fun interface CameraCapabilityProbePhaseExecutor {
    fun run(
        label: String,
        kind: ProbePhaseKind,
        deadline: Long,
        onDone: (Map<String, Any?>) -> Unit,
    )
}

/** Executes the five-phase capability-probe contract without owning camera lifecycle recovery. */
internal class CameraCapabilityProbeRunner(
    private val phaseExecutor: CameraCapabilityProbePhaseExecutor,
    private val uptimeMillis: () -> Long = SystemClock::uptimeMillis,
    private val phaseBudgetMs: Long = DEFAULT_PHASE_BUDGET_MS,
) {
    fun run(
        sequence: String,
        deadline: Long,
        isCancelled: () -> Boolean,
        onDone: (CameraCapabilityProbeResult) -> Unit,
    ) {
        val phases = mutableListOf<Map<String, Any?>>()
        val specs = CameraProbePlanPolicy.capabilitySpecs(sequence)
        fun finish(status: String, reason: String?) {
            onDone(CameraCapabilityProbeResult(status, reason, phases.toList()))
        }
        fun step(index: Int) {
            if (isCancelled()) {
                finish("error", "cancelled")
                return
            }
            if (uptimeMillis() + phaseBudgetMs > deadline) {
                finish("budget_exceeded", "检测时间预算不足")
                return
            }
            if (index >= specs.size) {
                finish("ok", null)
                return
            }
            val (label, kind) = specs[index]
            phaseExecutor.run(label, kind, deadline) { phaseResult ->
                phases += phaseResult
                when (phaseResult["outcome"]) {
                    CameraProbeOutcome.CONFIGURED.wire -> step(index + 1)
                    CameraProbeOutcome.CONFIGURE_FAILED.wire,
                    CameraProbeOutcome.UNSUPPORTED_COMBINATION.wire,
                    CameraProbeOutcome.CODEC_MISSING.wire,
                    CameraProbeOutcome.CODEC_CONFIG_FAILED.wire,
                    -> finish("ok", null)
                    else -> finish(
                        "error",
                        "${phaseResult["outcome"]}:${phaseResult["detail"] ?: ""}",
                    )
                }
            }
        }
        step(0)
    }

    private companion object {
        const val DEFAULT_PHASE_BUDGET_MS = 4_500L
    }
}

internal data class CameraCapabilityProbeEnvironment(
    val handler: Handler,
    val cameraManager: CameraManager,
    val streamConfigPolicy: StreamConfigPolicy,
    val videoCandidates: List<StreamSize>,
    val analysisCandidates: List<StreamSize>,
    val videoSize: StreamSize,
    val analysisSize: StreamSize,
    val selectedVideoMime: String,
    val cameraId: () -> String?,
    val cameraCharacteristics: () -> CameraCharacteristics?,
    val surfaceTexture: () -> SurfaceTexture?,
    val previewSurface: () -> Surface?,
    val updatePreviewSurface: (Surface) -> Unit,
    val cameraDevice: () -> CameraDevice?,
    val updateCameraDevice: (CameraDevice?) -> Unit,
    val isDisposed: () -> Boolean,
    val createEncoderFormat: (String, Int, Int) -> MediaFormat,
    val applyAutomaticCameraControls: (
        CaptureRequest.Builder,
        CameraCharacteristics,
    ) -> Unit,
)

/** Owns temporary Camera2, ImageReader and MediaCodec resources for one probe phase. */
internal class AndroidCameraCapabilityProbePhaseExecutor(
    private val environment: CameraCapabilityProbeEnvironment,
    private val uptimeMillis: () -> Long = SystemClock::uptimeMillis,
    private val phaseWindowMs: Long = DEFAULT_PHASE_WINDOW_MS,
    private val configTimeoutMs: Long = DEFAULT_CONFIG_TIMEOUT_MS,
    private val phaseBudgetMs: Long = DEFAULT_PHASE_BUDGET_MS,
) : CameraCapabilityProbePhaseExecutor {
    override fun run(
        label: String,
        kind: ProbePhaseKind,
        deadline: Long,
        onDone: (Map<String, Any?>) -> Unit,
    ) {
        val configs = CameraProbePlanPolicy.capabilityConfigs(
            kind = kind,
            streamConfigPolicy = environment.streamConfigPolicy,
            videoCandidates = environment.videoCandidates,
            analysisCandidates = environment.analysisCandidates,
            alternatingAnalysisSize = environment.analysisSize,
        )
        if (configs.isEmpty()) {
            onDone(emptyResult(label, "internal_error", "没有可用的候选组合"))
            return
        }
        fun attempt(index: Int, lastOutcome: String, lastDetail: String?) {
            if (environment.isDisposed()) {
                onDone(emptyResult(label, "internal_error", "摄像头已关闭"))
                return
            }
            if (uptimeMillis() + phaseBudgetMs > deadline) {
                onDone(emptyResult(label, "budget_exceeded", "检测时间预算不足"))
                return
            }
            if (index >= configs.size) {
                onDone(emptyResult(label, lastOutcome, lastDetail))
                return
            }
            val cameraId = environment.cameraId()
            val characteristics = environment.cameraCharacteristics()
            val texture = environment.surfaceTexture()
            if (cameraId == null || characteristics == null || texture == null) {
                onDone(emptyResult(label, "internal_error", "摄像头尚未准备完成"))
                return
            }
            val config = configs[index]
            var phaseCamera: CameraDevice? = null
            var phaseSession: CameraCaptureSession? = null
            var phaseReader: ImageReader? = null
            var phaseCodec: MediaCodec? = null
            var phaseCodecSurface: Surface? = null
            var codecFailed = false
            var finished = false
            val startedAtMs = uptimeMillis()
            var previewFrames = 0
            var analysisFrames = 0
            var encoderBuffers = 0
            val preview = environment.previewSurface() ?: Surface(texture).also {
                environment.updatePreviewSurface(it)
            }

            lateinit var configTimeout: Runnable

            fun cleanup() {
                // Keep the original deterministic order: session → camera → reader → encoder → surface.
                runCatching { phaseSession?.close() }
                phaseSession = null
                runCatching { phaseCamera?.close() }
                if (phaseCamera === environment.cameraDevice()) {
                    environment.updateCameraDevice(null)
                }
                phaseCamera = null
                runCatching { phaseReader?.close() }
                phaseReader = null
                runCatching { phaseCodec?.stop() }
                runCatching { phaseCodec?.release() }
                phaseCodec = null
                runCatching { phaseCodecSurface?.release() }
                phaseCodecSurface = null
                runCatching {
                    texture.setDefaultBufferSize(
                        environment.videoSize.width,
                        environment.videoSize.height,
                    )
                }
            }

            fun finish(outcome: String, detail: String?) {
                if (finished) return
                finished = true
                environment.handler.removeCallbacks(configTimeout)
                cleanup()
                onDone(
                    CameraDiagnosticsSnapshotMapper.probePhaseResult(
                        label,
                        config.candidateLabel,
                        outcome,
                        detail,
                        previewFrames,
                        analysisFrames,
                        encoderBuffers,
                        (uptimeMillis() - startedAtMs).toInt(),
                    ),
                )
            }

            fun retry(nextOutcome: String, nextDetail: String?) {
                if (finished) return
                finished = true
                environment.handler.removeCallbacks(configTimeout)
                cleanup()
                attempt(index + 1, nextOutcome, nextDetail)
            }

            configTimeout = Runnable {
                finish(CameraProbeOutcome.CONFIGURE_TIMEOUT.wire, null)
            }
            environment.handler.postDelayed(configTimeout, configTimeoutMs)
            try {
                if (kind.includeAnalysis) {
                    phaseReader = ImageReader.newInstance(
                        config.analysisWidth ?: environment.analysisSize.width,
                        config.analysisHeight ?: environment.analysisSize.height,
                        ImageFormat.YUV_420_888,
                        2,
                    ).also { reader ->
                        reader.setOnImageAvailableListener({ source ->
                            analysisFrames++
                            runCatching { source.acquireLatestImage()?.close() }
                        }, environment.handler)
                    }
                }
                if (kind.includeEncoder) {
                    try {
                        val codecResult = createCodec(
                            config.videoWidth,
                            config.videoHeight,
                            onEncoderFrame = { encoderBuffers++ },
                            onCodecError = { codecFailed = true },
                        )
                        phaseCodec = codecResult.codec
                        phaseCodecSurface = codecResult.surface
                    } catch (error: Throwable) {
                        // broad-catch: Probe failures are converted into the existing wire outcomes.
                        val outcome = when (error) {
                            is IllegalArgumentException -> CameraProbeOutcome.CODEC_MISSING
                            is IllegalStateException,
                            is MediaCodec.CodecException,
                            -> CameraProbeOutcome.CODEC_CONFIG_FAILED
                            else -> CameraProbeOutcome.INTERNAL_ERROR
                        }
                        if (outcome == CameraProbeOutcome.INTERNAL_ERROR) {
                            finish(outcome.wire, error.message ?: outcome.wire)
                        } else {
                            retry(outcome.wire, error.message ?: outcome.wire)
                        }
                        return
                    }
                }
                val surfaces = buildList {
                    if (kind.includePreview) add(preview)
                    if (kind.includeAnalysis) phaseReader?.surface?.let(::add)
                    if (kind.includeEncoder) phaseCodecSurface?.let(::add)
                }
                val expected = (if (kind.includePreview) 1 else 0) +
                    (if (kind.includeAnalysis) 1 else 0) +
                    (if (kind.includeEncoder) 1 else 0)
                if (surfaces.size < expected) {
                    finish(CameraProbeOutcome.SURFACE_MISSING.wire, "摄像头输出表面创建失败")
                    return@attempt
                }
                environment.cameraManager.openCamera(
                    cameraId,
                    object : CameraDevice.StateCallback() {
                        override fun onOpened(camera: CameraDevice) {
                            if (environment.isDisposed()) {
                                runCatching { camera.close() }
                                finish(CameraProbeOutcome.INTERNAL_ERROR.wire, "摄像头已关闭")
                                return
                            }
                            phaseCamera = camera
                            environment.updateCameraDevice(camera)
                            try {
                                camera.createCaptureSession(
                                    surfaces,
                                    object : CameraCaptureSession.StateCallback() {
                                        override fun onConfigured(session: CameraCaptureSession) {
                                            if (environment.isDisposed()) {
                                                runCatching { session.close() }
                                                finish(
                                                    CameraProbeOutcome.INTERNAL_ERROR.wire,
                                                    "摄像头已关闭",
                                                )
                                                return
                                            }
                                            environment.handler.removeCallbacks(configTimeout)
                                            phaseSession = session
                                            try {
                                                val request = camera.createCaptureRequest(
                                                    if (kind.includeEncoder) {
                                                        CameraDevice.TEMPLATE_RECORD
                                                    } else {
                                                        CameraDevice.TEMPLATE_PREVIEW
                                                    },
                                                ).apply {
                                                    if (kind.includePreview) {
                                                        environment.previewSurface()?.let(::addTarget)
                                                    }
                                                    if (kind.includeAnalysis) {
                                                        phaseReader?.surface?.let(::addTarget)
                                                    }
                                                    if (kind.includeEncoder) {
                                                        phaseCodecSurface?.let(::addTarget)
                                                    }
                                                    environment.applyAutomaticCameraControls(
                                                        this,
                                                        characteristics,
                                                    )
                                                }.build()
                                                session.setRepeatingRequest(
                                                    request,
                                                    object : CameraCaptureSession.CaptureCallback() {
                                                        override fun onCaptureCompleted(
                                                            session: CameraCaptureSession,
                                                            request: CaptureRequest,
                                                            result: TotalCaptureResult,
                                                        ) {
                                                            previewFrames++
                                                        }
                                                    },
                                                    environment.handler,
                                                )
                                            } catch (error: Throwable) {
                                                // broad-catch: Camera2 request errors end the probe as infra errors.
                                                finish(
                                                    CameraProbeOutcome.INTERNAL_ERROR.wire,
                                                    error.message ?: "探针重复请求提交失败",
                                                )
                                                return
                                            }
                                            val window = Runnable {
                                                finish(
                                                    if (codecFailed) {
                                                        CameraProbeOutcome.INTERNAL_ERROR.wire
                                                    } else {
                                                        CameraProbeOutcome.CONFIGURED.wire
                                                    },
                                                    null,
                                                )
                                            }
                                            environment.handler.postDelayed(window, phaseWindowMs)
                                        }

                                        override fun onConfigureFailed(
                                            session: CameraCaptureSession,
                                        ) {
                                            runCatching { session.close() }
                                            retry(CameraProbeOutcome.CONFIGURE_FAILED.wire, null)
                                        }
                                    },
                                    environment.handler,
                                )
                            } catch (error: Throwable) {
                                // broad-catch: Camera2 setup failures retain their existing classification.
                                val outcome = CameraProbeOutcomePolicy.sessionCreateError(error)
                                if (outcome == CameraProbeOutcome.UNSUPPORTED_COMBINATION) {
                                    retry(outcome.wire, error.message ?: outcome.wire)
                                } else {
                                    finish(outcome.wire, error.message ?: outcome.wire)
                                }
                            }
                        }

                        override fun onDisconnected(camera: CameraDevice) {
                            runCatching { camera.close() }
                            if (camera === environment.cameraDevice()) {
                                environment.updateCameraDevice(null)
                            }
                            finish(CameraProbeOutcome.CAMERA_DISCONNECTED.wire, null)
                        }

                        override fun onError(camera: CameraDevice, error: Int) {
                            runCatching { camera.close() }
                            if (camera === environment.cameraDevice()) {
                                environment.updateCameraDevice(null)
                            }
                            val outcome = CameraProbeOutcomePolicy.cameraStateError(error)
                            finish(outcome.wire, "camera_error_$error")
                        }
                    },
                    environment.handler,
                )
            } catch (error: Throwable) {
                // broad-catch: Camera open failures retain their existing wire classification.
                val outcome = CameraProbeOutcomePolicy.cameraOpenError(error)
                finish(outcome.wire, error.message ?: outcome.wire)
            }
        }
        attempt(0, CameraProbeOutcome.CONFIGURE_FAILED.wire, null)
    }

    private fun emptyResult(
        label: String,
        outcome: String,
        detail: String?,
    ): Map<String, Any?> = CameraDiagnosticsSnapshotMapper.probePhaseResult(
        label,
        null,
        outcome,
        detail,
        0,
        0,
        0,
        0,
    )

    private fun createCodec(
        width: Int,
        height: Int,
        onEncoderFrame: () -> Unit,
        onCodecError: () -> Unit,
    ): ProbeCodecHandle {
        val codec = MediaCodec.createEncoderByType(environment.selectedVideoMime)
        codec.setCallback(
            object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

                override fun onOutputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                    info: MediaCodec.BufferInfo,
                ) {
                    if (info.size > 0 &&
                        info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                    ) {
                        onEncoderFrame()
                    }
                    runCatching { codec.releaseOutputBuffer(index, false) }
                }

                override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
                    onCodecError()
                }

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) = Unit
            },
            environment.handler,
        )
        codec.configure(
            environment.createEncoderFormat(environment.selectedVideoMime, width, height),
            null,
            null,
            MediaCodec.CONFIGURE_FLAG_ENCODE,
        )
        val surface = codec.createInputSurface()
        codec.start()
        return ProbeCodecHandle(codec, surface)
    }

    private data class ProbeCodecHandle(
        val codec: MediaCodec,
        val surface: Surface,
    )

    private companion object {
        const val DEFAULT_PHASE_WINDOW_MS = 1_200L
        const val DEFAULT_CONFIG_TIMEOUT_MS = 2_500L
        const val DEFAULT_PHASE_BUDGET_MS = 4_500L
    }
}
