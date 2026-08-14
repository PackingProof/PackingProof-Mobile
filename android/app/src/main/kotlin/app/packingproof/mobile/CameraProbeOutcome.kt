package app.packingproof.mobile

import android.hardware.camera2.CameraAccessException

/**
 * 探针阶段结束原因。Dart 侧据此把阶段归入
 * `passed / failed_capability / error_infra`，因此这里的值必须与
 * `CameraCapabilityPolicy` 的映射保持一致。
 */
internal enum class CameraProbeOutcome(val wire: String) {
    CONFIGURED("configured"),
    CONFIGURE_FAILED("configure_failed"),
    UNSUPPORTED_COMBINATION("unsupported_combination"),
    CODEC_MISSING("codec_missing"),
    CODEC_CONFIG_FAILED("codec_config_failed"),
    CAMERA_ACCESS_ERROR("camera_access_error"),
    CAMERA_DISABLED("camera_disabled"),
    CAMERA_ERROR("camera_error"),
    CAMERA_DISCONNECTED("camera_disconnected"),
    CONFIGURE_TIMEOUT("configure_timeout"),
    INTERNAL_ERROR("internal_error"),
    SURFACE_MISSING("surface_missing"),
    BUDGET_EXCEEDED("budget_exceeded"),
}

/** 纯 JVM 可测的失败分类：只做“能力证据 / 探针异常”的机械映射。 */
internal object CameraProbeOutcomePolicy {
    fun cameraOpenError(error: Throwable): CameraProbeOutcome = when (error) {
        is CameraAccessException -> cameraOpenErrorReason(error.reason)
        is SecurityException -> CameraProbeOutcome.CAMERA_ACCESS_ERROR
        else -> CameraProbeOutcome.INTERNAL_ERROR
    }

    /** 纯 JVM 可测：按 Camera2 访问错误码分类，不依赖 android.jar 桩构造器。 */
    fun cameraOpenErrorReason(reason: Int): CameraProbeOutcome =
        if (reason == CameraAccessException.CAMERA_DISABLED) {
            CameraProbeOutcome.CAMERA_DISABLED
        } else {
            CameraProbeOutcome.CAMERA_ACCESS_ERROR
        }

    fun cameraStateError(errorCode: Int): CameraProbeOutcome =
        if (errorCode == android.hardware.camera2.CameraDevice.StateCallback.ERROR_CAMERA_DISABLED) {
            CameraProbeOutcome.CAMERA_DISABLED
        } else {
            CameraProbeOutcome.CAMERA_ERROR
        }

    fun sessionCreateError(error: Throwable): CameraProbeOutcome = when (error) {
        is IllegalArgumentException -> CameraProbeOutcome.UNSUPPORTED_COMBINATION
        is CameraAccessException -> CameraProbeOutcome.CAMERA_ACCESS_ERROR
        is SecurityException -> CameraProbeOutcome.CAMERA_ACCESS_ERROR
        else -> CameraProbeOutcome.INTERNAL_ERROR
    }

    fun codecCreateError(error: Throwable): CameraProbeOutcome = when (error) {
        is IllegalArgumentException -> CameraProbeOutcome.CODEC_MISSING
        else -> CameraProbeOutcome.INTERNAL_ERROR
    }

    fun codecConfigureError(error: Throwable): CameraProbeOutcome = when (error) {
        is IllegalArgumentException,
        is IllegalStateException,
        is android.media.MediaCodec.CodecException,
        -> CameraProbeOutcome.CODEC_CONFIG_FAILED
        else -> CameraProbeOutcome.INTERNAL_ERROR
    }
}
