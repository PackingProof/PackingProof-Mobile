package app.packingproof.mobile

import app.packingproof.mobile.generated.CameraHostApi
import app.packingproof.mobile.generated.CameraInitializeRequest
import app.packingproof.mobile.generated.CameraInitializationDto
import app.packingproof.mobile.generated.CameraLensDto
import app.packingproof.mobile.generated.CameraRecordingSplitDto
import app.packingproof.mobile.generated.CameraRecordingStartDto
import app.packingproof.mobile.generated.CameraRecordingStopDto
import app.packingproof.mobile.generated.FlutterError
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class PigeonCameraHostApi(
    private val plugin: ContinuousCameraPlugin,
) : CameraHostApi {
    override fun initialize(
        request: CameraInitializeRequest,
        callback: (Result<CameraInitializationDto>) -> Unit,
    ) {
        invokeCamera(
            "initialize",
            mapOf(
                "videoCodec" to request.videoCodec,
                "recordingSpec" to request.recordingSpec,
                "capabilityMode" to request.capabilityMode,
            ),
            callback,
        ) { value -> (value as Map<*, *>).toCameraInitializationDto() }
    }

    override fun ensurePermissions(
        recordAudio: Boolean,
        callback: (Result<Boolean>) -> Unit,
    ) {
        invokeCamera(
            "ensurePermissions",
            mapOf("recordAudio" to recordAudio),
            callback,
        ) { value -> value as Boolean }
    }

    override fun startWork(
        path: String,
        recordAudio: Boolean,
        callback: (Result<CameraRecordingStartDto>) -> Unit,
    ) {
        invokeCamera(
            "startWork",
            mapOf("path" to path, "recordAudio" to recordAudio),
            callback,
        ) { value -> (value as Map<*, *>).toCameraRecordingStartDto() }
    }

    override fun split(
        nextPath: String,
        callback: (Result<CameraRecordingSplitDto>) -> Unit,
    ) {
        invokeCamera(
            "split",
            mapOf("path" to nextPath),
            callback,
        ) { value -> (value as Map<*, *>).toCameraRecordingSplitDto() }
    }

    override fun stopWork(
        callback: (Result<CameraRecordingStopDto>) -> Unit,
    ) {
        invokeCamera("stopWork", null, callback) { value ->
            (value as Map<*, *>).toCameraRecordingStopDto()
        }
    }

    override fun getDiagnostics(
        callback: (Result<Map<String?, Any?>?>) -> Unit,
    ) {
        invokeCamera("getDiagnostics", null, callback) { value ->
            (value as? Map<*, *>)?.entries?.associate {
                (it.key as? String) to it.value
            }
        }
    }

    override fun setPairingScanEnabled(
        enabled: Boolean,
        callback: (Result<Unit>) -> Unit,
    ) {
        invokeCamera(
            "setPairingScanEnabled",
            mapOf("enabled" to enabled),
            callback,
        ) { }
    }

    override fun setWorkScanEnabled(
        enabled: Boolean,
        callback: (Result<Unit>) -> Unit,
    ) {
        invokeCamera(
            "setWorkScanEnabled",
            mapOf("enabled" to enabled),
            callback,
        ) { }
    }

    override fun setPreviewActive(
        active: Boolean,
        callback: (Result<Unit>) -> Unit,
    ) {
        invokeCamera("setPreviewActive", mapOf("active" to active), callback) { }
    }

    override fun setTorchEnabled(
        enabled: Boolean,
        callback: (Result<Boolean>) -> Unit,
    ) {
        invokeCamera(
            "setTorchEnabled",
            mapOf("enabled" to enabled),
            callback,
        ) { value -> value as Boolean }
    }

    override fun switchCamera(
        callback: (Result<CameraInitializationDto>) -> Unit,
    ) {
        invokeCamera("switchCamera", null, callback) { value ->
            (value as Map<*, *>).toCameraInitializationDto()
        }
    }

    override fun listCameras(
        callback: (Result<List<CameraLensDto>>) -> Unit,
    ) {
        invokeCamera("listCameras", null, callback) { value ->
            (value as? List<*>).orEmpty().map {
                (it as Map<*, *>).toCameraLensDto()
            }
        }
    }

    override fun switchToCamera(
        cameraId: String,
        callback: (Result<CameraInitializationDto>) -> Unit,
    ) {
        invokeCamera(
            "switchToCamera",
            mapOf("cameraId" to cameraId),
            callback,
        ) { value -> (value as Map<*, *>).toCameraInitializationDto() }
    }

    override fun probeSequence(
        sequence: String,
        budgetMs: Long,
        callback: (Result<Map<String?, Any?>?>) -> Unit,
    ) {
        invokeCamera(
            "probeSequence",
            mapOf("sequence" to sequence, "budgetMs" to budgetMs.toInt()),
            callback,
        ) { value ->
            (value as? Map<*, *>)?.entries?.associate {
                (it.key as? String) to it.value
            }
        }
    }

    override fun setCapabilityMode(mode: String) {
        plugin.onMethodCall(
            MethodCall("setCapabilityMode", mapOf("mode" to mode)),
            RawMethodResult { },
        )
    }

    override fun dispose(callback: (Result<Unit>) -> Unit) {
        invokeCamera("dispose", null, callback) { }
    }

    private fun <T> invokeCamera(
        method: String,
        arguments: Map<String, Any?>?,
        callback: (Result<T>) -> Unit,
        transform: (Any?) -> T,
    ) {
        plugin.onMethodCall(
            MethodCall(method, arguments),
            RawMethodResult { reply ->
                when (reply) {
                    is RawMethodReply.Success ->
                        callback(Result.success(transform(reply.value)))
                    is RawMethodReply.Error ->
                        callback(Result.failure(reply.error))
                }
            },
        )
    }
}

internal sealed interface RawMethodReply {
    data class Success(val value: Any?) : RawMethodReply
    data class Error(val error: FlutterError) : RawMethodReply
}

internal class RawMethodResult(
    private val callback: (RawMethodReply) -> Unit,
) : MethodChannel.Result {
    override fun success(result: Any?) = callback(RawMethodReply.Success(result))

    override fun error(
        errorCode: String,
        errorMessage: String?,
        errorDetails: Any?,
    ) {
        callback(
            RawMethodReply.Error(
                FlutterError(errorCode, errorMessage, errorDetails),
            ),
        )
    }

    override fun notImplemented() {
        callback(
            RawMethodReply.Error(
                FlutterError("not_implemented", "相机方法未实现", null),
            ),
        )
    }
}

private fun Map<*, *>.toCameraInitializationDto(): CameraInitializationDto =
    CameraInitializationDto(
        textureId = (this["textureId"] as Number).toLong(),
        previewWidth = (this["previewWidth"] as Number).toLong(),
        previewHeight = (this["previewHeight"] as Number).toLong(),
        sensorOrientation = (this["sensorOrientation"] as Number).toLong(),
        fps = (this["fps"] as Number).toLong(),
        videoMime = this["videoMime"] as String,
        codecFallbackReason = this["codecFallbackReason"] as? String,
        flashAvailable = this["flashAvailable"] as? Boolean ?: false,
        lensDirection = this["lensDirection"] as? String ?: "back",
        canSwitchCamera = this["canSwitchCamera"] as? Boolean ?: false,
        cameraId = this["cameraId"] as? String,
        zoomRatio = (this["zoomRatio"] as? Number)?.toDouble() ?: 1.0,
    )

private fun Map<*, *>.toCameraRecordingStartDto(): CameraRecordingStartDto =
    CameraRecordingStartDto(
        path = this["path"] as String,
        startedAtMs = (this["startedAtMs"] as Number).toLong(),
    )

private fun Map<*, *>.toCameraRecordingSplitDto(): CameraRecordingSplitDto =
    CameraRecordingSplitDto(
        completedPath = this["completedPath"] as String,
        nextPath = this["nextPath"] as String,
        completedStartedAtMs = (this["completedStartedAtMs"] as Number).toLong(),
        boundaryAtMs = (this["boundaryAtMs"] as Number).toLong(),
    )

private fun Map<*, *>.toCameraRecordingStopDto(): CameraRecordingStopDto =
    CameraRecordingStopDto(
        path = this["path"] as String,
        startedAtMs = (this["startedAtMs"] as Number).toLong(),
        endedAtMs = (this["endedAtMs"] as Number).toLong(),
    )

private fun Map<*, *>.toCameraLensDto(): CameraLensDto =
    CameraLensDto(
        cameraId = this["cameraId"] as? String ?: "",
        focalLength = (this["focalLength"] as? Number)?.toDouble() ?: 0.0,
        zoomRatio = (this["zoomRatio"] as? Number)?.toDouble() ?: 1.0,
        isMain = this["isMain"] as? Boolean ?: false,
    )
