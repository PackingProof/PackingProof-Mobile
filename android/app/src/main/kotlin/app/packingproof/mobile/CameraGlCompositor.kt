package app.packingproof.mobile

import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLExt
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal enum class CameraGlOutput {
    INPUT,
    PREVIEW,
    ENCODER,
}

internal data class CameraGlFailure(
    val output: CameraGlOutput,
    val error: Throwable,
)

internal class CameraGlOperationException(
    val stage: String,
    val api: String,
    val errorCode: Int?,
    cause: Throwable? = null,
) : IllegalStateException(
    buildString {
        append(api)
        append(" operation failed at ")
        append(stage)
        errorCode?.let {
            append(" with error 0x")
            append(it.toString(16))
        }
    },
    cause,
)

private data class CameraGlDrawResult(
    val submitted: Boolean,
    val watermarkRendered: Boolean,
)

/**
 * Camera OES input composited once for preview and MediaCodec surfaces.
 *
 * This class deliberately owns only its camera input Surface and EGL objects. The caller retains
 * ownership of previewOutput and encoderOutput. Barcode analysis remains a direct Camera2 output.
 */
internal class CameraGlCompositor(
    private val inputWidth: Int,
    private val inputHeight: Int,
    private val width: Int,
    private val height: Int,
    private val inputQuarterTurns: Int,
    private val previewOutput: Surface,
    private val encoderOutput: Surface,
    private val recordingOrientation: String = "portrait",
    private val onFailure: (CameraGlFailure) -> Unit,
    private val onEncodedWatermarkFrame: (Long, Boolean) -> Unit = { _, _ -> },
    private val onWatermarkFailure: (Throwable) -> Unit = {},
) {
    companion object {
        private const val START_TIMEOUT_SECONDS = 5L
        private const val EGL_RECORDABLE_ANDROID = 0x3142

        private val FULL_FRAME_VERTICES = floatArrayOf(
            -1f, -1f, 0f, 0f,
            1f, -1f, 1f, 0f,
            -1f, 1f, 0f, 1f,
            1f, 1f, 1f, 1f,
        )

        private const val VERTEX_SHADER = """
            attribute vec2 aPosition;
            attribute vec2 aTextureCoordinate;
            uniform mat4 uTextureTransform;
            uniform int uInputQuarterTurns;
            varying vec2 vTextureCoordinate;
            vec2 orientedCoordinate(vec2 coordinate) {
              if (uInputQuarterTurns == 1) return vec2(coordinate.y, 1.0 - coordinate.x);
              if (uInputQuarterTurns == 2) return vec2(1.0 - coordinate.x, 1.0 - coordinate.y);
              if (uInputQuarterTurns == 3) return vec2(1.0 - coordinate.y, coordinate.x);
              return coordinate;
            }
            void main() {
              gl_Position = vec4(aPosition, 0.0, 1.0);
              vec2 coordinate = orientedCoordinate(aTextureCoordinate);
              vTextureCoordinate = (uTextureTransform * vec4(coordinate, 0.0, 1.0)).xy;
            }
        """

        private const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES uCameraTexture;
            varying vec2 vTextureCoordinate;
            void main() {
              gl_FragColor = texture2D(uCameraTexture, vTextureCoordinate);
            }
        """

        private const val WATERMARK_VERTEX_SHADER = """
            attribute vec2 aPosition;
            attribute vec2 aTextureCoordinate;
            varying vec2 vTextureCoordinate;
            void main() {
              gl_Position = vec4(aPosition, 0.0, 1.0);
              vTextureCoordinate = aTextureCoordinate;
            }
        """

        private const val WATERMARK_FRAGMENT_SHADER = """
            precision mediump float;
            uniform sampler2D uWatermarkTexture;
            varying vec2 vTextureCoordinate;
            void main() {
              gl_FragColor = texture2D(uWatermarkTexture, vTextureCoordinate);
            }
        """
    }

    init {
        require(inputWidth > 0)
        require(inputHeight > 0)
        require(width > 0)
        require(height > 0)
        require(inputQuarterTurns in 0..3)
    }

    private val started = AtomicBoolean(false)
    private val released = AtomicBoolean(false)
    private val encoderEnabled = AtomicBoolean(false)
    // 「仅扫码」模式录像时要求可见预览停住：编码输出照常，只停预览纹理出帧。
    private val previewEnabled = AtomicBoolean(true)
    private val thread = HandlerThread("packing-camera-gl")
    private val rasterThread = HandlerThread("packing-watermark-raster")
    private lateinit var handler: Handler
    private lateinit var rasterHandler: Handler

    private var display = EGL14.EGL_NO_DISPLAY
    private var context = EGL14.EGL_NO_CONTEXT
    private var pbuffer = EGL14.EGL_NO_SURFACE
    private var previewEglSurface = EGL14.EGL_NO_SURFACE
    private var encoderEglSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var watermarkProgram = 0
    private var cameraTexture = 0
    private var watermarkTexture = 0
    private var cameraSurfaceTexture: SurfaceTexture? = null
    private var cameraSurface: Surface? = null
    private var vertexBuffer: FloatBuffer? = null
    private var watermarkVertexBuffer: FloatBuffer? = null
    private val textureTransform = FloatArray(16)
    private val watermarkGeneration = java.util.concurrent.atomic.AtomicInteger(0)
    @Volatile private var watermarkEnabled = false
    @Volatile private var watermarkTrackingNumber = ""
    private val requestedWatermarkKeys = mutableSetOf<LiveWatermarkFrameKey>()
    private var activeWatermarkKey: LiveWatermarkFrameKey? = null
    private var activeWatermarkWidth = 0
    private var activeWatermarkHeight = 0
    private val pendingWatermarks = mutableMapOf<LiveWatermarkFrameKey, Bitmap>()
    private var pendingTransitionFrameCallback: ((Long, Boolean) -> Unit)? = null
    @Volatile private var watermarkOverlayFailed = false

    fun start(): Surface {
        check(!released.get()) { "Camera GL compositor was released" }
        check(started.compareAndSet(false, true)) { "Camera GL compositor was already started" }
        thread.start()
        rasterThread.start()
        handler = Handler(thread.looper)
        rasterHandler = Handler(rasterThread.looper)
        val ready = CountDownLatch(1)
        var initializationError: Throwable? = null
        handler.post {
            try {
                initializeEgl()
            } catch (error: Throwable) {
                initializationError = error
                releaseGlResources()
            } finally {
                ready.countDown()
            }
        }
        if (!ready.await(START_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            released.set(true)
            handler.post(::releaseGlResources)
            thread.quitSafely()
            rasterThread.quitSafely()
            throw IllegalStateException("Timed out starting camera GL compositor")
        }
        initializationError?.let {
            released.set(true)
            thread.quitSafely()
            rasterThread.quitSafely()
            throw IllegalStateException("Camera GL compositor init failed", it)
        }
        return checkNotNull(cameraSurface)
    }

    fun setEncoderEnabled(enabled: Boolean) {
        encoderEnabled.set(enabled)
    }

    fun setPreviewEnabled(enabled: Boolean) {
        previewEnabled.set(enabled)
    }

    fun hasWatermarkOverlayFailed(): Boolean = watermarkOverlayFailed

    fun setWatermark(trackingNumber: String) {
        val normalized = trackingNumber.trim()
        watermarkGeneration.incrementAndGet()
        synchronized(this) {
            requestedWatermarkKeys.removeAll { it.trackingNumber == normalized }
        }
        watermarkTrackingNumber = normalized
        watermarkEnabled = true
        watermarkOverlayFailed = false
        if (::handler.isInitialized) {
            handler.post {
                activeWatermarkKey = null
                pendingTransitionFrameCallback = null
                pendingWatermarks.keys
                    .filter { it.trackingNumber != normalized }
                    .forEach { key -> pendingWatermarks.remove(key)?.recycle() }
            }
        }
        requestWatermarkTextures(System.currentTimeMillis())
    }

    /**
     * Prepares and activates the next segment watermark before asking MediaCodec for its keyframe.
     * Because both activation and frame callbacks run on [handler], the first encoder frame
     * submitted after [onActivated] observes the new texture.
     */
    fun prepareWatermarkTransition(
        trackingNumber: String,
        onActivated: () -> Unit,
        onFirstFrameSubmitted: (Long, Boolean) -> Unit,
    ) {
        val normalized = trackingNumber.trim()
        if (!::handler.isInitialized || !::rasterHandler.isInitialized || released.get()) {
            onActivated()
            return
        }
        val generation = watermarkGeneration.get()
        val epochSecond = Math.floorDiv(System.currentTimeMillis(), 1_000L)
        rasterHandler.post {
            try {
                val formatter = SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.ROOT)
                val outputHeight = LiveWatermarkQuadPolicy.outputHeight(
                    width,
                    height,
                    recordingOrientation,
                )
                val bitmaps = listOf(epochSecond, epochSecond + 1L).associate { second ->
                    val key = LiveWatermarkFrameKey(second, normalized)
                    key to renderWatermarkTextBitmap(
                        outputHeight,
                        watermarkTextLines(formatter.format(Date(second * 1_000L)), normalized),
                        recordingOrientation,
                    )
                }
                val accepted = handler.post transitionPost@ {
                    if (released.get() || generation != watermarkGeneration.get()) {
                        bitmaps.values.forEach { it.recycle() }
                        onActivated()
                        return@transitionPost
                    }
                    watermarkGeneration.incrementAndGet()
                    watermarkTrackingNumber = normalized
                    watermarkEnabled = true
                    watermarkOverlayFailed = false
                    activeWatermarkKey = null
                    pendingWatermarks.values.forEach { it.recycle() }
                    pendingWatermarks.clear()
                    pendingWatermarks.putAll(bitmaps)
                    pendingTransitionFrameCallback = onFirstFrameSubmitted
                    synchronized(this) {
                        requestedWatermarkKeys.clear()
                        requestedWatermarkKeys.addAll(bitmaps.keys)
                    }
                    onActivated()
                }
                if (!accepted) {
                    bitmaps.values.forEach { it.recycle() }
                    onActivated()
                }
            } catch (error: Throwable) {
                // broad-catch: GL 线程初始化错误交回相机线程统一降级
                val accepted = handler.post {
                    watermarkTrackingNumber = normalized
                    watermarkEnabled = true
                    pendingTransitionFrameCallback = onFirstFrameSubmitted
                    failWatermarkOverlay(error)
                    onActivated()
                }
                if (!accepted) onActivated()
            }
        }
    }

    fun clearWatermark() {
        watermarkEnabled = false
        watermarkTrackingNumber = ""
        synchronized(this) { requestedWatermarkKeys.clear() }
        watermarkGeneration.incrementAndGet()
        if (::handler.isInitialized) {
            handler.post {
                activeWatermarkKey = null
                pendingTransitionFrameCallback = null
                pendingWatermarks.values.forEach { it.recycle() }
                pendingWatermarks.clear()
            }
        }
    }

    fun release() {
        if (!released.compareAndSet(false, true)) return
        if (!::handler.isInitialized) return
        if (Looper.myLooper() == handler.looper) {
            releaseGlResources()
            thread.quitSafely()
            rasterThread.quitSafely()
            return
        }
        val finished = CountDownLatch(1)
        handler.post {
            releaseGlResources()
            finished.countDown()
        }
        finished.await(START_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        thread.quitSafely()
        rasterThread.quitSafely()
    }

    private fun initializeEgl() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) {
            throw CameraGlOperationException("get_display", "egl", null)
        }
        checkEgl(
            EGL14.eglInitialize(display, null, 0, null, 0),
            "initialize",
        )

        val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
        val configCount = IntArray(1)
        val configAttributes = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        checkEgl(
            EGL14.eglChooseConfig(
                display,
                configAttributes,
                0,
                configs,
                0,
                configs.size,
                configCount,
                0,
            ) && configCount[0] > 0,
            "choose_config",
        )
        val config = checkNotNull(configs[0])
        context = EGL14.eglCreateContext(
            display,
            config,
            EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
            0,
        )
        if (context == EGL14.EGL_NO_CONTEXT) {
            throw eglException("create_context")
        }
        pbuffer = EGL14.eglCreatePbufferSurface(
            display,
            config,
            intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE),
            0,
        )
        if (pbuffer == EGL14.EGL_NO_SURFACE) {
            throw eglException("create_pbuffer_surface")
        }
        previewEglSurface = createWindowSurface(config, previewOutput, "preview")
        encoderEglSurface = createWindowSurface(config, encoderOutput, "encoder")
        makeCurrent(pbuffer)

        program = createProgram(VERTEX_SHADER, FRAGMENT_SHADER)
        watermarkProgram = createProgram(WATERMARK_VERTEX_SHADER, WATERMARK_FRAGMENT_SHADER)
        cameraTexture = createExternalTexture()
        vertexBuffer = ByteBuffer
            .allocateDirect(FULL_FRAME_VERTICES.size * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(FULL_FRAME_VERTICES)
                position(0)
            }
        watermarkVertexBuffer = ByteBuffer
            .allocateDirect(16 * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
        cameraSurfaceTexture = SurfaceTexture(cameraTexture).apply {
            setDefaultBufferSize(inputWidth, inputHeight)
            setOnFrameAvailableListener({ renderFrame() }, handler)
        }
        cameraSurface = Surface(cameraSurfaceTexture)
    }

    private fun renderFrame() {
        if (released.get()) return
        val input = cameraSurfaceTexture ?: return
        try {
            makeCurrent(pbuffer)
            input.updateTexImage()
            input.getTransformMatrix(textureTransform)
        } catch (error: Throwable) {
            // broad-catch: 输入纹理异常通过统一失败回调报告并丢弃当前帧
            reportFailure(CameraGlOutput.INPUT, error)
            return
        }
        val frameTimeMs = System.currentTimeMillis()
        if (watermarkEnabled && !watermarkOverlayFailed) requestWatermarkTextures(frameTimeMs)
        if (previewEnabled.get()) {
            drawOutput(previewEglSurface, null, CameraGlOutput.PREVIEW, frameTimeMs)
        }
        if (encoderEnabled.get()) {
            drawOutput(
                encoderEglSurface,
                input.timestamp,
                CameraGlOutput.ENCODER,
                frameTimeMs,
            )
        }
    }

    private fun drawOutput(
        surface: android.opengl.EGLSurface,
        presentationTimeNs: Long?,
        output: CameraGlOutput,
        frameTimeMs: Long,
    ): CameraGlDrawResult {
        try {
            makeCurrent(surface)
            GLES20.glViewport(0, 0, width, height)
            GLES20.glUseProgram(program)
            val buffer = checkNotNull(vertexBuffer)
            val positionLocation = GLES20.glGetAttribLocation(program, "aPosition")
            val textureCoordinateLocation = GLES20.glGetAttribLocation(
                program,
                "aTextureCoordinate",
            )
            buffer.position(0)
            GLES20.glEnableVertexAttribArray(positionLocation)
            GLES20.glVertexAttribPointer(
                positionLocation,
                2,
                GLES20.GL_FLOAT,
                false,
                4 * Float.SIZE_BYTES,
                buffer,
            )
            buffer.position(2)
            GLES20.glEnableVertexAttribArray(textureCoordinateLocation)
            GLES20.glVertexAttribPointer(
                textureCoordinateLocation,
                2,
                GLES20.GL_FLOAT,
                false,
                4 * Float.SIZE_BYTES,
                buffer,
            )
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTexture)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uCameraTexture"), 0)
            GLES20.glUniform1i(
                GLES20.glGetUniformLocation(program, "uInputQuarterTurns"),
                inputQuarterTurns,
            )
            GLES20.glUniformMatrix4fv(
                GLES20.glGetUniformLocation(program, "uTextureTransform"),
                1,
                false,
                textureTransform,
                0,
            )
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            checkGlError("draw camera frame")
            val watermarkRendered = drawWatermark(frameTimeMs)
            if (output == CameraGlOutput.ENCODER &&
                watermarkEnabled &&
                !watermarkOverlayFailed &&
                !watermarkRendered
            ) {
                // Do not submit an unwatermarked frame while the first texture is warming up.
                // Preview remains live; a real overlay failure flips watermarkOverlayFailed and
                // deliberately resumes fail-open encoder delivery on the following frame.
                return CameraGlDrawResult(submitted = false, watermarkRendered = false)
            }
            if (presentationTimeNs != null) {
                checkEgl(
                    EGLExt.eglPresentationTimeANDROID(display, surface, presentationTimeNs),
                    "presentation_time",
                )
                notifyEncoderFrameWillSubmit(
                    presentationTimeNs / 1_000L,
                    watermarkRendered,
                )
            }
            checkEgl(EGL14.eglSwapBuffers(display, surface), "swap_buffers")
            return CameraGlDrawResult(submitted = true, watermarkRendered = watermarkRendered)
        } catch (error: Throwable) {
            // broad-catch: EGL/GL 输出异常通过统一失败回调报告
            reportFailure(output, error)
            return CameraGlDrawResult(submitted = false, watermarkRendered = false)
        }
    }

    /** Registers the frame before swap makes it visible to MediaCodec's callback thread. */
    private fun notifyEncoderFrameWillSubmit(
        presentationTimeUs: Long,
        watermarkRendered: Boolean,
    ) {
        pendingTransitionFrameCallback?.let { callback ->
            pendingTransitionFrameCallback = null
            try {
                callback(presentationTimeUs, watermarkRendered)
            } catch (_: Throwable) {
                // broad-catch: Split diagnostics must not interrupt frame delivery.
            }
        }
        try {
            onEncodedWatermarkFrame(presentationTimeUs, watermarkRendered)
        } catch (_: Throwable) {
            // broad-catch: Recording diagnostics must not interrupt frame delivery.
        }
    }

    @Synchronized
    private fun requestWatermarkTextures(
        frameTimeMs: Long,
        trackingNumber: String = watermarkTrackingNumber,
    ) {
        if (!watermarkEnabled || watermarkOverlayFailed || released.get()) return
        val key = LiveWatermarkFrameKey(
            epochSecond = Math.floorDiv(frameTimeMs, 1_000L),
            trackingNumber = trackingNumber,
        )
        requestedWatermarkKeys.removeAll {
            it.epochSecond < key.epochSecond - 1L ||
                (it.trackingNumber != watermarkTrackingNumber &&
                    it.trackingNumber != trackingNumber)
        }
        val requestedKeys = listOf(key, key.copy(epochSecond = key.epochSecond + 1L))
            .filter { requestedWatermarkKeys.add(it) }
        if (requestedKeys.isEmpty()) return
        val generation = watermarkGeneration.get()
        rasterHandler.post {
            try {
                val formatter = SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.ROOT)
                val outputHeight = LiveWatermarkQuadPolicy.outputHeight(
                    width,
                    height,
                    recordingOrientation,
                )
                val bitmaps = requestedKeys.associateWith { bitmapKey ->
                    renderWatermarkTextBitmap(
                        outputHeight,
                        watermarkTextLines(
                            formatter.format(Date(bitmapKey.epochSecond * 1_000L)),
                            trackingNumber,
                        ),
                        recordingOrientation,
                    )
                }
                val accepted = handler.post rasterPost@ {
                    if (released.get() || generation != watermarkGeneration.get()) {
                        bitmaps.values.forEach { it.recycle() }
                        return@rasterPost
                    }
                    for ((bitmapKey, bitmap) in bitmaps) {
                        pendingWatermarks.remove(bitmapKey)?.recycle()
                        pendingWatermarks[bitmapKey] = bitmap
                    }
                }
                if (!accepted) {
                    bitmaps.values.forEach { it.recycle() }
                    if (!released.get()) {
                        failWatermarkOverlay(
                            IllegalStateException("Watermark GL handler rejected raster result"),
                        )
                    }
                }
            } catch (error: Throwable) {
                // broad-catch: 异步水印生成错误统一关闭水印但保留基础录像
                val accepted = handler.post {
                    if (generation == watermarkGeneration.get()) failWatermarkOverlay(error)
                }
                if (!accepted && !released.get()) failWatermarkOverlay(error)
            }
        }
    }

    private fun drawWatermark(frameTimeMs: Long): Boolean {
        if (!watermarkEnabled || watermarkOverlayFailed) return false
        return try {
            val key = LiveWatermarkFrameKey(
                epochSecond = Math.floorDiv(frameTimeMs, 1_000L),
                trackingNumber = watermarkTrackingNumber,
            )
            val selection = LiveWatermarkFrameSelectionPolicy.select(
                target = key,
                active = activeWatermarkKey,
                available = pendingWatermarks.keys,
            )
            selection.keyToActivate?.let { selectedKey ->
                val bitmap = pendingWatermarks.remove(selectedKey) ?: return false
                uploadWatermark(bitmap)
                bitmap.recycle()
                activeWatermarkKey = selectedKey
                pendingWatermarks.keys
                    .filter {
                        it.trackingNumber == selectedKey.trackingNumber &&
                            it.epochSecond < key.epochSecond
                    }
                    .forEach { staleKey -> pendingWatermarks.remove(staleKey)?.recycle() }
            }
            if (!selection.canRender ||
                watermarkTexture == 0 ||
                activeWatermarkWidth <= 0 ||
                activeWatermarkHeight <= 0
            ) {
                return false
            }
            val quad = LiveWatermarkQuadPolicy.create(
                videoWidth = width,
                videoHeight = height,
                bitmapWidth = activeWatermarkWidth,
                bitmapHeight = activeWatermarkHeight,
                recordingOrientation = recordingOrientation,
            )
            val vertices = floatArrayOf(
                ndcX(quad.topLeft.x), ndcY(quad.topLeft.y), 0f, 0f,
                ndcX(quad.topRight.x), ndcY(quad.topRight.y), 1f, 0f,
                ndcX(quad.bottomLeft.x), ndcY(quad.bottomLeft.y), 0f, 1f,
                ndcX(quad.bottomRight.x), ndcY(quad.bottomRight.y), 1f, 1f,
            )
            val buffer = checkNotNull(watermarkVertexBuffer).apply {
                clear()
                put(vertices)
                position(0)
            }
            GLES20.glUseProgram(watermarkProgram)
            val position = GLES20.glGetAttribLocation(watermarkProgram, "aPosition")
            val textureCoordinate = GLES20.glGetAttribLocation(
                watermarkProgram,
                "aTextureCoordinate",
            )
            buffer.position(0)
            GLES20.glEnableVertexAttribArray(position)
            GLES20.glVertexAttribPointer(
                position,
                2,
                GLES20.GL_FLOAT,
                false,
                4 * Float.SIZE_BYTES,
                buffer,
            )
            buffer.position(2)
            GLES20.glEnableVertexAttribArray(textureCoordinate)
            GLES20.glVertexAttribPointer(
                textureCoordinate,
                2,
                GLES20.GL_FLOAT,
                false,
                4 * Float.SIZE_BYTES,
                buffer,
            )
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, watermarkTexture)
            GLES20.glUniform1i(
                GLES20.glGetUniformLocation(watermarkProgram, "uWatermarkTexture"),
                0,
            )
            GLES20.glEnable(GLES20.GL_BLEND)
            // Android Bitmap pixels uploaded by GLUtils are premultiplied-alpha.
            GLES20.glBlendFunc(GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glDisable(GLES20.GL_BLEND)
            checkGlError("draw watermark")
            true
        } catch (error: Throwable) {
            // broad-catch: 水印绘制失败时关闭混合并继续基础相机画面
            GLES20.glDisable(GLES20.GL_BLEND)
            failWatermarkOverlay(error)
            false
        }
    }

    private fun uploadWatermark(bitmap: Bitmap) {
        if (watermarkTexture == 0) {
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            watermarkTexture = textures[0]
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, watermarkTexture)
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MIN_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MAG_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_S,
                GLES20.GL_CLAMP_TO_EDGE,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_T,
                GLES20.GL_CLAMP_TO_EDGE,
            )
        } else {
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, watermarkTexture)
        }
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
        checkGlError("upload watermark")
        activeWatermarkWidth = bitmap.width
        activeWatermarkHeight = bitmap.height
    }

    private fun failWatermarkOverlay(error: Throwable) {
        if (watermarkOverlayFailed) return
        watermarkOverlayFailed = true
        try {
            onWatermarkFailure(error)
        } catch (_: Throwable) {
            // broad-catch: Failure reporting must never interrupt the base camera pass.
        }
    }

    private fun ndcX(pixelX: Float): Float = pixelX / width.toFloat() * 2f - 1f

    private fun ndcY(pixelY: Float): Float = 1f - pixelY / height.toFloat() * 2f

    private fun reportFailure(output: CameraGlOutput, error: Throwable) {
        try {
            onFailure(CameraGlFailure(output, error))
        } catch (_: Throwable) {
            // broad-catch: A diagnostics callback must never stop camera frame delivery.
        }
    }

    private fun createWindowSurface(
        config: android.opengl.EGLConfig,
        surface: Surface,
        label: String,
    ): android.opengl.EGLSurface {
        val result = EGL14.eglCreateWindowSurface(
            display,
            config,
            surface,
            intArrayOf(EGL14.EGL_NONE),
            0,
        )
        if (result == EGL14.EGL_NO_SURFACE) {
            throw eglException("create_window_surface_$label")
        }
        return result
    }

    private fun makeCurrent(surface: android.opengl.EGLSurface) {
        checkEgl(
            EGL14.eglMakeCurrent(display, surface, surface, context),
            "make_current",
        )
    }

    private fun createExternalTexture(): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        checkGlError("glGenTextures")
        return textures[0].also { texture ->
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_MIN_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_MAG_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_WRAP_S,
                GLES20.GL_CLAMP_TO_EDGE,
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_WRAP_T,
                GLES20.GL_CLAMP_TO_EDGE,
            )
            checkGlError("configure OES texture")
        }
    }

    private fun createProgram(vertexSource: String, fragmentSource: String): Int {
        val vertex = compileShader(GLES20.GL_VERTEX_SHADER, vertexSource)
        val fragment = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSource)
        return GLES20.glCreateProgram().also { result ->
            GLES20.glAttachShader(result, vertex)
            GLES20.glAttachShader(result, fragment)
            GLES20.glLinkProgram(result)
            val linkStatus = IntArray(1)
            GLES20.glGetProgramiv(result, GLES20.GL_LINK_STATUS, linkStatus, 0)
            GLES20.glDeleteShader(vertex)
            GLES20.glDeleteShader(fragment)
            if (linkStatus[0] != GLES20.GL_TRUE) {
                throw CameraGlOperationException("link_program", "gl", null)
            }
        }
    }

    private fun compileShader(type: Int, source: String): Int =
        GLES20.glCreateShader(type).also { shader ->
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val status = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
            if (status[0] != GLES20.GL_TRUE) {
                throw CameraGlOperationException("compile_shader", "gl", null)
            }
        }

    private fun checkGlError(operation: String) {
        val error = GLES20.glGetError()
        if (error != GLES20.GL_NO_ERROR) {
            throw CameraGlOperationException(operation, "gl", error)
        }
    }

    private fun checkEgl(success: Boolean, operation: String) {
        if (!success) throw eglException(operation)
    }

    private fun eglException(operation: String): CameraGlOperationException =
        CameraGlOperationException(operation, "egl", EGL14.eglGetError())

    private fun releaseGlResources() {
        cameraSurfaceTexture?.setOnFrameAvailableListener(null)
        cameraSurface?.release()
        cameraSurface = null
        cameraSurfaceTexture?.release()
        cameraSurfaceTexture = null
        if (display != EGL14.EGL_NO_DISPLAY) {
            if (context != EGL14.EGL_NO_CONTEXT && pbuffer != EGL14.EGL_NO_SURFACE) {
                EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
                if (cameraTexture != 0) GLES20.glDeleteTextures(1, intArrayOf(cameraTexture), 0)
                if (watermarkTexture != 0) {
                    GLES20.glDeleteTextures(1, intArrayOf(watermarkTexture), 0)
                }
                if (program != 0) GLES20.glDeleteProgram(program)
                if (watermarkProgram != 0) GLES20.glDeleteProgram(watermarkProgram)
            }
            if (previewEglSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(display, previewEglSurface)
            }
            if (encoderEglSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(display, encoderEglSurface)
            }
            if (pbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, pbuffer)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            EGL14.eglReleaseThread()
            EGL14.eglTerminate(display)
        }
        cameraTexture = 0
        watermarkTexture = 0
        program = 0
        watermarkProgram = 0
        pendingWatermarks.values.forEach { it.recycle() }
        pendingWatermarks.clear()
        pendingTransitionFrameCallback = null
        previewEglSurface = EGL14.EGL_NO_SURFACE
        encoderEglSurface = EGL14.EGL_NO_SURFACE
        pbuffer = EGL14.EGL_NO_SURFACE
        context = EGL14.EGL_NO_CONTEXT
        display = EGL14.EGL_NO_DISPLAY
        vertexBuffer = null
        watermarkVertexBuffer = null
    }
}
