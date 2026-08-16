package app.packingproof.mobile

import app.packingproof.mobile.generated.ExportRequest
import app.packingproof.mobile.generated.BarcodeCandidateDto
import app.packingproof.mobile.generated.CameraEventApi
import app.packingproof.mobile.generated.CameraHostApi
import app.packingproof.mobile.generated.BackupNativeEventApi
import app.packingproof.mobile.generated.BackupNativeHostApi
import app.packingproof.mobile.generated.FlutterError
import app.packingproof.mobile.generated.AlertAudioSessionHostApi
import app.packingproof.mobile.generated.MediaProcessingHostApi
import app.packingproof.mobile.generated.OrderInfoDto
import app.packingproof.mobile.generated.OrderReceiverEventApi
import app.packingproof.mobile.generated.OrderReceiverHostApi
import app.packingproof.mobile.generated.OrderReceiverStatusDto
import app.packingproof.mobile.generated.SystemMediaPresenterHostApi
import app.packingproof.mobile.generated.ThumbnailRequest
import app.packingproof.mobile.generated.VideoDecodeSupportDto
import app.packingproof.mobile.generated.WatermarkRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal fun registerPigeonPlatformApis(
    messenger: BinaryMessenger,
    thumbnailPlugin: RecordingThumbnailPlugin,
    orderInfoReceiverPlugin: OrderInfoReceiverPlugin,
    continuousCameraPlugin: ContinuousCameraPlugin,
    lanBackupPlugin: LanBackupPlugin,
    videoWatermarkPlugin: VideoWatermarkPlugin,
    videoExportPlugin: VideoExportPlugin,
    systemVideoPlayerPlugin: SystemVideoPlayerPlugin,
    maxVolumeController: MaxVolumeController,
) {
    MediaProcessingHostApi.setUp(
        messenger,
        PigeonMediaProcessingHostApi(
            thumbnailPlugin,
            videoWatermarkPlugin,
            videoExportPlugin,
        ),
    )
    SystemMediaPresenterHostApi.setUp(
        messenger,
        PigeonSystemMediaPresenterHostApi(systemVideoPlayerPlugin),
    )
    AlertAudioSessionHostApi.setUp(
        messenger,
        PigeonAlertAudioSessionHostApi(maxVolumeController),
    )
    val orderReceiverEventApi = OrderReceiverEventApi(messenger)
    OrderReceiverHostApi.setUp(
        messenger,
        PigeonOrderReceiverHostApi(orderInfoReceiverPlugin, orderReceiverEventApi),
    )
    orderInfoReceiverPlugin.addOrderInfoListener { items ->
        orderReceiverEventApi.orderInfoReceived(items.map { it.toOrderInfoDto() }) { }
    }
    val cameraEventApi = CameraEventApi(messenger)
    CameraHostApi.setUp(
        messenger,
        PigeonCameraHostApi(continuousCameraPlugin),
    )
    continuousCameraPlugin.addCameraEventListener { method, arguments ->
        when (method) {
            "barcodeFrame" -> {
                val candidates = (arguments as? List<*>).orEmpty().map {
                    (it as Map<*, *>).toBarcodeCandidateDto()
                }
                cameraEventApi.barcodeBatch(candidates) { }
            }
            "nativeError" ->
                cameraEventApi.nativeError(arguments?.toString().orEmpty()) { }
            "storageCritical" -> cameraEventApi.storageCritical { }
            "probeFinished" ->
                cameraEventApi.probeFinished(arguments as Map<String?, Any?>) { }
            "recordingFallback" ->
                cameraEventApi.recordingFallback(arguments as Map<String?, Any?>) { }
        }
    }
    val backupEventApi = BackupNativeEventApi(messenger)
    BackupNativeHostApi.setUp(
        messenger,
        PigeonBackupHostApi(lanBackupPlugin),
    )
    lanBackupPlugin.addSnapshotListener { snapshot ->
        backupEventApi.snapshotChanged(
            snapshot.entries.associate { (it.key as String?) to it.value },
        ) { }
    }
}

private class PigeonMediaProcessingHostApi(
    private val thumbnailPlugin: RecordingThumbnailPlugin,
    private val watermarkPlugin: VideoWatermarkPlugin,
    private val exportPlugin: VideoExportPlugin,
) : MediaProcessingHostApi {
    override fun generateThumbnail(
        request: ThumbnailRequest,
        callback: (Result<String?>) -> Unit,
    ) {
        thumbnailPlugin.generateThumbnail(request.path) { generated ->
            if (generated == null) {
                callback(
                    Result.failure(
                        FlutterError(
                            "thumbnail_failed",
                            "无法生成录像预览图",
                            null,
                        ),
                    ),
                )
            } else {
                callback(Result.success(generated))
            }
        }
    }

    override fun applyWatermark(
        request: WatermarkRequest,
        callback: (Result<String>) -> Unit,
    ) {
        invokePlugin(
            watermarkPlugin::invoke,
            "apply",
            mapOf(
                "inputPath" to request.inputPath,
                "outputPath" to request.outputPath,
                "startedAtMs" to request.startedAtMs,
                "trackingNumber" to request.trackingNumber,
                "videoCodec" to request.videoCodec,
            ),
            callback,
        ) { it as String }
    }

    override fun exportRange(
        request: ExportRequest,
        callback: (Result<String>) -> Unit,
    ) {
        invokePlugin(
            exportPlugin::invoke,
            "export",
            mapOf(
                "inputPath" to request.inputPath,
                "outputPath" to request.outputPath,
                "startMs" to request.startMs,
                "endMs" to request.endMs,
            ),
            callback,
        ) { it as String }
    }

    override fun exportProgress(callback: (Result<Long>) -> Unit) {
        invokePlugin(exportPlugin::invoke, "progress", null, callback) {
            (it as Number).toLong()
        }
    }
}

private class PigeonSystemMediaPresenterHostApi(
    private val plugin: SystemVideoPlayerPlugin,
) : SystemMediaPresenterHostApi {
    override fun getVideoTrackMime(
        path: String,
        callback: (Result<String?>) -> Unit,
    ) {
        invokePlugin(
            { method, arguments, result ->
                plugin.onMethodCall(MethodCall(method, arguments), result)
            },
            "getVideoTrackMime",
            mapOf("path" to path),
            callback,
        ) { it as? String }
    }

    override fun getVideoDecodeSupport(
        callback: (Result<VideoDecodeSupportDto?>) -> Unit,
    ) {
        invokePlugin(
            { method, arguments, result ->
                plugin.onMethodCall(MethodCall(method, arguments), result)
            },
            "getVideoDecodeSupport",
            null,
            callback,
        ) { value ->
            (value as? Map<*, *>)?.let(::videoDecodeSupportDto)
        }
    }

    override fun openWithSystemPlayer(
        path: String,
        callback: (Result<Unit>) -> Unit,
    ) {
        invokePlugin(
            { method, arguments, result ->
                plugin.onMethodCall(MethodCall(method, arguments), result)
            },
            "openWithSystemPlayer",
            mapOf("path" to path),
            callback,
        ) { }
    }
}

private class PigeonAlertAudioSessionHostApi(
    private val controller: MaxVolumeController,
) : AlertAudioSessionHostApi {
    override fun beginSession(callback: (Result<Unit>) -> Unit) {
        controller.enable()
        callback(Result.success(Unit))
    }

    override fun endSession(callback: (Result<Unit>) -> Unit) {
        controller.pauseSession()
        callback(Result.success(Unit))
    }

    override fun disable(callback: (Result<Unit>) -> Unit) {
        controller.disable()
        callback(Result.success(Unit))
    }

    override fun boost(callback: (Result<Unit>) -> Unit) {
        controller.boost()
        callback(Result.success(Unit))
    }
}

private fun videoDecodeSupportDto(value: Map<*, *>): VideoDecodeSupportDto =
    VideoDecodeSupportDto(
        manufacturer = value["manufacturer"] as? String ?: "",
        brand = value["brand"] as? String ?: "",
        model = value["model"] as? String ?: "",
        sdkInt = (value["sdkInt"] as? Number)?.toLong() ?: 0L,
        release = value["release"] as? String ?: "",
        hasHevcDecoder = value["hasHevcDecoder"] as? Boolean ?: false,
        hasAvcDecoder = value["hasAvcDecoder"] as? Boolean ?: false,
        forceSoftwareDecode = value["forceSoftwareDecode"] as? Boolean ?: false,
    )

private fun <T> invokePlugin(
    plugin: (
        String,
        Map<String, Any?>?,
        MethodChannel.Result,
    ) -> Unit,
    method: String,
    arguments: Map<String, Any?>?,
    callback: (Result<T>) -> Unit,
    transform: (Any?) -> T,
) {
    plugin(
        method,
        arguments,
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

private class PigeonOrderReceiverHostApi(
    private val plugin: OrderInfoReceiverPlugin,
    private val eventApi: OrderReceiverEventApi,
) : OrderReceiverHostApi {
    override fun startReceiver(backgroundDelivery: Boolean): OrderReceiverStatusDto =
        plugin.startReceiver(backgroundDelivery).toStatusDto()

    override fun getReceiverStatus(): OrderReceiverStatusDto =
        plugin.receiverStatus().toStatusDto()

    override fun lookup(trackingNumber: String): OrderInfoDto? =
        plugin.lookupOrder(trackingNumber)?.let(::orderInfoDtoFromMap)

    override fun updateBackgroundDelivery(enabled: Boolean) {
        plugin.updateBackgroundDelivery(enabled)
    }

    override fun stopReceiver() {
        plugin.stopReceiver()
    }
}

private fun Map<String, Any?>.toStatusDto(): OrderReceiverStatusDto =
    OrderReceiverStatusDto(
        running = this["running"] as? Boolean ?: false,
        ipAddress = this["ipAddress"] as? String ?: "",
        url = this["url"] as? String ?: "",
        port = ((this["port"] as? Number)?.toLong() ?: 5280L),
        errorMessage = this["errorMessage"] as? String ?: "",
    )

private fun OrderInfoRecord.toOrderInfoDto(): OrderInfoDto =
    OrderInfoDto(
        trackingNumber = trackingNumber,
        orderId = orderId,
        buyerMessage = buyerMessage,
        sellerMemo = sellerMemo,
        productInfo = productInfo,
        hasRefund = hasRefund,
        isPrintedRefund = isPrintedRefund,
        refundStatus = refundStatus,
        refundProductInfo = refundProductInfo,
        pushTimeMs = pushTimeMillis.takeIf { it > 0 },
        isTest = isTest,
    )

private fun orderInfoDtoFromMap(value: Map<String, Any?>): OrderInfoDto =
    OrderInfoDto(
        trackingNumber = value["trackingNumber"] as? String ?: "",
        orderId = value["orderId"] as? String ?: "",
        buyerMessage = value["buyerMessage"] as? String ?: "",
        sellerMemo = value["sellerMemo"] as? String ?: "",
        productInfo = value["productInfo"] as? String ?: "",
        hasRefund = value["hasRefund"] as? Boolean ?: false,
        isPrintedRefund = value["isPrintedRefund"] as? Boolean ?: false,
        refundStatus = value["refundStatus"] as? String ?: "",
        refundProductInfo = value["refundProductInfo"] as? String ?: "",
        pushTimeMs = (value["pushTimeMilliseconds"] as? Number)?.toLong(),
        isTest = value["isTest"] as? Boolean ?: false,
    )

private fun Map<*, *>.toBarcodeCandidateDto(): BarcodeCandidateDto =
    BarcodeCandidateDto(
        value = this["value"] as String,
        area = (this["area"] as Number).toLong(),
        format = this["format"] as? String,
        detectedAtMs = (this["detectedAtMs"] as? Number)?.toLong() ?: 0L,
    )
