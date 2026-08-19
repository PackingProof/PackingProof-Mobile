package app.packingproof.mobile

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class LanBackupStateStoreCacheTest {
    @Test
    fun unchangedMetasReuseCachedJobsWithoutReading() {
        val root = Files.createTempDirectory("packing-proof-job-meta-").toFile()
        try {
            val file = root.resolve("a.json")
            file.writeText("""{"id":"a","lastModified":100}""", Charsets.UTF_8)
            val metas = jobMetasOf(listOf(file))
            var reads = 0
            val first = mergeJobCache(null, null, metas) {
                reads++
                JSONObject("""{"id":"a","lastModified":100}""")
            }
            assertEquals(1, reads)
            assertEquals("a", first.single().getString("id"))

            val again = mergeJobCache(first, metas, metas) {
                reads++
                null
            }
            assertEquals(1, reads)
            assertEquals("a", again.single().getString("id"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun onlyChangedFilesAreReread() {
        val root = Files.createTempDirectory("packing-proof-job-diff-").toFile()
        try {
            val fileA = root.resolve("a.json")
            fileA.writeText("""{"id":"a","lastModified":100}""", Charsets.UTF_8)
            val fileB = root.resolve("b.json")
            fileB.writeText("""{"id":"b","lastModified":200}""", Charsets.UTF_8)
            val initialMetas = jobMetasOf(listOf(fileA, fileB))
            val initial = mergeJobCache(null, null, initialMetas) { id ->
                JSONObject("""{"id":"$id","lastModified":${if (id == "a") 100 else 200}}""")
            }
            assertEquals(2, initial.size)

            fileB.writeText("""{"id":"b","lastModified":201}""", Charsets.UTF_8)
            val changedMetas = jobMetasOf(listOf(fileA, fileB))
            val reads = mutableListOf<String>()
            val merged = mergeJobCache(initial, initialMetas, changedMetas) { id ->
                reads += id
                JSONObject("""{"id":"$id","lastModified":201}""")
            }
            assertEquals(listOf("b"), reads)
            assertEquals(2, merged.size)
            assertEquals(100L, merged.first { it.getString("id") == "a" }.optLong("lastModified"))
            assertEquals(201L, merged.first { it.getString("id") == "b" }.optLong("lastModified"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun removedAndNewFilesReflectInCache() {
        val root = Files.createTempDirectory("packing-proof-job-removed-").toFile()
        try {
            val fileA = root.resolve("a.json")
            fileA.writeText("""{"id":"a","lastModified":100}""", Charsets.UTF_8)
            val fileB = root.resolve("b.json")
            fileB.writeText("""{"id":"b","lastModified":200}""", Charsets.UTF_8)
            val initialMetas = jobMetasOf(listOf(fileA, fileB))
            val initial = mergeJobCache(null, null, initialMetas) { id ->
                JSONObject("""{"id":"$id","lastModified":100}""")
            }
            assertTrue(initial.any { it.getString("id") == "b" })

            fileB.delete()
            val fileC = root.resolve("c.json")
            fileC.writeText("""{"id":"c","lastModified":300}""", Charsets.UTF_8)
            val changedMetas = jobMetasOf(listOf(fileA, fileC))
            val merged = mergeJobCache(initial, initialMetas, changedMetas) { id ->
                JSONObject("""{"id":"$id","lastModified":300}""")
            }
            val ids = merged.map { it.getString("id") }
            assertTrue(ids.contains("a"))
            assertTrue(ids.contains("c"))
            assertTrue(!ids.contains("b"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun bakFileMetaFallsBackWhenJsonMissing() {
        val root = Files.createTempDirectory("packing-proof-job-bak-").toFile()
        try {
            val file = root.resolve("a.json.bak")
            file.writeText("""{"id":"a","lastModified":100}""", Charsets.UTF_8)
            val metas = jobMetasOf(listOf(file))
            assertEquals("a", metas.single().id)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun emptyCacheFallbackReturnsEmptyList() {
        val root = Files.createTempDirectory("packing-proof-job-empty-").toFile()
        try {
            assertEquals(0, jobMetasOf(emptyList()).size)
            assertNull(mergeJobCache(null, null, emptyList()) { null }.firstOrNull())
        } finally {
            root.deleteRecursively()
        }
    }
}
