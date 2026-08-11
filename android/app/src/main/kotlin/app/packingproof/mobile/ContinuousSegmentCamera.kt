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
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.media.MediaMuxer
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.os.StatFs
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
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.max

/**
 * Keeps one Camera2 session and one hardware video encoder alive while work is active.
 * Barcode boundaries only rotate the MP4 muxer, so preview and camera capture
 * never restart. Each completed label is therefore an independent physical file.
 */
class ContinuousSegmentCamera(
    private val activity: Activity,
    private val textures: TextureRegistry,
    private val preferredLensFacing: Int = CameraCharacteristics.LENS_FACING_BACK,
    private val emit: (String, Any?) -> Unit,
) {
    companion object {
        private const val AUDIO_SAMPLE_RATE = 48_000
        private const val AUDIO_CHANNEL_COUNT = 1
        private const val AUDIO_BIT_RATE = 96_000
        private const val ANALYSIS_INTERVAL_MS = 250L
        private const val START_TIMEOUT_MS = 6_000L
        private const val SPLIT_TIMEOUT_MS = 3_000L
        private const val CAMERA_LOG_TAG = "PackingProof.Camera"
        private const val PREVIEW_STALL_THRESHOLD_MS = 1_500L
        private const val PREVIEW_STALL_CHECK_INTERVAL_MS = 2_000L
        private const val MUX_WRITE_STALL_THRESHOLD_MS = 100L
        private const val CAMERA_DISABLED_MESSAGE =
            "摄像头被系统或设备策略禁用，请检查摄像头访问开关"
    }

    private val mainHandler = Handler(activity.mainLooper)
    private val cameraManager = activity.getSystemService(CameraManager::class.java)
    private val captureRequestTargetPolicy = CaptureRequestTargetPolicy()
    private var recordingFpsRangePolicy =
        RecordingFpsRangePolicy(RecordingSpecPolicy.HD.fps)
    private val stallRecoveryPolicy = PreviewStallRecoveryPolicy()
    private var recordingSpec = RecordingSpecPolicy.HD
    private var recordingSpecName = RecordingSpecPolicy.DEFAULT_SPEC_NAME
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
    private var cameraHandler: Handler? = null
    private var muxThread: HandlerThread? = null
    private var muxHandler: Handler? = null

    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var previewSurface: Surface? = null
    private var cameraDevice: CameraDevice? = null
    @Volatile private var selectedCameraId: String? = null
    @Volatile private var selectedCameraCharacteristics: CameraCharacteristics? = null
    private var captureSession: CameraCaptureSession? = null
    private var analysisReader: ImageReader? = null
    @Volatile private var sensorOrientation = 90
    @Volatile private var selectedLensFacing = CameraCharacteristics.LENS_FACING_BACK
    @Volatile private var canSwitchCamera = false
    @Volatile private var videoSize = Size(
        RecordingSpecPolicy.HD.videoWidth,
        RecordingSpecPolicy.HD.videoHeight,
    )
    @Volatile private var analysisSize = Size(1280, 720)
    @Volatile private var sessionConfigStage: String? = null
    @Volatile private var sessionConfigAttempts = 0
    private var streamConfigPolicy = StreamConfigPolicy(
        RecordingSpecPolicy.HD.videoWidth,
        RecordingSpecPolicy.HD.videoHeight,
    )
    private var videoCandidates = emptyList<Size>()
    private var analysisCandidates = emptyList<Size>()
    private var workingStreamConfig: StreamConfig? = null
    @Volatile private var initialized = false
    private var disposed = false
    private var initializeResult: MethodChannel.Result? = null
    private var openCameraAttempts = 0
    private var preferredVideoMime = MediaFormat.MIMETYPE_VIDEO_HEVC
    private var codecFallbackReason: String? = null

    private var videoEncoder: MediaCodec? = null
    private var videoInputSurface: Surface? = null
    private var videoOutputFormat: MediaFormat? = null
    @Volatile private var selectedVideoMime = MediaFormat.MIMETYPE_VIDEO_HEVC
    private var audioOutputFormat: MediaFormat? = null

    private val audioRunning = AtomicBoolean(false)
    @Volatile private var audioRecord: AudioRecord? = null
    @Volatile private var audioThread: Thread? = null

    @Volatile private var recordingRequested = false
    @Volatile private var recordingActive = false
    private var startResult: MethodChannel.Result? = null
    private var stopResult: MethodChannel.Result? = null
    private var splitResult: MethodChannel.Result? = null
    private var pendingStartPath: String? = null
    private var pendingSplitPath: String? = null
    private val pendingAudio = mutableListOf<EncodedSample>()

    private var muxer: MediaMuxer? = null
    private var videoTrack = -1
    private var audioTrack = -1
    private var currentPath: String? = null
    private var segmentBasePtsUs = 0L
    private var segmentStartedAtMs = 0L
    private var lastVideoPtsUs = -1L
    private var lastAudioPtsUs = -1L
    private var lastMediaPtsUs = 0L
    private var audioToVideoPtsOffsetUs: Long? = null
    private var storageFailureReported = false

    private var scannerBusy = false
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
        recordingSpec = RecordingSpecPolicy.resolve(recordingSpecName)
        this.recordingSpecName = RecordingSpecPolicy.resolveName(recordingSpecName)
        recordingFpsRangePolicy = RecordingFpsRangePolicy(recordingSpec.fps)
        streamConfigPolicy = StreamConfigPolicy(
            recordingSpec.videoWidth,
            recordingSpec.videoHeight,
        )
        sessionConfigStage = null
        sessionConfigAttempts = 0
        workingStreamConfig = null
        videoCandidates = emptyList()
        analysisCandidates = emptyList()
        preferredVideoMime = if (videoCodec == "h264") {
            MediaFormat.MIMETYPE_VIDEO_AVC
        } else {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        }
        startThreads()
        textureEntry = textures.createSurfaceTexture()
        muxHandler!!.post {
            try {
                selectCameraConfiguration()
                prepareVideoEncoder()
                cameraHandler!!.post { openCamera() }
            } catch (error: Throwable) {
                failInitialization("encoder_init", "视频编码器初始化失败", error)
            }
        }
    }

    fun startWork(path: String, recordAudio: Boolean, result: MethodChannel.Result) {
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
                replyError(result, "storage_low", "存储空间不足 2GB，无法开始录像")
                return@post
            }
            this@ContinuousSegmentCamera.recordAudio = recordAudio
            ensureParent(path)
            storageFailureReported = false
            recordingRequested = true
            resetStallRecovery()
            Log.i(CAMERA_LOG_TAG, "startWork path=$path recordAudio=$recordAudio")
            pendingStartPath = path
            startResult = result
            audioOutputFormat = null
            audioToVideoPtsOffsetUs = null
            pendingAudio.clear()
            setVideoSuspended(false)
            if (recordAudio) {
                startAudioPipeline()
            }
            // 后置摄像头在运行中的重复请求上增删录像目标会冻结预览；
            // 与 camera_android 一致：开始工作时重建会话，让预览+识别+编码
            // 目标从会话配置起保持固定。
            recreateCaptureSession(
                onConfigured = {
                    muxHandler?.post {
                        if (startResult != null && recordingRequested) {
                            requestSyncFrame()
                        }
                    }
                },
                onError = { message ->
                    muxHandler?.post { failPendingStart("session_config", message) }
                },
            )
            handler.postDelayed({
                if (startResult === result) {
                    failPendingStart("start_timeout", "录像编码器启动超时")
                }
            }, START_TIMEOUT_MS)
        }
    }

    fun split(path: String, result: MethodChannel.Result) {
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
            if (!recordingActive || muxer == null) {
                replyError(result, "not_recording", "当前没有正在录制的视频")
                return@post
            }
            if (splitResult != null) {
                replyError(result, "split_pending", "上一段录像正在保存")
                return@post
            }
            if (!hasRecordingReserve(path)) {
                replyError(result, "storage_low", "存储空间不足 2GB，无法创建下一段录像")
                if (!storageFailureReported) {
                    storageFailureReported = true
                    emit("storageCritical", mapOf("message" to "存储空间不足"))
                }
                return@post
            }
            ensureParent(path)
            pendingSplitPath = path
            splitResult = result
            pendingAudio.clear()
            requestSyncFrame()
            handler.postDelayed({
                if (splitResult === result) {
                    flushPendingAudioToCurrent()
                    pendingSplitPath = null
                    splitResult = null
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
            resetStallRecovery()
            Log.i(CAMERA_LOG_TAG, "stopWork")
            recreateCaptureSession()
            audioRunning.set(false)
            try {
                audioRecord?.stop()
            } catch (_: Throwable) {
                // The audio loop may already have stopped after an encoder failure.
            }
            if (audioThread == null) {
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

    fun dispose(onDisposed: (() -> Unit)? = null) {
        if (disposed) {
            onDisposed?.let { mainHandler.post(it) }
            return
        }
        disposed = true
        initializeResult?.let { replyError(it, "disposed", "摄像头初始化已取消") }
        startResult?.let { replyError(it, "disposed", "录像启动已取消") }
        splitResult?.let { replyError(it, "disposed", "录像分段已取消") }
        stopResult?.let { replyError(it, "disposed", "录像保存已取消") }
        audioRunning.set(false)
        try {
            audioRecord?.stop()
        } catch (_: Throwable) {
        }
        val cleanupCount = AtomicInteger(2)
        fun finishCleanup() {
            if (cleanupCount.decrementAndGet() == 0) onDisposed?.let { mainHandler.post(it) }
        }
        val activeMuxHandler = muxHandler
        val activeCameraHandler = cameraHandler
        if (activeMuxHandler != null) activeMuxHandler.post {
            // 与 muxHandler 上可能在途的开始/停止/分段任务串行清空状态。
            initializeResult = null
            startResult = null
            stopResult = null
            splitResult = null
            pendingStartPath = null
            pendingSplitPath = null
            recordingRequested = false
            recordingActive = false
            initialized = false
            closeMuxer(deleteEmpty = false)
            try {
                videoEncoder?.stop()
            } catch (_: Throwable) {
            }
            try {
                videoEncoder?.release()
            } catch (_: Throwable) {
            }
            videoEncoder = null
            videoInputSurface?.release()
            videoInputSurface = null
            finishCleanup()
        } else finishCleanup()
        if (activeCameraHandler != null) activeCameraHandler.post {
            scannerBusy = false
            workScanEnabled = false
            pairingScanEnabled = false
            analysisReader?.close()
            analysisReader = null
            captureSession?.close()
            captureSession = null
            resetStallRecovery()
            cameraDevice?.close()
            cameraDevice = null
            cameraHandler?.removeCallbacks(previewStallCheck)
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

    private fun prepareVideoEncoder() {
        var lastError: Throwable? = null
        codecFallbackReason = null
        val rawPreferred = if (preferredVideoMime == MediaFormat.MIMETYPE_VIDEO_AVC) {
            MediaFormat.MIMETYPE_VIDEO_AVC
        } else {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        }
        val fallback = if (rawPreferred == MediaFormat.MIMETYPE_VIDEO_AVC) {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        } else {
            MediaFormat.MIMETYPE_VIDEO_AVC
        }
        // 部分鸿蒙/低端机型只有 H.265 编码器却没有可用的 H.265 解码器，
        // 录出的 H.265 在本机无法播放，必须直接回退到 H.264。
        val hevcDecodable = CodecCapabilities.hasDecoder(MediaFormat.MIMETYPE_VIDEO_HEVC)
        if (rawPreferred == MediaFormat.MIMETYPE_VIDEO_HEVC && !hevcDecodable) {
            codecFallbackReason = RecordingCodecPolicy.FALLBACK_NO_HEVC_DECODER
        }
        val candidates = listOf(rawPreferred, fallback).filter {
            it != MediaFormat.MIMETYPE_VIDEO_HEVC || hevcDecodable
        }
        for (mime in candidates) {
            val formats = buildList {
                add(createEncoderFormat(mime).apply {
                    if (mime == MediaFormat.MIMETYPE_VIDEO_AVC) {
                        setInteger(
                            MediaFormat.KEY_PROFILE,
                            MediaCodecInfo.CodecProfileLevel.AVCProfileMain,
                        )
                    }
                })
                if (mime == MediaFormat.MIMETYPE_VIDEO_AVC) {
                    // 个别厂商编码器不接受显式 Main Profile，再试一次默认 Profile。
                    add(createEncoderFormat(mime))
                }
            }
            for (format in formats) {
                var codec: MediaCodec? = null
                try {
                    codec = MediaCodec.createEncoderByType(mime)
                    codec.setCallback(videoEncoderCallback(), muxHandler)
                    codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    videoInputSurface = codec.createInputSurface()
                    codec.start()
                    videoEncoder = codec
                    selectedVideoMime = mime
                    setVideoSuspended(true)
                    return
                } catch (error: Throwable) {
                    lastError = error
                    try {
                        codec?.release()
                    } catch (_: Throwable) {
                    }
                    videoInputSurface?.release()
                    videoInputSurface = null
                }
            }
        }
        throw IllegalStateException("设备没有可用的 H.265 或 H.264 编码器", lastError)
    }

    private fun createEncoderFormat(mime: String): MediaFormat =
        MediaFormat.createVideoFormat(mime, videoSize.width, videoSize.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(
                MediaFormat.KEY_BIT_RATE,
                if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC) {
                    recordingSpec.hevcBitRate
                } else {
                    recordingSpec.avcBitRate
                },
            )
            setInteger(MediaFormat.KEY_FRAME_RATE, recordingSpec.fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }
        }

    private fun videoEncoderCallback(): MediaCodec.Callback =
        object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

            override fun onOutputBufferAvailable(
                codec: MediaCodec,
                index: Int,
                info: MediaCodec.BufferInfo,
            ) {
                try {
                    val buffer = codec.getOutputBuffer(index)
                    if (buffer != null && info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        handleVideoSample(buffer, info)
                    }
                } catch (error: Throwable) {
                    notifyWriteError("视频写入失败", error)
                } finally {
                    try {
                        codec.releaseOutputBuffer(index, false)
                    } catch (_: Throwable) {
                    }
                }
            }

            override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
                notifyNativeError("视频编码器异常", error)
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                videoOutputFormat = format
                if (recordingRequested && startResult != null) requestSyncFrame()
            }
        }

    @SuppressLint("MissingPermission")
    private fun openCamera() {
        try {
            val cameraId = selectedCameraId
                ?: throw IllegalStateException("没有检测到可用摄像头")
            val characteristics = selectedCameraCharacteristics
                ?: throw IllegalStateException("无法读取摄像头能力")

            if (previewSurface == null || analysisReader == null) {
                val surfaceTexture = textureEntry!!.surfaceTexture()
                surfaceTexture.setDefaultBufferSize(videoSize.width, videoSize.height)
                previewSurface = Surface(surfaceTexture)
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
                    if (initializeResult != null &&
                        openCameraAttempts < CameraOpenRetryPolicy.MAX_ATTEMPTS
                    ) {
                        retryCameraOpen()
                    } else {
                        failInitialization("camera_disconnected", "摄像头连接已断开", null)
                    }
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    closeCameraSafely(camera)
                    if (initializeResult != null &&
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

    private fun closeCameraSafely(camera: CameraDevice) {
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
            CameraOpenRetryPolicy.RETRY_DELAY_MS,
        )
    }

    private fun selectCameraConfiguration() {
        val availableFacing = cameraManager.cameraIdList.mapNotNull { id ->
            cameraManager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING)
        }.toSet()
        canSwitchCamera =
            CameraCharacteristics.LENS_FACING_BACK in availableFacing &&
            CameraCharacteristics.LENS_FACING_FRONT in availableFacing
        val cameraId = cameraManager.cameraIdList.firstOrNull { id ->
            cameraManager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == preferredLensFacing
        } ?: cameraManager.cameraIdList.firstOrNull()
            ?: throw IllegalStateException("没有检测到可用摄像头")
        val characteristics = cameraManager.getCameraCharacteristics(cameraId)
        val configuration = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: throw IllegalStateException("无法读取摄像头输出能力")
        selectedCameraId = cameraId
        selectedCameraCharacteristics = characteristics
        selectedLensFacing = characteristics.get(CameraCharacteristics.LENS_FACING)
            ?: CameraCharacteristics.LENS_FACING_BACK
        sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        val videoSizes = configuration.getOutputSizes(MediaRecorder::class.java)
            ?.toList()
            .orEmpty()
        val analysisSizes = configuration.getOutputSizes(ImageFormat.YUV_420_888)
            ?.toList()
            .orEmpty()
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
                    applyCaptureRequest(session, camera, characteristics)
                    initialized = true
                    schedulePreviewStallCheck()
                    Log.i(
                        CAMERA_LOG_TAG,
                        "camera session configured cameraId=$selectedCameraId " +
                            "video=$videoSize analysis=$analysisSize mime=$selectedVideoMime",
                    )
                    val result = initializeResult
                    initializeResult = null
                    if (result != null) replySuccess(result, initializationMap())
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

    private fun applyAutomaticCameraControls(
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
                val expected = if (config.includeEncoder) 3 else 2
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
                        Log.i(CAMERA_LOG_TAG, "camera session configured stage=${config.label}")
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
        val applyCameraSide = {
            if (analysisChanged) recreateAnalysisReader(analysis)
            resizePreviewSurface(video)
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
                releaseVideoEncoder()
                try {
                    prepareVideoEncoder()
                    setVideoSuspended(!(recordingRequested || recordingActive))
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

    private fun sessionSurfaces(config: StreamConfig): List<Surface> = buildList {
        previewSurface?.let(::add)
        if (config.includeEncoder) videoInputSurface?.let(::add)
        analysisReader?.surface?.let(::add)
    }

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

    private fun resizePreviewSurface(size: Size) {
        val entry = textureEntry ?: return
        entry.surfaceTexture().setDefaultBufferSize(size.width, size.height)
        if (previewSurface == null) {
            previewSurface = Surface(entry.surfaceTexture())
        }
        videoSize = size
    }

    private fun releaseVideoEncoder() {
        try {
            videoEncoder?.stop()
        } catch (_: Throwable) {
        }
        try {
            videoEncoder?.release()
        } catch (_: Throwable) {
        }
        videoEncoder = null
        videoInputSurface?.release()
        videoInputSurface = null
        videoOutputFormat = null
    }

    private fun analyzeImage(reader: ImageReader) {
        val image = reader.acquireLatestImage() ?: return
        if ((!recordingActive && !recordingRequested && !workScanEnabled && !pairingScanEnabled) || scannerBusy || SystemClock.elapsedRealtime() - lastAnalysisElapsedMs < ANALYSIS_INTERVAL_MS) {
            image.close()
            return
        }
        scannerBusy = true
        lastAnalysisElapsedMs = SystemClock.elapsedRealtime()
        try {
            val input = InputImage.fromMediaImage(image, sensorOrientation)
            barcodeScanner.process(input)
                .addOnSuccessListener { barcodes ->
                    val values = barcodes.mapNotNull { barcode ->
                        val raw = barcode.rawValue?.trim().orEmpty()
                        if (raw.isEmpty()) null else mapOf(
                            "value" to raw,
                            "area" to ((barcode.boundingBox ?: Rect()).let { it.width().toLong() * it.height() }),
                            "format" to barcodeFormatName(barcode.format),
                        )
                    }
                    emit("barcodeFrame", values)
                }
                .addOnFailureListener { emit("barcodeFrame", emptyList<Any>()) }
                .addOnCompleteListener {
                    cameraHandler?.post {
                        image.close()
                        scannerBusy = false
                    }
                }
        } catch (error: Throwable) {
            image.close()
            scannerBusy = false
        }
    }

    private fun barcodeFormatName(format: Int): String? = when (format) {
        Barcode.FORMAT_EAN_13 -> "ean13"
        Barcode.FORMAT_EAN_8 -> "ean8"
        Barcode.FORMAT_UPC_A -> "upca"
        Barcode.FORMAT_UPC_E -> "upce"
        Barcode.FORMAT_ITF -> "itf"
        else -> null
    }

    private fun refreshCaptureRequest() {
        cameraHandler?.post {
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
            try {
                oldSession?.close()
            } catch (error: Throwable) {
                notifyNativeError("摄像头会话创建失败", error)
                onError?.invoke(error.message ?: "摄像头会话创建失败")
                return@post
            }
            val recording = recordingRequested || recordingActive
            val candidates = if (recording) {
                streamConfigPolicy.threeSurfaceCandidates(
                    videoCandidates.map { StreamSize(it.width, it.height) },
                    analysisCandidates.map { StreamSize(it.width, it.height) },
                )
            } else {
                workingStreamConfig?.let { listOf(it) }
                    ?: streamConfigPolicy.initializationCandidates(
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
        val preview = previewSurface ?: return
        val request = camera.createCaptureRequest(
            if (targets.includeEncoder) CameraDevice.TEMPLATE_RECORD else CameraDevice.TEMPLATE_PREVIEW,
        ).apply {
            addTarget(preview)
            if (targets.includeEncoder) videoInputSurface?.let(::addTarget)
            if (targets.includeAnalysis) analysisReader?.surface?.let(::addTarget)
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
                "analysis=${targets.includeAnalysis} encoder=${targets.includeEncoder}",
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

    fun setPreviewActive(active: Boolean) {
        previewActive = active
        if (active) refreshCaptureRequest()
        Log.i(CAMERA_LOG_TAG, "previewActive=$active")
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

    private fun startAudioPipeline() {
        if (audioThread != null || !recordAudio) return
        audioRunning.set(true)
        val thread = Thread({ runAudioPipeline() }, "parcel-audio")
        audioThread = thread
        thread.start()
    }

    @SuppressLint("MissingPermission")
    private fun runAudioPipeline() {
        var codec: MediaCodec? = null
        var recorder: AudioRecord? = null
        try {
            val minBuffer = AudioRecord.getMinBufferSize(
                AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val bufferSize = max(minBuffer, 16_384)
            recorder = AudioRecord(
                MediaRecorder.AudioSource.CAMCORDER,
                AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize * 2,
            )
            if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                throw IllegalStateException("麦克风初始化失败")
            }
            audioRecord = recorder
            val audioFormat = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                AUDIO_SAMPLE_RATE,
                AUDIO_CHANNEL_COUNT,
            ).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufferSize)
            }
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec.configure(audioFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            recorder.startRecording()
            val audioClockBaseUs = System.nanoTime() / 1_000L
            var submittedFrames = 0L
            var inputEnded = false
            var outputEnded = false
            while (!outputEnded) {
                if (!inputEnded) {
                    val inputIndex = codec.dequeueInputBuffer(10_000)
                    if (inputIndex >= 0) {
                        val input = codec.getInputBuffer(inputIndex) ?: continue
                        input.clear()
                        if (audioRunning.get()) {
                            val read = recorder.read(input, input.capacity(), AudioRecord.READ_BLOCKING)
                            if (read > 0) {
                                val ptsUs = audioClockBaseUs + submittedFrames * 1_000_000L / AUDIO_SAMPLE_RATE
                                submittedFrames += read / 2L / AUDIO_CHANNEL_COUNT
                                codec.queueInputBuffer(inputIndex, 0, read, ptsUs, 0)
                            }
                        } else {
                            codec.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                audioClockBaseUs + submittedFrames * 1_000_000L / AUDIO_SAMPLE_RATE,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputEnded = true
                        }
                    }
                }
                val info = MediaCodec.BufferInfo()
                var outputIndex = codec.dequeueOutputBuffer(info, 10_000)
                while (outputIndex >= 0) {
                    val output = codec.getOutputBuffer(outputIndex)
                    if (output != null && info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        output.position(info.offset)
                        output.limit(info.offset + info.size)
                        val bytes = ByteArray(info.size)
                        output.get(bytes)
                        val sample = EncodedSample(bytes, info.presentationTimeUs, info.flags)
                        muxHandler?.post { handleAudioSample(sample) }
                    }
                    outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    codec.releaseOutputBuffer(outputIndex, false)
                    outputIndex = codec.dequeueOutputBuffer(info, 10_000)
                }
                if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val format = codec.outputFormat
                    muxHandler?.post {
                        audioOutputFormat = format
                        if (recordingRequested && startResult != null) requestSyncFrame()
                    }
                }
            }
        } catch (error: Throwable) {
            muxHandler?.post {
                if (startResult != null) {
                    failPendingStart("audio_init", "麦克风或音频编码器启动失败")
                } else {
                    notifyNativeError("声音录制异常", error)
                }
            }
        } finally {
            try {
                recorder?.stop()
            } catch (_: Throwable) {
            }
            recorder?.release()
            audioRecord = null
            try {
                codec?.stop()
            } catch (_: Throwable) {
            }
            codec?.release()
            audioThread = null
            muxHandler?.post {
                if (stopResult != null) finishStop()
            }
        }
    }

    private fun handleVideoSample(buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        val isKeyFrame = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
        if (startResult != null && recordingRequested && isKeyFrame && formatsReady()) {
            val path = pendingStartPath ?: return
            try {
                openMuxer(path, info.presentationTimeUs, System.currentTimeMillis())
                recordingActive = true
                flushPendingAudioToCurrent()
                val result = startResult
                startResult = null
                pendingStartPath = null
                if (result != null) {
                    replySuccess(result, mapOf(
                        "path" to path,
                        "startedAtMs" to segmentStartedAtMs,
                    ))
                }
            } catch (error: Throwable) {
                failPendingStart("muxer_start", "录像文件创建失败")
                notifyNativeError("录像文件创建失败", error)
                return
            }
        }

        if (!recordingActive || muxer == null) return

        if (splitResult != null && pendingSplitPath != null && isKeyFrame) {
            rotateMuxerAtKeyFrame(buffer, info)
            return
        }
        writeVideo(buffer, info.presentationTimeUs, info.flags)
    }

    private fun handleAudioSample(sample: EncodedSample) {
        try {
            if (!recordingActive || muxer == null) {
                if (recordingRequested) pendingAudio.add(sample)
                return
            }
            if (splitResult != null) {
                pendingAudio.add(sample)
                return
            }
            writeAudio(sample)
        } catch (error: Throwable) {
            notifyWriteError("声音写入失败", error)
        }
    }

    private fun rotateMuxerAtKeyFrame(buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        val result = splitResult ?: return
        val nextPath = pendingSplitPath ?: return
        val completedPath = currentPath ?: return
        val boundaryPtsUs = info.presentationTimeUs
        val completedStartedAt = segmentStartedAtMs
        val boundaryAtMs = segmentStartedAtMs + max(0L, boundaryPtsUs - segmentBasePtsUs) / 1_000L
        try {
            pendingAudio.filter { audioPtsOnVideoTimeline(it) < boundaryPtsUs }.forEach(::writeAudio)
            closeMuxer(deleteEmpty = false)
            openMuxer(nextPath, boundaryPtsUs, boundaryAtMs)
            pendingAudio.filter { audioPtsOnVideoTimeline(it) >= boundaryPtsUs }.forEach(::writeAudio)
            pendingAudio.clear()
            writeVideo(buffer, info.presentationTimeUs, info.flags)
            splitResult = null
            pendingSplitPath = null
            replySuccess(result, mapOf(
                "completedPath" to completedPath,
                "nextPath" to nextPath,
                "completedStartedAtMs" to completedStartedAt,
                "boundaryAtMs" to boundaryAtMs,
            ))
        } catch (error: Throwable) {
            pendingAudio.clear()
            splitResult = null
            pendingSplitPath = null
            replyError(result, "split_failed", "录像分段保存失败")
            notifyNativeError("录像分段保存失败", error)
        }
    }

    private fun formatsReady(): Boolean =
        videoOutputFormat != null && (!recordAudio || audioOutputFormat != null)

    private fun openMuxer(path: String, basePtsUs: Long, startedAtMs: Long) {
        val outputFile = File(path)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists() && !outputFile.delete()) {
            error("无法覆盖录像文件")
        }
        val newMuxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        newMuxer.setOrientationHint(sensorOrientation)
        videoTrack = newMuxer.addTrack(videoOutputFormat!!)
        audioTrack = if (recordAudio && audioOutputFormat != null) {
            newMuxer.addTrack(audioOutputFormat!!)
        } else {
            -1
        }
        newMuxer.start()
        muxer = newMuxer
        currentPath = path
        segmentBasePtsUs = basePtsUs
        segmentStartedAtMs = startedAtMs
        lastVideoPtsUs = -1L
        lastAudioPtsUs = -1L
        lastMediaPtsUs = basePtsUs
    }

    private fun writeVideo(buffer: ByteBuffer, sourcePtsUs: Long, flags: Int) {
        val activeMuxer = muxer ?: return
        var ptsUs = max(0L, sourcePtsUs - segmentBasePtsUs)
        if (ptsUs <= lastVideoPtsUs) ptsUs = lastVideoPtsUs + 1L
        lastVideoPtsUs = ptsUs
        lastMediaPtsUs = max(lastMediaPtsUs, sourcePtsUs)
        val sample = buffer.slice()
        val info = MediaCodec.BufferInfo().apply {
            set(
                0,
                sample.remaining(),
                ptsUs,
                flags and MediaCodec.BUFFER_FLAG_KEY_FRAME,
            )
        }
        val writeStartedAtMs = SystemClock.elapsedRealtime()
        activeMuxer.writeSampleData(
            videoTrack,
            sample,
            info,
        )
        recordMuxWrite(writeStartedAtMs)
    }

    private fun writeAudio(sample: EncodedSample) {
        val sourcePtsUs = audioPtsOnVideoTimeline(sample)
        if (sourcePtsUs < segmentBasePtsUs) return
        val activeMuxer = muxer ?: return
        var ptsUs = sourcePtsUs - segmentBasePtsUs
        if (ptsUs <= lastAudioPtsUs) ptsUs = lastAudioPtsUs + 1L
        lastAudioPtsUs = ptsUs
        lastMediaPtsUs = max(lastMediaPtsUs, sourcePtsUs)
        val info = MediaCodec.BufferInfo().apply {
            set(0, sample.bytes.size, ptsUs, 0)
        }
        val writeStartedAtMs = SystemClock.elapsedRealtime()
        activeMuxer.writeSampleData(audioTrack, ByteBuffer.wrap(sample.bytes), info)
        recordMuxWrite(writeStartedAtMs)
    }

    private fun recordMuxWrite(startedAtMs: Long) {
        val elapsedMs = SystemClock.elapsedRealtime() - startedAtMs
        if (elapsedMs > muxWriteMaxMs) muxWriteMaxMs = elapsedMs
        if (elapsedMs > MUX_WRITE_STALL_THRESHOLD_MS) muxWriteStallCount++
    }

    private fun audioPtsOnVideoTimeline(sample: EncodedSample): Long {
        val offsetUs = audioToVideoPtsOffsetUs
            ?: (segmentBasePtsUs - sample.presentationTimeUs).also {
                audioToVideoPtsOffsetUs = it
            }
        return sample.presentationTimeUs + offsetUs
    }

    private fun flushPendingAudioToCurrent() {
        pendingAudio.forEach(::writeAudio)
        pendingAudio.clear()
    }

    private fun finishStop() {
        val result = stopResult ?: return
        flushPendingAudioToCurrent()
        val path = currentPath
        val startedAt = segmentStartedAtMs
        val endedAt = if (lastMediaPtsUs >= segmentBasePtsUs) {
            startedAt + (lastMediaPtsUs - segmentBasePtsUs) / 1_000L
        } else {
            System.currentTimeMillis()
        }
        try {
            closeMuxer(deleteEmpty = false)
            setVideoSuspended(true)
            stopResult = null
            pendingStartPath = null
            pendingSplitPath = null
            if (path == null) {
                replyError(result, "empty_recording", "没有生成有效录像")
            } else {
                replySuccess(result, mapOf(
                    "path" to path,
                    "startedAtMs" to startedAt,
                    "endedAtMs" to max(startedAt, endedAt),
                ))
            }
        } catch (error: Throwable) {
            stopResult = null
            replyError(result, "muxer_stop", "录像文件保存失败")
            notifyNativeError("录像文件保存失败", error)
        }
    }

    private fun closeMuxer(deleteEmpty: Boolean) {
        val closing = muxer
        val path = currentPath
        muxer = null
        videoTrack = -1
        audioTrack = -1
        if (closing != null) {
            try {
                closing.stop()
            } finally {
                closing.release()
                if (deleteEmpty && path != null) File(path).delete()
            }
        }
    }

    private fun requestSyncFrame() {
        try {
            videoEncoder?.setParameters(Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            })
        } catch (error: Throwable) {
            notifyNativeError("无法请求录像关键帧", error)
        }
    }

    private fun setVideoSuspended(suspended: Boolean) {
        try {
            videoEncoder?.setParameters(Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_SUSPEND, if (suspended) 1 else 0)
            })
        } catch (_: Throwable) {
            // A few vendor encoders omit dynamic suspend; discarding their idle output is safe.
        }
    }

    private fun failPendingStart(code: String, message: String) {
        val result = startResult ?: return
        Log.w(CAMERA_LOG_TAG, "start failed code=$code message=$message")
        startResult = null
        pendingStartPath?.let { File(it).delete() }
        pendingStartPath = null
        recordingRequested = false
        recordingActive = false
        resetStallRecovery()
        recreateCaptureSession()
        setVideoSuspended(true)
        audioRunning.set(false)
        try {
            audioRecord?.stop()
        } catch (_: Throwable) {
        }
        replyError(result, code, message)
    }

    private fun failInitialization(code: String, message: String, error: Throwable?) {
        val result = initializeResult
        initializeResult = null
        initialized = false
        Log.w(CAMERA_LOG_TAG, "initialization failed code=$code message=$message", error)
        closeCameraResourcesForRetry()
        if (result != null) replyError(result, code, error?.let { "$message：${it.message}" } ?: message)
        else notifyNativeError(message, error)
    }

    private fun closeCameraResourcesForRetry() {
        cameraHandler?.post {
            if (disposed) return@post
            captureSession?.close()
            captureSession = null
            analysisReader?.close()
            analysisReader = null
            cameraDevice?.close()
            cameraDevice = null
            previewSurface?.release()
            previewSurface = null
            resetStallRecovery()
        }
    }

    fun getDiagnostics(result: MethodChannel.Result) {
        val now = SystemClock.elapsedRealtime()
        val state = mapOf<String, Any?>(
            "initialized" to initialized,
            "cameraId" to selectedCameraId,
            "lensFacing" to if (selectedLensFacing == CameraCharacteristics.LENS_FACING_FRONT) "front" else "back",
            "sensorOrientation" to sensorOrientation,
            "videoWidth" to videoSize.width,
            "videoHeight" to videoSize.height,
            "analysisWidth" to analysisSize.width,
            "analysisHeight" to analysisSize.height,
            "videoMime" to selectedVideoMime,
            "fps" to (if (recordingRequested || recordingActive) recordingSpec.fps else "auto"),
            "recordingSpec" to recordingSpecName,
            "previewActive" to previewActive,
            "workScanEnabled" to workScanEnabled,
            "pairingScanEnabled" to pairingScanEnabled,
            "recordingRequested" to recordingRequested,
            "recordingActive" to recordingActive,
            "torchEnabled" to torchEnabled,
            "canSwitchCamera" to canSwitchCamera,
            "previewFrameCount" to captureStartedCount,
            "previewFrameAgeMs" to if (lastCaptureStartedAtMs == 0L) -1L else now - lastCaptureStartedAtMs,
            "lastCaptureCompletedAgeMs" to if (lastCaptureCompletedAtMs == 0L) -1L else now - lastCaptureCompletedAtMs,
            "storageAvailableBytes" to runCatching {
                StatFs(activity.filesDir.path).availableBytes
            }.getOrDefault(-1L),
            "storageTotalBytes" to runCatching {
                StatFs(activity.filesDir.path).totalBytes
            }.getOrDefault(-1L),
            "muxWriteMaxMs" to muxWriteMaxMs,
            "muxWriteStallCount" to muxWriteStallCount,
            "codecFallbackReason" to codecFallbackReason,
            "lastRequestTemplate" to lastRequestTemplate,
            "stallActive" to stallActive,
            "stallRecoveryStage" to stallRecoveryStage,
            "sessionConfigStage" to sessionConfigStage,
            "sessionConfigAttempts" to sessionConfigAttempts,
        )
        result.success(
            mapOf(
                "device" to mapOf(
                    "manufacturer" to Build.MANUFACTURER,
                    "model" to Build.MODEL,
                    "sdkInt" to Build.VERSION.SDK_INT,
                    "release" to Build.VERSION.RELEASE,
                ),
                "camera" to state,
            ),
        )
    }

    private fun notifyNativeError(message: String, error: Throwable?) {
        Log.w(CAMERA_LOG_TAG, "$message", error)
        emit("nativeError", error?.let { "$message：${it.message}" } ?: message)
    }

    private fun notifyWriteError(message: String, error: Throwable) {
        val availableBytes = runCatching {
            StatFs(activity.filesDir.path).availableBytes
        }.getOrDefault(Long.MAX_VALUE)
        if (availableBytes < RecordingStoragePolicy.MINIMUM_BYTES) {
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

    private fun initializationMap(): Map<String, Any?> = mapOf(
        "textureId" to (textureEntry?.id() ?: -1L),
        "previewWidth" to videoSize.width,
        "previewHeight" to videoSize.height,
        "sensorOrientation" to sensorOrientation,
        "lensDirection" to if (selectedLensFacing == CameraCharacteristics.LENS_FACING_FRONT) "front" else "back",
        "canSwitchCamera" to canSwitchCamera,
        "fps" to recordingSpec.fps,
        "recordingSpec" to recordingSpecName,
        "videoMime" to selectedVideoMime,
        "codecFallbackReason" to codecFallbackReason,
        "flashAvailable" to (
            selectedCameraCharacteristics?.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        ),
    )

    private fun ensureParent(path: String) {
        File(path).parentFile?.mkdirs()
    }

    private fun hasRecordingReserve(path: String): Boolean = runCatching {
        val parent = File(path).parentFile ?: activity.filesDir
        StatFs(parent.path).availableBytes >= RecordingStoragePolicy.MINIMUM_BYTES
    }.getOrDefault(false)

    private fun replySuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun replyError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    private data class EncodedSample(
        val bytes: ByteArray,
        val presentationTimeUs: Long,
        val flags: Int,
    )
}
