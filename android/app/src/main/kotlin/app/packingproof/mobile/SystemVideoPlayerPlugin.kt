package app.packingproof.mobile

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * 播放失败时使用的系统播放器兜底，以及读取视频轨道编码信息。
 */
class SystemVideoPlayerPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL_NAME = "app.packingproof.mobile/system_player"
        private const val VIDEO_MIME = "video/mp4"
        private const val TAG = "PackingProof.Gallery"
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getVideoTrackMime" -> result.success(
                getVideoTrackMime(call.argument<String>("path")),
            )
            "getVideoDecodeSupport" -> result.success(
                mapOf(
                    "manufacturer" to Build.MANUFACTURER,
                    "brand" to Build.BRAND,
                    "model" to Build.MODEL,
                    "sdkInt" to Build.VERSION.SDK_INT,
                    "release" to Build.VERSION.RELEASE,
                    "hasHevcDecoder" to CodecCapabilities.hasDecoder(
                        MediaFormat.MIMETYPE_VIDEO_HEVC,
                    ),
                    "hasAvcDecoder" to CodecCapabilities.hasDecoder(
                        MediaFormat.MIMETYPE_VIDEO_AVC,
                    ),
                    "hasHevcEncoder" to CodecCapabilities.hasEncoder(
                        MediaFormat.MIMETYPE_VIDEO_HEVC,
                    ),
                    "hasAvcEncoder" to CodecCapabilities.hasEncoder(
                        MediaFormat.MIMETYPE_VIDEO_AVC,
                    ),
                    "forceSoftwareDecode" to RecordingCodecPolicy(
                        Build.MANUFACTURER,
                        Build.VERSION.SDK_INT,
                    ).forceSoftwareDecoderPreferenceForPlayback(),
                ),
            )
            "openWithSystemPlayer" -> openWithSystemPlayer(
                call.argument<String>("path"),
                result,
            )
            "saveVideoToGallery" -> saveVideoToGallery(
                call.argument<String>("path"),
                result,
            )
            else -> result.notImplemented()
        }
    }

    private fun getVideoTrackMime(path: String?): String? {
        if (path.isNullOrBlank()) return null
        return try {
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(path)
                for (index in 0 until extractor.trackCount) {
                    val mime = extractor.getTrackFormat(index)
                        .getString(MediaFormat.KEY_MIME)
                        ?: continue
                    if (mime.startsWith("video/")) return mime
                }
                null
            } finally {
                extractor.release()
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun openWithSystemPlayer(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("invalid_path", "录像文件路径不能为空", null)
            return
        }
        try {
            val file = File(path)
            if (!file.exists()) {
                result.error("file_missing", "录像文件不存在", null)
                return
            }
            val token = SystemVideoPlayerProvider.register(file)
            val uri = Uri.parse(
                "content://${activity.packageName}.system_player_provider/$token",
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "video/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            result.success(true)
        } catch (error: ActivityNotFoundException) {
            result.error("no_player", "没有可用的系统播放器", null)
        } catch (error: Throwable) {
            result.error("open_failed", error.message ?: "系统播放器打开失败", null)
        }
    }

    private fun saveVideoToGallery(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("invalid_path", "录像文件路径不能为空", null)
            return
        }
        val source = File(path)
        if (!source.exists() || !source.isFile) {
            result.error("file_missing", "录像文件不存在", null)
            return
        }
        try {
            saveVideoToGalleryInternal(source)
            result.success(null)
        } catch (error: Throwable) {
            Log.w(TAG, "saveVideoToGallery failed", error)
            result.error("save_failed", "保存到相册失败", error.message)
        }
    }

    private fun saveVideoToGalleryInternal(source: File) {
        val resolver = activity.contentResolver
        val displayName = galleryDisplayName(source.name)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Video.Media.MIME_TYPE, VIDEO_MIME)
                put(
                    MediaStore.Video.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_MOVIES}/PackingProof",
                )
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                values,
            ) ?: throw IOException("无法创建相册记录")
            try {
                resolver.openOutputStream(uri)?.use { output ->
                    source.inputStream().use { input -> input.copyTo(output) }
                } ?: throw IOException("无法写入相册")
                resolver.update(
                    uri,
                    ContentValues().apply {
                        put(MediaStore.Video.Media.IS_PENDING, 0)
                    },
                    null,
                    null,
                )
            } catch (error: Throwable) {
                resolver.delete(uri, null, null)
                throw error
            }
        } else {
            // Android 9 及以下：应用专属外部 Movies 目录无需存储权限，写完交给
            // 媒体扫描器入库；卸载应用时该目录会随容器移除。
            val directory = activity.getExternalFilesDir(Environment.DIRECTORY_MOVIES)
                ?: throw IOException("没有可用的外部存储")
            val target = File(directory, displayName)
            source.inputStream().use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
            MediaScannerConnection.scanFile(
                activity,
                arrayOf(target.absolutePath),
                arrayOf(VIDEO_MIME),
                null,
            )
        }
    }

    private fun galleryDisplayName(name: String): String {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return "PackingProof.mp4"
        return if (trimmed.contains('.')) trimmed else "$trimmed.mp4"
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
