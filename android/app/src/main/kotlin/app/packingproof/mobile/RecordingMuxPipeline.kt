package app.packingproof.mobile

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.SystemClock
import java.io.File
import java.nio.ByteBuffer

internal data class EncodedMuxSample(
    val bytes: ByteArray,
    val presentationTimeUs: Long,
    val flags: Int,
)

internal data class MuxSegmentRotation(
    val completedPath: String,
    val nextPath: String,
    val completedStartedAtMs: Long,
    val boundaryAtMs: Long,
)

internal data class MuxStopSummary(
    val path: String?,
    val startedAtMs: Long,
    val endedAtMs: Long,
)

internal fun interface SegmentMuxerFactory {
    fun open(
        path: String,
        orientationHintDegrees: Int,
        recordAudio: Boolean,
    ): SegmentMuxer
}

internal interface SegmentMuxer {
    fun writeVideo(buffer: ByteBuffer, presentationTimeUs: Long, flags: Int)

    fun writeAudio(sample: EncodedMuxSample, presentationTimeUs: Long)

    fun close(deleteOutput: Boolean)
}

/**
 * Serial A/V mux state for one continuous recording.
 *
 * All calls are made on the owning mux handler. Camera sessions and codec lifecycles stay outside
 * this class; it owns only segment writers, pending audio and the cross-segment PTS mapping.
 */
internal class RecordingMuxPipeline(
    private val muxerFactory: SegmentMuxerFactory,
    private val timeline: MuxTimelinePolicy = MuxTimelinePolicy(),
) {
    private val pendingAudio = mutableListOf<EncodedMuxSample>()
    private var muxer: SegmentMuxer? = null

    var currentPath: String? = null
        private set

    var segmentStartedAtMs: Long = 0L
        private set

    val hasActiveMuxer: Boolean
        get() = muxer != null

    fun beginRecording() {
        timeline.beginRecording()
        pendingAudio.clear()
    }

    fun beginSplit() {
        pendingAudio.clear()
    }

    fun acceptAudio(
        sample: EncodedMuxSample,
        recordingRequested: Boolean,
        recordingActive: Boolean,
        splitPending: Boolean,
    ) {
        if (!recordingActive || muxer == null) {
            if (recordingRequested) pendingAudio.add(sample)
            return
        }
        if (splitPending) {
            pendingAudio.add(sample)
            return
        }
        writeAudio(sample)
    }

    fun openSegment(
        path: String,
        basePtsUs: Long,
        startedAtMs: Long,
        orientationHintDegrees: Int,
        recordAudio: Boolean,
    ) {
        val newMuxer = muxerFactory.open(path, orientationHintDegrees, recordAudio)
        muxer = newMuxer
        currentPath = path
        segmentStartedAtMs = startedAtMs
        timeline.openSegment(basePtsUs)
    }

    fun writeVideo(buffer: ByteBuffer, sourcePtsUs: Long, flags: Int) {
        val activeMuxer = muxer ?: return
        activeMuxer.writeVideo(buffer, timeline.videoPtsUs(sourcePtsUs), flags)
    }

    fun flushPendingAudio() {
        pendingAudio.forEach(::writeAudio)
        pendingAudio.clear()
    }

    fun discardPendingAudio() {
        pendingAudio.clear()
    }

    fun rotateAtKeyFrame(
        nextPath: String,
        buffer: ByteBuffer,
        sourcePtsUs: Long,
        flags: Int,
        orientationHintDegrees: Int,
        recordAudio: Boolean,
    ): MuxSegmentRotation {
        val completedPath = checkNotNull(currentPath)
        val completedStartedAtMs = segmentStartedAtMs
        val boundaryAtMs = timeline.boundaryAtMs(segmentStartedAtMs, sourcePtsUs)
        pendingAudio
            .filter { timeline.audioSourcePtsUs(it.presentationTimeUs) < sourcePtsUs }
            .forEach(::writeAudio)
        close(deleteOutput = false)
        openSegment(
            nextPath,
            sourcePtsUs,
            boundaryAtMs,
            orientationHintDegrees,
            recordAudio,
        )
        pendingAudio
            .filter { timeline.audioSourcePtsUs(it.presentationTimeUs) >= sourcePtsUs }
            .forEach(::writeAudio)
        pendingAudio.clear()
        writeVideo(buffer, sourcePtsUs, flags)
        return MuxSegmentRotation(
            completedPath,
            nextPath,
            completedStartedAtMs,
            boundaryAtMs,
        )
    }

    fun finishStop(nowMs: Long): MuxStopSummary {
        flushPendingAudio()
        val path = currentPath
        val startedAtMs = segmentStartedAtMs
        val endedAtMs = timeline.endedAtMs(startedAtMs, nowMs)
        close(deleteOutput = false)
        return MuxStopSummary(path, startedAtMs, endedAtMs)
    }

    fun close(deleteOutput: Boolean) {
        val closing = muxer
        muxer = null
        closing?.close(deleteOutput)
    }

    private fun writeAudio(sample: EncodedMuxSample) {
        val activeMuxer = muxer ?: return
        val ptsUs = timeline.audioPtsUs(sample.presentationTimeUs) ?: return
        activeMuxer.writeAudio(sample, ptsUs)
    }
}

internal class AndroidSegmentMuxerFactory(
    private val videoFormat: () -> MediaFormat?,
    private val audioFormat: () -> MediaFormat?,
    private val onWriteCompleted: (startedAtMs: Long) -> Unit,
    private val elapsedRealtimeMs: () -> Long = SystemClock::elapsedRealtime,
) : SegmentMuxerFactory {
    override fun open(
        path: String,
        orientationHintDegrees: Int,
        recordAudio: Boolean,
    ): SegmentMuxer {
        val outputFile = File(path)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists() && !outputFile.delete()) {
            error("无法覆盖录像文件")
        }
        val muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        muxer.setOrientationHint(orientationHintDegrees)
        val videoTrack = muxer.addTrack(videoFormat()!!)
        val selectedAudioFormat = audioFormat()
        val audioTrack = if (recordAudio && selectedAudioFormat != null) {
            muxer.addTrack(selectedAudioFormat)
        } else {
            -1
        }
        muxer.start()
        return FrameworkSegmentMuxer(
            backend = AndroidFrameworkMuxerBackend(muxer),
            path = path,
            videoTrack = videoTrack,
            audioTrack = audioTrack,
            elapsedRealtimeMs = elapsedRealtimeMs,
            onWriteCompleted = onWriteCompleted,
        )
    }
}

internal interface FrameworkMuxerBackend {
    fun writeSampleData(track: Int, buffer: ByteBuffer, info: MediaCodec.BufferInfo)

    fun stop()

    fun release()
}

private class AndroidFrameworkMuxerBackend(
    private val muxer: MediaMuxer,
) : FrameworkMuxerBackend {
    override fun writeSampleData(
        track: Int,
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
    ) {
        muxer.writeSampleData(track, buffer, info)
    }

    override fun stop() = muxer.stop()

    override fun release() = muxer.release()
}

internal class FrameworkSegmentMuxer(
    private val backend: FrameworkMuxerBackend,
    private val path: String,
    private val videoTrack: Int,
    private val audioTrack: Int,
    private val elapsedRealtimeMs: () -> Long,
    private val onWriteCompleted: (startedAtMs: Long) -> Unit,
) : SegmentMuxer {
    override fun writeVideo(buffer: ByteBuffer, presentationTimeUs: Long, flags: Int) {
        val sample = buffer.slice()
        val info = MediaCodec.BufferInfo().apply {
            set(
                0,
                sample.remaining(),
                presentationTimeUs,
                flags and MediaCodec.BUFFER_FLAG_KEY_FRAME,
            )
        }
        val writeStartedAtMs = elapsedRealtimeMs()
        backend.writeSampleData(videoTrack, sample, info)
        onWriteCompleted(writeStartedAtMs)
    }

    override fun writeAudio(sample: EncodedMuxSample, presentationTimeUs: Long) {
        val info = MediaCodec.BufferInfo().apply {
            set(0, sample.bytes.size, presentationTimeUs, 0)
        }
        val writeStartedAtMs = elapsedRealtimeMs()
        backend.writeSampleData(audioTrack, ByteBuffer.wrap(sample.bytes), info)
        onWriteCompleted(writeStartedAtMs)
    }

    override fun close(deleteOutput: Boolean) {
        try {
            backend.stop()
        } finally {
            backend.release()
            if (deleteOutput) File(path).delete()
        }
    }
}
