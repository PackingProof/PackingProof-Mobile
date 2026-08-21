package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraCapabilityProbeRunnerTest {
    @Test
    fun `configured phases preserve the five-step contract`() {
        val executed = mutableListOf<Pair<String, ProbePhaseKind>>()
        val runner = runner { label, kind, _, onDone ->
            executed += label to kind
            onDone(phase(label, CameraProbeOutcome.CONFIGURED.wire))
        }

        val result = run(runner, "encoder_analysis")

        assertEquals(
            CameraProbePlanPolicy.capabilitySpecs("encoder_analysis"),
            executed,
        )
        assertEquals("ok", result.status)
        assertEquals(null, result.reason)
        assertEquals(5, result.phases.size)
    }

    @Test
    fun `capability failure stops remaining phases but keeps an ok envelope`() {
        var calls = 0
        val runner = runner { label, _, _, onDone ->
            calls++
            onDone(phase(label, CameraProbeOutcome.UNSUPPORTED_COMBINATION.wire))
        }

        val result = run(runner, "full")

        assertEquals(1, calls)
        assertEquals("ok", result.status)
        assertEquals(null, result.reason)
        assertEquals(
            CameraProbeOutcome.UNSUPPORTED_COMBINATION.wire,
            result.phases.single()["outcome"],
        )
    }

    @Test
    fun `infrastructure failure preserves outcome and detail in the envelope`() {
        val runner = runner { label, _, _, onDone ->
            onDone(
                phase(
                    label,
                    CameraProbeOutcome.CAMERA_ERROR.wire,
                    "camera_error_3",
                ),
            )
        }

        val result = run(runner, "alternating")

        assertEquals("error", result.status)
        assertEquals("camera_error:camera_error_3", result.reason)
        assertEquals(1, result.phases.size)
    }

    @Test
    fun `cancel and exhausted budget finish before starting a phase`() {
        var calls = 0
        val runner = runner { _, _, _, _ -> calls++ }
        var cancelledResult: CameraCapabilityProbeResult? = null
        runner.run(
            sequence = "full",
            deadline = 10_000,
            isCancelled = { true },
            onDone = { cancelledResult = it },
        )
        assertEquals("error", cancelledResult?.status)
        assertEquals("cancelled", cancelledResult?.reason)
        assertEquals(0, calls)

        var budgetResult: CameraCapabilityProbeResult? = null
        runner.run(
            sequence = "full",
            deadline = 4_499,
            isCancelled = { false },
            onDone = { budgetResult = it },
        )
        assertEquals("budget_exceeded", budgetResult?.status)
        assertEquals("检测时间预算不足", budgetResult?.reason)
        assertEquals(0, calls)
    }

    private fun runner(
        execute: (
            String,
            ProbePhaseKind,
            Long,
            (Map<String, Any?>) -> Unit,
        ) -> Unit,
    ): CameraCapabilityProbeRunner = CameraCapabilityProbeRunner(
        phaseExecutor = CameraCapabilityProbePhaseExecutor(execute),
        uptimeMillis = { 0L },
    )

    private fun run(
        runner: CameraCapabilityProbeRunner,
        sequence: String,
    ): CameraCapabilityProbeResult {
        var result: CameraCapabilityProbeResult? = null
        runner.run(
            sequence = sequence,
            deadline = 30_000,
            isCancelled = { false },
            onDone = { result = it },
        )
        return checkNotNull(result)
    }

    private fun phase(
        label: String,
        outcome: String,
        detail: String? = null,
    ): Map<String, Any?> = CameraDiagnosticsSnapshotMapper.probePhaseResult(
        label,
        "candidate",
        outcome,
        detail,
        1,
        1,
        1,
        1,
    )
}
