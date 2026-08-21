package app.packingproof.mobile

import android.hardware.camera2.CameraCharacteristics
import java.io.File

internal data class CameraIdentityDiagnostics(
    val initialized: Boolean,
    val cameraId: String?,
    val zoomRatio: Double,
    val cameraIdList: List<String>,
    val zoomRatioRange: List<Float>?,
    val frontFacing: Boolean,
    val sensorOrientation: Int,
)

internal data class CameraStreamDiagnostics(
    val videoSize: StreamSize,
    val analysisSize: StreamSize,
    val videoMime: String,
    val fps: Any,
    val recordingSpec: String,
    val recordAudio: Boolean,
)

internal data class CameraActivityDiagnostics(
    val previewActive: Boolean,
    val workScanEnabled: Boolean,
    val pairingScanEnabled: Boolean,
    val recordingRequested: Boolean,
    val recordingActive: Boolean,
    val torchEnabled: Boolean,
    val canSwitchCamera: Boolean,
)

internal data class CameraAnalysisDiagnostics(
    val startedCount: Long,
    val completedCount: Long,
    val detectedCount: Long,
    val failureCount: Long,
    val lastCompletedElapsedMs: Long,
    val lastFailure: String?,
)

internal data class CameraSwitchAndFrameDiagnostics(
    val switchCount: Int,
    val lastSwitchDurationMs: Long,
    val lastSwitchRestartedEncoder: Boolean,
    val previewFrameCount: Long,
    val lastPreviewFrameElapsedMs: Long,
    val lastCaptureCompletedElapsedMs: Long,
)

internal data class CameraResourceDiagnostics(
    val storageAvailableBytes: Long,
    val storageTotalBytes: Long,
    val muxWriteMaxMs: Long,
    val muxWriteStallCount: Long,
)

internal data class CameraRecoveryDiagnostics(
    val codecFallbackReason: String?,
    val lastRequestTemplate: String?,
    val stallActive: Boolean,
    val stallRecoveryStage: Int,
    val sessionConfigStage: String?,
    val sessionConfigAttempts: Int,
    val initFailureStage: String?,
    val initFailureDetail: String?,
    val startFailureStage: String?,
    val startFailureDetail: String?,
    val recordingFallbackMode: String?,
)

internal data class CameraCapabilityDiagnostics(
    val mode: String,
    val preferEncoderAnalysisRecording: Boolean,
    val sessionHasPreview: Boolean,
    val sessionHasEncoder: Boolean,
    val sessionHasAnalysis: Boolean,
    val probeResults: List<Map<String, Any?>>,
    val probeInProgress: Boolean,
    val probeCached: Boolean,
    val hardwareLevel: Int?,
    val capabilities: List<String>,
    val yuvSizes: List<String>,
    val videoSizes: List<String>,
    val previewSizes: List<String>,
    val physicalCameraIds: List<String>,
    val backLenses: List<Map<String, Any?>>,
    val fpsRanges: List<String>,
)

internal data class CameraDiagnosticsInput(
    val identity: CameraIdentityDiagnostics,
    val stream: CameraStreamDiagnostics,
    val activity: CameraActivityDiagnostics,
    val analysis: CameraAnalysisDiagnostics,
    val switchAndFrames: CameraSwitchAndFrameDiagnostics,
    val resources: CameraResourceDiagnostics,
    val recovery: CameraRecoveryDiagnostics,
    val capability: CameraCapabilityDiagnostics,
)

internal data class CameraDeviceDiagnostics(
    val manufacturer: String,
    val model: String,
    val sdkInt: Int,
    val release: String,
)

internal data class CameraProcessDiagnostics(
    val javaHeapUsedBytes: Long,
    val javaHeapMaxBytes: Long,
    val nativeHeapAllocatedBytes: Long,
    val threadCount: Int,
    val openFdCount: Int,
)

internal data class CameraProbeIdentityDiagnostics(
    val cameraId: String?,
    val videoSize: StreamSize,
    val analysisSize: StreamSize,
    val codec: String,
    val recordingSpec: String,
    val probeSchemaVersion: Int,
    val cameraPipelineVersion: Int,
)

internal data class CameraInitializationDiagnostics(
    val textureId: Long,
    val previewSize: StreamSize,
    val sensorOrientation: Int,
    val cameraId: String?,
    val zoomRatio: Double,
    val frontFacing: Boolean,
    val canSwitchCamera: Boolean,
    val fps: Int,
    val recordingSpec: String,
    val videoMime: String,
    val codecFallbackReason: String?,
    val flashAvailable: Boolean,
)

/** Camera diagnostics wire-map policy; contains no Camera2 or codec resource operations. */
internal object CameraDiagnosticsSnapshotMapper {
    fun snapshot(
        nowElapsedMs: Long,
        camera: CameraDiagnosticsInput,
        device: CameraDeviceDiagnostics,
        process: CameraProcessDiagnostics,
    ): Map<String, Any?> = mapOf(
        "device" to mapOf(
            "manufacturer" to device.manufacturer,
            "model" to device.model,
            "sdkInt" to device.sdkInt,
            "release" to device.release,
        ),
        "camera" to cameraMap(nowElapsedMs, camera),
        "process" to mapOf(
            "javaHeapUsedBytes" to process.javaHeapUsedBytes,
            "javaHeapMaxBytes" to process.javaHeapMaxBytes,
            "nativeHeapAllocatedBytes" to process.nativeHeapAllocatedBytes,
            "threadCount" to process.threadCount,
            "openFdCount" to process.openFdCount,
        ),
    )

    fun capabilityProbeIdentity(input: CameraProbeIdentityDiagnostics): Map<String, Any?> = mapOf(
        "cameraId" to input.cameraId.orEmpty(),
        "videoSize" to sizeLabel(input.videoSize.width, input.videoSize.height),
        "analysisSize" to sizeLabel(input.analysisSize.width, input.analysisSize.height),
        "codec" to input.codec,
        "spec" to input.recordingSpec,
        "probeSchemaVersion" to input.probeSchemaVersion,
        "cameraPipelineVersion" to input.cameraPipelineVersion,
    )

    fun initialization(input: CameraInitializationDiagnostics): Map<String, Any?> = mapOf(
        "textureId" to input.textureId,
        "previewWidth" to input.previewSize.width,
        "previewHeight" to input.previewSize.height,
        "sensorOrientation" to input.sensorOrientation,
        "cameraId" to input.cameraId,
        "zoomRatio" to input.zoomRatio,
        "lensDirection" to if (input.frontFacing) "front" else "back",
        "canSwitchCamera" to input.canSwitchCamera,
        "fps" to input.fps,
        "recordingSpec" to input.recordingSpec,
        "videoMime" to input.videoMime,
        "codecFallbackReason" to input.codecFallbackReason,
        "flashAvailable" to input.flashAvailable,
    )

    fun sizeLabel(width: Int, height: Int): String = "${width}x$height"

    fun backLens(lens: BackLensInfo): Map<String, Any?> = mapOf(
        "cameraId" to lens.cameraId,
        "focalLength" to lens.focalLength,
        "zoomRatio" to lens.zoomRatio,
        "isMain" to lens.isMain,
    )

    fun probePhaseResult(
        label: String,
        candidate: String?,
        outcome: String,
        detail: String?,
        previewFrames: Int,
        analysisFrames: Int,
        encoderBuffers: Int,
        durationMs: Int,
    ): Map<String, Any?> = mapOf(
        "phase" to label,
        "candidate" to candidate,
        "outcome" to outcome,
        "detail" to detail,
        "previewFrames" to previewFrames,
        "analysisFrames" to analysisFrames,
        "encoderBuffers" to encoderBuffers,
        "durationMs" to durationMs,
    )

    fun openFileDescriptorCount(): Int = runCatching {
        File("/proc/self/fd").listFiles()?.size ?: -1
    }.getOrDefault(-1)

    fun capabilityName(capability: Int): String = when (capability) {
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE -> "backward_compatible"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR -> "manual_sensor"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING -> "manual_post_processing"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW -> "raw"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_PRIVATE_REPROCESSING -> "private_reprocessing"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_READ_SENSOR_SETTINGS -> "read_sensor_settings"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BURST_CAPTURE -> "burst_capture"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT -> "depth_output"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_CONSTRAINED_HIGH_SPEED_VIDEO -> "constrained_high_speed_video"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MOTION_TRACKING -> "motion_tracking"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA -> "logical_multi_camera"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MONOCHROME -> "monochrome"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_SECURE_IMAGE_DATA -> "secure_image_data"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_SYSTEM_CAMERA -> "system_camera"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_ULTRA_HIGH_RESOLUTION_SENSOR -> "ultra_high_resolution_sensor"
        else -> "capability_$capability"
    }

    private fun cameraMap(nowElapsedMs: Long, input: CameraDiagnosticsInput): Map<String, Any?> {
        val identity = input.identity
        val stream = input.stream
        val activity = input.activity
        val analysis = input.analysis
        val switchAndFrames = input.switchAndFrames
        val resources = input.resources
        val recovery = input.recovery
        val capability = input.capability
        return mapOf(
            "initialized" to identity.initialized,
            "cameraId" to identity.cameraId,
            "zoomRatio" to identity.zoomRatio,
            "cameraIdList" to identity.cameraIdList,
            "zoomRatioRange" to identity.zoomRatioRange,
            "lensFacing" to if (identity.frontFacing) "front" else "back",
            "sensorOrientation" to identity.sensorOrientation,
            "videoWidth" to stream.videoSize.width,
            "videoHeight" to stream.videoSize.height,
            "analysisWidth" to stream.analysisSize.width,
            "analysisHeight" to stream.analysisSize.height,
            "videoMime" to stream.videoMime,
            "fps" to stream.fps,
            "recordingSpec" to stream.recordingSpec,
            "recordAudio" to stream.recordAudio,
            "previewActive" to activity.previewActive,
            "workScanEnabled" to activity.workScanEnabled,
            "pairingScanEnabled" to activity.pairingScanEnabled,
            "analysisStartedCount" to analysis.startedCount,
            "analysisCompletedCount" to analysis.completedCount,
            "analysisDetectedCount" to analysis.detectedCount,
            "analysisFailureCount" to analysis.failureCount,
            "lastAnalysisCompletedAgeMs" to elapsedAge(nowElapsedMs, analysis.lastCompletedElapsedMs),
            "lastAnalysisFailure" to analysis.lastFailure,
            "recordingRequested" to activity.recordingRequested,
            "recordingActive" to activity.recordingActive,
            "torchEnabled" to activity.torchEnabled,
            "canSwitchCamera" to activity.canSwitchCamera,
            "switchCount" to switchAndFrames.switchCount,
            "lastSwitchDurationMs" to switchAndFrames.lastSwitchDurationMs,
            "lastSwitchRestartedEncoder" to switchAndFrames.lastSwitchRestartedEncoder,
            "previewFrameCount" to switchAndFrames.previewFrameCount,
            "previewFrameAgeMs" to elapsedAge(nowElapsedMs, switchAndFrames.lastPreviewFrameElapsedMs),
            "lastCaptureCompletedAgeMs" to elapsedAge(
                nowElapsedMs,
                switchAndFrames.lastCaptureCompletedElapsedMs,
            ),
            "storageAvailableBytes" to resources.storageAvailableBytes,
            "storageTotalBytes" to resources.storageTotalBytes,
            "muxWriteMaxMs" to resources.muxWriteMaxMs,
            "muxWriteStallCount" to resources.muxWriteStallCount,
            "codecFallbackReason" to recovery.codecFallbackReason,
            "lastRequestTemplate" to recovery.lastRequestTemplate,
            "stallActive" to recovery.stallActive,
            "stallRecoveryStage" to recovery.stallRecoveryStage,
            "sessionConfigStage" to recovery.sessionConfigStage,
            "sessionConfigAttempts" to recovery.sessionConfigAttempts,
            "initFailureStage" to recovery.initFailureStage,
            "initFailureDetail" to recovery.initFailureDetail,
            "startFailureStage" to recovery.startFailureStage,
            "startFailureDetail" to recovery.startFailureDetail,
            "recordingFallbackMode" to recovery.recordingFallbackMode,
            "capabilityMode" to capability.mode,
            "preferEncoderAnalysisRecording" to capability.preferEncoderAnalysisRecording,
            "sessionSurfaces" to "preview=${capability.sessionHasPreview} " +
                "encoder=${capability.sessionHasEncoder} analysis=${capability.sessionHasAnalysis}",
            "probeResults" to capability.probeResults,
            "probeInProgress" to capability.probeInProgress,
            "probeCached" to capability.probeCached,
            "hardwareLevel" to capability.hardwareLevel,
            "capabilities" to capability.capabilities,
            "yuvSizes" to capability.yuvSizes,
            "videoSizes" to capability.videoSizes,
            "previewSizes" to capability.previewSizes,
            "physicalCameraIds" to capability.physicalCameraIds,
            "backLenses" to capability.backLenses,
            "fpsRanges" to capability.fpsRanges,
        )
    }

    private fun elapsedAge(nowElapsedMs: Long, lastElapsedMs: Long): Long =
        if (lastElapsedMs == 0L) -1L else nowElapsedMs - lastElapsedMs
}
