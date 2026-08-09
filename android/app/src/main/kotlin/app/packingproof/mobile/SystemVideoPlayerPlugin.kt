package app.packingproof.mobile

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 播放失败时使用的系统播放器兜底，以及读取视频轨道编码信息。
 */
class SystemVideoPlayerPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL_NAME = "app.packingproof.mobile/system_player"
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
                    "preferH264" to RecordingCodecPolicy(
                        Build.MANUFACTURER,
                    ).preferH264OverHevc(),
                    "forceSoftwareDecode" to RecordingCodecPolicy(
                        Build.MANUFACTURER,
                    ).forceSoftwareDecoderPreferenceForPlayback(),
                ),
            )
            "openWithSystemPlayer" -> openWithSystemPlayer(
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

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
