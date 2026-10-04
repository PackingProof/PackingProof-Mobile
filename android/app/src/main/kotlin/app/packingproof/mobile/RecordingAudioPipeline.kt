package app.packingproof.mobile

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/**
 * 麦克风初始化或启动失败：多半是麦克风被通话或其他应用占用。
 *
 * 单独成类型是为了让上层把失败分类成「麦克风被占用」，提示操作员结束通话
 * 或关掉占用麦克风的应用后重试，而不是笼统地报一句录制失败。
 */
internal class MicrophoneBusyException(cause: Throwable) :
    IllegalStateException("麦克风被占用或不可用", cause)

internal class AudioInputFrameClock(
    private val basePtsUs: Long,
    private val sampleRate: Int,
    private val channelCount: Int,
) {
    private var submittedFrames = 0L

    fun nextInputPtsUs(): Long =
        basePtsUs + submittedFrames * 1_000_000L / sampleRate

    fun advance(byteCount: Int) {
        submittedFrames += byteCount / BYTES_PER_PCM_16_SAMPLE / channelCount
    }

    private companion object {
        const val BYTES_PER_PCM_16_SAMPLE = 2L
    }
}

internal fun releaseRecordingAudioResources(
    stopRecorder: () -> Unit,
    releaseRecorder: () -> Unit,
    afterRecorderRelease: () -> Unit,
    stopEncoder: () -> Unit,
    releaseEncoder: () -> Unit,
) {
    try {
        stopRecorder()
    } catch (_: Throwable) {
        // broad-catch: The audio loop may already have stopped the recorder.
    }
    releaseRecorder()
    afterRecorderRelease()
    try {
        stopEncoder()
    } catch (_: Throwable) {
        // broad-catch: A codec failure can leave the encoder outside the started state.
    }
    releaseEncoder()
}

/** Owns the blocking AudioRecord thread and its synchronous AAC MediaCodec drain loop. */
internal class RecordingAudioPipeline(
    private val onSample: (EncodedMuxSample) -> Unit,
    private val onOutputFormat: (MediaFormat) -> Unit,
    private val onFailure: (Throwable) -> Unit,
    private val onStopped: () -> Unit,
    private val nanoTime: () -> Long = System::nanoTime,
) {
    private val running = AtomicBoolean(false)

    @Volatile
    private var recorder: AudioRecord? = null

    @Volatile
    private var workerThread: Thread? = null

    val hasActiveThread: Boolean
        get() = workerThread != null

    fun start(enabled: Boolean) {
        if (workerThread != null || !enabled) return
        running.set(true)
        val thread = Thread(::runPipeline, THREAD_NAME)
        workerThread = thread
        thread.start()
    }

    fun stop() {
        running.set(false)
        try {
            recorder?.stop()
        } catch (_: Throwable) {
            // broad-catch: The blocking read may already have stopped after an encoder failure.
        }
    }

    @SuppressLint("MissingPermission")
    private fun createMicrophoneRecorder(bufferSize: Int): AudioRecord {
        val activeRecorder = AudioRecord(
            MediaRecorder.AudioSource.CAMCORDER,
            AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize * 2,
        )
        if (activeRecorder.state != AudioRecord.STATE_INITIALIZED) {
            activeRecorder.release()
            throw MicrophoneBusyException(IllegalStateException("麦克风初始化失败"))
        }
        return activeRecorder
    }

    @SuppressLint("MissingPermission")
    private fun runPipeline() {
        var codec: MediaCodec? = null
        var localRecorder: AudioRecord? = null
        try {
            val minimumBufferSize = AudioRecord.getMinBufferSize(
                AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val bufferSize = max(minimumBufferSize, MINIMUM_BUFFER_SIZE)
            val activeRecorder = createMicrophoneRecorder(bufferSize)
            localRecorder = activeRecorder
            recorder = activeRecorder
            val audioFormat = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                AUDIO_SAMPLE_RATE,
                AUDIO_CHANNEL_COUNT,
            ).apply {
                setInteger(
                    MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC,
                )
                setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufferSize)
            }
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec.configure(audioFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            try {
                activeRecorder.startRecording()
            } catch (error: Throwable) {
                throw MicrophoneBusyException(error)
            }
            val inputClock = AudioInputFrameClock(
                nanoTime() / 1_000L,
                AUDIO_SAMPLE_RATE,
                AUDIO_CHANNEL_COUNT,
            )
            var inputEnded = false
            var outputEnded = false
            while (!outputEnded) {
                if (!inputEnded) {
                    val inputIndex = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val input = codec.getInputBuffer(inputIndex) ?: continue
                        input.clear()
                        if (running.get()) {
                            val read = activeRecorder.read(
                                input,
                                input.capacity(),
                                AudioRecord.READ_BLOCKING,
                            )
                            if (read > 0) {
                                val ptsUs = inputClock.nextInputPtsUs()
                                inputClock.advance(read)
                                codec.queueInputBuffer(inputIndex, 0, read, ptsUs, 0)
                            }
                        } else {
                            codec.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                inputClock.nextInputPtsUs(),
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputEnded = true
                        }
                    }
                }
                val info = MediaCodec.BufferInfo()
                var outputIndex = codec.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)
                while (outputIndex >= 0) {
                    val output = codec.getOutputBuffer(outputIndex)
                    if (output != null &&
                        info.size > 0 &&
                        info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                    ) {
                        output.position(info.offset)
                        output.limit(info.offset + info.size)
                        val bytes = ByteArray(info.size)
                        output.get(bytes)
                        onSample(EncodedMuxSample(bytes, info.presentationTimeUs, info.flags))
                    }
                    outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    codec.releaseOutputBuffer(outputIndex, false)
                    outputIndex = codec.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)
                }
                if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    onOutputFormat(codec.outputFormat)
                }
            }
        } catch (error: Throwable) {
            // broad-catch: Platform capture and codec failures are reported through one callback.
            onFailure(error)
        } finally {
            releaseRecordingAudioResources(
                stopRecorder = { localRecorder?.stop() },
                releaseRecorder = { localRecorder?.release() },
                afterRecorderRelease = { recorder = null },
                stopEncoder = { codec?.stop() },
                releaseEncoder = { codec?.release() },
            )
            workerThread = null
            onStopped()
        }
    }

    private companion object {
        const val AUDIO_SAMPLE_RATE = 48_000
        const val AUDIO_CHANNEL_COUNT = 1
        const val AUDIO_BIT_RATE = 96_000
        const val MINIMUM_BUFFER_SIZE = 16_384
        const val CODEC_TIMEOUT_US = 10_000L
        const val THREAD_NAME = "parcel-audio"
    }
}
