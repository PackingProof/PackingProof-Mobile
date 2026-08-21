package app.packingproof.mobile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.OverlaySettings
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(UnstableApi::class)
class VideoWatermarkPlugin(
    context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "app.packingproof.mobile/video_watermark")
    private val applicationContext = context.applicationContext
    private var transformer: Transformer? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingOutput: File? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "apply" -> apply(call.arguments as? Map<*, *>, result)
                else -> result.notImplemented()
            }
        }
    }

    internal fun invoke(
        method: String,
        arguments: Map<String, Any?>?,
        result: MethodChannel.Result,
    ) {
        when (method) {
            "apply" -> apply(arguments, result)
            else -> result.notImplemented()
        }
    }

    private fun apply(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("watermark_busy", "正在保存上一段录像", null)
            return
        }
        val inputPath = arguments?.get("inputPath") as? String
        val outputPath = arguments?.get("outputPath") as? String
        val startedAtMs = (arguments?.get("startedAtMs") as? Number)?.toLong()
        val trackingNumber = arguments?.get("trackingNumber") as? String ?: ""
        val recordingOrientation = arguments?.get("recordingOrientation") as? String ?: "portrait"
        val videoMime = if (arguments?.get("videoCodec") == "h264") {
            MimeTypes.VIDEO_H264
        } else {
            MimeTypes.VIDEO_H265
        }
        if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank() || startedAtMs == null) {
            result.error("invalid_watermark", "录像水印参数无效", null)
            return
        }
        val input = File(inputPath)
        if (!input.isFile) {
            result.error("missing_input", "录像文件不存在", null)
            return
        }
        val output = File(outputPath)
        output.parentFile?.mkdirs()
        output.delete()

        val settings = StaticOverlaySettings.Builder()
            .setOverlayFrameAnchor(1f, 1f)
            .setBackgroundFrameAnchor(0.96f, 0.08f)
            .build()
        val overlay = object : BitmapOverlay() {
            private val formatter = SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.ROOT)
            private var videoSize = Size(1080, 1920)
            private var cachedSecond = Long.MIN_VALUE
            private var cachedBitmap: Bitmap? = null

            override fun configure(videoSize: Size) {
                super.configure(videoSize)
                this.videoSize = videoSize
                clearCache()
            }

            override fun getBitmap(presentationTimeUs: Long): Bitmap {
                val second = presentationTimeUs / 1_000_000L
                cachedBitmap?.takeIf { cachedSecond == second }?.let { return it }
                val timestamp = formatter.format(Date(startedAtMs + presentationTimeUs / 1_000L))
                val lines = if (trackingNumber.isBlank()) {
                    listOf(timestamp)
                } else {
                    listOf(timestamp, "Order:$trackingNumber")
                }
                val bitmap = renderOutlinedText(lines)
                cachedBitmap?.recycle()
                cachedSecond = second
                cachedBitmap = bitmap
                return bitmap
            }

            override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings = settings

            override fun release() {
                clearCache()
                super.release()
            }

            private fun renderOutlinedText(lines: List<String>): Bitmap {
                val textSize = (videoSize.height * 0.032f).coerceIn(35f, 61f)
                val strokeWidth = (textSize / 10f).coerceAtLeast(3f)
                val padding = strokeWidth + 3f
                val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    this.textSize = textSize
                    textAlign = Paint.Align.RIGHT
                    strokeJoin = Paint.Join.ROUND
                }
                val lineHeight = (paint.fontMetrics.bottom - paint.fontMetrics.top) * 1.08f
                val contentWidth = lines.maxOf { paint.measureText(it) }
                val width = (contentWidth + padding * 2).toInt().coerceAtLeast(1)
                val height = (lineHeight * lines.size + padding * 2).toInt().coerceAtLeast(1)
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap.density = Bitmap.DENSITY_NONE
                val canvas = Canvas(bitmap)
                val rotation = when (recordingOrientation) {
                    "landscapeLeft" -> -90f
                    "landscapeRight" -> 90f
                    else -> 0f
                }
                canvas.rotate(rotation, width / 2f, height / 2f)
                val right = width - padding
                var baseline = padding - paint.fontMetrics.top
                for (line in lines) {
                    paint.style = Paint.Style.STROKE
                    paint.strokeWidth = strokeWidth
                    paint.color = Color.BLACK
                    canvas.drawText(line, right, baseline, paint)
                    paint.style = Paint.Style.FILL
                    paint.color = Color.WHITE
                    canvas.drawText(line, right, baseline, paint)
                    baseline += lineHeight
                }
                return bitmap
            }

            private fun clearCache() {
                cachedBitmap?.recycle()
                cachedBitmap = null
                cachedSecond = Long.MIN_VALUE
            }
        }
        val editedMediaItem = EditedMediaItem.Builder(
            MediaItem.fromUri(Uri.fromFile(input)),
        ).setEffects(
            Effects(emptyList(), listOf(OverlayEffect(listOf(overlay)))),
        ).build()

        pendingResult = result
        pendingOutput = output
        transformer = Transformer.Builder(applicationContext)
            .setVideoMimeType(videoMime)
            .addListener(
                object : Transformer.Listener {
                    override fun onCompleted(
                        composition: Composition,
                        exportResult: ExportResult,
                    ) = finishSuccess(outputPath)

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException,
                    ) = finishError(exportException)
                },
            )
            .build()
        try {
            transformer?.start(editedMediaItem, outputPath)
        } catch (error: Exception) {
            finishError(error)
        }
    }

    private fun finishSuccess(outputPath: String) {
        val result = pendingResult
        pendingResult = null
        pendingOutput = null
        transformer = null
        result?.success(outputPath)
    }

    private fun finishError(error: Throwable) {
        pendingOutput?.delete()
        pendingOutput = null
        val result = pendingResult
        pendingResult = null
        transformer = null
        result?.error("watermark_failed", error.message ?: "录像水印生成失败", null)
    }

    fun dispose() {
        transformer?.cancel()
        transformer = null
        pendingOutput?.delete()
        pendingOutput = null
        pendingResult?.error("watermark_cancelled", "录像水印生成已取消", null)
        pendingResult = null
        channel.setMethodCallHandler(null)
    }
}
