package app.packingproof.mobile

import app.packingproof.mobile.generated.BackupNativeHostApi
import app.packingproof.mobile.generated.FlutterError
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class PigeonBackupHostApi(
    private val plugin: LanBackupPlugin,
) : BackupNativeHostApi {
    override fun snapshot(callback: (Result<Map<String?, Any?>?>) -> Unit) {
        invoke("snapshot", null, callback) { value ->
            (value as? Map<*, *>)?.entries?.associate {
                (it.key as? String) to it.value
            }
        }
    }

    override fun initialize(
        request: Map<String?, Any?>,
        callback: (Result<Map<String?, Any?>?>) -> Unit,
    ) {
        invoke("initialize", request, callback) { value ->
            (value as? Map<*, *>)?.entries?.associate {
                (it.key as? String) to it.value
            }
        }
    }

    override fun loadAccessKey(callback: (Result<String?>) -> Unit) {
        invoke("loadAccessKey", null, callback) { value -> value as? String }
    }

    override fun isWifiConnected(callback: (Result<Boolean>) -> Unit) {
        invoke("isWifiConnected", null, callback) { value -> value as Boolean }
    }

    override fun saveConnection(
        connection: Map<String?, Any?>,
        callback: (Result<Unit>) -> Unit,
    ) {
        invoke("saveConnection", connection, callback) { }
    }

    override fun disconnect(callback: (Result<Unit>) -> Unit) {
        invoke("disconnect", null, callback) { }
    }

    override fun enqueueJob(
        request: Map<String?, Any?>,
        callback: (Result<Unit>) -> Unit,
    ) {
        invoke("enqueue", request, callback) { }
    }

    override fun requeueJob(
        jobId: String,
        callback: (Result<Unit>) -> Unit,
    ) {
        invoke("retry", mapOf("id" to jobId), callback) { }
    }

    override fun cancelJob(
        jobId: String,
        callback: (Result<Unit>) -> Unit,
    ) {
        invoke("cancel", mapOf("id" to jobId), callback) { }
    }

    override fun updateRetentionSchedule(
        request: Map<String?, Any?>,
        callback: (Result<Unit>) -> Unit,
    ) {
        invoke("setRetentionPolicies", request, callback) { }
    }

    override fun reclaimStorageIfNeeded(
        callback: (Result<Map<String?, Any?>>) -> Unit,
    ) {
        invoke("checkAndReclaimStorage", null, callback) { value ->
            (value as? Map<*, *>)?.entries?.associate {
                (it.key as? String) to it.value
            }.orEmpty()
        }
    }

    override fun getNetworkDiagnostics(
        callback: (Result<Map<String?, Any?>?>) -> Unit,
    ) {
        invoke("getNetworkDiagnostics", null, callback) { value ->
            (value as? Map<*, *>)?.entries?.associate {
                (it.key as? String) to it.value
            }
        }
    }

    private fun <T> invoke(
        method: String,
        arguments: Map<String?, Any?>?,
        callback: (Result<T>) -> Unit,
        transform: (Any?) -> T,
    ) {
        plugin.onMethodCall(
            MethodCall(method, arguments),
            BackupMethodResult { reply ->
                when (reply) {
                    is BackupMethodReply.Success ->
                        callback(Result.success(transform(reply.value)))
                    is BackupMethodReply.Error ->
                        callback(Result.failure(reply.error))
                }
            },
        )
    }
}

private sealed interface BackupMethodReply {
    data class Success(val value: Any?) : BackupMethodReply
    data class Error(val error: FlutterError) : BackupMethodReply
}

private class BackupMethodResult(
    private val callback: (BackupMethodReply) -> Unit,
) : MethodChannel.Result {
    override fun success(result: Any?) = callback(BackupMethodReply.Success(result))

    override fun error(
        errorCode: String,
        errorMessage: String?,
        errorDetails: Any?,
    ) {
        callback(
            BackupMethodReply.Error(
                FlutterError(errorCode, errorMessage, errorDetails),
            ),
        )
    }

    override fun notImplemented() {
        callback(
            BackupMethodReply.Error(
                FlutterError("not_implemented", "备份方法未实现", null),
            ),
        )
    }
}
