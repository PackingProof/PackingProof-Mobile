package app.packingproof.mobile

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

class ContinuousCameraPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL_NAME = "app.packingproof.mobile/continuous_camera"
        private const val PERMISSION_REQUEST = 4102
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private var engine = createEngine()
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissionRecordAudio = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> initialize(result, call.argument<String>("videoCodec"))
            "ensurePermissions" -> ensurePermissions(
                call.argument<Boolean>("recordAudio") == true,
                result,
            )
            "startWork" -> {
                val path = call.argument<String>("path")
                val recordAudio = call.argument<Boolean>("recordAudio") ?: true
                if (path.isNullOrBlank()) {
                    result.error("invalid_path", "录像文件路径不能为空", null)
                } else {
                    engine.startWork(path, recordAudio, result)
                }
            }
            "split" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("invalid_path", "下一段录像路径不能为空", null)
                } else {
                    engine.split(path, result)
                }
            }
            "stopWork" -> engine.stopWork(result)
            "getDiagnostics" -> engine.getDiagnostics(result)
            "setPairingScanEnabled" -> {
                engine.setPairingScanEnabled(call.argument<Boolean>("enabled") == true)
                result.success(null)
            }
            "setWorkScanEnabled" -> {
                engine.setWorkScanEnabled(call.argument<Boolean>("enabled") == true)
                result.success(null)
            }
            "setPreviewActive" -> {
                engine.setPreviewActive(call.argument<Boolean>("active") == true)
                result.success(null)
            }
            "setTorchEnabled" -> {
                engine.setTorchEnabled(call.argument<Boolean>("enabled") == true, result)
            }
            "switchCamera" -> {
                if (!engine.canSwitchNow()) {
                    result.error("camera_busy", "当前状态不能切换摄像头", null)
                } else {
                    val target = if (
                        engine.currentLensFacing() == CameraCharacteristics.LENS_FACING_FRONT
                    ) CameraCharacteristics.LENS_FACING_BACK
                    else CameraCharacteristics.LENS_FACING_FRONT
                    engine.dispose {
                        engine = createEngine(target)
                        engine.initialize(result)
                    }
                }
            }
            "dispose" -> {
                pendingPermissionResult?.error("disposed", "页面已关闭", null)
                pendingPermissionResult = null
                pendingPermissionRecordAudio = false
                engine.dispose()
                engine = createEngine()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun initialize(result: MethodChannel.Result, videoCodec: String?) {
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            engine.initialize(result, videoCodec)
            return
        }
        result.error("permission_denied", "需要摄像头权限才能工作", null)
    }

    private fun ensurePermissions(recordAudio: Boolean, result: MethodChannel.Result) {
        if (hasPermissions(requireAudio = recordAudio)) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_pending", "正在等待权限", null)
            return
        }
        pendingPermissionResult = result
        pendingPermissionRecordAudio = recordAudio
        val permissions = mutableListOf(Manifest.permission.CAMERA)
        if (recordAudio) {
            permissions += Manifest.permission.RECORD_AUDIO
        }
        ActivityCompat.requestPermissions(
            activity,
            permissions.toTypedArray(),
            PERMISSION_REQUEST,
        )
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) {
            return false
        }
        val result = pendingPermissionResult
        pendingPermissionResult = null
        val recordAudio = pendingPermissionRecordAudio
        pendingPermissionRecordAudio = false
        if (result == null) {
            return true
        }
        if (grantResults.size >= 1 && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
            result.success(true)
        } else {
            result.error(
                "permission_denied",
                if (recordAudio) "需要摄像头和麦克风权限才能工作" else "需要摄像头权限才能工作",
                null,
            )
        }
        return true
    }

    private fun hasPermissions(requireAudio: Boolean): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED &&
            (!requireAudio ||
                ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED)

    fun dispose() {
        channel.setMethodCallHandler(null)
        pendingPermissionResult?.error("disposed", "页面已关闭", null)
        pendingPermissionResult = null
        pendingPermissionRecordAudio = false
        engine.dispose()
    }

    private fun createEngine(
        preferredLensFacing: Int = CameraCharacteristics.LENS_FACING_BACK,
    ): ContinuousSegmentCamera =
        ContinuousSegmentCamera(activity, textures, preferredLensFacing) { method, arguments ->
            activity.runOnUiThread { channel.invokeMethod(method, arguments) }
        }
}
