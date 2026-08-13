package app.packingproof.mobile

import android.content.Context
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

@OptIn(UnstableApi::class)
class VideoExportPlugin(
    context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "app.packingproof.mobile/video_export")
    private val applicationContext = context.applicationContext
    private var transformer: Transformer? = null
    private var pendingResult: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "export" -> export(call.arguments as? Map<*, *>, result)
                "progress" -> reportProgress(result)
                "cancel" -> {
                    cancel()
                    result.success(null)
                }
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
            "export" -> export(arguments, result)
            "progress" -> reportProgress(result)
            "cancel" -> {
                cancel()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun export(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("export_busy", "已有分享视频正在生成", null)
            return
        }
        val inputPath = arguments?.get("inputPath") as? String
        val outputPath = arguments?.get("outputPath") as? String
        val startMs = (arguments?.get("startMs") as? Number)?.toLong()
        val endMs = (arguments?.get("endMs") as? Number)?.toLong()
        if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank() ||
            startMs == null || endMs == null || startMs < 0 || endMs <= startMs
        ) {
            result.error("invalid_export", "分享视频参数无效", null)
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

        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(input))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(startMs)
                    .setEndPositionMs(endMs)
                    .build(),
            )
            .build()
        val editedMediaItem = EditedMediaItem.Builder(mediaItem).build()
        pendingResult = result
        transformer = Transformer.Builder(applicationContext)
            .addListener(
                object : Transformer.Listener {
                    override fun onCompleted(
                        composition: Composition,
                        exportResult: ExportResult,
                    ) {
                        finishSuccess(outputPath)
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException,
                    ) {
                        finishError(exportException)
                    }
                },
            )
            .build()
        try {
            transformer?.start(editedMediaItem, outputPath)
        } catch (error: Exception) {
            finishError(error)
        }
    }

    private fun reportProgress(result: MethodChannel.Result) {
        val active = transformer
        if (active == null || pendingResult == null) {
            result.success(100)
            return
        }
        val holder = ProgressHolder()
        active.getProgress(holder)
        result.success(holder.progress)
    }

    private fun finishSuccess(outputPath: String) {
        val result = pendingResult
        pendingResult = null
        transformer = null
        result?.success(outputPath)
    }

    private fun finishError(error: Throwable) {
        val result = pendingResult
        pendingResult = null
        transformer = null
        result?.error("export_failed", error.message ?: "分享视频生成失败", null)
    }

    fun cancel() {
        transformer?.cancel()
        transformer = null
        val result = pendingResult
        pendingResult = null
        result?.error("export_cancelled", "已取消生成分享视频", null)
    }

    fun dispose() {
        cancel()
        channel.setMethodCallHandler(null)
    }
}
