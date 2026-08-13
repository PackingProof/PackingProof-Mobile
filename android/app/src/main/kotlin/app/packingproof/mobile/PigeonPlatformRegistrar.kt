package app.packingproof.mobile

import app.packingproof.mobile.generated.ExportRequest
import app.packingproof.mobile.generated.FlutterError
import app.packingproof.mobile.generated.MediaProcessingHostApi
import app.packingproof.mobile.generated.OrderInfoDto
import app.packingproof.mobile.generated.OrderReceiverEventApi
import app.packingproof.mobile.generated.OrderReceiverHostApi
import app.packingproof.mobile.generated.OrderReceiverStatusDto
import app.packingproof.mobile.generated.ThumbnailRequest
import app.packingproof.mobile.generated.WatermarkRequest
import io.flutter.plugin.common.BinaryMessenger

internal fun registerPigeonPlatformApis(
    messenger: BinaryMessenger,
    thumbnailPlugin: RecordingThumbnailPlugin,
    orderInfoReceiverPlugin: OrderInfoReceiverPlugin,
) {
    MediaProcessingHostApi.setUp(
        messenger,
        PigeonMediaProcessingHostApi(thumbnailPlugin),
    )
    val orderReceiverEventApi = OrderReceiverEventApi(messenger)
    OrderReceiverHostApi.setUp(
        messenger,
        PigeonOrderReceiverHostApi(orderInfoReceiverPlugin, orderReceiverEventApi),
    )
    orderInfoReceiverPlugin.addOrderInfoListener { items ->
        orderReceiverEventApi.orderInfoReceived(items.map { it.toOrderInfoDto() }) { }
    }
}

private class PigeonMediaProcessingHostApi(
    private val thumbnailPlugin: RecordingThumbnailPlugin,
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

    override fun applyWatermark(request: WatermarkRequest): String =
        throw FlutterError("not_implemented", "水印平台适配器尚未接入", null)

    override fun exportRange(request: ExportRequest): String =
        throw FlutterError("not_implemented", "导出平台适配器尚未接入", null)

    override fun exportProgress(): Long =
        throw FlutterError("not_implemented", "导出平台适配器尚未接入", null)
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
