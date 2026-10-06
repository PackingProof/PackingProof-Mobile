package app.packingproof.mobile

import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class Yuv420Nv21CropTest {
    @Test
    fun `中心裁剪按 NV21 打包并保持 VU 顺序`() {
        val width = 8
        val height = 8
        val y = ByteArray(width * height) { it.toByte() }
        val u = ByteArray(width * height / 4) { (100 + it).toByte() }
        val v = ByteArray(width * height / 4) { (50 + it).toByte() }

        val cropped = cropYuv420CenterToNv21(
            y = YuvPlane(ByteBuffer.wrap(y), width, 1),
            u = YuvPlane(ByteBuffer.wrap(u), width / 2, 1),
            v = YuvPlane(ByteBuffer.wrap(v), width / 2, 1),
            width = width,
            height = height,
            scale = 0.5,
        )

        assertEquals(4, cropped!!.width)
        assertEquals(4, cropped.height)
        assertEquals(24, cropped.bytes.size)
        assertArrayEquals(
            byteArrayOf(
                y[2 * width + 2], y[2 * width + 3], y[2 * width + 4], y[2 * width + 5],
                y[3 * width + 2], y[3 * width + 3], y[3 * width + 4], y[3 * width + 5],
                y[4 * width + 2], y[4 * width + 3], y[4 * width + 4], y[4 * width + 5],
                y[5 * width + 2], y[5 * width + 3], y[5 * width + 4], y[5 * width + 5],
            ),
            cropped.bytes.copyOfRange(0, 16),
        )
        assertEquals(v[1 * (width / 2) + 1], cropped.bytes[16])
        assertEquals(u[1 * (width / 2) + 1], cropped.bytes[17])
    }

    @Test
    fun `行跨度与像素步长不同的平面也能读取`() {
        val width = 8
        val height = 8
        val yRowStride = width + 4
        val y = ByteArray(yRowStride * height) { (it % 97).toByte() }
        val uRowStride = width + 2
        val vRowStride = width + 2
        val u = ByteArray(uRowStride * height / 2) { (10 + it).toByte() }
        val v = ByteArray(vRowStride * height / 2) { (200 + it).toByte() }

        val cropped = cropYuv420CenterToNv21(
            y = YuvPlane(ByteBuffer.wrap(y), yRowStride, 1),
            u = YuvPlane(ByteBuffer.wrap(u), uRowStride, 2),
            v = YuvPlane(ByteBuffer.wrap(v), vRowStride, 2),
            width = width,
            height = height,
            scale = 1.0,
        )

        assertEquals(8, cropped!!.width)
        assertEquals(v[0], cropped.bytes[64])
        assertEquals(u[0], cropped.bytes[65])
    }

    @Test
    fun `非法比例或过小画面返回空`() {
        val plane = YuvPlane(ByteBuffer.wrap(ByteArray(16)), 4, 1)
        assertNull(cropYuv420CenterToNv21(plane, plane, plane, 4, 4, 0.0))
        assertNull(cropYuv420CenterToNv21(plane, plane, plane, 4, 4, 1.5))
        assertNull(cropYuv420CenterToNv21(plane, plane, plane, 2, 2, 1.0))
    }
}
