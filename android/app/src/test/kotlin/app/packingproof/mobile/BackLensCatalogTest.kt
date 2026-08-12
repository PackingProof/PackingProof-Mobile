package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BackLensCatalogTest {
    @Test
    fun `三镜头按焦距升序排序并选主摄换算等效倍数`() {
        val lenses = BackLensCatalog.build(
            listOf(
                BackLensEntry("wide", 5.4f, 9.8f),
                BackLensEntry("ultra", 2.2f, 5.0f),
                BackLensEntry("tele", 6.8f, 5.24f),
            ),
        )
        assertEquals(listOf("ultra", "wide", "tele"), lenses.map { it.cameraId })
        assertEquals(0.8, lenses[0].zoomRatio, 0.001)
        assertEquals(1.0, lenses[1].zoomRatio, 0.001)
        assertEquals(2.5, lenses[2].zoomRatio, 0.001)
        assertEquals("wide", lenses.single { it.isMain }.cameraId)
    }

    @Test
    fun `单镜头作为主摄返回1x`() {
        val lenses = BackLensCatalog.build(
            listOf(BackLensEntry("only", 5.4f, 9.8f)),
        )
        assertEquals(1, lenses.size)
        assertEquals("only", lenses.single().cameraId)
        assertEquals(1.0, lenses.single().zoomRatio, 0.001)
        assertTrue(lenses.single().isMain)
    }

    @Test
    fun `焦距相差不超过百分之五视为同一镜头去重`() {
        val lenses = BackLensCatalog.build(
            listOf(
                BackLensEntry("wide", 5.3f, 9.8f),
                BackLensEntry("duplicate", 5.5f, 9.8f),
                BackLensEntry("ultra", 2.2f, 5.0f),
            ),
        )
        assertEquals(listOf("ultra", "wide"), lenses.map { it.cameraId })
    }

    @Test
    fun `焦距或传感器未知时返回空列表`() {
        assertTrue(
            BackLensCatalog.build(
                listOf(
                    BackLensEntry("a", 0f, 9.8f),
                    BackLensEntry("b", -1f, 9.8f),
                    BackLensEntry("c", 5.4f, 0f),
                ),
            ).isEmpty(),
        )
        assertTrue(BackLensCatalog.build(emptyList()).isEmpty())
    }

    @Test
    fun `主摄选取焦距最接近4_5毫米的镜头`() {
        val lenses = BackLensCatalog.build(
            listOf(
                BackLensEntry("ultra", 3.5f, 9.8f),
                BackLensEntry("tele", 8f, 5.24f),
                BackLensEntry("long", 6.5f, 9.8f),
            ),
        )
        assertEquals("ultra", lenses.single { it.isMain }.cameraId)
    }

    @Test
    fun `指定主摄并使用系统广角档位得到0_7_1_5档`() {
        val lenses = BackLensCatalog.build(
            listOf(
                BackLensEntry("ultra", 2.61f, 5.0135f),
                BackLensEntry("wide", 6.62f, 9.8058f),
                BackLensEntry("tele", 17.27f, 5.2429f),
            ),
            mainCameraId = "wide",
            wideZoomRatio = 0.7,
        )
        assertEquals(listOf("ultra", "wide", "tele"), lenses.map { it.cameraId })
        assertEquals(0.7, lenses[0].zoomRatio, 0.001)
        assertEquals(1.0, lenses[1].zoomRatio, 0.001)
        assertEquals(5.0, lenses[2].zoomRatio, 0.001)
        assertEquals("wide", lenses.single { it.isMain }.cameraId)
    }
}
