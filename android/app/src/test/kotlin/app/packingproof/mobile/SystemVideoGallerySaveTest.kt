package app.packingproof.mobile

import android.provider.MediaStore
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [29])
class SystemVideoGallerySaveTest {
    @Test
    fun finalizedVideoIsVisibleAndComplete() {
        val context = RuntimeEnvironment.getApplication()
        val source = File(context.cacheDir, "gallery-save-test.mp4").apply {
            writeBytes(ByteArray(4096) { (it % 251).toByte() })
        }
        val resolver = context.contentResolver

        val uri = saveVideoToGalleryOnQPlus(resolver, source)
        val row = resolver.query(
            uri,
            arrayOf(
                MediaStore.Video.Media.IS_PENDING,
                MediaStore.Video.Media.SIZE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null
            cursor.getInt(
                cursor.getColumnIndexOrThrow(
                    MediaStore.Video.Media.IS_PENDING,
                ),
            ) to
                cursor.getLong(
                    cursor.getColumnIndexOrThrow(
                        MediaStore.Video.Media.SIZE,
                    ),
                )
        }
        assertNotNull(row)

        assertEquals(0, row!!.first)
        assertEquals(source.length(), row.second)
        val stored = resolver.openInputStream(uri)
        assertNotNull(stored)
        assertArrayEquals(source.readBytes(), stored!!.use { it.readBytes() })

        assertEquals(1, resolver.delete(uri, null, null))
        source.delete()
    }

    @Test
    fun fileNameAlwaysKeepsVideoExtension() {
        assertEquals("PackingProof.mp4", galleryDisplayName("  "))
        assertEquals("recording.mp4", galleryDisplayName("recording"))
        assertEquals("recording.mp4", galleryDisplayName("recording.mp4"))
    }
}
