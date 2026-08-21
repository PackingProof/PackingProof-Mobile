package app.packingproof.mobile

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.view.Surface
import java.nio.ByteBuffer

internal data class VideoEncoderCandidate(
    val mime: String,
    val useAvcMainProfile: Boolean,
)

internal data class VideoEncoderPlan(
    val candidates: List<VideoEncoderCandidate>,
    val fallbackReason: String?,
)

internal data class VideoEncoderFormatValues(
    val bitRate: Int,
    val framesPerSecond: Int,
    val iFrameIntervalSeconds: Int,
    val bitRateMode: Int,
    val disableBFrames: Boolean,
)

internal object VideoEncoderFormatPolicy {
    fun create(mime: String, spec: RecordingSpec, sdkInt: Int): VideoEncoderFormatValues =
        VideoEncoderFormatValues(
            bitRate = if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC) {
                spec.hevcBitRate
            } else {
                spec.avcBitRate
            },
            framesPerSecond = spec.fps,
            iFrameIntervalSeconds = 1,
            bitRateMode = MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR,
            disableBFrames = sdkInt >= Build.VERSION_CODES.Q,
        )
}

internal object VideoEncoderPlanPolicy {
    fun create(preferredMime: String, hevcDecodable: Boolean): VideoEncoderPlan {
        val normalizedPreferred = if (preferredMime == MediaFormat.MIMETYPE_VIDEO_AVC) {
            MediaFormat.MIMETYPE_VIDEO_AVC
        } else {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        }
        val fallback = if (normalizedPreferred == MediaFormat.MIMETYPE_VIDEO_AVC) {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        } else {
            MediaFormat.MIMETYPE_VIDEO_AVC
        }
        val fallbackReason = if (
            normalizedPreferred == MediaFormat.MIMETYPE_VIDEO_HEVC && !hevcDecodable
        ) {
            RecordingCodecPolicy.FALLBACK_NO_HEVC_DECODER
        } else {
            null
        }
        val candidates = listOf(normalizedPreferred, fallback)
            .filter { it != MediaFormat.MIMETYPE_VIDEO_HEVC || hevcDecodable }
            .flatMap { mime ->
                if (mime == MediaFormat.MIMETYPE_VIDEO_AVC) {
                    listOf(
                        VideoEncoderCandidate(mime, useAvcMainProfile = true),
                        VideoEncoderCandidate(mime, useAvcMainProfile = false),
                    )
                } else {
                    listOf(VideoEncoderCandidate(mime, useAvcMainProfile = false))
                }
            }
        return VideoEncoderPlan(candidates, fallbackReason)
    }
}

internal fun releaseRecordingVideoEncoderResources(
    stopCodec: () -> Unit,
    releaseCodec: () -> Unit,
    afterCodecRelease: () -> Unit,
    releaseSurface: () -> Unit,
    afterSurfaceRelease: () -> Unit,
) {
    try {
        stopCodec()
    } catch (_: Throwable) {
        // broad-catch: A failed or already stopped vendor codec still needs release.
    }
    try {
        releaseCodec()
    } catch (_: Throwable) {
        // broad-catch: Surface release must continue even if the codec release fails.
    }
    afterCodecRelease()
    releaseSurface()
    afterSurfaceRelease()
}

/** Owns the long-lived MediaCodec surface encoder used by Camera2 recording sessions. */
internal class RecordingVideoEncoder(
    private val recordingSpec: () -> RecordingSpec,
    private val onSample: (ByteBuffer, MediaCodec.BufferInfo) -> Unit,
    private val onSampleFailure: (Throwable) -> Unit,
    private val onEncoderError: (MediaCodec.CodecException) -> Unit,
    private val onOutputFormatChanged: () -> Unit,
    private val onSyncFrameFailure: (Throwable) -> Unit,
) {
    var preferredMime: String = MediaFormat.MIMETYPE_VIDEO_HEVC

    @Volatile
    var selectedMime: String = MediaFormat.MIMETYPE_VIDEO_HEVC
        private set

    var fallbackReason: String? = null
        private set

    @Volatile
    var inputSurface: Surface? = null
        private set

    @Volatile
    var outputFormat: MediaFormat? = null
        private set

    private var codec: MediaCodec? = null

    fun prepare(width: Int, height: Int, callbackHandler: Handler?) {
        var lastError: Throwable? = null
        fallbackReason = null
        val plan = VideoEncoderPlanPolicy.create(
            preferredMime,
            CodecCapabilities.hasDecoder(MediaFormat.MIMETYPE_VIDEO_HEVC),
        )
        fallbackReason = plan.fallbackReason
        for (candidate in plan.candidates) {
            var candidateCodec: MediaCodec? = null
            try {
                val format = createFormat(candidate.mime, width, height).apply {
                    if (candidate.useAvcMainProfile) {
                        setInteger(
                            MediaFormat.KEY_PROFILE,
                            MediaCodecInfo.CodecProfileLevel.AVCProfileMain,
                        )
                    }
                }
                candidateCodec = MediaCodec.createEncoderByType(candidate.mime)
                candidateCodec.setCallback(callback(), callbackHandler)
                candidateCodec.configure(
                    format,
                    null,
                    null,
                    MediaCodec.CONFIGURE_FLAG_ENCODE,
                )
                inputSurface = candidateCodec.createInputSurface()
                candidateCodec.start()
                codec = candidateCodec
                selectedMime = candidate.mime
                setSuspended(true)
                return
            } catch (error: Throwable) {
                // broad-catch: Each vendor codec/profile candidate is retried deterministically.
                lastError = error
                try {
                    candidateCodec?.release()
                } catch (_: Throwable) {
                    // broad-catch: Continue with the next candidate after vendor release failure.
                }
                inputSurface?.release()
                inputSurface = null
            }
        }
        throw IllegalStateException("设备没有可用的 H.265 或 H.264 编码器", lastError)
    }

    fun createFormat(mime: String, width: Int, height: Int): MediaFormat {
        val values = VideoEncoderFormatPolicy.create(
            mime,
            recordingSpec(),
            Build.VERSION.SDK_INT,
        )
        return MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
            setInteger(
                MediaFormat.KEY_BIT_RATE,
                values.bitRate,
            )
            setInteger(MediaFormat.KEY_FRAME_RATE, values.framesPerSecond)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, values.iFrameIntervalSeconds)
            setInteger(MediaFormat.KEY_BITRATE_MODE, values.bitRateMode)
            if (values.disableBFrames) {
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }
        }
    }

    fun requestSyncFrame() {
        try {
            codec?.setParameters(Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            })
        } catch (error: Throwable) {
            // broad-catch: Dynamic sync-frame requests are best-effort on vendor codecs.
            onSyncFrameFailure(error)
        }
    }

    fun setSuspended(suspended: Boolean) {
        try {
            codec?.setParameters(Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_SUSPEND, if (suspended) 1 else 0)
            })
        } catch (_: Throwable) {
            // broad-catch: Some vendor encoders omit dynamic suspend; idle output can be discarded.
        }
    }

    fun release() {
        releaseRecordingVideoEncoderResources(
            stopCodec = { codec?.stop() },
            releaseCodec = { codec?.release() },
            afterCodecRelease = { codec = null },
            releaseSurface = { inputSurface?.release() },
            afterSurfaceRelease = {
                inputSurface = null
                outputFormat = null
            },
        )
    }

    private fun callback(): MediaCodec.Callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

        override fun onOutputBufferAvailable(
            codec: MediaCodec,
            index: Int,
            info: MediaCodec.BufferInfo,
        ) {
            try {
                val buffer = codec.getOutputBuffer(index)
                if (buffer != null &&
                    info.size > 0 &&
                    info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                ) {
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    onSample(buffer, info)
                }
            } catch (error: Throwable) {
                // broad-catch: Sample and mux failures are reported without leaking codec buffers.
                onSampleFailure(error)
            } finally {
                try {
                    codec.releaseOutputBuffer(index, false)
                } catch (_: Throwable) {
                    // broad-catch: The codec may have transitioned to an error state asynchronously.
                }
            }
        }

        override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
            onEncoderError(error)
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            outputFormat = format
            onOutputFormatChanged()
        }
    }
}
