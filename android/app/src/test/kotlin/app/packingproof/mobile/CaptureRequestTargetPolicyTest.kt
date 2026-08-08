package app.packingproof.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureRequestTargetPolicyTest {
    private val policy = CaptureRequestTargetPolicy()

    @Test
    fun `analysis target stays active in every state`() {
        assertTrue(policy.targets(recordingRequested = false, recordingActive = false).includeAnalysis)
        assertTrue(policy.targets(recordingRequested = true, recordingActive = false).includeAnalysis)
        assertTrue(policy.targets(recordingRequested = false, recordingActive = true).includeAnalysis)
        assertTrue(policy.targets(recordingRequested = true, recordingActive = true).includeAnalysis)
    }

    @Test
    fun `encoder target joins only when recording is requested or active`() {
        assertFalse(policy.targets(recordingRequested = false, recordingActive = false).includeEncoder)
        assertTrue(policy.targets(recordingRequested = true, recordingActive = false).includeEncoder)
        assertTrue(policy.targets(recordingRequested = false, recordingActive = true).includeEncoder)
        assertTrue(policy.targets(recordingRequested = true, recordingActive = true).includeEncoder)
    }
}
