package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class LanBackupWorkerOffsetTest {
    @Test
    fun hostOffsetIsAuthoritativeForInitialUploadOffset() {
        assertEquals(0L, resolveInitialUploadOffset(0L, 100L))
        assertEquals(37L, resolveInitialUploadOffset(37L, 100L))
    }

    @Test
    fun hostOffsetIsClampedToFileRange() {
        assertEquals(0L, resolveInitialUploadOffset(-1L, 100L))
        assertEquals(100L, resolveInitialUploadOffset(500L, 100L))
        assertEquals(0L, resolveInitialUploadOffset(0L, 0L))
    }

    @Test
    fun hostChunkSizeCannotCreateUnboundedWorkerBuffer() {
        assertEquals(256 * 1024, boundedUploadChunkSize(1))
        assertEquals(4 * 1024 * 1024, boundedUploadChunkSize(4 * 1024 * 1024))
        assertEquals(8 * 1024 * 1024, boundedUploadChunkSize(Int.MAX_VALUE))
    }
}
