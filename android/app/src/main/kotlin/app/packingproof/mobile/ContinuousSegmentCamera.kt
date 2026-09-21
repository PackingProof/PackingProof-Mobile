package app.packingproof.mobile

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.StreamConfigurationMap
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.os.StatFs
import android.os.Debug
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.max

internal const val CONTINUOUS_CAMERA_PROBE_TIMEOUT_MS = 2_500L
internal const val CONTINUOUS_CAMERA_CAPABILITY_PROBE_SCHEMA_VERSION = 1
internal const val CONTINUOUS_CAMERA_PIPELINE_VERSION = 2
internal val CONTINUOUS_CAMERA_PROBE_TRIGGER_STAGES = setOf(
    "camera_open", "camera_error", "camera_disconnected", "camera_disabled",
    "session_config", "session_create", "capture_request",
)

/** 进程内共享的初始化组合探针结果，避免重试时重复探测。 */
internal object ContinuousCameraInitProbeCache {
    @Volatile var results: List<Map<String, Any?>>? = null
    @Volatile var inProgress = false
}

/**
 * Keeps one Camera2 session and one hardware video encoder alive while work is active.
 * Barcode boundaries only rotate the MP4 muxer, so preview and camera capture
 * never restart. Each completed label is therefore an independent physical file.
 */
class ContinuousSegmentCamera(
    private val activity: Activity,
    private val textures: TextureRegistry,
    private val preferredLensFacing: Int = CameraCharacteristics.LENS_FACING_BACK,
    private val preferredCameraId: String? = null,
    internal val emit: (String, Any?) -> Unit,
) {
    companion object {
        private const val ANALYSIS_INTERVAL_MS = 250L
        private const val START_TIMEOUT_MS = 6_000L
        private const val SPLIT_TIMEOUT_MS = 3_000L
        private const val CAMERA_LOG_TAG = "PackingProof.Camera"
        private const val PREVIEW_STALL_THRESHOLD_MS = 1_500L
        private const val PREVIEW_STALL_CHECK_INTERVAL_MS = 2_000L
        private const val MUX_WRITE_STALL_THRESHOLD_MS = 100L
        private const val CAMERA_DISABLED_MESSAGE =
            "摄像头被系统或设备策略禁用，请检查摄像头访问开关"
        private const val START_STALL_FALLBACK_THRESHOLD_MS = 2_500L
    }

    private val mainHandler = Handler(activity.mainLooper)
    internal val cameraManager = activity.getSystemService(CameraManager::class.java)
    private val backCameraCatalog = BackCameraCatalog(cameraManager)
    private val captureRequestTargetPolicy = CaptureRequestTargetPolicy()
    private val recordingSpecState = RecordingSpecRuntimeState()
    private val recordingFpsRangePolicy get() = recordingSpecState.fpsRangePolicy
    private val stallRecoveryPolicy = PreviewStallRecoveryPolicy()
    private val recordingSpec get() = recordingSpecState.spec
    internal val recordingSpecName get() = recordingSpecState.name
    private var recordingOrientationName = "portrait"
    @Volatile private var captureStartedCount = 0L
    @Volatile private var lastCaptureStartedAtMs = 0L
    @Volatile private var lastCaptureCompletedAtMs = 0L
    @Volatile private var stallActive = false
    @Volatile private var stallRecoveryStage = 0
    private var stallRecoveryBaseCaptureMs = 0L
    private var stallRecoveryLastLogAtMs = 0L
    @Volatile private var muxWriteMaxMs = 0L
    @Volatile private var muxWriteStallCount = 0L
    @Volatile private var lastRequestTemplate = "preview"
    private val barcodeScanner: BarcodeScanner = BarcodeScanning.getClient(
        BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_ALL_FORMATS).build(),
    )

    private var cameraThread: HandlerThread? = null
    internal var cameraHandler: Handler? = null
    private var muxThread: HandlerThread? = null
    internal var muxHandler: Handler? = null

    internal var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    internal var previewSurface: Surface? = null
    private var cameraGlCompositor: CameraGlCompositor? = null
    private var compositorInputSurface: Surface? = null
    @Volatile internal var cameraSurfacePipeline = CameraSurfacePipeline.GL_COMPOSITOR
    @Volatile private var cameraSurfaceFallbackReason: String? = null
    @Volatile private var glFailureStage: String? = null
    @Volatile private var glFailureOutput: String? = null
    @Volatile private var glFailureApi: String? = null
    @Volatile private var glFailureErrorCode: String? = null
    @Volatile private var glFailureType: String? = null
    internal var cameraDevice: CameraDevice? = null
    @Volatile internal var selectedCameraId: String? = null
    @Volatile internal var selectedCameraCharacteristics: CameraCharacteristics? = null
    internal var captureSession: CameraCaptureSession? = null
    private var analysisReader: ImageReader? = null
    @Volatile private var sensorOrientation = 90
    @Volatile private var selectedLensFacing = CameraCharacteristics.LENS_FACING_BACK
    @Volatile private var selectedZoomRatio = 1.0
    private var cachedBackLenses: List<Map<String, Any?>>? = null
    private var cachedCameraIdList: List<String> = emptyList()
    private var cachedZoomRatioRange: List<Float>? = null
    @Volatile private var canSwitchCamera = false
    @Volatile private var switchCount = 0
    @Volatile private var lastSwitchDurationMs = 0L
    @Volatile private var lastSwitchRestartedEncoder = false
    private var pendingSwitchStartedAtMs = 0L
    @Volatile internal var videoSize = Size(
        RecordingSpecPolicy.HD.videoWidth,
        RecordingSpecPolicy.HD.videoHeight,
    )
    @Volatile internal var analysisSize = Size(1280, 720)
    @Volatile private var sessionConfigStage: String? = null
    @Volatile private var sessionConfigAttempts = 0
    internal val streamConfigPolicy get() = recordingSpecState.streamConfigPolicy
    internal var videoCandidates = emptyList<Size>()
    internal var analysisCandidates = emptyList<Size>()
    private var workingStreamConfig: StreamConfig? = null
    @Volatile internal var initFailureStage: String? = null
    @Volatile private var initFailureDetail: String? = null
    @Volatile private var startFailureStage: String? = null
    @Volatile private var startFailureDetail: String? = null
    @Volatile internal var sessionHasPreview = false
    @Volatile internal var sessionHasEncoder = false
    @Volatile internal var sessionHasAnalysis = false
    @Volatile private var startFallbackTried = false
    @Volatile private var recordingFallbackMode: String? = null
    @Volatile private var capabilityMode = CameraCapabilityMode.UNVERIFIED
    @Volatile private var sessionFallbackEncoderAnalysis = false
    @Volatile internal var capabilityProbeActive = false
    internal var probeRestoreCallback: ((Throwable?) -> Unit)? = null
    @Volatile internal var probeResults: List<Map<String, Any?>> = emptyList()
    @Volatile internal var probeInProgress = false
    @Volatile internal var probeGeneration = 0
    internal val probeReaders = mutableListOf<ImageReader>()
    private var supportedVideoSizes: List<String> = emptyList()
    private var supportedYuvSizes: List<String> = emptyList()
    private var supportedPreviewSizes: List<String> = emptyList()
    private var fpsRanges: List<String> = emptyList()
    @Volatile internal var hardwareLevel: Int? = null
    private var capabilities: List<String> = emptyList()
    private var physicalCameraIds: List<String> = emptyList()
    @Volatile internal var initialized = false
    internal var disposed = false
    private var initializeResult: MethodChannel.Result? = null
    private var previewResumeResult: MethodChannel.Result? = null
    private var openCameraAttempts = 0
    private var audioOutputFormat: MediaFormat? = null

    @Volatile internal var recordingRequested = false
    @Volatile internal var recordingActive = false
    internal var startResult: MethodChannel.Result? = null
    internal var stopResult: MethodChannel.Result? = null
    internal var splitResult: MethodChannel.Result? = null
    private var pendingStartPath: String? = null
    private var pendingSplitPath: String? = null
    private var pendingNextTrackingNumber: String? = null
    private var activeWatermarkTrackingNumber: String = ""
    @Volatile private var pendingWatermarkTransitionPtsUs: Long? = null
    private val liveWatermarkSegmentState = LiveWatermarkSegmentState()
    internal val encodedWatermarkFrameTracker = EncodedWatermarkFrameTracker()
    internal val recordingVideoEncoder = RecordingVideoEncoder(
        recordingSpec = { recordingSpec },
        onSample = ::handleVideoSample,
        onSampleFailure = { error ->
            liveWatermarkSegmentState.markWatermarkFailure()
            encodedWatermarkFrameTracker.reset()
            notifyWriteError("视频写入失败", error)
        },
        onEncoderError = { error ->
            liveWatermarkSegmentState.markWatermarkFailure()
            encodedWatermarkFrameTracker.reset()
            notifyNativeError("视频编码器异常", error)
        },
        onOutputFormatChanged = ::handleVideoEncoderOutputFormatChanged,
        onSyncFrameFailure = { error -> notifyNativeError("无法请求录像关键帧", error) },
    )
    private val recordingMuxPipeline = RecordingMuxPipeline(
        AndroidSegmentMuxerFactory(
            videoFormat = { recordingVideoEncoder.outputFormat },
            audioFormat = { audioOutputFormat },
            onWriteCompleted = ::recordMuxWrite,
        ),
    )
    private val recordingAudioPipeline = RecordingAudioPipeline(
        onSample = { sample ->
            muxHandler?.post { handleAudioSample(sample) }
        },
        onOutputFormat = { format ->
            muxHandler?.post {
                audioOutputFormat = format
                if (recordingRequested && startResult != null) {
                    recordingVideoEncoder.requestSyncFrame()
                }
            }
        },
        onFailure = { error ->
            muxHandler?.post {
                if (startResult != null) {
                    failPendingStart("audio_init", "麦克风或音频编码器启动失败")
                } else {
                    notifyNativeError("声音录制异常", error)
                }
            }
        },
        onStopped = {
            muxHandler?.post {
                if (stopResult != null) finishStop()
            }
        },
    )
    private var storageFailureReported = false

    private var scannerBusy = false
    @Volatile private var analysisGeneration = 0L
    @Volatile private var analysisStartedCount = 0L
    @Volatile private var analysisCompletedCount = 0L
    @Volatile private var analysisDetectedCount = 0L
    @Volatile private var analysisFailureCount = 0L
    @Volatile private var lastAnalysisCompletedElapsedMs = 0L
    @Volatile private var lastAnalysisFailure: String? = null
    @Volatile private var pairingScanEnabled = false
    @Volatile private var workScanEnabled = false
    @Volatile private var torchEnabled = false
    @Volatile private var lastAnalysisElapsedMs = 0L
    @Volatile private var previewActive = true
    private var recordAudio = true

    fun initialize(
        result: MethodChannel.Result,
        videoCodec: String? = null,
        recordingSpecName: String? = null,
        capabilityModeName: String? = null,
        recordingOrientationName: String? = null,
    ) {
        if (disposed) {
            result.error("disposed", "摄像头已经关闭", null)
            return
        }
        if (initialized) {
            result.success(initializationMap())
            return
        }
        if (initializeResult != null) {
            result.error("initializing", "摄像头正在初始化", null)
            return
        }
        initializeResult = result
        openCameraAttempts = 0
        recordingSpecState.request(recordingSpecName)
        this.recordingOrientationName = when (recordingOrientationName) {
            "landscapeLeft", "landscapeRight" -> recordingOrientationName
            else -> "portrait"
        }
        sessionConfigStage = null
        sessionConfigAttempts = 0
        workingStreamConfig = null
        videoCandidates = emptyList()
        analysisCandidates = emptyList()
        initFailureStage = null
        initFailureDetail = null
        startFailureStage = null
        startFailureDetail = null
        probeResults = ContinuousCameraInitProbeCache.results ?: emptyList()
        probeInProgress = false
        sessionHasPreview = false
        sessionHasEncoder = false
        sessionHasAnalysis = false
        cameraSurfacePipeline = CameraSurfacePipeline.GL_COMPOSITOR
        cameraSurfaceFallbackReason = null
        glFailureStage = null
        glFailureOutput = null
        glFailureApi = null
        glFailureErrorCode = null
        glFailureType = null
        startFallbackTried = false
        recordingFallbackMode = null
        capabilityMode = CameraCapabilityMode.fromWire(capabilityModeName)
        sessionFallbackEncoderAnalysis = false
        recordingVideoEncoder.preferredMime = if (videoCodec == "h264") {
            MediaFormat.MIMETYPE_VIDEO_AVC
        } else {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        }
        startThreads()
        textureEntry = textures.createSurfaceTexture()
        muxHandler!!.post {
            try {
                selectCameraConfiguration()
                val output = cameraGlOutputGeometry(videoSize)
                recordingVideoEncoder.prepare(output.width, output.height, muxHandler)
                cameraHandler!!.post { openCamera() }
            } catch (error: Throwable) {
                failInitialization("encoder_init", "视频编码器初始化失败", error)
            }
        }
    }

    fun startWork(
        path: String,
        recordAudio: Boolean,
        trackingNumber: String,
        result: MethodChannel.Result,
    ) {
        val handler = muxHandler
        if (disposed) {
            result.error("disposed", "摄像头已经关闭", null)
            return
        }
        if (!initialized || handler == null) {
            result.error("camera_not_ready", "摄像头尚未准备完成", null)
            return
        }
        handler.post {
            if (recordingRequested || recordingActive || startResult != null) {
                replyError(result, "already_recording", "录像已经开始")
                return@post
            }
            if (!hasRecordingReserve(path)) {
                replyError(
                    result,
                    "storage_low",
                    "存储空间不足 ${reserveGigabytes()}，无法开始录像",
                )
                return@post
            }
            this@ContinuousSegmentCamera.recordAudio = recordAudio
            ensureParent(path)
            storageFailureReported = false
            recordingRequested = true
            resetStallRecovery()
            startFailureStage = null
            startFailureDetail = null
            startFallbackTried = false
            recordingFallbackMode = null
            Log.i(CAMERA_LOG_TAG, "startWork path=$path recordAudio=$recordAudio")
            pendingStartPath = path
            startResult = result
            audioOutputFormat = null
            recordingMuxPipeline.beginRecording()
            liveWatermarkSegmentState.reset()
            encodedWatermarkFrameTracker.reset()
            activeWatermarkTrackingNumber = trackingNumber
            if (cameraSurfacePipeline == CameraSurfacePipeline.GL_COMPOSITOR &&
                cameraGlCompositor != null
            ) {
                cameraGlCompositor?.setWatermark(trackingNumber)
            } else {
                liveWatermarkSegmentState.markWatermarkFailure()
            }
            cameraGlCompositor?.setEncoderEnabled(true)
            recordingVideoEncoder.setSuspended(false)
            if (recordAudio) {
                recordingAudioPipeline.start(enabled = true)
            }
            when (effectiveRecordingMode()) {
                CameraCapabilityMode.UNSUPPORTED -> {
                    failPendingStart("capability_unsupported", "此设备不支持持续录像")
                }
                CameraCapabilityMode.ENCODER_ANALYSIS -> {
                    // 本机已保存兼容模式：直接以“编码器 + 识别”两路会话开始，
                    // 不再先尝试三路，避免每次启动都经历停摆重试。
                    recreateEncoderAnalysisSession(
                        onError = { message ->
                            muxHandler?.post { failPendingStart("session_config", message) }
                        },
                    )
                }
                CameraCapabilityMode.ALTERNATING -> {
                    recreateAlternatingRecordingSession(
                        onError = { message ->
                            muxHandler?.post { failPendingStart("session_config", message) }
                        },
                    )
                }
                CameraCapabilityMode.FULL, CameraCapabilityMode.UNVERIFIED -> {
                    // 后置摄像头在运行中的重复请求上增删录像目标会冻结预览；
                    // 与 camera_android 一致：开始工作时重建会话，让预览+识别+编码
                    // 目标从会话配置起保持固定。
                    recreateCaptureSession(
                        onConfigured = {
                            muxHandler?.post {
                                if (startResult != null && recordingRequested) {
                                    recordingVideoEncoder.requestSyncFrame()
                                }
                            }
                        },
                        onError = { message ->
                            muxHandler?.post { failPendingStart("session_config", message) }
                        },
                    )
                }
            }
            handler.postDelayed({
                if (startResult === result) {
                    failPendingStart("start_timeout", "录像编码器启动超时")
                }
            }, START_TIMEOUT_MS)
        }
    }

    fun split(path: String, trackingNumber: String, result: MethodChannel.Result) {
        val handler = muxHandler
        if (disposed) {
            result.error("disposed", "摄像头已经关闭", null)
            return
        }
        if (handler == null) {
            result.error("camera_not_ready", "摄像头尚未准备完成", null)
            return
        }
        handler.post {
            if (!recordingActive || !recordingMuxPipeline.hasActiveMuxer) {
                replyError(result, "not_recording", "当前没有正在录制的视频")
                return@post
            }
            if (splitResult != null) {
                replyError(result, "split_pending", "上一段录像正在保存")
                return@post
            }
            if (!hasRecordingReserve(path)) {
                // 只是这一段的启动被空间拦住，录制本身还在继续：不上报 storageCritical，
                // 由 Dart 侧先回收空间再重试；清理不出空间时监控会按策略停止录制。
                replyError(
                    result,
                    "storage_low",
                    "存储空间不足 ${reserveGigabytes()}，无法创建下一段录像",
                )
                return@post
            }
            ensureParent(path)
            pendingSplitPath = path
            pendingNextTrackingNumber = trackingNumber
            splitResult = result
            recordingMuxPipeline.beginSplit()
            val compositor = cameraGlCompositor
            if (cameraSurfacePipeline == CameraSurfacePipeline.GL_COMPOSITOR &&
                compositor != null
            ) {
                compositor.prepareWatermarkTransition(
                    trackingNumber,
                    onActivated = {
                        muxHandler?.post {
                            if (splitResult === result &&
                                pendingNextTrackingNumber == trackingNumber
                            ) {
                                recordingVideoEncoder.requestSyncFrame()
                            }
                        }
                    },
                    onFirstFrameSubmitted = { presentationTimeUs, _ ->
                        pendingWatermarkTransitionPtsUs = presentationTimeUs
                    },
                )
            } else {
                recordingVideoEncoder.requestSyncFrame()
            }
            handler.postDelayed({
                if (splitResult === result) {
                    recordingMuxPipeline.cancelSplit(pendingWatermarkTransitionPtsUs)
                    pendingSplitPath = null
                    pendingNextTrackingNumber = null
                    pendingWatermarkTransitionPtsUs = null
                    splitResult = null
                    liveWatermarkSegmentState.markWatermarkFailure()
                    encodedWatermarkFrameTracker.reset()
                    cameraGlCompositor?.setWatermark(activeWatermarkTrackingNumber)
                    replyError(result, "split_timeout", "等待关键帧超时，当前录像仍在继续")
                }
            }, SPLIT_TIMEOUT_MS)
        }
    }

    fun stopWork(result: MethodChannel.Result) {
        val handler = muxHandler
        if (disposed) {
            result.error("disposed", "摄像头已经关闭", null)
            return
        }
        if (handler == null) {
            result.error("camera_not_ready", "摄像头尚未准备完成", null)
            return
        }
        handler.post {
            if (!recordingRequested && !recordingActive) {
                replyError(result, "not_recording", "当前没有正在录制的视频")
                return@post
            }
            if (stopResult != null) {
                replyError(result, "stop_pending", "录像正在保存")
                return@post
            }
            if (splitResult != null) {
                replyError(result, "split_pending", "请等待当前分段保存完成")
                return@post
            }
            stopResult = result
            recordingRequested = false
            recordingActive = false
            cameraGlCompositor?.setEncoderEnabled(false)
            resetStallRecovery()
            Log.i(CAMERA_LOG_TAG, "stopWork")
            recreateCaptureSession()
            recordingAudioPipeline.stop()
            if (!recordingAudioPipeline.hasActiveThread) {
                finishStop()
            }
        }
    }

    fun canSwitchNow(): Boolean = initialized &&
        canSwitchCamera &&
        !recordingRequested &&
        !recordingActive &&
        startResult == null &&
        stopResult == null &&
        splitResult == null &&
        !pairingScanEnabled &&
        !workScanEnabled

    fun currentLensFacing(): Int = selectedLensFacing

    fun currentCameraId(): String? = selectedCameraId

    fun hasBackCamera(cameraId: String): Boolean = cameraId in allBackCameraIds()

    fun switchToCamera(cameraId: String, result: MethodChannel.Result) {
        reconfigureCamera(result, targetCameraId = cameraId)
    }

    fun switchToLensFacing(lensFacing: Int, result: MethodChannel.Result) {
        reconfigureCamera(result, targetLensFacing = lensFacing)
    }

    private fun reconfigureCamera(
        result: MethodChannel.Result,
        targetCameraId: String? = null,
        targetLensFacing: Int? = null,
    ) {
        if (!canSwitchNow()) {
            replyError(result, "camera_busy", "当前状态不能切换摄像头")
            return
        }
        initialized = false
        initializeResult = result
        openCameraAttempts = 0
        pendingSwitchStartedAtMs = SystemClock.elapsedRealtime()
        cameraHandler?.post {
            if (disposed) {
                failInitialization("disposed", "摄像头已经关闭", null)
                return@post
            }
            val previousVideoSize = videoSize
            captureSession?.close()
            captureSession = null
            cameraDevice?.close()
            cameraDevice = null
            analysisReader?.close()
            analysisReader = null
            resetStallRecovery()
            sessionHasPreview = false
            sessionHasEncoder = false
            sessionHasAnalysis = false
            workingStreamConfig = null
            sessionConfigStage = null
            try {
                selectCameraConfiguration(
                    targetCameraId = targetCameraId,
                    targetLensFacing = targetLensFacing,
                )
                val output = cameraGlOutputGeometry(videoSize)
                textureEntry?.surfaceTexture()?.setDefaultBufferSize(output.width, output.height)
                val restartEncoder = CameraSwitchResourcePolicy.shouldRestartEncoder(
                    previousWidth = previousVideoSize.width,
                    previousHeight = previousVideoSize.height,
                    nextWidth = videoSize.width,
                    nextHeight = videoSize.height,
                )
                lastSwitchRestartedEncoder = restartEncoder
                if (restartEncoder) {
                    muxHandler?.post {
                        if (disposed) return@post
                        try {
                            releaseCameraGlCompositor()
                            encodedWatermarkFrameTracker.reset()
                            recordingVideoEncoder.release()
                            val nextOutput = cameraGlOutputGeometry(videoSize)
                            recordingVideoEncoder.prepare(
                                nextOutput.width,
                                nextOutput.height,
                                muxHandler,
                            )
                            recordingVideoEncoder.setSuspended(true)
                            cameraHandler?.post(::openCamera)
                                ?: failInitialization(
                                    "camera_thread",
                                    "摄像头线程不可用",
                                    null,
                                )
                        } catch (error: Throwable) {
                            failInitialization(
                                "encoder_init",
                                "视频编码器初始化失败",
                                error,
                            )
                        }
                    } ?: failInitialization("camera_thread", "编码线程不可用", null)
                } else {
                    openCamera()
                }
            } catch (error: Throwable) {
                failInitialization("camera_switch", "摄像头切换失败", error)
            }
        } ?: failInitialization("camera_thread", "摄像头线程不可用", null)
    }

    /** 探测完成后由 Dart 设置最终工作模式，并清除上一次的临时降级。 */
    fun setCapabilityMode(modeName: String?) {
        capabilityMode = CameraCapabilityMode.fromWire(modeName)
        sessionFallbackEncoderAnalysis = false
        Log.i(CAMERA_LOG_TAG, "capabilityMode=${capabilityMode.name.lowercase()}")
    }

    /**
     * 当前实际使用的录像模式：UNVERIFIED 或 FULL 发生运行时停摆降级时，
     * 当前工作会话临时按 ENCODER_ANALYSIS 运行，但持久结论不被改写。
     */
    private fun effectiveRecordingMode(): CameraCapabilityMode =
        if (sessionFallbackEncoderAnalysis &&
            capabilityMode in setOf(
                CameraCapabilityMode.FULL,
                CameraCapabilityMode.UNVERIFIED,
            )
        ) {
            CameraCapabilityMode.ENCODER_ANALYSIS
        } else {
            capabilityMode
        }

    fun listCameras(): List<Map<String, Any?>> {
        val cached = cachedBackLenses
        if (cached != null) {
            return cached
        }
        return backCameraCatalog.build(backCameraCatalog.defaultId())
            .map(CameraDiagnosticsSnapshotMapper::backLens)
            .also { cachedBackLenses = it }
    }

    private fun allBackCameraIds(): Set<String> = backCameraCatalog.allIds()

    fun dispose(onDisposed: (() -> Unit)? = null) {
        if (disposed) {
            onDisposed?.let { mainHandler.post(it) }
            return
        }
        disposed = true
        ContinuousCameraInitProbeCache.inProgress = false
        probeGeneration++
        probeInProgress = false
        initializeResult?.let { replyError(it, "disposed", "摄像头初始化已取消") }
        previewResumeResult?.let { replyError(it, "disposed", "摄像头恢复已取消") }
        startResult?.let { replyError(it, "disposed", "录像启动已取消") }
        splitResult?.let { replyError(it, "disposed", "录像分段已取消") }
        stopResult?.let { replyError(it, "disposed", "录像保存已取消") }
        recordingAudioPipeline.stop()
        val cleanupCount = AtomicInteger(2)
        fun finishCleanup() {
            if (cleanupCount.decrementAndGet() == 0) onDisposed?.let { mainHandler.post(it) }
        }
        val activeMuxHandler = muxHandler
        val activeCameraHandler = cameraHandler
        if (activeMuxHandler != null) activeMuxHandler.post {
            // 与 muxHandler 上可能在途的开始/停止/分段任务串行清空状态。
            initializeResult = null
            previewResumeResult = null
            startResult = null
            stopResult = null
            splitResult = null
            pendingStartPath = null
            pendingSplitPath = null
            pendingNextTrackingNumber = null
            recordingRequested = false
            recordingActive = false
            initialized = false
            recordingMuxPipeline.close(deleteOutput = false)
            releaseCameraGlCompositor()
            encodedWatermarkFrameTracker.reset()
            recordingVideoEncoder.release()
            finishCleanup()
        } else finishCleanup()
        if (activeCameraHandler != null) activeCameraHandler.post {
            scannerBusy = false
            workScanEnabled = false
            pairingScanEnabled = false
            analysisReader?.close()
            analysisReader = null
            probeReaders.forEach { reader ->
                try {
                    reader.close()
                } catch (_: Throwable) {
                }
            }
            probeReaders.clear()
            captureSession?.close()
            captureSession = null
            resetStallRecovery()
            cameraDevice?.close()
            cameraDevice = null
            cameraHandler?.removeCallbacks(previewStallCheck)
            releaseCameraGlCompositor()
            previewSurface?.release()
            previewSurface = null
            mainHandler.post {
                textureEntry?.release()
                textureEntry = null
                finishCleanup()
            }
        } else finishCleanup()
        barcodeScanner.close()
        cameraThread?.quitSafely()
        muxThread?.quitSafely()
        cameraThread = null
        muxThread = null
        cameraHandler = null
        muxHandler = null
    }

    private fun startThreads() {
        if (cameraThread == null) {
            cameraThread = HandlerThread("parcel-camera").also { it.start() }
            cameraHandler = Handler(cameraThread!!.looper)
        }
        if (muxThread == null) {
            muxThread = HandlerThread("parcel-mux").also { it.start() }
            muxHandler = Handler(muxThread!!.looper)
        }
    }

    @SuppressLint("MissingPermission")
    internal fun openCamera() {
        try {
            val cameraId = selectedCameraId
                ?: throw IllegalStateException("没有检测到可用摄像头")
            val characteristics = selectedCameraCharacteristics
                ?: throw IllegalStateException("无法读取摄像头能力")

            if (previewSurface == null) {
                val surfaceTexture = textureEntry!!.surfaceTexture()
                val output = cameraGlOutputGeometry(videoSize)
                surfaceTexture.setDefaultBufferSize(output.width, output.height)
                previewSurface = Surface(surfaceTexture)
            }
            if (analysisReader == null) {
                analysisReader = ImageReader.newInstance(
                    analysisSize.width,
                    analysisSize.height,
                    ImageFormat.YUV_420_888,
                    2,
                ).also { reader -> reader.setOnImageAvailableListener({ analyzeImage(it) }, cameraHandler) }
            }

            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraDevice = camera
                    openCameraAttempts = 0
                    createCaptureSession(characteristics)
                }

                override fun onDisconnected(camera: CameraDevice) {
                    closeCameraSafely(camera)
                    if ((initializeResult != null || previewResumeResult != null) &&
                        openCameraAttempts < CameraOpenRetryPolicy.MAX_ATTEMPTS
                    ) {
                        retryCameraOpen()
                    } else {
                        failInitialization("camera_disconnected", "摄像头连接已断开", null)
                    }
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    closeCameraSafely(camera)
                    if ((initializeResult != null || previewResumeResult != null) &&
                        CameraOpenRetryPolicy.isTransientStateError(error) &&
                        openCameraAttempts < CameraOpenRetryPolicy.MAX_ATTEMPTS
                    ) {
                        retryCameraOpen()
                    } else {
                        failInitialization(
                            "camera_error",
                            if (error == CameraDevice.StateCallback.ERROR_CAMERA_DISABLED) {
                                CAMERA_DISABLED_MESSAGE
                            } else {
                                "摄像头打开失败（$error）"
                            },
                            null,
                        )
                    }
                }
            }, cameraHandler)
        } catch (error: Throwable) {
            if (error is CameraAccessException &&
                error.reason == CameraAccessException.CAMERA_DISABLED
            ) {
                failInitialization(
                    "camera_disabled",
                    CAMERA_DISABLED_MESSAGE,
                    error,
                )
                return
            }
            if (openCameraAttempts < CameraOpenRetryPolicy.MAX_ATTEMPTS &&
                (error is CameraAccessException || error is SecurityException)
            ) {
                retryCameraOpen()
            } else {
                failInitialization("camera_open", "摄像头打开失败", error)
            }
        }
    }

    internal fun closeCameraSafely(camera: CameraDevice) {
        cameraDevice = null
        try {
            camera.close()
        } catch (_: Throwable) {
        }
    }

    private fun retryCameraOpen() {
        val handler = cameraHandler ?: return
        if (disposed) return
        openCameraAttempts++
        handler.postDelayed(
            { openCamera() },
            CameraOpenRetryPolicy.retryDelayMs(openCameraAttempts - 1),
        )
    }

    private fun selectCameraConfiguration(
        targetCameraId: String? = preferredCameraId,
        targetLensFacing: Int? = preferredLensFacing,
    ) {
        val availableFacing = cameraManager.cameraIdList.mapNotNull { id ->
            cameraManager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING)
        }.toSet()
        canSwitchCamera =
            CameraCharacteristics.LENS_FACING_BACK in availableFacing &&
            CameraCharacteristics.LENS_FACING_FRONT in availableFacing
        val cameraId = when {
            targetCameraId != null &&
                hasBackCamera(targetCameraId) -> targetCameraId
            else -> cameraManager.cameraIdList.firstOrNull { id ->
                cameraManager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING) == targetLensFacing
            } ?: cameraManager.cameraIdList.firstOrNull()
                ?: throw IllegalStateException("没有检测到可用摄像头")
        }
        val characteristics = cameraManager.getCameraCharacteristics(cameraId)
        val configuration = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: throw IllegalStateException("无法读取摄像头输出能力")
        selectedCameraId = cameraId
        selectedCameraCharacteristics = characteristics
        val backLenses = backCameraCatalog.build(backCameraCatalog.defaultId())
        selectedZoomRatio = backLenses.firstOrNull { it.cameraId == cameraId }
            ?.zoomRatio
            ?: 1.0
        cachedBackLenses = backLenses.map(CameraDiagnosticsSnapshotMapper::backLens)
        cachedCameraIdList = cameraManager.cameraIdList.toList()
        cachedZoomRatioRange = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            characteristics
                .get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
                ?.let { listOf(it.lower, it.upper) }
        } else {
            null
        }
        selectedLensFacing = characteristics.get(CameraCharacteristics.LENS_FACING)
            ?: CameraCharacteristics.LENS_FACING_BACK
        sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        val videoSizes = configuration.getOutputSizes(MediaRecorder::class.java)
            ?.toList()
            .orEmpty()
        val analysisSizes = configuration.getOutputSizes(ImageFormat.YUV_420_888)
            ?.toList()
            .orEmpty()
        val availableFpsRanges = characteristics
            .get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?.toList()
            .orEmpty()
        supportedVideoSizes = videoSizes.map {
            CameraDiagnosticsSnapshotMapper.sizeLabel(it.width, it.height)
        }
        supportedYuvSizes = analysisSizes.map {
            CameraDiagnosticsSnapshotMapper.sizeLabel(it.width, it.height)
        }
        supportedPreviewSizes = configuration.getOutputSizes(SurfaceTexture::class.java)
            ?.toList()
            .orEmpty()
            .map { CameraDiagnosticsSnapshotMapper.sizeLabel(it.width, it.height) }
        fpsRanges = availableFpsRanges.map { "${it.lower}-${it.upper}" }
        hardwareLevel = characteristics.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
        capabilities = characteristics.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
            ?.map(CameraDiagnosticsSnapshotMapper::capabilityName)
            .orEmpty()
        physicalCameraIds = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            characteristics.physicalCameraIds.toList()
        } else {
            emptyList()
        }
        val uhdFps = CameraRecordingSpecCapabilityProbe.selectUhdFps(
            configuration, videoSizes, availableFpsRanges, cameraId,
        )
        recordingSpecState.updateUhdFps(uhdFps)
        videoCandidates = streamConfigPolicy.videoCandidates(
            videoSizes.map { StreamSize(it.width, it.height) },
        ).map { Size(it.width, it.height) }
        analysisCandidates = streamConfigPolicy.analysisCandidates(
            analysisSizes.map { StreamSize(it.width, it.height) },
        ).map { Size(it.width, it.height) }
        videoSize = videoCandidates.first()
        analysisSize = analysisCandidates.first()
    }

    private fun createCaptureSession(characteristics: CameraCharacteristics) {
        val camera = cameraDevice ?: return
        val candidates = streamConfigPolicy.initializationCandidates(
            videoCandidates.map { StreamSize(it.width, it.height) },
            analysisCandidates.map { StreamSize(it.width, it.height) },
        )
        submitWithFallback(
            camera = camera,
            candidates = candidates,
            onConfigured = { session ->
                captureSession = session
                try {
                    if (!previewActive) {
                        initialized = true
                        val result = initializeResult
                        initializeResult = null
                        if (result != null) replySuccess(result, initializationMap())
                        initialized = false
                        session.close()
                        captureSession = null
                        sessionHasPreview = false
                        sessionHasEncoder = false
                        sessionHasAnalysis = false
                        if (cameraDevice === camera) {
                            camera.close()
                            cameraDevice = null
                        }
                        Log.i(
                            CAMERA_LOG_TAG,
                            "camera initialization completed while preview suspended",
                        )
                        return@submitWithFallback
                    }
                    applyCaptureRequest(session, camera, characteristics)
                    initialized = true
                    schedulePreviewStallCheck()
                    Log.i(
                        CAMERA_LOG_TAG,
                        "camera session configured cameraId=$selectedCameraId " +
                            "video=$videoSize analysis=$analysisSize " +
                                "mime=${recordingVideoEncoder.selectedMime}",
                    )
                    if (pendingSwitchStartedAtMs > 0L) {
                        lastSwitchDurationMs =
                            SystemClock.elapsedRealtime() - pendingSwitchStartedAtMs
                        pendingSwitchStartedAtMs = 0L
                        switchCount++
                        Log.i(
                            CAMERA_LOG_TAG,
                            "camera switch configured durationMs=$lastSwitchDurationMs " +
                                "encoderRestarted=$lastSwitchRestartedEncoder",
                        )
                    }
                    val result = initializeResult
                    initializeResult = null
                    if (result != null) replySuccess(result, initializationMap())
                    val resumed = previewResumeResult
                    previewResumeResult = null
                    if (resumed != null) replySuccess(resumed, null)
                    val restoreCallback = probeRestoreCallback
                    probeRestoreCallback = null
                    restoreCallback?.invoke(null)
                } catch (error: Throwable) {
                    failInitialization("capture_request", "摄像头预览启动失败", error)
                }
            },
            onFinalFailure = { message ->
                closeCameraResourcesForRetry()
                failInitialization("session_config", message, null)
            },
        )
    }

    private fun submitCaptureSession(
        camera: CameraDevice,
        surfaces: List<Surface>,
        onConfigured: (CameraCaptureSession) -> Unit,
        onConfigureFailed: () -> Unit,
        onCreateFailed: (Throwable) -> Unit,
    ) {
        try {
            camera.createCaptureSession(
                surfaces,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (disposed) {
                            session.close()
                            return
                        }
                        onConfigured(session)
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        onConfigureFailed()
                    }
                },
                cameraHandler,
            )
        } catch (error: Throwable) {
            onCreateFailed(error)
        }
    }

    internal fun applyAutomaticCameraControls(
        request: CaptureRequest.Builder,
        characteristics: CameraCharacteristics,
    ) {
        request.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)

        chooseSupportedMode(
            characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES),
            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO,
            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE,
            CaptureRequest.CONTROL_AF_MODE_AUTO,
        )?.let { request.set(CaptureRequest.CONTROL_AF_MODE, it) }

        chooseSupportedMode(
            characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES),
            CaptureRequest.CONTROL_AE_MODE_ON,
        )?.let { request.set(CaptureRequest.CONTROL_AE_MODE, it) }
        if (characteristics.get(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true) {
            request.set(CaptureRequest.CONTROL_AE_LOCK, false)
        }

        chooseSupportedMode(
            characteristics.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES),
            CaptureRequest.CONTROL_AWB_MODE_AUTO,
        )?.let { request.set(CaptureRequest.CONTROL_AWB_MODE, it) }
        if (characteristics.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) == true) {
            request.set(CaptureRequest.CONTROL_AWB_LOCK, false)
        }

        chooseSupportedMode(
            characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_ANTIBANDING_MODES),
            CaptureRequest.CONTROL_AE_ANTIBANDING_MODE_AUTO,
            CaptureRequest.CONTROL_AE_ANTIBANDING_MODE_50HZ,
            CaptureRequest.CONTROL_AE_ANTIBANDING_MODE_60HZ,
        )?.let { request.set(CaptureRequest.CONTROL_AE_ANTIBANDING_MODE, it) }

        chooseSupportedMode(
            characteristics.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES),
            CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
        )?.let { request.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, it) }
        chooseSupportedMode(
            characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION),
            CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON,
        )?.let { request.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, it) }

        chooseSupportedMode(
            characteristics.get(CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES),
            CaptureRequest.NOISE_REDUCTION_MODE_FAST,
            CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY,
        )?.let { request.set(CaptureRequest.NOISE_REDUCTION_MODE, it) }
        chooseSupportedMode(
            characteristics.get(CameraCharacteristics.EDGE_AVAILABLE_EDGE_MODES),
            CaptureRequest.EDGE_MODE_FAST,
            CaptureRequest.EDGE_MODE_HIGH_QUALITY,
        )?.let { request.set(CaptureRequest.EDGE_MODE, it) }
    }

    private fun chooseSupportedMode(availableModes: IntArray?, vararg preferredModes: Int): Int? {
        if (availableModes == null) return null
        return preferredModes.firstOrNull(availableModes::contains)
    }

    private fun submitWithFallback(
        camera: CameraDevice,
        candidates: List<StreamConfig>,
        onConfigured: (CameraCaptureSession) -> Unit,
        onFinalFailure: (String) -> Unit,
    ) {
        val config = candidates.firstOrNull()
        if (config == null) {
            onFinalFailure("摄像头无法同时提供预览、识别和录像")
            return
        }
        val remaining = candidates.drop(1)
        applyStreamConfig(
            config = config,
            onReady = {
                sessionConfigAttempts++
                val surfaces = sessionSurfaces(config)
                val expected = CameraSurfaceTopologyPolicy.create(
                    pipeline = cameraSurfacePipeline,
                    includePreview = true,
                    includeEncoder = config.includeEncoder,
                    includeAnalysis = true,
                ).cameraSurfaceCount
                if (surfaces.size < expected) {
                    onFinalFailure("摄像头输出表面创建失败")
                    return@applyStreamConfig
                }
                submitCaptureSession(
                    camera = camera,
                    surfaces = surfaces,
                    onConfigured = { session ->
                        workingStreamConfig = config
                        sessionConfigStage = config.label
                        sessionHasPreview = true
                        sessionHasEncoder = cameraSurfacePipeline ==
                            CameraSurfacePipeline.GL_COMPOSITOR || config.includeEncoder
                        sessionHasAnalysis = true
                        Log.i(
                            CAMERA_LOG_TAG,
                            "camera session configured stage=${config.label} " +
                                "pipeline=${cameraSurfacePipeline.name.lowercase()}",
                        )
                        onConfigured(session)
                    },
                    onConfigureFailed = {
                        Log.w(CAMERA_LOG_TAG, "camera session configure failed stage=${config.label}")
                        submitWithFallback(camera, remaining, onConfigured, onFinalFailure)
                    },
                    onCreateFailed = { error ->
                        Log.w(
                            CAMERA_LOG_TAG,
                            "camera session create failed stage=${config.label}",
                            error,
                        )
                        submitWithFallback(camera, remaining, onConfigured, onFinalFailure)
                    },
                )
            },
            onFailure = { message -> onFinalFailure(message) },
        )
    }

    private fun applyStreamConfig(
        config: StreamConfig,
        onReady: () -> Unit,
        onFailure: (String) -> Unit,
    ) {
        val video = config.toVideoSize()
        val analysis = config.toAnalysisSize()
        val encoderChanged = video != videoSize
        val analysisChanged = analysis != analysisSize
        if (recordingSpecState.shouldRejectUhd(video.width, video.height)) {
            recordingSpecState.rejectUhd(selectedCameraId)
        }
        val applyCameraSide = {
            if (analysisChanged) recreateAnalysisReader(analysis)
            prepareFramePipeline(video)
            onReady()
        }
        if (encoderChanged) {
            val handler = muxHandler
            if (handler == null) {
                onFailure("摄像头会话创建失败")
                return
            }
            handler.post {
                if (disposed) return@post
                videoSize = video
                if (
                    CameraSurfaceLifecyclePolicy.shouldRebuildCompositor(
                        pipeline = cameraSurfacePipeline,
                        compositorReady = cameraGlCompositor != null,
                        videoSizeChanged = true,
                        encoderSurfaceChanged = true,
                    )
                ) {
                    releaseCameraGlCompositor()
                }
                encodedWatermarkFrameTracker.reset()
                recordingVideoEncoder.release()
                try {
                    val output = cameraGlOutputGeometry(videoSize)
                    recordingVideoEncoder.prepare(
                        output.width,
                        output.height,
                        muxHandler,
                    )
                    recordingVideoEncoder.setSuspended(
                        !(recordingRequested || recordingActive),
                    )
                } catch (error: Throwable) {
                    notifyNativeError("视频编码器初始化失败", error)
                    onFailure(error.message ?: "视频编码器初始化失败")
                    return@post
                }
                cameraHandler?.post {
                    if (disposed) return@post
                    applyCameraSide()
                } ?: onFailure("摄像头会话创建失败")
            }
        } else {
            cameraHandler?.post {
                if (disposed) return@post
                applyCameraSide()
            } ?: onFailure("摄像头会话创建失败")
        }
    }

    private fun sessionSurfaces(config: StreamConfig): List<Surface> =
        cameraSurfaces(
            includePreview = true,
            includeEncoder = config.includeEncoder,
            includeAnalysis = true,
        )

    private fun recreateAnalysisReader(size: Size) {
        analysisReader?.close()
        analysisReader = null
        analysisSize = size
        val reader = ImageReader.newInstance(
            size.width,
            size.height,
            ImageFormat.YUV_420_888,
            2,
        )
        reader.setOnImageAvailableListener({ analyzeImage(it) }, cameraHandler)
        analysisReader = reader
    }

    private fun prepareFramePipeline(size: Size) {
        val entry = textureEntry ?: return
        val output = cameraGlOutputGeometry(size)
        entry.surfaceTexture().setDefaultBufferSize(output.width, output.height)
        if (previewSurface == null) {
            previewSurface = Surface(entry.surfaceTexture())
        }
        videoSize = size
        if (!CameraSurfaceLifecyclePolicy.shouldRebuildCompositor(
                pipeline = cameraSurfacePipeline,
                compositorReady = cameraGlCompositor != null,
                videoSizeChanged = false,
                encoderSurfaceChanged = false,
            )
        ) {
            return
        }
        val preview = previewSurface ?: return
        val encoder = recordingVideoEncoder.inputSurface
        if (encoder == null) {
            fallbackToDirectCameraPipeline(
                stage = "encoder_surface_missing",
                error = IllegalStateException("视频编码器输出表面不存在"),
                recreateSession = false,
            )
            return
        }
        try {
            val compositor = CameraGlCompositor(
                inputWidth = size.width,
                inputHeight = size.height,
                width = output.width,
                height = output.height,
                inputQuarterTurns = output.inputQuarterTurns,
                previewOutput = preview,
                encoderOutput = encoder,
                recordingOrientation = recordingOrientationName,
                onFailure = ::handleCameraGlFailure,
                onEncodedWatermarkFrame = { presentationTimeUs, rendered ->
                    if (encodedWatermarkFrameTracker.recordSubmitted(
                            presentationTimeUs,
                            rendered,
                        )
                    ) {
                        liveWatermarkSegmentState.markWatermarkFailure()
                    }
                },
                onWatermarkFailure = { error ->
                    liveWatermarkSegmentState.markWatermarkFailure()
                    recordCameraGlFailure("watermark_overlay", "encoder", error)
                    Log.e(CAMERA_LOG_TAG, "live watermark overlay disabled", error)
                },
            )
            val input = compositor.start()
            val attached = attachCameraGlCompositor(compositor, input)
            if (!attached) {
                compositor.release()
                return
            }
            // 预览与编码共用同一个 GL 水印渲染器。空闲时只显示时间，
            // 开始录像后在同一图层加入面单号，避免 Flutter/原生两套水印跳变。
            compositor.setWatermark("")
            compositor.setEncoderEnabled(recordingRequested || recordingActive)
            Log.i(
                CAMERA_LOG_TAG,
                "camera GL compositor ready size=${size.width}x${size.height}",
            )
        } catch (error: Throwable) {
            // broad-catch: 任意合成器初始化错误都必须回退到可录像的直接链路
            fallbackToDirectCameraPipeline(
                stage = "compositor_init",
                error = error,
                recreateSession = false,
            )
        }
    }

    private fun cameraSurfaces(
        includePreview: Boolean,
        includeEncoder: Boolean,
        includeAnalysis: Boolean,
    ): List<Surface> {
        val topology = CameraSurfaceTopologyPolicy.create(
            pipeline = cameraSurfacePipeline,
            includePreview = includePreview,
            includeEncoder = includeEncoder,
            includeAnalysis = includeAnalysis,
        )
        cameraGlCompositor?.setEncoderEnabled(topology.compositorEncoderEnabled)
        return buildList {
            if (topology.cameraUsesFrameSurface) compositorInputSurface?.let(::add)
            if (topology.cameraUsesPreviewSurface) previewSurface?.let(::add)
            if (topology.cameraUsesEncoderSurface) {
                recordingVideoEncoder.inputSurface?.let(::add)
            }
            if (topology.cameraUsesAnalysisSurface) analysisReader?.surface?.let(::add)
        }
    }

    @Synchronized
    private fun attachCameraGlCompositor(
        compositor: CameraGlCompositor,
        inputSurface: Surface,
    ): Boolean {
        if (disposed ||
            cameraSurfacePipeline != CameraSurfacePipeline.GL_COMPOSITOR ||
            cameraGlCompositor != null
        ) {
            return false
        }
        cameraGlCompositor = compositor
        compositorInputSurface = inputSurface
        return true
    }

    @Synchronized
    internal fun releaseCameraGlCompositor() {
        cameraGlCompositor?.release()
        cameraGlCompositor = null
        compositorInputSurface = null
    }

    private fun handleCameraGlFailure(failure: CameraGlFailure) {
        cameraHandler?.post {
            if (disposed || cameraSurfacePipeline != CameraSurfacePipeline.GL_COMPOSITOR) {
                return@post
            }
            fallbackToDirectCameraPipeline(
                stage = "compositor_${failure.output.name.lowercase()}",
                error = failure.error,
                recreateSession = true,
                output = failure.output.name.lowercase(),
            )
        }
    }

    private fun fallbackToDirectCameraPipeline(
        stage: String,
        error: Throwable,
        recreateSession: Boolean,
        output: String? = null,
    ) {
        if (cameraSurfacePipeline == CameraSurfacePipeline.DIRECT) return
        recordCameraGlFailure(stage, output, error)
        liveWatermarkSegmentState.markWatermarkFailure()
        encodedWatermarkFrameTracker.reset()
        cameraSurfacePipeline = CameraSurfaceLifecyclePolicy.failureFallback(
            cameraSurfacePipeline,
        )
        cameraSurfaceFallbackReason = "$stage:${error.javaClass.simpleName}"
        Log.e(
            CAMERA_LOG_TAG,
            "camera GL compositor unavailable; falling back to direct Camera2 stage=$stage",
            error,
        )
        emit(
            "cameraPipelineFallback",
            mapOf(
                "pipeline" to "direct",
                "stage" to stage,
                "errorType" to error.javaClass.simpleName,
            ),
        )
        if (recreateSession) {
            runCatching { captureSession?.close() }
            captureSession = null
            sessionHasPreview = false
            sessionHasEncoder = false
            sessionHasAnalysis = false
        }
        releaseCameraGlCompositor()
        if (recreateSession && !disposed) {
            recreateCaptureSession(
                onError = { message ->
                    notifyNativeError("摄像头直连管线恢复失败：$message", error)
                },
            )
        }
    }

    private fun recordCameraGlFailure(
        fallbackStage: String,
        output: String?,
        error: Throwable,
    ) {
        val operation = error as? CameraGlOperationException
        glFailureStage = operation?.stage ?: fallbackStage
        glFailureOutput = output
        glFailureApi = operation?.api
        glFailureErrorCode = operation?.errorCode?.let { "0x${it.toString(16)}" }
        glFailureType = error.javaClass.simpleName
    }

    private fun analyzeImage(reader: ImageReader) {
        val image = reader.acquireLatestImage() ?: return
        if (!shouldAnalyzeBarcodeFrame(
                previewActive = previewActive,
                pairingScanEnabled = pairingScanEnabled,
                workScanEnabled = workScanEnabled,
                scannerBusy = scannerBusy,
                elapsedSinceLastAnalysisMs = SystemClock.elapsedRealtime() - lastAnalysisElapsedMs,
                analysisIntervalMs = ANALYSIS_INTERVAL_MS,
            )
        ) {
            image.close()
            return
        }
        scannerBusy = true
        val generation = analysisGeneration
        lastAnalysisElapsedMs = SystemClock.elapsedRealtime()
        analysisStartedCount++
        try {
            val input = InputImage.fromMediaImage(image, sensorOrientation)
            barcodeScanner.process(input)
                .addOnSuccessListener { barcodes ->
                    if (!shouldAcceptBarcodeAnalysisResult(
                            resultGeneration = generation,
                            activeGeneration = analysisGeneration,
                            previewActive = previewActive,
                        )
                    ) {
                        return@addOnSuccessListener
                    }
                    recordAnalysisResult(barcodes.size)
                    val detectedAtMs = System.currentTimeMillis()
                    val values = barcodes.mapNotNull { barcode ->
                        val raw = barcode.rawValue?.trim().orEmpty()
                        if (raw.isEmpty()) null else mapOf(
                            "value" to raw,
                            "area" to ((barcode.boundingBox ?: Rect()).let { it.width().toLong() * it.height() }),
                            "format" to barcodeFormatName(barcode.format),
                            "detectedAtMs" to detectedAtMs,
                        )
                    }
                    emit("barcodeFrame", values)
                }
                .addOnFailureListener { error ->
                    if (!shouldAcceptBarcodeAnalysisResult(
                            resultGeneration = generation,
                            activeGeneration = analysisGeneration,
                            previewActive = previewActive,
                        )
                    ) {
                        return@addOnFailureListener
                    }
                    recordAnalysisResult(0, error)
                    emit("barcodeFrame", emptyList<Any>())
                }
                .addOnCompleteListener {
                    cameraHandler?.post {
                        image.close()
                        if (generation == analysisGeneration) {
                            scannerBusy = false
                        }
                    }
                }
        } catch (error: Throwable) {
            recordAnalysisResult(0, error)
            image.close()
            scannerBusy = false
        }
    }

    private fun recordAnalysisResult(count: Int, error: Throwable? = null) {
        analysisCompletedCount++
        lastAnalysisCompletedElapsedMs = SystemClock.elapsedRealtime()
        if (count > 0) analysisDetectedCount += count
        if (error != null) {
            analysisFailureCount++
            lastAnalysisFailure = "${error.javaClass.simpleName}: ${error.message.orEmpty()}"
        }
    }

    private fun refreshCaptureRequest() {
        cameraHandler?.post {
            if (!previewActive || !initialized) return@post
            val session = captureSession ?: return@post
            val camera = cameraDevice ?: return@post
            val characteristics = selectedCameraCharacteristics ?: return@post
            try {
                applyCaptureRequest(session, camera, characteristics)
            } catch (error: Throwable) {
                notifyNativeError("摄像头输出模式切换失败", error)
            }
        }
    }

    private val captureCallback = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureStarted(
            session: CameraCaptureSession,
            request: CaptureRequest,
            timestamp: Long,
            frameNumber: Long,
        ) {
            val now = SystemClock.elapsedRealtime()
            val previous = lastCaptureStartedAtMs
            if (previous != 0L && now - previous > PREVIEW_STALL_THRESHOLD_MS) {
                markStall(now - previous)
            }
            captureStartedCount++
            lastCaptureStartedAtMs = now
        }

        override fun onCaptureCompleted(
            session: CameraCaptureSession,
            request: CaptureRequest,
            result: TotalCaptureResult,
        ) {
            lastCaptureCompletedAtMs = SystemClock.elapsedRealtime()
            if (stallActive) {
                stallActive = false
                stallRecoveryStage = 0
                stallRecoveryBaseCaptureMs = 0L
                Log.i(CAMERA_LOG_TAG, "preview recovered: captures resumed")
            }
        }
    }

    private val previewStallCheck = Runnable {
        if (disposed || !initialized) return@Runnable
        val now = SystemClock.elapsedRealtime()
        val last = lastCaptureStartedAtMs
        val recording = recordingRequested || recordingActive
        if (last != 0L && previewActive && now - last > PREVIEW_STALL_THRESHOLD_MS) {
            markStall(now - last)
            if (recordingRequested &&
                !startFallbackTried &&
                now - last > START_STALL_FALLBACK_THRESHOLD_MS
            ) {
                if (recordingActive) {
                    // 录像已开始但管线停摆：当前工作会话降级为两路并提示用户；
                    // 已探明能力的模式不被永久改写，下次工作仍按探测结果开始。
                    startFallbackTried = true
                    sessionFallbackEncoderAnalysis = true
                    Log.w(
                        CAMERA_LOG_TAG,
                        "recording stall while active; save encoder+analysis mode for next start",
                    )
                    emit(
                        "recordingFallback",
                        mapOf(
                            "mode" to "encoder_analysis",
                            "phase" to "stall_during_recording",
                        ),
                    )
                } else if (startResult != null) {
                    runStartStallFallback()
                }
            }
            runStallRecoveryStep(now, last, recording)
        } else if (stallActive) {
            stallActive = false
            stallRecoveryStage = 0
            stallRecoveryBaseCaptureMs = 0L
            Log.i(CAMERA_LOG_TAG, "preview recovered: captures resumed")
        }
        schedulePreviewStallCheck()
    }

    private fun runStallRecoveryStep(
        nowMs: Long,
        lastCaptureMs: Long,
        recording: Boolean,
    ) {
        when (stallRecoveryPolicy.nextAction(stallRecoveryStage, recording, stallActive)) {
            PreviewStallRecoveryAction.REAPPLY_REQUEST -> {
                stallRecoveryStage = 1
                stallRecoveryBaseCaptureMs = lastCaptureMs
                Log.w(CAMERA_LOG_TAG, "preview recovery stage=reapply request")
                refreshCaptureRequest()
            }
            PreviewStallRecoveryAction.RECREATE_SESSION -> {
                if (lastCaptureStartedAtMs == stallRecoveryBaseCaptureMs) {
                    stallRecoveryStage = 2
                    stallRecoveryBaseCaptureMs = lastCaptureStartedAtMs
                    Log.w(CAMERA_LOG_TAG, "preview recovery stage=recreate session")
                    recreateCaptureSession()
                }
            }
            PreviewStallRecoveryAction.LOG_FAILURE -> {
                if (nowMs - stallRecoveryLastLogAtMs >= 10_000L) {
                    stallRecoveryLastLogAtMs = nowMs
                    Log.w(
                        CAMERA_LOG_TAG,
                        "preview recovery failed: captures still stalled " +
                            "recording=$recording request=$lastRequestTemplate",
                    )
                }
            }
            PreviewStallRecoveryAction.NONE -> Unit
        }
    }

    private fun resetStallRecovery() {
        stallRecoveryStage = 0
        stallRecoveryBaseCaptureMs = 0L
        stallRecoveryLastLogAtMs = 0L
    }

    /**
     * 录像启动阶段三路会话停摆（部分机型如荣耀 X70 / Android 16 的 HAL
     * 无法持续输出预览+编码+识别三路）时，自动降级为“编码器 + 识别”两路
     * 会话：录制与条码识别继续工作，预览画面暂停；停止工作后仍重建两路
     * 预览会话恢复画面。
     */
    private fun runStartStallFallback() {
        if (startFallbackTried || disposed) return
        startFallbackTried = true
        Log.w(CAMERA_LOG_TAG, "recording start stalled; fallback to encoder+analysis session")
        recreateEncoderAnalysisSession(
            onError = { message ->
                muxHandler?.post { failPendingStart("session_config", message) }
            },
        )
    }

    /**
     * 轮换模式录像会话：“预览 + 编码器”两路，彻底移除识别 surface。
     * 预览画面保持可见，条码识别关闭；录完一单后由 stopWork 重建
     * “预览 + 识别”会话恢复扫码，编码器保持长驻不销毁。
     */
    private fun recreateAlternatingRecordingSession(
        onConfigured: (() -> Unit)? = null,
        onError: ((String) -> Unit)? = null,
    ) {
        val mux = muxHandler ?: return
        val cam = cameraHandler ?: return
        mux.post {
            if (disposed || !recordingRequested || recordingActive || startResult == null) {
                onError?.invoke("摄像头尚未就绪")
                return@post
            }
            cam.post {
                if (disposed || !recordingRequested || recordingActive || startResult == null) {
                    onError?.invoke("摄像头尚未就绪")
                    return@post
                }
                val camera = cameraDevice ?: return@post
                val characteristics = selectedCameraCharacteristics ?: return@post
                val surfaces = cameraSurfaces(
                    includePreview = true,
                    includeEncoder = true,
                    includeAnalysis = false,
                )
                val expected = CameraSurfaceTopologyPolicy.create(
                    pipeline = cameraSurfacePipeline,
                    includePreview = true,
                    includeEncoder = true,
                    includeAnalysis = false,
                ).cameraSurfaceCount
                if (surfaces.size < expected) {
                    onError?.invoke("摄像头轮换输出表面不存在")
                    return@post
                }
                val oldSession = captureSession
                captureSession = null
                sessionHasPreview = false
                sessionHasEncoder = false
                sessionHasAnalysis = false
                try {
                    oldSession?.close()
                } catch (error: Throwable) {
                    notifyNativeError("摄像头轮换会话关闭失败", error)
                    onError?.invoke(error.message ?: "摄像头轮换会话关闭失败")
                    return@post
                }
                submitCaptureSession(
                    camera = camera,
                    surfaces = surfaces,
                    onConfigured = { session ->
                        captureSession = session
                        sessionHasPreview = true
                        sessionHasEncoder = true
                        sessionHasAnalysis = false
                        recordingFallbackMode = "alternating"
                        try {
                            applyCaptureRequest(session, camera, characteristics)
                            Log.w(
                                CAMERA_LOG_TAG,
                                "alternating recording session configured " +
                                    "pipeline=${cameraSurfacePipeline.name.lowercase()}",
                            )
                            mux.post {
                                if (startResult != null && recordingRequested) {
                                    recordingVideoEncoder.requestSyncFrame()
                                }
                                onConfigured?.invoke()
                            }
                        } catch (error: Throwable) {
                            notifyNativeError("摄像头轮换会话启动失败", error)
                            onError?.invoke(error.message ?: "摄像头轮换会话启动失败")
                        }
                    },
                    onConfigureFailed = {
                        notifyNativeError("此设备无法启动轮换录像", null)
                        onError?.invoke("此设备无法启动轮换录像")
                    },
                    onCreateFailed = { error ->
                        notifyNativeError("摄像头轮换会话创建失败", error)
                        onError?.invoke(error.message ?: "摄像头轮换会话创建失败")
                    },
                )
            }
        }
    }

    /**
     * 重建为“编码器 + 识别”两路会话：录像与条码识别继续工作，预览画面暂停。
     * 用于启动阶段三路停摆后的自动降级，以及已保存兼容模式的直接开始。
     */
    private fun recreateEncoderAnalysisSession(
        onConfigured: (() -> Unit)? = null,
        onError: ((String) -> Unit)? = null,
    ) {
        val mux = muxHandler ?: return
        val cam = cameraHandler ?: return
        mux.post {
            if (disposed || !recordingRequested || recordingActive || startResult == null) {
                onError?.invoke("摄像头尚未就绪")
                return@post
            }
            cam.post {
                if (disposed || !recordingRequested || recordingActive || startResult == null) {
                    onError?.invoke("摄像头尚未就绪")
                    return@post
                }
                val camera = cameraDevice ?: return@post
                val characteristics = selectedCameraCharacteristics ?: return@post
                val surfaces = cameraSurfaces(
                    includePreview = cameraSurfacePipeline ==
                        CameraSurfacePipeline.GL_COMPOSITOR,
                    includeEncoder = true,
                    includeAnalysis = true,
                )
                val expected = CameraSurfaceTopologyPolicy.create(
                    pipeline = cameraSurfacePipeline,
                    includePreview = cameraSurfacePipeline ==
                        CameraSurfacePipeline.GL_COMPOSITOR,
                    includeEncoder = true,
                    includeAnalysis = true,
                ).cameraSurfaceCount
                if (surfaces.size < expected) {
                    onError?.invoke("摄像头降级输出表面不存在")
                    return@post
                }
                val oldSession = captureSession
                captureSession = null
                sessionHasPreview = false
                sessionHasEncoder = false
                sessionHasAnalysis = false
                try {
                    oldSession?.close()
                } catch (error: Throwable) {
                    notifyNativeError("摄像头降级会话关闭失败", error)
                    onError?.invoke(error.message ?: "摄像头降级会话关闭失败")
                    return@post
                }
                submitCaptureSession(
                    camera = camera,
                    surfaces = surfaces,
                    onConfigured = { session ->
                        captureSession = session
                        sessionHasEncoder = true
                        sessionHasAnalysis = true
                        sessionHasPreview = cameraSurfacePipeline ==
                            CameraSurfacePipeline.GL_COMPOSITOR
                        recordingFallbackMode = "encoder_analysis"
                        sessionFallbackEncoderAnalysis = true
                        try {
                            applyCaptureRequest(session, camera, characteristics)
                            Log.w(
                                CAMERA_LOG_TAG,
                                "recording fallback session configured " +
                                    "pipeline=${cameraSurfacePipeline.name.lowercase()}",
                            )
                            emit("recordingFallback", mapOf("mode" to "encoder_analysis"))
                            mux.post {
                                if (startResult != null && recordingRequested) {
                                    recordingVideoEncoder.requestSyncFrame()
                                }
                                onConfigured?.invoke()
                            }
                        } catch (error: Throwable) {
                            notifyNativeError("摄像头降级会话启动失败", error)
                            onError?.invoke(error.message ?: "摄像头降级会话启动失败")
                        }
                    },
                    onConfigureFailed = {
                        notifyNativeError("此设备无法同时录像与识别", null)
                        onError?.invoke("此设备无法同时录像与识别")
                    },
                    onCreateFailed = { error ->
                        notifyNativeError("摄像头降级会话创建失败", error)
                        onError?.invoke(error.message ?: "摄像头降级会话创建失败")
                    },
                )
            }
        }
    }

    private fun recreateCaptureSession(
        onConfigured: (() -> Unit)? = null,
        onError: ((String) -> Unit)? = null,
    ) {
        val handler = cameraHandler ?: return
        handler.post {
            val camera = cameraDevice ?: return@post
            val characteristics = selectedCameraCharacteristics ?: return@post
            val oldSession = captureSession
            captureSession = null
            sessionHasPreview = false
            sessionHasEncoder = false
            sessionHasAnalysis = false
            try {
                oldSession?.close()
            } catch (error: Throwable) {
                notifyNativeError("摄像头会话创建失败", error)
                onError?.invoke(error.message ?: "摄像头会话创建失败")
                return@post
            }
            val recording = recordingRequested || recordingActive
            val candidates = if (
                recording && cameraSurfacePipeline == CameraSurfacePipeline.DIRECT
            ) {
                streamConfigPolicy.threeSurfaceCandidates(
                    videoCandidates.map { StreamSize(it.width, it.height) },
                    analysisCandidates.map { StreamSize(it.width, it.height) },
                )
            } else {
                // GL 管线始终只向 Camera2 提交“合成输入 + 识别”两路；直连
                // 管线停止/自愈也回到“预览 + 识别”，避免沿用三路失败组合。
                streamConfigPolicy.initializationCandidates(
                    videoCandidates.map { StreamSize(it.width, it.height) },
                    analysisCandidates.map { StreamSize(it.width, it.height) },
                )
            }
            if (candidates.isEmpty()) {
                val message = if (recording) {
                    "此设备无法同时提供预览、识别和录像，录像未能开始"
                } else {
                    "摄像头会话配置失败"
                }
                notifyNativeError(message, null)
                onError?.invoke(message)
                return@post
            }
            submitWithFallback(
                camera = camera,
                candidates = candidates,
                onConfigured = { session ->
                    captureSession = session
                    try {
                        applyCaptureRequest(session, camera, characteristics)
                        Log.i(
                            CAMERA_LOG_TAG,
                            "capture session recreated stage=${sessionConfigStage}",
                        )
                        onConfigured?.invoke()
                    } catch (error: Throwable) {
                        notifyNativeError("摄像头会话启动失败", error)
                        onError?.invoke(error.message ?: "摄像头会话启动失败")
                    }
                },
                onFinalFailure = { message ->
                    notifyNativeError(message, null)
                    onError?.invoke(message)
                },
            )
        }
    }

    private fun schedulePreviewStallCheck() {
        cameraHandler?.postDelayed(previewStallCheck, PREVIEW_STALL_CHECK_INTERVAL_MS)
    }

    private fun markStall(gapMs: Long) {
        if (stallActive) return
        stallActive = true
        Log.w(
            CAMERA_LOG_TAG,
            "preview stall: no capture for ${gapMs}ms " +
                "previewActive=$previewActive workScanEnabled=$workScanEnabled " +
                "recordingActive=$recordingActive request=$lastRequestTemplate",
        )
    }

    private fun applyCaptureRequest(
        session: CameraCaptureSession,
        camera: CameraDevice,
        characteristics: CameraCharacteristics,
    ) {
        val targets = captureRequestTargetPolicy.targets(recordingRequested, recordingActive)
        val topology = CameraSurfaceTopologyPolicy.create(
            pipeline = cameraSurfacePipeline,
            includePreview = sessionHasPreview,
            includeEncoder = targets.includeEncoder && sessionHasEncoder,
            includeAnalysis = targets.includeAnalysis && sessionHasAnalysis,
        )
        cameraGlCompositor?.setEncoderEnabled(topology.compositorEncoderEnabled)
        val request = camera.createCaptureRequest(
            if (targets.includeEncoder) CameraDevice.TEMPLATE_RECORD else CameraDevice.TEMPLATE_PREVIEW,
        ).apply {
            if (topology.cameraUsesFrameSurface) compositorInputSurface?.let(::addTarget)
            if (topology.cameraUsesPreviewSurface) previewSurface?.let(::addTarget)
            if (topology.cameraUsesEncoderSurface) {
                recordingVideoEncoder.inputSurface?.let(::addTarget)
            }
            if (topology.cameraUsesAnalysisSurface) analysisReader?.surface?.let(::addTarget)
            applyAutomaticCameraControls(this, characteristics)
            set(
                CaptureRequest.FLASH_MODE,
                if (torchEnabled) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF,
            )
            if (targets.includeEncoder) {
                recordingFpsRangePolicy.choose(
                    characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                        ?.map { it.lower to it.upper },
                )?.let { (lower, upper) ->
                    set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(lower, upper))
                    Log.i(CAMERA_LOG_TAG, "capture fpsRange=$lower-$upper")
                }
            }
        }.build()
        session.setRepeatingRequest(request, captureCallback, cameraHandler)
        lastRequestTemplate = if (targets.includeEncoder) "record" else "preview"
        Log.i(
            CAMERA_LOG_TAG,
            "capture request template=$lastRequestTemplate " +
                "analysis=${targets.includeAnalysis} encoder=${targets.includeEncoder} " +
                "pipeline=${cameraSurfacePipeline.name.lowercase()}",
        )
    }

    fun setPairingScanEnabled(enabled: Boolean) {
        pairingScanEnabled = enabled
        Log.i(CAMERA_LOG_TAG, "pairingScanEnabled=$enabled")
        refreshCaptureRequest()
    }

    fun setWorkScanEnabled(enabled: Boolean) {
        workScanEnabled = enabled
        if (!enabled) lastAnalysisElapsedMs = 0L
        Log.i(CAMERA_LOG_TAG, "workScanEnabled=$enabled")
        refreshCaptureRequest()
    }

    fun setPreviewActive(active: Boolean, result: MethodChannel.Result) {
        val handler = cameraHandler
        if (disposed || handler == null) {
            replyError(result, "camera_not_ready", "摄像头尚未准备完成")
            return
        }
        handler.post {
            if (recordingRequested || recordingActive) {
                replyError(result, "camera_busy", "录像期间不能暂停摄像头")
                return@post
            }
            if (!active) {
                previewActive = false
                // Closing Camera2 can leave the ML Kit task for the last frame
                // unresolved. Invalidate that task so it cannot permanently keep
                // the next camera session in the busy state or emit a stale code.
                analysisGeneration++
                scannerBusy = false
                lastAnalysisElapsedMs = 0L
                previewResumeResult?.let {
                    replyError(it, "preview_suspended", "摄像头恢复已取消")
                }
                previewResumeResult = null
                initialized = false
                cameraHandler?.removeCallbacks(previewStallCheck)
                try {
                    captureSession?.stopRepeating()
                    captureSession?.abortCaptures()
                } catch (_: Throwable) {
                }
                captureSession?.close()
                captureSession = null
                sessionHasPreview = false
                sessionHasEncoder = false
                sessionHasAnalysis = false
                cameraDevice?.close()
                cameraDevice = null
                lastCaptureStartedAtMs = 0L
                lastCaptureCompletedAtMs = 0L
                stallActive = false
                resetStallRecovery()
                Log.i(CAMERA_LOG_TAG, "previewActive=false camera suspended")
                replySuccess(result, null)
                return@post
            }
            previewActive = true
            if (initialized && cameraDevice != null && captureSession != null) {
                val camera = cameraDevice
                val characteristics = selectedCameraCharacteristics
                if (camera == null || characteristics == null) {
                    replyError(result, "camera_not_ready", "摄像头尚未准备完成")
                    return@post
                }
                try {
                    applyCaptureRequest(captureSession!!, camera, characteristics)
                    Log.i(CAMERA_LOG_TAG, "previewActive=true camera already active")
                    replySuccess(result, null)
                } catch (error: Throwable) {
                    replyError(result, "preview_resume_failed", error.message ?: "摄像头恢复失败")
                }
                return@post
            }
            if (previewResumeResult != null || initializeResult != null) {
                replyError(result, "camera_busy", "摄像头正在恢复")
                return@post
            }
            previewResumeResult = result
            openCameraAttempts = 0
            lastAnalysisElapsedMs = 0L
            Log.i(CAMERA_LOG_TAG, "previewActive=true reopening camera")
            openCamera()
        }
    }

    fun setTorchEnabled(enabled: Boolean, result: MethodChannel.Result) {
        if (!initialized) {
            result.error("camera_not_ready", "摄像头尚未准备完成", null)
            return
        }
        val available = selectedCameraCharacteristics
            ?.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        if (enabled && !available) {
            result.error("flash_unavailable", "当前摄像头不支持闪光灯", null)
            return
        }
        torchEnabled = enabled && available
        refreshCaptureRequest()
        result.success(torchEnabled)
    }

    private fun handleVideoSample(buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        val watermarkRendered = encodedWatermarkFrameTracker.takeForEncodedSample(
            info.presentationTimeUs,
        )
        val isKeyFrame = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
        if (startResult != null && recordingRequested && isKeyFrame && formatsReady()) {
            val path = pendingStartPath ?: return
            try {
                recordingMuxPipeline.openSegment(
                    path,
                    info.presentationTimeUs,
                    System.currentTimeMillis(),
                    orientationHintDegrees(),
                    recordAudio,
                )
                recordingActive = true
                recordingMuxPipeline.flushPendingAudio()
                val result = startResult
                startResult = null
                pendingStartPath = null
                if (result != null) {
                    replySuccess(result, mapOf(
                        "path" to path,
                        "startedAtMs" to recordingMuxPipeline.segmentStartedAtMs,
                    ))
                }
            } catch (error: Throwable) {
                failPendingStart("muxer_start", "录像文件创建失败")
                notifyNativeError("录像文件创建失败", error)
                return
            }
        }

        if (!recordingActive || !recordingMuxPipeline.hasActiveMuxer) return

        if (splitResult != null && pendingSplitPath != null) {
            when (SplitVideoSamplePolicy.decide(
                samplePtsUs = info.presentationTimeUs,
                isKeyFrame = isKeyFrame,
                transitionPtsUs = pendingWatermarkTransitionPtsUs,
            )) {
                SplitVideoSampleAction.ROTATE -> {
                    rotateMuxerAtKeyFrame(buffer, info, watermarkRendered)
                    return
                }
                SplitVideoSampleAction.DROP_TRANSITION -> return
                SplitVideoSampleAction.WRITE_CURRENT -> Unit
            }
        }
        if (recordingMuxPipeline.writeVideo(
                buffer,
                info.presentationTimeUs,
                info.flags,
            )
        ) {
            liveWatermarkSegmentState.markMuxedWatermarkSample(watermarkRendered)
        }
    }

    private fun handleVideoEncoderOutputFormatChanged() {
        if (recordingRequested && startResult != null) {
            recordingVideoEncoder.requestSyncFrame()
        }
    }

    private fun handleAudioSample(sample: EncodedMuxSample) {
        try {
            recordingMuxPipeline.acceptAudio(
                sample,
                recordingRequested,
                recordingActive,
                splitResult != null,
            )
        } catch (error: Throwable) {
            notifyWriteError("声音写入失败", error)
        }
    }

    private fun rotateMuxerAtKeyFrame(
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
        watermarkRendered: Boolean?,
    ) {
        val result = splitResult ?: return
        val nextPath = pendingSplitPath ?: return
        if (recordingMuxPipeline.currentPath == null) return
        try {
            val transitionPtsUs = pendingWatermarkTransitionPtsUs
            val rotation = recordingMuxPipeline.rotateAtKeyFrame(
                nextPath = nextPath,
                buffer = buffer,
                sourcePtsUs = info.presentationTimeUs,
                flags = info.flags,
                orientationHintDegrees = orientationHintDegrees(),
                recordAudio = recordAudio,
                oldSegmentEndSourcePtsUs = transitionPtsUs ?: info.presentationTimeUs,
            )
            splitResult = null
            pendingSplitPath = null
            pendingWatermarkTransitionPtsUs = null
            val watermarkDisposition = liveWatermarkDispositionWire()
            liveWatermarkSegmentState.reset()
            activeWatermarkTrackingNumber = pendingNextTrackingNumber.orEmpty()
            pendingNextTrackingNumber = null
            liveWatermarkSegmentState.markMuxedWatermarkSample(watermarkRendered)
            if (cameraSurfacePipeline != CameraSurfacePipeline.GL_COMPOSITOR ||
                cameraGlCompositor == null
            ) {
                liveWatermarkSegmentState.markWatermarkFailure()
            }
            replySuccess(result, mapOf(
                "completedPath" to rotation.completedPath,
                "nextPath" to rotation.nextPath,
                "completedStartedAtMs" to rotation.completedStartedAtMs,
                "boundaryAtMs" to rotation.boundaryAtMs,
                "watermarkDisposition" to watermarkDisposition,
            ))
        } catch (error: Throwable) {
            recordingMuxPipeline.discardPendingAudio()
            splitResult = null
            pendingSplitPath = null
            pendingNextTrackingNumber = null
            pendingWatermarkTransitionPtsUs = null
            liveWatermarkSegmentState.markWatermarkFailure()
            encodedWatermarkFrameTracker.reset()
            cameraGlCompositor?.setWatermark(activeWatermarkTrackingNumber)
            replyError(result, "split_failed", "录像分段保存失败")
            notifyNativeError("录像分段保存失败", error)
        }
    }

    private fun formatsReady(): Boolean =
        recordingVideoEncoder.outputFormat != null && (!recordAudio || audioOutputFormat != null)

    private fun orientationHintDegrees(): Int = when (recordingOrientationName) {
        "landscapeLeft" -> 90
        "landscapeRight" -> 270
        else -> 0
    }

    internal fun cameraGlOutputGeometry(size: Size): CameraGlOutputGeometry =
        CameraGlOutputGeometryPolicy.create(size.width, size.height, sensorOrientation)

    private fun recordMuxWrite(startedAtMs: Long) {
        val elapsedMs = SystemClock.elapsedRealtime() - startedAtMs
        if (elapsedMs > muxWriteMaxMs) muxWriteMaxMs = elapsedMs
        if (elapsedMs > MUX_WRITE_STALL_THRESHOLD_MS) muxWriteStallCount++
    }

    private fun liveWatermarkDispositionWire(): String =
        when (liveWatermarkSegmentState.disposition()) {
            LiveWatermarkSegmentDisposition.COMPLETED -> "completed"
            LiveWatermarkSegmentDisposition.FAILED_PARTIAL -> "failedPartial"
        }

    private fun finishStop() {
        val result = stopResult ?: return
        try {
            val summary = recordingMuxPipeline.finishStop(System.currentTimeMillis())
            val watermarkDisposition = liveWatermarkDispositionWire()
            encodedWatermarkFrameTracker.reset()
            cameraGlCompositor?.setEncoderEnabled(false)
            cameraGlCompositor?.setWatermark("")
            activeWatermarkTrackingNumber = ""
            recordingVideoEncoder.setSuspended(true)
            stopResult = null
            pendingStartPath = null
            pendingSplitPath = null
            if (summary.path == null) {
                replyError(result, "empty_recording", "没有生成有效录像")
            } else {
                replySuccess(result, mapOf(
                    "path" to summary.path,
                    "startedAtMs" to summary.startedAtMs,
                    "endedAtMs" to max(summary.startedAtMs, summary.endedAtMs),
                    "watermarkDisposition" to watermarkDisposition,
                ))
            }
        } catch (error: Throwable) {
            encodedWatermarkFrameTracker.reset()
            stopResult = null
            pendingNextTrackingNumber = null
            cameraGlCompositor?.setEncoderEnabled(false)
            cameraGlCompositor?.setWatermark("")
            activeWatermarkTrackingNumber = ""
            replyError(result, "muxer_stop", "录像文件保存失败")
            notifyNativeError("录像文件保存失败", error)
        }
    }

    private fun failPendingStart(code: String, message: String) {
        val result = startResult ?: return
        Log.w(CAMERA_LOG_TAG, "start failed code=$code message=$message")
        startFailureStage = code
        startFailureDetail = message
        startResult = null
        pendingStartPath?.let { File(it).delete() }
        pendingStartPath = null
        pendingNextTrackingNumber = null
        pendingWatermarkTransitionPtsUs = null
        encodedWatermarkFrameTracker.reset()
        recordingRequested = false
        recordingActive = false
        cameraGlCompositor?.setEncoderEnabled(false)
        cameraGlCompositor?.clearWatermark()
        activeWatermarkTrackingNumber = ""
        resetStallRecovery()
        recreateCaptureSession()
        recordingVideoEncoder.setSuspended(true)
        recordingAudioPipeline.stop()
        replyError(result, code, message)
    }

    private fun failInitialization(code: String, message: String, error: Throwable?) {
        val result = initializeResult
        initializeResult = null
        val resumed = previewResumeResult
        previewResumeResult = null
        initialized = false
        pendingSwitchStartedAtMs = 0L
        initFailureStage = code
        initFailureDetail = error?.let { "$message：${it.message}" } ?: message
        Log.w(CAMERA_LOG_TAG, "initialization failed code=$code message=$message", error)
        closeCameraResourcesForRetry()
        val detail = error?.let { "$message：${it.message}" } ?: message
        if (result != null) replyError(result, code, detail)
        if (resumed != null) replyError(resumed, code, detail)
        if (result == null && resumed == null) notifyNativeError(message, error)
        val restoreCallback = probeRestoreCallback
        probeRestoreCallback = null
        restoreCallback?.invoke(error)
        runInitProbesIfNeeded()
    }

    private fun closeCameraResourcesForRetry() {
        cameraHandler?.post {
            if (disposed) return@post
            captureSession?.close()
            captureSession = null
            sessionHasPreview = false
            sessionHasEncoder = false
            sessionHasAnalysis = false
            analysisReader?.close()
            analysisReader = null
            cameraDevice?.close()
            cameraDevice = null
            releaseCameraGlCompositor()
            previewSurface?.release()
            previewSurface = null
            resetStallRecovery()
        }
    }

    /**
     * 持续出帧能力探针。由 Dart 按 FULL → ENCODER_ANALYSIS → ALTERNATING
     * 顺序逐条调用，每条序列执行 idle → record → idle → record → idle，
     * 每个阶段统计真实预览帧、识别帧与编码输出 buffer，不写盘、不建 muxer。
     *
     * 阶段只上报“是否配置成功 + 原始计数”，通过/失败阈值与模式决策全部
     * 留在 Dart 的 CameraCapabilityPolicy，避免两端策略漂移。
     */
    fun getDiagnostics(result: MethodChannel.Result) {
        val snapshot = CameraDiagnosticsSnapshotMapper.snapshot(
            SystemClock.elapsedRealtime(),
            CameraDiagnosticsInput(
                CameraIdentityDiagnostics(
                    initialized, selectedCameraId, selectedZoomRatio, cachedCameraIdList,
                    cachedZoomRatioRange, selectedLensFacing == CameraCharacteristics.LENS_FACING_FRONT,
                    sensorOrientation,
                ),
                CameraStreamDiagnostics(
                    StreamSize(videoSize.width, videoSize.height),
                    StreamSize(analysisSize.width, analysisSize.height),
                    recordingVideoEncoder.selectedMime,
                    if (recordingRequested || recordingActive) recordingSpec.fps else "auto",
                    recordingSpecName, recordingSpecState.supportedNames, recordAudio,
                ),
                CameraActivityDiagnostics(
                    previewActive, workScanEnabled, pairingScanEnabled, recordingRequested,
                    recordingActive, torchEnabled, canSwitchCamera,
                ),
                CameraAnalysisDiagnostics(
                    analysisStartedCount, analysisCompletedCount, analysisDetectedCount,
                    analysisFailureCount, lastAnalysisCompletedElapsedMs, lastAnalysisFailure,
                ),
                CameraSwitchAndFrameDiagnostics(
                    switchCount, lastSwitchDurationMs, lastSwitchRestartedEncoder,
                    captureStartedCount, lastCaptureStartedAtMs, lastCaptureCompletedAtMs,
                ),
                CameraResourceDiagnostics(
                    runCatching { StatFs(activity.filesDir.path).availableBytes }.getOrDefault(-1L),
                    runCatching { StatFs(activity.filesDir.path).totalBytes }.getOrDefault(-1L),
                    muxWriteMaxMs, muxWriteStallCount,
                ),
                CameraRecoveryDiagnostics(
                    recordingVideoEncoder.fallbackReason,
                    lastRequestTemplate,
                    stallActive,
                    stallRecoveryStage,
                    sessionConfigStage, sessionConfigAttempts, initFailureStage, initFailureDetail,
                    startFailureStage, startFailureDetail, recordingFallbackMode,
                    cameraSurfacePipeline.name.lowercase(), cameraSurfaceFallbackReason,
                    glFailureStage, glFailureOutput, glFailureApi, glFailureErrorCode,
                    glFailureType,
                ),
                CameraCapabilityDiagnostics(
                    capabilityMode.name.lowercase(),
                    capabilityMode == CameraCapabilityMode.ENCODER_ANALYSIS ||
                        sessionFallbackEncoderAnalysis,
                    sessionHasPreview, sessionHasEncoder, sessionHasAnalysis,
                    probeResults, probeInProgress, ContinuousCameraInitProbeCache.results != null, hardwareLevel,
                    capabilities, supportedYuvSizes, supportedVideoSizes, supportedPreviewSizes,
                    physicalCameraIds, cachedBackLenses ?: emptyList(), fpsRanges,
                ),
            ),
            CameraDeviceDiagnostics(
                Build.MANUFACTURER, Build.MODEL, Build.VERSION.SDK_INT, Build.VERSION.RELEASE,
            ),
            CameraProcessDiagnostics(
                Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory(),
                Runtime.getRuntime().maxMemory(),
                Debug.getNativeHeapAllocatedSize(), Thread.getAllStackTraces().size,
                CameraDiagnosticsSnapshotMapper.openFileDescriptorCount(),
            ),
        )
        result.success(snapshot)
    }

    internal fun notifyNativeError(message: String, error: Throwable?) {
        Log.w(CAMERA_LOG_TAG, "$message", error)
        emit("nativeError", error?.let { "$message：${it.message}" } ?: message)
    }

    private fun notifyWriteError(message: String, error: Throwable) {
        val availableBytes = runCatching {
            StatFs(activity.filesDir.path).availableBytes
        }.getOrDefault(Long.MAX_VALUE)
        if (availableBytes < BackupStoragePolicyStore.current(activity).minimumBytes) {
            if (!storageFailureReported) {
                storageFailureReported = true
                emit(
                    "storageCritical",
                    mapOf(
                        "availableBytes" to availableBytes,
                        "message" to "存储空间不足，录像写入已停止",
                    ),
                )
            }
            return
        }
        notifyNativeError(message, error)
    }

    private fun initializationMap(): Map<String, Any?> =
        CameraDiagnosticsSnapshotMapper.initialization(
            CameraInitializationDiagnostics(
                textureEntry?.id() ?: -1L, StreamSize(videoSize.width, videoSize.height),
                sensorOrientation, selectedCameraId, selectedZoomRatio,
                selectedLensFacing == CameraCharacteristics.LENS_FACING_FRONT,
                canSwitchCamera, recordingSpec.fps, recordingSpecName,
                recordingVideoEncoder.selectedMime,
                recordingVideoEncoder.fallbackReason,
                selectedCameraCharacteristics?.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true,
            ),
        )

    private fun ensureParent(path: String) {
        File(path).parentFile?.mkdirs()
    }

    private fun hasRecordingReserve(path: String): Boolean = runCatching {
        val parent = File(path).parentFile ?: activity.filesDir
        StatFs(parent.path).availableBytes >=
            BackupStoragePolicyStore.current(activity).minimumBytes
    }.getOrDefault(false)

    /// 保留空间文案跟随 Dart 下发的策略，不再写死 2GB。
    private fun reserveGigabytes(): String =
        "${BackupStoragePolicyStore.current(activity).minimumBytes / (1024L * 1024 * 1024)}GB"

    internal fun replySuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    internal fun replyError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

}

internal fun shouldAnalyzeBarcodeFrame(
    previewActive: Boolean,
    pairingScanEnabled: Boolean,
    workScanEnabled: Boolean,
    scannerBusy: Boolean,
    elapsedSinceLastAnalysisMs: Long,
    analysisIntervalMs: Long,
): Boolean = previewActive &&
    (pairingScanEnabled || workScanEnabled) &&
    !scannerBusy &&
    elapsedSinceLastAnalysisMs >= analysisIntervalMs

internal fun shouldAcceptBarcodeAnalysisResult(
    resultGeneration: Long,
    activeGeneration: Long,
    previewActive: Boolean,
): Boolean = previewActive && resultGeneration == activeGeneration

internal fun barcodeFormatName(format: Int): String? = when (format) {
    Barcode.FORMAT_EAN_13 -> "ean13"
    Barcode.FORMAT_EAN_8 -> "ean8"
    Barcode.FORMAT_UPC_A -> "upca"
    Barcode.FORMAT_UPC_E -> "upce"
    Barcode.FORMAT_ITF -> "itf"
    Barcode.FORMAT_CODE_128 -> "code128"
    Barcode.FORMAT_CODE_39 -> "code39"
    Barcode.FORMAT_CODE_93 -> "code93"
    Barcode.FORMAT_CODABAR -> "codabar"
    Barcode.FORMAT_QR_CODE -> "qr"
    Barcode.FORMAT_DATA_MATRIX -> "dataMatrix"
    Barcode.FORMAT_PDF417 -> "pdf417"
    Barcode.FORMAT_AZTEC -> "aztec"
    else -> null
}
