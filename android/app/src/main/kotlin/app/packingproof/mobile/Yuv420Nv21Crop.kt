package app.packingproof.mobile

import java.nio.ByteBuffer

/** 中心裁剪并按 NV21 打包后的识别帧。 */
internal data class CroppedNv21Frame(
    val bytes: ByteArray,
    val width: Int,
    val height: Int,
)

/** YUV_420_888 单个平面的读取参数。 */
internal data class YuvPlane(
    val buffer: ByteBuffer,
    val rowStride: Int,
    val pixelStride: Int,
)

/**
 * 从 YUV_420_888 帧中裁剪中心正方形并转换为 NV21。
 *
 * 仅用于超广角识别实验：裁剪是数字放大，不会增加条码码元的真实像素；
 * 它只用于验证 ML Kit 是否因整帧过大而做了内部降采样。
 */
internal fun cropYuv420CenterToNv21(
    y: YuvPlane,
    u: YuvPlane,
    v: YuvPlane,
    width: Int,
    height: Int,
    scale: Double,
): CroppedNv21Frame? {
    if (width < 4 || height < 4 || scale <= 0.0 || scale > 1.0) return null
    val shortSide = minOf(width, height)
    val cropSide = ((shortSide * scale).toInt() / 2) * 2
    if (cropSide < 2 || cropSide > shortSide) return null
    val left = (((width - cropSide) / 2) / 2) * 2
    val top = (((height - cropSide) / 2) / 2) * 2
    val bytes = ByteArray(cropSide * cropSide * 3 / 2)

    var lumaDestination = 0
    for (row in 0 until cropSide) {
        val rowStart = (top + row) * y.rowStride + left * y.pixelStride
        for (column in 0 until cropSide) {
            val index = rowStart + column * y.pixelStride
            if (index < 0 || index >= y.buffer.capacity()) return null
            bytes[lumaDestination + column] = y.buffer.get(index)
        }
        lumaDestination += cropSide
    }

    val chromaSize = cropSide / 2
    val chromaDestinationStart = cropSide * cropSide
    for (row in 0 until chromaSize) {
        val vRowStart = (top / 2 + row) * v.rowStride
        val uRowStart = (top / 2 + row) * u.rowStride
        for (column in 0 until chromaSize) {
            val vIndex = vRowStart + (left / 2 + column) * v.pixelStride
            val uIndex = uRowStart + (left / 2 + column) * u.pixelStride
            if (vIndex < 0 || vIndex >= v.buffer.capacity() ||
                uIndex < 0 || uIndex >= u.buffer.capacity()
            ) {
                return null
            }
            val destination = chromaDestinationStart + row * cropSide + column * 2
            // NV21 的色度平面顺序是 V 在前、U 在后。
            bytes[destination] = v.buffer.get(vIndex)
            bytes[destination + 1] = u.buffer.get(uIndex)
        }
    }
    return CroppedNv21Frame(bytes = bytes, width = cropSide, height = cropSide)
}
