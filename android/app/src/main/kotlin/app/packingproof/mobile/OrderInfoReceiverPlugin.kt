package app.packingproof.mobile

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class OrderInfoReceiverPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val handler = Handler(Looper.getMainLooper())
    private var keepAliveInBackground = false
    private var hostForeground = true
    private val listeners = mutableListOf<(List<OrderInfoRecord>) -> Unit>()

    init {
        channel.setMethodCallHandler(this)
        addOrderInfoListener { items ->
            channel.invokeMethod("orderInfoReceived", items.map(OrderInfoRecord::toMap))
        }
        OrderInfoReceiverRuntime.start(activity.applicationContext)
    }

    internal fun addOrderInfoListener(listener: (List<OrderInfoRecord>) -> Unit) {
        listeners.add(listener)
        OrderInfoReceiverRuntime.addListener(listener)
    }

    internal fun removeOrderInfoListener(listener: (List<OrderInfoRecord>) -> Unit) {
        listeners.remove(listener)
        OrderInfoReceiverRuntime.removeListener(listener)
    }

    internal fun startReceiver(backgroundDelivery: Boolean): Map<String, Any?> {
        keepAliveInBackground = backgroundDelivery
        applyHostState()
        return OrderInfoReceiverRuntime.start(activity.applicationContext)
    }

    internal fun receiverStatus(): Map<String, Any?> = OrderInfoReceiverRuntime.status()

    internal fun lookupOrder(trackingNumber: String): Map<String, Any?>? =
        OrderInfoReceiverRuntime.lookup(trackingNumber)

    internal fun updateBackgroundDelivery(enabled: Boolean) {
        keepAliveInBackground = enabled
        applyHostState()
    }

    internal fun stopReceiver() {
        keepAliveInBackground = false
        stopForegroundService()
        OrderInfoReceiverRuntime.stop()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start", "retry" -> result.success(OrderInfoReceiverRuntime.start(activity.applicationContext))
            "status" -> result.success(OrderInfoReceiverRuntime.status())
            "lookup" -> {
                val trackingNumber = call.argument<String>("trackingNumber").orEmpty()
                result.success(OrderInfoReceiverRuntime.lookup(trackingNumber))
            }
            "setBackgroundKeepAlive" -> {
                keepAliveInBackground = call.argument<Boolean>("enabled") == true
                applyHostState()
                result.success(null)
            }
            "stop" -> {
                keepAliveInBackground = false
                stopForegroundService()
                OrderInfoReceiverRuntime.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun onHostForeground() {
        hostForeground = true
        stopForegroundService()
        OrderInfoReceiverRuntime.start(activity.applicationContext)
    }

    fun onHostBackground() {
        hostForeground = false
        applyHostState()
    }

    private fun applyHostState() {
        if (hostForeground) return
        if (keepAliveInBackground) {
            activity.startForegroundService(Intent(activity, OrderInfoReceiverForegroundService::class.java))
        } else {
            stopForegroundService()
            OrderInfoReceiverRuntime.stop()
        }
    }

    private fun stopForegroundService() {
        activity.stopService(Intent(activity, OrderInfoReceiverForegroundService::class.java))
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        listeners.forEach(OrderInfoReceiverRuntime::removeListener)
        listeners.clear()
        if (!keepAliveInBackground) OrderInfoReceiverRuntime.stop()
    }

    companion object {
        private const val CHANNEL_NAME = "app.packingproof.mobile/order_info_receiver"
    }
}
