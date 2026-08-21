package app.packingproof.mobile

import android.hardware.camera2.CameraCharacteristics
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraDiagnosticsSnapshotMapperTest {
    @Test
    fun `快照保持设备进程与摄像头 wire map`() {
        val snapshot = CameraDiagnosticsSnapshotMapper.snapshot(
            nowElapsedMs = 10_000L,
            camera = diagnosticsInput(),
            device = CameraDeviceDiagnostics("maker", "model", 35, "15"),
            process = CameraProcessDiagnostics(10L, 20L, 30L, 4, 5),
        )

        assertEquals(
            mapOf("manufacturer" to "maker", "model" to "model", "sdkInt" to 35, "release" to "15"),
            snapshot["device"],
        )
        assertEquals(
            mapOf(
                "javaHeapUsedBytes" to 10L,
                "javaHeapMaxBytes" to 20L,
                "nativeHeapAllocatedBytes" to 30L,
                "threadCount" to 4,
                "openFdCount" to 5,
            ),
            snapshot["process"],
        )

        @Suppress("UNCHECKED_CAST")
        val camera = snapshot.getValue("camera") as Map<String, Any?>
        assertEquals("camera-1", camera["cameraId"])
        assertEquals(1920, camera["videoWidth"])
        assertEquals(540, camera["analysisHeight"])
        assertEquals(1_000L, camera["lastAnalysisCompletedAgeMs"])
        assertEquals(-1L, camera["previewFrameAgeMs"])
        assertEquals(2_000L, camera["lastCaptureCompletedAgeMs"])
        assertEquals("preview=true encoder=false analysis=true", camera["sessionSurfaces"])
        assertEquals(listOf(mapOf("phase" to "idle")), camera["probeResults"])
        assertEquals(100L, camera["storageAvailableBytes"])
        assertEquals(2L, camera["muxWriteStallCount"])
        assertEquals(2, camera["stallRecoveryStage"])
        assertEquals(listOf("depth_output"), camera["capabilities"])
        assertTrue(camera["probeInProgress"] as Boolean)
        assertFalse(camera["probeCached"] as Boolean)
    }

    @Test
    fun `初始化与能力探针映射保持协议字段`() {
        assertEquals(
            mapOf(
                "cameraId" to "camera-1",
                "videoSize" to "1920x1080",
                "analysisSize" to "960x540",
                "codec" to "hevc",
                "spec" to "hd1080p30",
                "probeSchemaVersion" to 2,
                "cameraPipelineVersion" to 3,
            ),
            CameraDiagnosticsSnapshotMapper.capabilityProbeIdentity(
                CameraProbeIdentityDiagnostics(
                    "camera-1",
                    StreamSize(1920, 1080),
                    StreamSize(960, 540),
                    "hevc",
                    "hd1080p30",
                    2,
                    3,
                ),
            ),
        )

        val initialization = CameraDiagnosticsSnapshotMapper.initialization(
            CameraInitializationDiagnostics(
                7L,
                StreamSize(1920, 1080),
                90,
                null,
                0.7,
                frontFacing = true,
                canSwitchCamera = true,
                fps = 30,
                recordingSpec = "hd1080p30",
                videoMime = "video/hevc",
                codecFallbackReason = null,
                flashAvailable = false,
            ),
        )
        assertEquals(7L, initialization["textureId"])
        assertEquals("front", initialization["lensDirection"])
        assertEquals(0.7, initialization["zoomRatio"])
        assertNull(initialization["cameraId"])
        assertFalse(initialization["flashAvailable"] as Boolean)
    }

    @Test
    fun `阶段镜头与能力名称映射稳定`() {
        assertEquals(
            mapOf(
                "phase" to "record",
                "candidate" to "3_1920x1080_960x540",
                "outcome" to "success",
                "detail" to null,
                "previewFrames" to 3,
                "analysisFrames" to 2,
                "encoderBuffers" to 1,
                "durationMs" to 400,
            ),
            CameraDiagnosticsSnapshotMapper.probePhaseResult(
                "record",
                "3_1920x1080_960x540",
                "success",
                null,
                3,
                2,
                1,
                400,
            ),
        )
        assertEquals(
            mapOf(
                "cameraId" to "wide",
                "focalLength" to 4.5f,
                "zoomRatio" to 1.0,
                "isMain" to true,
            ),
            CameraDiagnosticsSnapshotMapper.backLens(BackLensInfo("wide", 4.5f, 1.0, true)),
        )
        assertEquals(
            "depth_output",
            CameraDiagnosticsSnapshotMapper.capabilityName(
                CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT,
            ),
        )
        assertEquals("capability_999", CameraDiagnosticsSnapshotMapper.capabilityName(999))
    }

    private fun diagnosticsInput(): CameraDiagnosticsInput = CameraDiagnosticsInput(
        identity = CameraIdentityDiagnostics(
            initialized = true,
            cameraId = "camera-1",
            zoomRatio = 1.0,
            cameraIdList = listOf("camera-1"),
            zoomRatioRange = listOf(1f, 4f),
            frontFacing = false,
            sensorOrientation = 90,
        ),
        stream = CameraStreamDiagnostics(
            videoSize = StreamSize(1920, 1080),
            analysisSize = StreamSize(960, 540),
            videoMime = "video/hevc",
            fps = 30,
            recordingSpec = "hd1080p30",
            recordAudio = true,
        ),
        activity = CameraActivityDiagnostics(
            previewActive = true,
            workScanEnabled = true,
            pairingScanEnabled = false,
            recordingRequested = true,
            recordingActive = false,
            torchEnabled = false,
            canSwitchCamera = true,
        ),
        analysis = CameraAnalysisDiagnostics(1L, 2L, 3L, 4L, 9_000L, "failure"),
        switchAndFrames = CameraSwitchAndFrameDiagnostics(2, 50L, true, 6L, 0L, 8_000L),
        resources = CameraResourceDiagnostics(100L, 200L, 8L, 2L),
        recovery = CameraRecoveryDiagnostics(
            null,
            "record",
            false,
            2,
            "configured",
            2,
            null,
            null,
            null,
            null,
            null,
        ),
        capability = CameraCapabilityDiagnostics(
            mode = "full",
            preferEncoderAnalysisRecording = false,
            sessionHasPreview = true,
            sessionHasEncoder = false,
            sessionHasAnalysis = true,
            probeResults = listOf(mapOf("phase" to "idle")),
            probeInProgress = true,
            probeCached = false,
            hardwareLevel = 1,
            capabilities = listOf("depth_output"),
            yuvSizes = listOf("960x540"),
            videoSizes = listOf("1920x1080"),
            previewSizes = listOf("1920x1080"),
            physicalCameraIds = listOf("camera-1"),
            backLenses = listOf(mapOf("cameraId" to "camera-1")),
            fpsRanges = listOf("15-30"),
        ),
    )
}
