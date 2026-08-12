package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BackLensCatalogTest {
    @Test
    fun `三镜头按焦距升序排序并选主摄换算倍数`() {
        val lenses = BackLensCatalog.build(
            listOf(
                "wide" to 5.4f,
                "ultra" to 2.2f,
                "tele" to 6.8f,
            ),
        )
        assertEquals(listOf("ultra", "wide", "tele"), lenses.map { it.cameraId })
        assertEquals(0.4, lenses[0].zoomRatio, 0.001)
        assertEquals(1.0, lenses[1].zoomRatio, 0.001)
        assertEquals(1.3, lenses[2].zoomRatio, 0.001)
        assertEquals("wide", lenses.single { it.isMain }.cameraId)
    }

    @Test
    fun `单镜头作为主摄返回1x`() {
        val lenses = BackLensCatalog.build(listOf("only" to 5.4f))
        assertEquals(1, lenses.size)
        assertEquals("only", lenses.single().cameraId)
        assertEquals(1.0, lenses.single().zoomRatio, 0.001)
        assertTrue(lenses.single().isMain)
    }

    @Test
    fun `焦距相差不超过百分之五视为同一镜头去重`() {
        val lenses = BackLensCatalog.build(
            listOf(
                "wide" to 5.3f,
                "duplicate" to 5.5f,
                "ultra" to 2.2f,
            ),
        )
        assertEquals(listOf("ultra", "wide"), lenses.map { it.cameraId })
    }

    @Test
    fun `焦距未知时返回空列表`() {
        assertTrue(
            BackLensCatalog.build(
                listOf("a" to 0f, "b" to -1f),
            ).isEmpty(),
        )
        assertTrue(BackLensCatalog.build(emptyList()).isEmpty())
    }

    @Test
    fun `主摄选取焦距最接近4_5毫米的镜头`() {
        val lenses = BackLensCatalog.build(
            listOf(
                "ultra" to 3.5f,
                "tele" to 8f,
                "long" to 6.5f,
            ),
        )
        assertEquals("ultra", lenses.single { it.isMain }.cameraId)
    }
}
