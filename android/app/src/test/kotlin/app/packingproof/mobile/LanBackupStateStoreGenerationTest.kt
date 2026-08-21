package app.packingproof.mobile

import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class LanBackupStateStoreGenerationTest {
    private val context
        get() = RuntimeEnvironment.getApplication()
    private lateinit var source: File
    private lateinit var store: LanBackupStateStore

    @Before
    fun setUp() {
        context.deleteDatabase("lan_backup.db")
        source = File(context.cacheDir, "generation-test.mp4").apply {
            writeText("test-video", Charsets.UTF_8)
        }
        store = LanBackupStateStore(context)
    }

    @After
    fun tearDown() {
        source.delete()
        context.deleteDatabase("lan_backup.db")
    }

    @Test
    fun cancelAndRequeueRejectOldWorkerWritesAndDeletes() {
        val job = store.upsertJob(source.path, sessions()).job
        val id = job.getString("id")
        val initialGeneration = job.getString("generation")

        val cancelled = store.updateJob(id, initialGeneration) { current ->
            current.put("generation", "cancel-generation")
                .put("state", "paused")
            true
        }
        assertNotNull(cancelled)
        assertNull(store.updateJob(id, initialGeneration) { current ->
            current.put("state", "completed")
            true
        })
        assertFalse(store.deleteJob(id, initialGeneration))
        assertEquals("paused", store.readJob(id)?.getString("state"))

        val requeued = store.updateJob(id, "cancel-generation") { current ->
            current.put("generation", "requeue-generation")
                .put("state", "pending")
                .put("errorMessage", JSONObject.NULL)
            true
        }
        assertNotNull(requeued)
        assertNull(store.updateJob(id, "cancel-generation") { current ->
            current.put("state", "paused")
            true
        })
        assertFalse(store.deleteJob(id, "cancel-generation"))
        assertEquals("pending", store.readJob(id)?.getString("state"))
        assertEquals(
            "requeue-generation",
            store.readJob(id)?.getString("generation"),
        )
    }

    @Test
    fun completedJobCannotBeDeletedEvenByCurrentGeneration() {
        val job = store.upsertJob(source.path, sessions()).job
        val id = job.getString("id")
        val generation = job.getString("generation")
        assertNotNull(store.updateJob(id, generation) { current ->
            current.put("state", "completed")
            true
        })

        assertFalse(store.deleteJob(id, generation))
        assertEquals("completed", store.readJob(id)?.getString("state"))
    }

    private fun sessions(): JSONArray = JSONArray().put(
        JSONObject()
            .put("id", "generation-session")
            .put("startedAt", "2026-08-21T09:30:00Z")
            .put("endedAt", "2026-08-21T09:30:01Z"),
    )
}
