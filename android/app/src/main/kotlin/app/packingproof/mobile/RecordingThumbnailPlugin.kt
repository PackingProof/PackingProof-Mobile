package app.packingproof.mobile

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors

internal class RecordingThumbnailPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor = Executors.newSingleThreadExecutor()

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "generate") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path").orEmpty()
        generateThumbnail(path) { generated ->
            if (generated == null) {
                result.error("thumbnail_failed", "无法生成录像预览图", null)
            } else {
                result.success(generated)
            }
        }
    }

    internal fun generateThumbnail(path: String, callback: (String?) -> Unit) {
        executor.execute {
            runCatching { generate(path) }
                .onSuccess { context.mainExecutor.execute { callback(it) } }
                .onFailure { context.mainExecutor.execute { callback(null) } }
        }
    }

    private fun generate(path: String): String {
        val source = File(path)
        require(source.isFile) { "录像文件不存在" }
        val directory = File(context.cacheDir, "recording_thumbnails").apply { mkdirs() }
        val key = sha256("v3-50|${source.canonicalPath}|${source.lastModified()}|${source.length()}")
        val target = File(directory, "$key.jpg")
        if (target.length() > 0) return target.absolutePath

        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(source.absolutePath)
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()?.coerceAtLeast(1L) ?: 1L
            val frameMs = RecordingThumbnailPolicy.frameTimeMs(durationMs)
            val bitmap = retriever.getFrameAtTime(frameMs.coerceAtLeast(0L) * 1_000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: error("无法读取录像画面")
            val temp = File(directory, "$key.tmp")
            FileOutputStream(temp).use { bitmap.compress(Bitmap.CompressFormat.JPEG, 78, it) }
            bitmap.recycle()
            if (!temp.renameTo(target)) {
                temp.copyTo(target, overwrite = true)
                temp.delete()
            }
            cleanup(directory, target)
            return target.absolutePath
        } finally {
            retriever.release()
        }
    }

    private fun cleanup(directory: File, keep: File) {
        val files = directory.listFiles { file -> file.extension == "jpg" }
            ?.sortedByDescending { it.lastModified() }.orEmpty()
        var total = 0L
        files.forEach { file ->
            total += file.length()
            if (file != keep && (total > 128L * 1024 * 1024 || System.currentTimeMillis() - file.lastModified() > 30L * 24 * 60 * 60 * 1000)) {
                file.delete()
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray())
        .joinToString("") { "%02x".format(it) }

    companion object { private const val CHANNEL = "app.packingproof.mobile/recording_thumbnail" }
}

internal object RecordingThumbnailPolicy {
    fun frameTimeMs(durationMs: Long): Long {
        val safeDurationMs = durationMs.coerceAtLeast(1L)
        return (safeDurationMs / 2).coerceAtMost(safeDurationMs - 1).coerceAtLeast(0L)
    }
}
