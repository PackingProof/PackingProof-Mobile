import AVFoundation
import Flutter
import CryptoKit
import SQLite3
import UIKit
import XCTest
@testable import Runner
@testable import flutter_tts

private final class FakeIosAudioSession: IosAudioSessionProtocol {
  enum Failure: Error {
    case activation
    case deactivation
  }

  var categoryCalls: [(
    AVAudioSession.Category,
    AVAudioSession.Mode,
    AVAudioSession.CategoryOptions
  )] = []
  var activeCalls: [Bool] = []
  var isActive = false
  var failNextActivation = false
  var failNextDeactivation = false

  func setCategory(
    _ category: AVAudioSession.Category,
    mode: AVAudioSession.Mode,
    options: AVAudioSession.CategoryOptions
  ) throws {
    categoryCalls.append((category, mode, options))
  }

  func setActive(
    _ active: Bool,
    options: AVAudioSession.SetActiveOptions
  ) throws {
    activeCalls.append(active)
    if active && failNextActivation {
      failNextActivation = false
      throw Failure.activation
    }
    if !active && failNextDeactivation {
      failNextDeactivation = false
      throw Failure.deactivation
    }
    isActive = active
  }
}

private final class FirstWrittenFrameFinishProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [Bool] = []

  func record(_ written: Bool) {
    lock.lock()
    storedValues.append(written)
    lock.unlock()
  }

  var values: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

private final class LockedTestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue = 0

  func increment() -> Int {
    lock.lock()
    storedValue += 1
    let result = storedValue
    lock.unlock()
    return result
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedValue
  }
}

class RunnerTests: XCTestCase {

  func testEndingMaxVolumeKeepsRunningCameraAudioSessionActive() throws {
    let session = FakeIosAudioSession()
    let coordinator = IosSharedAudioSessionCoordinator(session: session)
    let maxVolume = IosAlertAudioSessionHostApi(
      audioSessionCoordinator: coordinator
    )

    // 相机初始化后持续持有共享录音会话，即使当前工作段已经停止。
    try coordinator.acquire(.camera)
    var firstBegin: Result<Void, Error>?
    maxVolume.beginSession { firstBegin = $0 }
    try XCTUnwrap(firstBegin).get()
    var duplicateBegin: Result<Void, Error>?
    maxVolume.beginSession { duplicateBegin = $0 }
    try XCTUnwrap(duplicateBegin).get()
    var firstEnd: Result<Void, Error>?
    maxVolume.endSession { firstEnd = $0 }
    try XCTUnwrap(firstEnd).get()

    XCTAssertTrue(session.isActive)
    XCTAssertFalse(session.activeCalls.contains(false))
    XCTAssertEqual(session.activeCalls.filter { $0 }.count, 1)
    XCTAssertEqual(session.categoryCalls.count, 1)
    XCTAssertEqual(coordinator.ownerCount(.camera), 1)
    XCTAssertEqual(coordinator.ownerCount(.maxVolume), 0)

    // 第二轮工作开始前再次确保 active，不需要重建 AVCaptureSession。
    try coordinator.ensureActive(for: .camera)
    var secondBegin: Result<Void, Error>?
    maxVolume.beginSession { secondBegin = $0 }
    try XCTUnwrap(secondBegin).get()
    var secondEnd: Result<Void, Error>?
    maxVolume.endSession { secondEnd = $0 }
    try XCTUnwrap(secondEnd).get()

    XCTAssertTrue(session.isActive)
    XCTAssertFalse(session.activeCalls.contains(false))
    XCTAssertEqual(session.activeCalls.filter { $0 }.count, 2)
    XCTAssertEqual(session.categoryCalls.count, 2)
    XCTAssertTrue(session.categoryCalls.allSatisfy {
      $0.0 == .playAndRecord &&
        $0.1 == .videoRecording &&
        $0.2.contains(.defaultToSpeaker)
    })

    try coordinator.release(.camera)
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(session.activeCalls.filter { !$0 }.count, 1)
  }

  func testAudioSessionActivationFailureIsNotReportedAsSuccess() {
    let session = FakeIosAudioSession()
    session.failNextActivation = true
    let coordinator = IosSharedAudioSessionCoordinator(session: session)
    let maxVolume = IosAlertAudioSessionHostApi(
      audioSessionCoordinator: coordinator
    )
    var result: Result<Void, Error>?

    maxVolume.beginSession { result = $0 }

    XCTAssertThrowsError(try XCTUnwrap(result).get())
    XCTAssertEqual(coordinator.ownerCount(.maxVolume), 0)
    XCTAssertFalse(session.isActive)
  }

  func testIndependentCameraOwnersDoNotDeactivateEachOther() throws {
    let session = FakeIosAudioSession()
    let coordinator = IosSharedAudioSessionCoordinator(session: session)

    try coordinator.acquire(.camera)
    try coordinator.acquire(.camera)
    XCTAssertEqual(coordinator.ownerCount(.camera), 2)
    XCTAssertEqual(session.activeCalls.filter { $0 }.count, 1)
    XCTAssertEqual(session.categoryCalls.count, 1)

    try coordinator.release(.camera)
    XCTAssertEqual(coordinator.ownerCount(.camera), 1)
    XCTAssertTrue(session.isActive)
    XCTAssertFalse(session.activeCalls.contains(false))

    try coordinator.release(.camera)
    XCTAssertEqual(coordinator.ownerCount(.camera), 0)
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(session.activeCalls.filter { !$0 }.count, 1)
  }

  func testAudioSessionDeactivationFailureIsReturnedToCaller() throws {
    let session = FakeIosAudioSession()
    let coordinator = IosSharedAudioSessionCoordinator(session: session)
    let maxVolume = IosAlertAudioSessionHostApi(
      audioSessionCoordinator: coordinator
    )
    var beginResult: Result<Void, Error>?
    maxVolume.beginSession { beginResult = $0 }
    try XCTUnwrap(beginResult).get()
    session.failNextDeactivation = true
    var endResult: Result<Void, Error>?

    maxVolume.endSession { endResult = $0 }

    XCTAssertThrowsError(try XCTUnwrap(endResult).get())
    XCTAssertEqual(coordinator.ownerCount(.maxVolume), 1)
    XCTAssertTrue(session.isActive)
  }

  func testAbandonRemovesUnretryableOwnerAfterDeactivationFailure() throws {
    let session = FakeIosAudioSession()
    let coordinator = IosSharedAudioSessionCoordinator(session: session)
    try coordinator.acquire(.camera)
    session.failNextDeactivation = true

    XCTAssertThrowsError(try coordinator.release(.camera))
    XCTAssertEqual(coordinator.ownerCount(.camera), 1)

    coordinator.abandon(.camera)
    XCTAssertEqual(coordinator.ownerCount(.camera), 0)

    try coordinator.acquire(.prompt)
    XCTAssertEqual(coordinator.ownerCount(.prompt), 1)
    XCTAssertEqual(session.activeCalls.filter { $0 }.count, 2)
  }

  func testAudioEnergyProbeReadsSigned16BitPcmSampleBuffer() throws {
    var streamDescription = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    XCTAssertEqual(
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &streamDescription,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
      ),
      noErr
    )

    let samples: [Int16] = [0, 8_192, 16_384, -32_768]
    var blockBuffer: CMBlockBuffer?
    XCTAssertEqual(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: samples.count * MemoryLayout<Int16>.stride,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: samples.count * MemoryLayout<Int16>.stride,
        flags: 0,
        blockBufferOut: &blockBuffer
      ),
      kCMBlockBufferNoErr
    )
    let copyStatus = samples.withUnsafeBytes { bytes in
      CMBlockBufferReplaceDataBytes(
        with: bytes.baseAddress!,
        blockBuffer: blockBuffer!,
        offsetIntoDestination: 0,
        dataLength: bytes.count
      )
    }
    XCTAssertEqual(copyStatus, kCMBlockBufferNoErr)

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48_000),
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid
    )
    var sampleSize = MemoryLayout<Int16>.stride
    var sampleBuffer: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: samples.count,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
      ),
      noErr
    )

    let peak = try XCTUnwrap(
      IosAudioSampleEnergyProbe.normalizedPeak(in: try XCTUnwrap(sampleBuffer))
    )
    XCTAssertEqual(peak, 1, accuracy: 0.000_001)
  }

  func testCompletedSegmentTrackInspectionStartsPendingThenPublishes() {
    let diagnostics = IosLastSegmentDiagnostics()

    XCTAssertTrue(diagnostics.recordWriterResult(
      serial: 7,
      writerStatus: "completed",
      writerError: nil,
      hasCompletedFile: true,
      inspectionError: nil
    ))
    var state = diagnostics.currentState()
    XCTAssertNil(state.trackCheckSucceeded)
    XCTAssertNil(state.trackCount)

    diagnostics.recordTrackResult(
      serial: 7,
      trackCount: 1,
      inspectionError: nil
    )
    state = diagnostics.currentState()
    XCTAssertEqual(state.writerStatus, "completed")
    XCTAssertEqual(state.trackCheckSucceeded, true)
    XCTAssertEqual(state.trackCount, 1)
    XCTAssertEqual(state.trackPresent, true)
    XCTAssertNil(state.trackInspectionError)
  }

  func testLateTrackInspectionCannotOverwriteNewerSegment() {
    let diagnostics = IosLastSegmentDiagnostics()
    XCTAssertTrue(diagnostics.recordWriterResult(
      serial: 3,
      writerStatus: "completed",
      writerError: nil,
      hasCompletedFile: true,
      inspectionError: nil
    ))
    XCTAssertTrue(diagnostics.recordWriterResult(
      serial: 4,
      writerStatus: "completed",
      writerError: nil,
      hasCompletedFile: true,
      inspectionError: nil
    ))

    diagnostics.recordTrackResult(
      serial: 3,
      trackCount: 0,
      inspectionError: nil
    )

    let state = diagnostics.currentState()
    XCTAssertNil(state.trackCheckSucceeded)
    XCTAssertNil(state.trackCount)
    XCTAssertNil(state.trackPresent)
  }

  func testWriterFailureDoesNotScheduleTrackInspection() {
    let diagnostics = IosLastSegmentDiagnostics()

    XCTAssertFalse(diagnostics.recordWriterResult(
      serial: 9,
      writerStatus: "failed",
      writerError: "writer failed",
      hasCompletedFile: false,
      inspectionError: "writer failed"
    ))

    let state = diagnostics.currentState()
    XCTAssertEqual(state.writerStatus, "failed")
    XCTAssertEqual(state.writerError, "writer failed")
    XCTAssertEqual(state.trackCheckSucceeded, false)
    XCTAssertEqual(state.trackInspectionError, "writer failed")
  }

  func testWatermarkCancellationBeforeSessionCreationCompletesOnceAndDeletesOutput() throws {
    let queue = DispatchQueue(label: "watermark-cancel-before-session")
    queue.suspend()
    defer { queue.resume() }
    let core = IosMediaProcessingCore(processingQueue: queue)
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("watermark-cancel-\(UUID().uuidString).mp4")
    try Data([1, 2, 3]).write(to: output)
    defer { try? FileManager.default.removeItem(at: output) }
    let cancelled = expectation(description: "watermark cancellation returned")
    cancelled.assertForOverFulfill = true
    let workerDrained = expectation(description: "cancelled worker drained")
    var completionCount = 0
    var cancellationCode: String?

    core.applyWatermark(
      request: IosWatermarkExportRequest(
        inputPath: "/missing/input.mp4",
        outputPath: output.path,
        startedAtMs: 0,
        trackingNumber: ""
      )
    ) { result in
      completionCount += 1
      if case .failure(let error) = result {
        cancellationCode = (error as? IosMediaProcessingCoreError)?.code
      }
      cancelled.fulfill()
    }

    core.cancelWatermark()
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    queue.resume()
    queue.async { workerDrained.fulfill() }
    wait(for: [cancelled, workerDrained], timeout: 1)
    queue.suspend()

    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(cancellationCode, "watermark_cancelled")
  }

  func testWatermarkCancellationArrivingBeforeApplyCancelsNextExportOnly() {
    let core = IosMediaProcessingCore()
    let firstCancelled = expectation(description: "early cancellation consumed")

    core.cancelWatermark()
    core.applyWatermark(
      request: IosWatermarkExportRequest(
        inputPath: "/missing/input.mp4",
        outputPath: "/missing/output.mp4",
        startedAtMs: 0,
        trackingNumber: ""
      )
    ) { result in
      if case .failure(let error) = result {
        XCTAssertEqual(
          (error as? IosMediaProcessingCoreError)?.code,
          "watermark_cancelled"
        )
      } else {
        XCTFail("预先到达的取消必须拒绝下一次水印导出")
      }
      firstCancelled.fulfill()
    }

    wait(for: [firstCancelled], timeout: 1)
  }

  func testIosCameraCapabilityPolicyAcceptsOnlyFixedPipelineInitialization() {
    XCTAssertNoThrow(
      try IosCameraCapabilityPolicy.validateInitializationMode("unverified")
    )
    XCTAssertNoThrow(
      try IosCameraCapabilityPolicy.validateInitializationMode("full")
    )

    for mode in ["encoder_analysis", "alternating", "unknown"] {
      XCTAssertThrowsError(
        try IosCameraCapabilityPolicy.validateInitializationMode(mode)
      ) { error in
        XCTAssertEqual(
          (error as? PigeonError)?.code,
          "camera_capability_mode_unsupported"
        )
      }
    }
  }

  func testIosCameraStartRetryPolicyIsBounded() {
    XCTAssertEqual(IosCameraStartRetryPolicy.maximumAttempts, 6)
    XCTAssertEqual(
      IosCameraStartRetryPolicy.retryDelay(afterAttempt: 1),
      0.75,
      accuracy: 0.001
    )
    XCTAssertEqual(
      IosCameraStartRetryPolicy.retryDelay(afterAttempt: 2),
      1.5,
      accuracy: 0.001
    )
    XCTAssertEqual(
      IosCameraStartRetryPolicy.retryDelay(afterAttempt: 3),
      2,
      accuracy: 0.001
    )
    XCTAssertEqual(
      IosCameraStartRetryPolicy.retryDelay(afterAttempt: 99),
      2,
      accuracy: 0.001
    )
  }

  func testIosCameraCapabilityOperationsFailWithTypedErrors() {
    let probeError = IosCameraCapabilityPolicy.probeUnsupportedError(
      sequence: "full"
    )
    XCTAssertEqual(probeError.code, "camera_capability_probe_unsupported")

    for mode in ["full", "encoder_analysis", "alternating", "unknown"] {
      XCTAssertEqual(
        IosCameraCapabilityPolicy.modeSwitchUnsupportedError(mode: mode).code,
        "camera_capability_mode_unsupported"
      )
    }
  }

  func testIosBarcodeVisionFallbackPolicyWaitsForMetadataAndThrottles() {
    XCTAssertTrue(
      IosBarcodeVisionFallbackPolicy.shouldSchedule(
        now: 10,
        lastCandidateAt: nil,
        lastSubmittedAt: nil,
        inFlight: false,
        scanningEnabled: true
      )
    )
    XCTAssertFalse(
      IosBarcodeVisionFallbackPolicy.shouldSchedule(
        now: 10.1,
        lastCandidateAt: nil,
        lastSubmittedAt: 10,
        inFlight: false,
        scanningEnabled: true
      )
    )
    XCTAssertFalse(
      IosBarcodeVisionFallbackPolicy.shouldSchedule(
        now: 10.2,
        lastCandidateAt: 10.0,
        lastSubmittedAt: nil,
        inFlight: false,
        scanningEnabled: true
      )
    )
    XCTAssertFalse(
      IosBarcodeVisionFallbackPolicy.shouldSchedule(
        now: 10.5,
        lastCandidateAt: nil,
        lastSubmittedAt: nil,
        inFlight: true,
        scanningEnabled: true
      )
    )
    XCTAssertTrue(
      IosBarcodeVisionFallbackPolicy.shouldSchedule(
        now: 10.2,
        lastCandidateAt: 10.0,
        lastSubmittedAt: nil,
        inFlight: false,
        scanningEnabled: true,
        ignoreRecentCandidate: true
      )
    )
    XCTAssertTrue(
      IosBarcodeVisionFallbackPolicy.shouldSchedule(
        now: 10.04,
        lastCandidateAt: nil,
        lastSubmittedAt: 10.0,
        inFlight: false,
        scanningEnabled: true,
        ignoreRecentCandidate: true,
        minimumInterval: 1.0 / 30.0
      )
    )
  }

  func testIosBarcodeScanEngineReadsDebugTestMode() {
    XCTAssertEqual(
      IosBarcodeScanEngine(environment: [
        "PACKINGPROOF_IOS_SCAN_ENGINE": "vision",
        "PACKINGPROOF_SCAN_BENCHMARK": "1",
      ]),
      .vision
    )
    XCTAssertEqual(
      IosBarcodeScanEngine(environment: [
        "PACKINGPROOF_IOS_SCAN_ENGINE": "metadata",
        "PACKINGPROOF_SCAN_BENCHMARK": "1",
      ]),
      .metadata
    )
    XCTAssertEqual(
      IosBarcodeScanEngine(environment: [:]),
      .automatic
    )
  }

  func testIosCapturePresetSelectionFallsBackWithoutChangingWriterSizeContract() {
    XCTAssertEqual(
      IosCapturePresetSelection.select(
        supportsHd1080: true,
        supportsHigh: true,
        supportsMedium: true
      ),
      IosCapturePresetSelection(
        name: "hd1920x1080",
        portraitWidth: 1080,
        portraitHeight: 1920
      )
    )
    XCTAssertEqual(
      IosCapturePresetSelection.select(
        supportsHd1080: false,
        supportsHigh: true,
        supportsMedium: true
      )?.name,
      "high"
    )
    XCTAssertEqual(
      IosCapturePresetSelection.select(
        supportsHd1080: false,
        supportsHigh: false,
        supportsMedium: true
      )?.portraitWidth,
      360
    )
    XCTAssertNil(
      IosCapturePresetSelection.select(
        supportsHd1080: false,
        supportsHigh: false,
        supportsMedium: false
      )
    )
  }

  func testIosCapturePresetSelectionUses4KOnlyWhenCurrentLensSupportsIt() {
    XCTAssertEqual(
      IosCapturePresetSelection.select(
        requestedSpec: "uhd4k30",
        supports4K: true,
        supportsHd1080: true,
        supportsHd720: true,
        supportsHigh: true,
        supportsMedium: true
      ),
      IosCapturePresetSelection(
        name: "hd4K3840x2160",
        portraitWidth: 2160,
        portraitHeight: 3840,
        recordingSpecName: "uhd4k30"
      )
    )
    XCTAssertEqual(
      IosCapturePresetSelection.select(
        requestedSpec: "uhd4k30",
        supports4K: false,
        supportsHd1080: true,
        supportsHigh: true,
        supportsMedium: true
      )?.recordingSpecName,
      "hd1080p30"
    )
  }

  func testIosPreferredRecordingFpsSelectsHighestCompatible4KRate() {
    XCTAssertEqual(
      iosPreferredRecordingFps(ranges: [(minimum: 1, maximum: 24)]),
      24
    )
    XCTAssertEqual(
      iosPreferredRecordingFps(ranges: [(minimum: 23.976, maximum: 23.976)]),
      24
    )
    XCTAssertEqual(
      iosPreferredRecordingFps(ranges: [(minimum: 30, maximum: 60)]),
      30
    )
    XCTAssertNil(
      iosPreferredRecordingFps(ranges: [(minimum: 1, maximum: 14)])
    )
  }

  func testIosCapturePresetSelectionHonors720pRequest() {
    XCTAssertEqual(
      IosCapturePresetSelection.select(
        requestedSpec: "smooth720p30",
        supportsHd1080: true,
        supportsHd720: true,
        supportsHigh: true,
        supportsMedium: true
      ),
      IosCapturePresetSelection(
        name: "hd1280x720",
        portraitWidth: 720,
        portraitHeight: 1280,
        recordingSpecName: "smooth720p30"
      )
    )
  }

  func testIosRecordingSpecEncodingPolicyUsesSpecAndCodecBitRates() {
    XCTAssertEqual(
      IosRecordingSpecEncodingPolicy.averageBitRate(
        spec: "uhd4k30", codec: "hevc"
      ),
      24_000_000
    )
    XCTAssertEqual(
      IosRecordingSpecEncodingPolicy.averageBitRate(
        spec: "uhd4k30", codec: "h264"
      ),
      35_000_000
    )
    XCTAssertEqual(
      IosRecordingSpecEncodingPolicy.averageBitRate(
        spec: "smooth720p30", codec: "hevc"
      ),
      4_500_000
    )
    XCTAssertEqual(
      IosRecordingSpecEncodingPolicy.averageBitRate(
        spec: "hd1080p30", codec: "h264"
      ),
      10_000_000
    )
  }

  func testIosVideoExportPolicyUsesPassthroughForHevcRemux() {
    let remux = iosVideoExportPolicy(passthrough: true)
    XCTAssertEqual(remux.presetName, AVAssetExportPresetPassthrough)
    XCTAssertTrue(remux.optimizeForNetworkUse)
    XCTAssertFalse(remux.appliesRequestedTimeRange)

    let clip = iosVideoExportPolicy(passthrough: false)
    XCTAssertEqual(clip.presetName, AVAssetExportPresetHighestQuality)
    XCTAssertFalse(clip.optimizeForNetworkUse)
    XCTAssertTrue(clip.appliesRequestedTimeRange)
  }

  func testIosRecordingTransformUsesSelectedCaptureSize() {
    let transform = iosRecordingTransform(
      for: "landscapeLeft",
      sourceSize: CGSize(width: 720, height: 1280)
    )
    XCTAssertEqual(transform.tx, 1280, accuracy: 0.001)
    XCTAssertEqual(transform.ty, 0, accuracy: 0.001)
  }

  func testIosDeviceIdentityMapsIPhone6sAndPreservesUnknownHardwareId() {
    XCTAssertEqual(IosDeviceIdentity.displayName(for: "iPhone8,1"), "iPhone 6s")
    XCTAssertEqual(
      IosDeviceIdentity.displayName(for: "iPhone99,1"),
      "iPhone99,1"
    )
  }

  func testLanBackupVersionComparison() {
    XCTAssertEqual(compareLanBackupVersions("v0.5.11+11011", "0.5.11"), 0)
    XCTAssertGreaterThan(compareLanBackupVersions("0.5.12", "0.5.11"), 0)
    XCTAssertLessThan(compareLanBackupVersions("0.5.10", "0.5.11"), 0)
    XCTAssertLessThan(compareLanBackupVersions("invalid", "0.5.11"), 0)
  }

  func testSharedFixtureMatchesIosCompletionContract() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fixtureURL = testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("protocol-fixtures/mobile-backup-v2-complete.json")
    let fixture = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
        as? [String: Any]
    )
    let request = try XCTUnwrap(fixture["request"] as? [String: Any])
    let expectedSessions = try XCTUnwrap(request["sessions"] as? [Any])
    let expectedSession = try XCTUnwrap(expectedSessions.first as? [String: Any])
    let actualSession = try XCTUnwrap(
      IosBackupHostApi.backupCompletionSession(expectedSession)
    )
    let response = try XCTUnwrap(fixture["response"] as? [String: Any])

    XCTAssertEqual(expectedSessions.count, 1)
    XCTAssertEqual(request["videoCodec"] as? String, "h265")
    XCTAssertEqual(actualSession as NSDictionary, expectedSession as NSDictionary)
    XCTAssertEqual((response["recordId"] as? NSNumber)?.int64Value, 42)
    XCTAssertNil(response["recordIds"])
  }

  func testUploadedVideoCodecAcceptsDocumentedValuesAndNormalizesAliases() {
    XCTAssertEqual(IosBackupHostApi.normalizedVideoCodec("AVC"), "h264")
    XCTAssertEqual(IosBackupHostApi.normalizedVideoCodec("hevc"), "h265")
    XCTAssertEqual(IosBackupHostApi.normalizedVideoCodec("av1"), "av1")
    XCTAssertNil(IosBackupHostApi.normalizedVideoCodec("vp9"))
    XCTAssertNil(IosBackupHostApi.normalizedVideoCodec(nil))
  }

  func testRequiredUsageDescriptionsPresent() {
    let requiredKeys = [
      "NSCameraUsageDescription",
      "NSMicrophoneUsageDescription",
      "NSLocalNetworkUsageDescription",
    ]
    for key in requiredKeys {
      let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
      XCTAssertFalse(
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
        "Info.plist 缺少非空权限说明：\(key)"
      )
    }
  }

  func testLocalNetworkingATSIsEnabled() {
    let settings =
      Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity")
      as? [String: Any]
    XCTAssertEqual(
      settings?["NSAllowsLocalNetworking"] as? Bool,
      true,
      "Info.plist 必须允许局域网明文 HTTP，否则备份与订单接收会被 ATS 拦截"
    )
  }

  func testWatermarkTimelineAdvancesWithCompositionTime() {
    let timeline = IosWatermarkTimeline(
      startedAtMs: 1_767_268_800_000,
      trackingNumber: "TRACK-001",
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    XCTAssertEqual(
      timeline.text(at: 0),
      "2026/01/01 12:00:00\nTRACK-001"
    )
    XCTAssertEqual(
      timeline.text(at: 2.9),
      "2026/01/01 12:00:02\nTRACK-001"
    )
    XCTAssertEqual(timeline.keyframeSeconds(duration: 2.5), [0, 1, 2, 2.5])
  }

  func testWatermarkFontSizeScales4KFrom1080pReference() {
    XCTAssertEqual(
      iosWatermarkFontSize(forOutputSize: CGSize(width: 1080, height: 1920)),
      44
    )
    XCTAssertEqual(
      iosWatermarkFontSize(forOutputSize: CGSize(width: 1920, height: 1080)),
      44
    )
    XCTAssertEqual(
      iosWatermarkFontSize(forOutputSize: CGSize(width: 2160, height: 3840)),
      88
    )
    XCTAssertEqual(
      iosWatermarkFontSize(forOutputSize: CGSize(width: 3840, height: 2160)),
      88
    )
  }

  func testWatermarkFontSizeDoesNotShrinkExistingLowerResolutions() {
    XCTAssertEqual(
      iosWatermarkFontSize(forOutputSize: CGSize(width: 720, height: 1280)),
      44
    )
  }

  func testWatermarkLayoutUsesFinalVideoCoordinatesForAllOrientations() {
    let naturalSize = CGSize(width: 1080, height: 1920)
    let transforms = [
      CGAffineTransform.identity,
      CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1920, ty: 0),
      CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1080),
    ]

    for transform in transforms {
      let layout = IosWatermarkLayout.make(
        naturalSize: naturalSize,
        preferredTransform: transform,
        textSize: CGSize(width: 300, height: 80)
      )
      XCTAssertEqual(layout.textFrame.midX, layout.renderSize.width / 2)
      XCTAssertEqual(
        layout.renderSize.height - layout.textFrame.maxY,
        layout.renderSize.height
          * iosWatermarkTopFraction(forOutputSize: layout.renderSize),
        accuracy: 0.0001
      )
    }
    XCTAssertEqual(
      IosWatermarkLayout.make(
        naturalSize: naturalSize,
        preferredTransform: transforms[0],
        textSize: CGSize(width: 300, height: 80)
      ).renderSize,
      CGSize(width: 1080, height: 1920)
    )
    for transform in transforms.dropFirst() {
      XCTAssertEqual(
        IosWatermarkLayout.make(
          naturalSize: naturalSize,
          preferredTransform: transform,
          textSize: CGSize(width: 300, height: 80)
        ).renderSize,
        CGSize(width: 1920, height: 1080)
      )
    }
  }

  func testCameraOperationTimingContainsOnlyAggregateStageData() throws {
    let timing = IosCameraOperationTiming(
      operation: "split",
      startedAtNs: 1_000_000_000
    )
    timing.record(stage: "writerFinish", durationMs: 417)
    timing.record(stage: "nextWriterSetup", durationMs: 23)
    timing.record(stage: "nextWatermarkPrepare", durationMs: 11)

    let snapshot = try XCTUnwrap(timing.finish(
      succeeded: true,
      endedAtNs: 1_500_000_000
    ))
    XCTAssertEqual(Set(snapshot.keys), [
      "operation", "succeeded", "totalMs", "stagesMs",
    ])
    XCTAssertEqual(snapshot["operation"] as? String, "split")
    XCTAssertEqual(snapshot["succeeded"] as? Bool, true)
    XCTAssertEqual(snapshot["totalMs"] as? Int64, 500)
    let stages = try XCTUnwrap(snapshot["stagesMs"] as? [String: Int64])
    XCTAssertEqual(stages, [
      "writerFinish": 417,
      "nextWriterSetup": 23,
      "nextWatermarkPrepare": 11,
    ])
    XCTAssertFalse(snapshot.keys.contains("path"))
    XCTAssertFalse(snapshot.keys.contains("trackingNumber"))
    XCTAssertNil(timing.finish(succeeded: false, endedAtNs: 2_000_000_000))
  }

  func testFirstWrittenFrameTimingCancelsOnceWhenReleasedBeforeFrame() {
    let probe = FirstWrittenFrameFinishProbe()
    weak var releasedTiming: IosCameraFirstWrittenFrameTiming?
    autoreleasepool {
      var timing: IosCameraFirstWrittenFrameTiming? =
        IosCameraFirstWrittenFrameTiming(onFinished: { @Sendable written in
          probe.record(written)
        })
      timing?.begin(operation: "start", startedAtNs: 1_000_000_000)
      releasedTiming = timing
      timing = nil
    }

    XCTAssertNil(releasedTiming)
    XCTAssertEqual(probe.values, [false])
  }

  func testFirstWrittenFrameTimingCancelsIdempotentlyOnDisposeBeforeFrame() {
    let probe = FirstWrittenFrameFinishProbe()
    let timing = IosCameraFirstWrittenFrameTiming(
      onFinished: { @Sendable written in probe.record(written) }
    )
    timing.begin(operation: "start", startedAtNs: 1_000_000_000)

    XCTAssertTrue(timing.cancelIfNeeded())
    XCTAssertFalse(timing.cancelIfNeeded())
    XCTAssertNil(timing.snapshot())
    XCTAssertEqual(probe.values, [false])
  }

  func testFirstWrittenFrameWaitsUntilVideoAppendActuallySucceeds() throws {
    let probe = FirstWrittenFrameFinishProbe()
    let timing = IosCameraFirstWrittenFrameTiming(
      onFinished: { @Sendable written in probe.record(written) }
    )
    timing.begin(operation: "split", startedAtNs: 1_000_000_000)
    var appendAttempts = 0

    XCTAssertFalse(IosCameraVideoAppendPolicy.appendWhenReady(
      isReady: false,
      append: {
        appendAttempts += 1
        return true
      },
      onWritten: {
        _ = timing.recordWrittenFrameIfNeeded(endedAtNs: 1_100_000_000)
      }
    ))
    XCTAssertEqual(appendAttempts, 0)
    XCTAssertNil(timing.snapshot())
    XCTAssertFalse(IosCameraVideoAppendPolicy.appendWhenReady(
      isReady: true,
      append: {
        appendAttempts += 1
        return false
      },
      onWritten: {
        _ = timing.recordWrittenFrameIfNeeded(endedAtNs: 1_200_000_000)
      }
    ))
    XCTAssertNil(timing.snapshot())
    XCTAssertTrue(IosCameraVideoAppendPolicy.appendWhenReady(
      isReady: true,
      append: {
        appendAttempts += 1
        return true
      },
      onWritten: {
        _ = timing.recordWrittenFrameIfNeeded(endedAtNs: 1_500_000_000)
      }
    ))
    _ = timing.recordWrittenFrameIfNeeded(endedAtNs: 1_900_000_000)

    XCTAssertEqual(appendAttempts, 2)
    XCTAssertEqual(probe.values, [true])
    let snapshot = try XCTUnwrap(timing.snapshot())
    XCTAssertEqual(Set(snapshot.keys), [
      "operation", "writerReadyToFirstWrittenFrameMs",
    ])
    XCTAssertEqual(snapshot["operation"] as? String, "split")
    XCTAssertEqual(
      snapshot["writerReadyToFirstWrittenFrameMs"] as? Int64,
      500
    )
  }

  func testFirstWrittenFrameSnapshotSupportsConcurrentFinishAndReads() throws {
    let probe = FirstWrittenFrameFinishProbe()
    let timing = IosCameraFirstWrittenFrameTiming(
      onFinished: { @Sendable written in probe.record(written) }
    )
    timing.begin(operation: "start", startedAtNs: 1_000_000_000)

    DispatchQueue.concurrentPerform(iterations: 200) { index in
      if index.isMultiple(of: 7) {
        _ = timing.recordWrittenFrameIfNeeded(endedAtNs: 1_300_000_000)
      } else {
        _ = timing.snapshot()
      }
    }

    XCTAssertEqual(probe.values, [true])
    let snapshot = try XCTUnwrap(timing.snapshot())
    XCTAssertEqual(snapshot["operation"] as? String, "start")
    XCTAssertEqual(
      snapshot["writerReadyToFirstWrittenFrameMs"] as? Int64,
      300
    )
    XCTAssertFalse(timing.cancelIfNeeded())
  }

  func testBackupReceiptVerifierAcceptsValidReceipt() {
    let fixture = makeReceiptFixture()
    XCTAssertTrue(verifyReceipt(fixture.response, fixture: fixture))
  }

  func testBackupReceiptVerifierRejectsMismatchedBoundFields() {
    let fixture = makeReceiptFixture()
    let mutations: [(String, Any)] = [
      ("fileSha256", String(repeating: "b", count: 64)),
      ("hostNodeId", "other-host"),
      ("sourceDeviceId", "other-device"),
      ("sourceSessionId", "other-session"),
      ("fileSizeBytes", fixture.fileSize + 1),
      ("recordId", fixture.recordId + 1),
    ]
    for (key, value) in mutations {
      var response = fixture.response
      response[key] = value
      XCTAssertFalse(verifyReceipt(response, fixture: fixture), key)
    }
  }

  func testBackupReceiptVerifierRejectsExpiredInvalidOrMissingSignature() {
    let fixture = makeReceiptFixture()

    var expired = fixture.response
    expired["verifiedAtUnixSeconds"] = fixture.now - 301
    XCTAssertFalse(verifyReceipt(expired, fixture: fixture))

    var invalid = fixture.response
    invalid["receiptSignature"] = String(repeating: "0", count: 64)
    XCTAssertFalse(verifyReceipt(invalid, fixture: fixture))

    var mixedContract = fixture.response
    mixedContract["recordIds"] = [fixture.recordId]
    XCTAssertFalse(verifyReceipt(mixedContract, fixture: fixture))

    for key in [
      "authVersion", "verifiedAtUnixSeconds", "hostNodeId", "sourceDeviceId",
      "sourceSessionId", "fileSha256", "fileSizeBytes", "recordId",
      "receiptSignature",
    ] {
      var missing = fixture.response
      missing.removeValue(forKey: key)
      XCTAssertFalse(verifyReceipt(missing, fixture: fixture), key)
    }
  }

  func testBackupFileReaderHashesAndReadsBoundedChunks() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("backup-reader-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let sourceLength = 2 * 1024 * 1024 + 17
    let sourceBytes: [UInt8] = (0..<sourceLength).map { index in
      UInt8(index % 251)
    }
    let source = Data(sourceBytes)
    try source.write(to: url)

    let reader = try IosBackupFileReader(url: url)
    let expectedHash = SHA256.hash(data: source)
      .map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(try reader.sha256(bufferSize: 64 * 1024), expectedHash)
    XCTAssertEqual(
      try reader.read(offset: 1024 * 1024 - 7, count: 32),
      source.subdata(in: (1024 * 1024 - 7)..<(1024 * 1024 + 25))
    )
    XCTAssertEqual(
      try reader.read(offset: Int64(source.count - 9), count: 64).count,
      9
    )
  }

  func testBackupFileReaderRejectsReplacedSource() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("backup-reader-replaced-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(repeating: 1, count: 1024).write(to: url)
    let reader = try IosBackupFileReader(url: url)
    try Data(repeating: 2, count: 2048).write(to: url)
    XCTAssertThrowsError(try reader.read(offset: 0, count: 32))
  }

  func testBackupJobStorePersistsCrudAcrossRestart() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let job = makeBackupJob(id: "job-1")

    do {
      let store = try IosBackupJobStore(
        databaseURL: fixture.databaseURL, defaults: fixture.defaults
      )
      try store.upsert(job)
      XCTAssertEqual(try store.summaryValues()["totalCount"] as? Int64, 1)
      XCTAssertTrue(try store.updateJob(id: "job-1") { current in
        current["state"] = "paused"
        current["uploadedBytes"] = 512
      })
      XCTAssertFalse(try store.updateJob(id: "missing") { _ in })
    }

    let reopened = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let restored = try XCTUnwrap(reopened.readJob(id: "job-1"))
    XCTAssertEqual(restored["state"] as? String, "paused")
    XCTAssertEqual((restored["uploadedBytes"] as? NSNumber)?.int64Value, 512)
    XCTAssertEqual((restored["sessions"] as? [Any])?.count, 1)
    let pausedSummary = try reopened.summaryValues()
    XCTAssertEqual(pausedSummary["totalCount"] as? Int64, 1)
    XCTAssertEqual(pausedSummary["pausedCount"] as? Int64, 1)
    XCTAssertEqual(pausedSummary["unfinishedUploadedBytes"] as? Int64, 512)
    try reopened.deleteJob(id: "job-1")
    XCTAssertNil(try reopened.readJob(id: "job-1"))
    XCTAssertEqual(try reopened.summaryValues()["totalCount"] as? Int64, 0)
  }

  func testBackupSummaryQuerySkipsMalformedSessions() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let id = "snapshot-with-corrupt-sessions"
    try store.upsert(makeBackupJob(id: id))
    try executeBackupStoreSql(
      "UPDATE backup_jobs SET sessions = '{invalid-json' WHERE id = '\(id)'",
      databaseURL: fixture.databaseURL
    )

    XCTAssertThrowsError(try store.readJob(id: id))
    let summary = try store.summaryValues()
    let activeJob = try XCTUnwrap(summary["activeJob"] as? [String: Any])
    XCTAssertEqual(activeJob["id"] as? String, id)
    XCTAssertEqual(activeJob["filePath"] as? String, "/recordings/\(id).mp4")
    XCTAssertNil(activeJob["sessions"])
  }

  func testBackupSummaryCountersRecoverFromInterruptedSeedWithoutRewritingJobs() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    do {
      _ = try IosBackupJobStore(
        databaseURL: fixture.databaseURL, defaults: fixture.defaults
      )
    }
    try executeBackupStoreSql(
      """
      INSERT INTO backup_jobs(
        id, generation, file_path, state, total_bytes, sessions, revision
      ) VALUES('seed-recovery', 'generation-seed', '/recordings/seed.mp4',
               'pending', 123, '[]', 1);
      UPDATE backup_meta SET int_value = 999 WHERE key = 'summary_total_count';
      DELETE FROM backup_meta WHERE key = 'summary_counters_initialized';
      """,
      databaseURL: fixture.databaseURL
    )

    let reopened = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let summary = try reopened.summaryValues()
    XCTAssertEqual(summary["totalCount"] as? Int64, 1)
    XCTAssertEqual(summary["pendingCount"] as? Int64, 1)
    XCTAssertEqual(summary["unfinishedTotalBytes"] as? Int64, 123)
    XCTAssertEqual(try reopened.readJob(id: "seed-recovery")?["state"] as? String, "pending")
  }

  func testBackupJobStoreAtomicallyRejectsStaleGenerationUpdate() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    try store.upsert(makeBackupJob(id: "generation-guard"))

    XCTAssertTrue(
      try store.updateJob(
        id: "generation-guard",
        expectedGeneration: "generation-generation-guard"
      ) { job in
        job["uploadedBytes"] = Int64(512)
      }
    )
    XCTAssertTrue(
      try store.updateJob(id: "generation-guard") { job in
        job["generation"] = "replacement-generation"
        job["state"] = "pending"
      }
    )
    var staleMutationRan = false
    XCTAssertFalse(
      try store.updateJob(
        id: "generation-guard",
        expectedGeneration: "generation-generation-guard"
      ) { job in
        staleMutationRan = true
        job["state"] = "completed"
      }
    )

    XCTAssertFalse(staleMutationRan)
    let current = try XCTUnwrap(store.readJob(id: "generation-guard"))
    XCTAssertEqual(current["generation"] as? String, "replacement-generation")
    XCTAssertEqual(current["state"] as? String, "pending")
    XCTAssertEqual((current["uploadedBytes"] as? NSNumber)?.int64Value, 512)
  }

  func testBackupJobRevisionsAreMonotonicAndStaleUpdateDoesNotAdvance() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let id = "revision-guard"
    try store.upsert(makeBackupJob(id: id))
    let first = try XCTUnwrap(store.readJob(id: id)?["revision"] as? Int64)
    XCTAssertTrue(try store.updateJob(id: id) { $0["uploadedBytes"] = 10 })
    let second = try XCTUnwrap(store.readJob(id: id)?["revision"] as? Int64)
    XCTAssertGreaterThan(second, first)

    XCTAssertFalse(
      try store.updateJob(id: id, expectedGeneration: "stale") {
        $0["state"] = "completed"
      }
    )
    XCTAssertEqual(try store.readJob(id: id)?["revision"] as? Int64, second)
    XCTAssertEqual(try store.summaryValues()["revision"] as? Int64, second)
  }

  func testBackupSummaryUsesSharedDominantFailurePriority() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    var credential = makeBackupJob(id: "failure-credential")
    credential["state"] = "failed"
    credential["failureKind"] = "credential_invalid"
    try store.upsert(credential)
    var offline = makeBackupJob(id: "failure-offline")
    offline["state"] = "failed"
    offline["failureKind"] = "offline_or_timeout"
    try store.upsert(offline)

    let summary = try store.summaryValues()
    XCTAssertEqual(summary["dominantFailureKind"] as? String, "credential_invalid")
    XCTAssertEqual(
      (summary["problemJob"] as? [String: Any])?["id"] as? String,
      "failure-credential"
    )
  }

  func testCompatibleHostRecoveryOnlyRequeuesItsOwnIncompatibleFailures() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    var incompatible = makeBackupJob(id: "failure-incompatible")
    incompatible["state"] = "failed"
    incompatible["failureKind"] = "incompatible_version"
    incompatible["errorMessage"] = "电脑端版本不兼容"
    incompatible["destinationComputerId"] = "computer-1"
    try store.upsert(incompatible)
    var storage = makeBackupJob(id: "failure-storage")
    storage["state"] = "failed"
    storage["failureKind"] = "storage_unavailable"
    storage["destinationComputerId"] = "computer-1"
    try store.upsert(storage)
    var otherDestination = makeBackupJob(id: "failure-other-destination")
    otherDestination["state"] = "failed"
    otherDestination["failureKind"] = "incompatible_version"
    otherDestination["destinationComputerId"] = "computer-2"
    try store.upsert(otherDestination)

    XCTAssertEqual(
      try store.recoverIncompatibleFailures(destinationComputerId: "computer-1"),
      1
    )

    let recovered = try XCTUnwrap(store.readJob(id: "failure-incompatible"))
    XCTAssertEqual(recovered["state"] as? String, "pending")
    XCTAssertNil(recovered["failureKind"] as? String)
    XCTAssertNil(recovered["errorMessage"] as? String)
    XCTAssertEqual(
      try store.readJob(id: "failure-storage")?["state"] as? String,
      "failed"
    )
    XCTAssertEqual(
      try store.readJob(id: "failure-other-destination")?["state"] as? String,
      "failed"
    )
    let summary = try store.summaryValues()
    XCTAssertEqual(summary["pendingCount"] as? Int64, 1)
    XCTAssertEqual(summary["failedCount"] as? Int64, 2)
  }

  func testEnablingUploadsOnlyRevivesRecoverableStoragePause() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    var userPaused = makeBackupJob(id: "user-paused")
    userPaused["state"] = "paused"
    try store.upsert(userPaused)
    var credentialPaused = makeBackupJob(id: "credential-paused")
    credentialPaused["state"] = "paused"
    credentialPaused["failureKind"] = "credential_invalid"
    credentialPaused["errorMessage"] = "需要重新配对"
    try store.upsert(credentialPaused)
    var storagePaused = makeBackupJob(id: "storage-paused")
    storagePaused["state"] = "paused"
    storagePaused["failureKind"] = "storage_unavailable"
    storagePaused["errorMessage"] = "无法读取录像文件信息"
    try store.upsert(storagePaused)

    XCTAssertEqual(try store.setUploadsEnabled(true), 2)
    XCTAssertEqual(try store.readJob(id: "user-paused")?["state"] as? String, "pending")
    let recovered = try XCTUnwrap(store.readJob(id: "storage-paused"))
    XCTAssertEqual(recovered["state"] as? String, "pending")
    XCTAssertNil(recovered["failureKind"] as? String)
    XCTAssertNil(recovered["errorMessage"] as? String)
    let preserved = try XCTUnwrap(store.readJob(id: "credential-paused"))
    XCTAssertEqual(preserved["state"] as? String, "paused")
    XCTAssertEqual(preserved["failureKind"] as? String, "credential_invalid")
    XCTAssertEqual(preserved["errorMessage"] as? String, "需要重新配对")
    let summary = try store.summaryValues()
    XCTAssertEqual(summary["pendingCount"] as? Int64, 2)
    XCTAssertEqual(summary["pausedCount"] as? Int64, 1)
  }

  func testBackupCleanupEventIsCreatedAndAcknowledgedTransactionally() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let id = "cleanup-event"
    try store.upsert(makeBackupJob(id: id))
    XCTAssertTrue(try store.updateJob(id: id) { job in
      job["localDeletedAt"] = "2026-08-23T01:02:03Z"
      job["cleanupReason"] = "已备份录像保留策略清理"
    })

    let page = try store.cleanupEvents(afterRevision: 0, limit: 1)
    let event = try XCTUnwrap(page.events.first)
    XCTAssertEqual(event["jobId"] as? String, id)
    XCTAssertEqual(event["filePath"] as? String, "/recordings/\(id).mp4")
    XCTAssertEqual(event["reason"] as? String, "已备份录像保留策略清理")
    let revision = try XCTUnwrap(event["revision"] as? Int64)
    XCTAssertEqual(page.latest, revision)

    try store.acknowledgeCleanupEvents(throughRevision: revision)
    XCTAssertTrue(try store.cleanupEvents(afterRevision: 0, limit: 10).events.isEmpty)
  }

  func testBackupJobsForPathsReturnsOnlyRequestedJobs() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    try store.upsert(makeBackupJob(id: "path-a"))
    try store.upsert(makeBackupJob(id: "path-b"))

    let result = try store.jobsForPaths([
      "/recordings/path-b.mp4", "/recordings/missing.mp4",
    ])
    XCTAssertEqual(result.jobs.count, 1)
    XCTAssertEqual(result.jobs.first?["id"] as? String, "path-b")
    XCTAssertGreaterThan(result.revision, 0)
  }

  func testBackupJobLookupMatchesEscapedHistoricalContainerSuffix() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    var historical = makeBackupJob(id: "historical-container")
    historical["filePath"] = "/private/old/Application/OLD/Documents/recordings/day/video_100%.mp4"
    try store.upsert(historical)

    let matched = try store.latestJob(
      filePathSuffix: "/Documents/recordings/day/video_100%.mp4"
    )
    XCTAssertEqual(matched?["id"] as? String, "historical-container")
    XCTAssertNil(
      try store.latestJob(
        filePathSuffix: "/Documents/recordings/day/videoX100Y.mp4"
      )
    )
  }

  func testClaimNextUploadJobUsesSqliteQueueAndSkipsPausedJobs() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    var paused = makeBackupJob(id: "paused")
    paused["state"] = "paused"
    try store.upsert(paused)
    try store.upsert(makeBackupJob(id: "pending"))

    let claimed = try XCTUnwrap(store.claimNextUploadJob())
    XCTAssertEqual(claimed["id"] as? String, "pending")
    XCTAssertEqual(claimed["state"] as? String, "uploading")
    XCTAssertEqual(
      try store.readJob(id: "pending")?["state"] as? String,
      "uploading"
    )

    _ = try store.updateJob(id: "pending") { $0["state"] = "completed" }
    XCTAssertNil(try store.claimNextUploadJob())
    XCTAssertEqual(try store.readJob(id: "paused")?["state"] as? String, "paused")
  }

  func testTenThousandCleanupCandidatesAreReadInPagesOfAtMostOneHundred() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    try executeBackupStoreSql(
      """
      WITH RECURSIVE counter(value) AS (
        SELECT 0
        UNION ALL
        SELECT value + 1 FROM counter WHERE value < 9999
      )
      INSERT INTO backup_jobs(
        id, generation, file_path, state, uploaded_bytes, total_bytes,
        last_modified, file_created_at, backup_completed_at, waiting_cleanup,
        content_sha256, verification_version, last_attested_at, sessions, revision
      )
      SELECT
        printf('scale-%05d', value),
        printf('generation-%05d', value),
        printf('/recordings/scale-%05d.mp4', value),
        CASE value % 4
          WHEN 0 THEN 'pending'
          WHEN 1 THEN 'paused'
          WHEN 2 THEN 'uploading'
          ELSE 'completed'
        END,
        0, 1, value, '2026-08-23T00:00:00Z',
        CASE WHEN value % 4 = 3 THEN '2026-08-23T00:01:00Z' ELSE NULL END,
        0,
        CASE WHEN value % 4 = 3 THEN printf('%064d', value) ELSE NULL END,
        CASE WHEN value % 4 = 3 THEN \(IosBackupReceiptVerifier.version) ELSE 0 END,
        CASE WHEN value % 4 = 3 THEN '2026-08-23T00:02:00Z' ELSE NULL END,
        '[]', value
      FROM counter;
      """,
      databaseURL: fixture.databaseURL
    )

    var afterId: String?
    var cleanupCount = 0
    var page: [[String: Any]]
    repeat {
      page = try store.cleanupCandidateJobsPage(afterId: afterId)
      XCTAssertLessThanOrEqual(page.count, 100)
      cleanupCount += page.count
      afterId = page.last?["id"] as? String
    } while page.count == 100
    XCTAssertEqual(cleanupCount, 5_000)

    var createdAt: String?
    afterId = nil
    var storageCount = 0
    var storagePage: (jobs: [[String: Any]], nextCreatedAtKey: String?, nextId: String?)
    repeat {
      storagePage = try store.storageRecoveryJobsPage(
        afterCreatedAtKey: createdAt,
        afterId: afterId,
        minimumVerificationVersion: IosBackupReceiptVerifier.version
      )
      XCTAssertLessThanOrEqual(storagePage.jobs.count, 100)
      storageCount += storagePage.jobs.count
      createdAt = storagePage.nextCreatedAtKey
      afterId = storagePage.nextId
    } while storagePage.jobs.count == 100
    XCTAssertEqual(storageCount, 2_500)
  }

  func testCleanupSliceQueryPlanUsesKeysetAndBothIntentIndexes() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    _ = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let plan = try backupStoreQueryPlan(
      """
      SELECT * FROM backup_jobs
      WHERE local_deleted_at IS NULL
        AND state NOT IN ('pending', 'uploading')
        AND id > 'cursor'
        AND NOT EXISTS (
          SELECT 1 FROM backup_cleanup_intents i
          WHERE i.job_id = backup_jobs.id
            AND i.phase IN ('claimed','moving','renamed')
        )
        AND NOT EXISTS (
          SELECT 1 FROM backup_cleanup_intents i
          WHERE i.original_path = backup_jobs.file_path
            AND i.phase IN ('claimed','moving','renamed')
        )
      ORDER BY id ASC LIMIT 101
      """,
      databaseURL: fixture.databaseURL
    )
    let details = plan.joined(separator: "\n")
    XCTAssertTrue(details.contains("idx_backup_jobs_cleanup_scan"), details)
    XCTAssertTrue(details.contains("idx_backup_cleanup_intents_active_job"), details)
    XCTAssertTrue(details.contains("idx_backup_cleanup_intents_active_path"), details)
    XCTAssertFalse(details.contains("USE TEMP B-TREE"), details)
    XCTAssertFalse(details.contains("SCAN backup_jobs"), details)
  }

  func testRecordingActivityOwnersCannotClearEachOther() {
    let state = IosRecordingActivityState()
    let oldOwner = UUID()
    let newOwner = UUID()

    state.setActive(true, owner: oldOwner)
    state.setActive(true, owner: newOwner)
    state.setActive(false, owner: oldOwner)

    XCTAssertTrue(state.isActive)
    state.setActive(false, owner: newOwner)
    XCTAssertFalse(state.isActive)
  }

  func testFiftyThousandCleanupCandidatesUseBoundedPersistentSlices() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    var store: IosBackupJobStore? = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    try executeBackupStoreSql(
      """
      WITH RECURSIVE counter(value) AS (
        SELECT 0 UNION ALL SELECT value + 1 FROM counter WHERE value < 49999
      )
      INSERT INTO backup_jobs(
        id,generation,file_path,state,uploaded_bytes,total_bytes,last_modified,
        file_created_at,waiting_cleanup,sessions,revision
      )
      SELECT printf('bounded-%05d',value),printf('generation-%05d',value),
        printf('/recordings/bounded-%05d.mp4',value),'paused',0,1,value,
        '2026-08-23T00:00:00Z',0,'[]',value FROM counter;
      """,
      databaseURL: fixture.databaseURL
    )
    let first = try XCTUnwrap(store).cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 7
    )
    XCTAssertEqual(first.jobs.count, 100)
    XCTAssertTrue(first.hasMore)
    XCTAssertTrue(try XCTUnwrap(store).finishCleanupSlice(first))

    // Reopening the database must continue at the persisted keyset cursor.
    store = nil
    let reopened = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let second = try reopened.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 7
    )
    XCTAssertEqual(second.jobs.count, 100)
    XCTAssertEqual(second.jobs.first?["id"] as? String, "bounded-00100")
    XCTAssertEqual(second.generation, first.generation)

    var totalCount = first.jobs.count
    var current = second
    while true {
      XCTAssertLessThanOrEqual(current.jobs.count, 100)
      totalCount += current.jobs.count
      let shouldContinue = try reopened.finishCleanupSlice(current)
      XCTAssertEqual(shouldContinue, current.hasMore)
      guard shouldContinue else { break }
      current = try reopened.cleanupCandidateJobsSlice(
        unbackedRetentionDays: 30, backedRetentionDays: 7
      )
      XCTAssertEqual(current.generation, first.generation)
    }
    XCTAssertEqual(totalCount, 50_000)
  }

  func testCleanupSliceExactHundredDoesNotRequireEmptyTailSlice() throws {
    for count in [99, 100, 101] {
      let fixture = try makeBackupStoreFixture()
      defer { removeBackupStoreFixture(fixture) }
      let store = try IosBackupJobStore(
        databaseURL: fixture.databaseURL, defaults: fixture.defaults
      )
      for index in 0..<count {
        var job = makeBackupJob(id: String(format: "edge-%03d", index))
        job["state"] = "paused"
        try store.upsert(job)
      }
      let slice = try store.cleanupCandidateJobsSlice(
        unbackedRetentionDays: 30, backedRetentionDays: 7
      )
      XCTAssertEqual(slice.jobs.count, min(count, 100), "count=\(count)")
      XCTAssertEqual(slice.hasMore, count > 100, "count=\(count)")
      XCTAssertEqual(try store.finishCleanupSlice(slice), count > 100)
    }
  }

  func testCleanupSliceRestartsForInputInsertedBehindCursor() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    for index in 0..<101 {
      var job = makeBackupJob(id: String(format: "middle-%03d", index))
      job["state"] = "paused"
      try store.upsert(job)
    }
    let first = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 7
    )
    var inserted = makeBackupJob(id: "ahead-of-cursor")
    inserted["state"] = "paused"
    try store.upsert(inserted)
    XCTAssertTrue(try store.finishCleanupSlice(first))
    let tail = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 7
    )
    XCTAssertEqual(tail.jobs.count, 1)
    XCTAssertTrue(try store.finishCleanupSlice(tail))
    let restarted = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 7
    )
    XCTAssertEqual(restarted.jobs.first?["id"] as? String, "ahead-of-cursor")
    XCTAssertNotEqual(restarted.generation, first.generation)
  }

  func testCleanupSliceRestartsWhenSmallerIdArrivesAfterCursorWasPersisted() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    for index in 0..<101 {
      var job = makeBackupJob(id: String(format: "persisted-%03d", index))
      job["state"] = "paused"
      try store.upsert(job)
    }
    let first = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 7
    )
    XCTAssertEqual(first.jobs.last?["id"] as? String, "persisted-099")
    XCTAssertTrue(try store.finishCleanupSlice(first))

    var inserted = makeBackupJob(id: "after-cursor-smaller")
    inserted["state"] = "paused"
    try store.upsert(inserted)
    let tail = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 7
    )
    XCTAssertEqual(tail.jobs.map { $0["id"] as? String }, ["persisted-100"])
    XCTAssertTrue(try store.finishCleanupSlice(tail))

    let restarted = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 7
    )
    XCTAssertEqual(restarted.jobs.first?["id"] as? String, "after-cursor-smaller")
    XCTAssertNotEqual(restarted.generation, first.generation)
  }

  func testCleanupPolicySwitchInvalidatesCursorAndClaimedRetentionIntent() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    try store.activateCleanupPolicy(unbackedRetentionDays: 1, backedRetentionDays: 1)
    let oldSlice = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 1, backedRetentionDays: 1
    )
    var job = makeBackupJob(id: "claimed-old-policy")
    job["state"] = "paused"
    job["filePath"] = "/recordings/claimed-old-policy-missing.mp4"
    try store.upsert(job)
    XCTAssertNotNil(try store.beginCleanupIntent(
      jobId: "claimed-old-policy",
      expectedGeneration: "generation-claimed-old-policy",
      allowedStates: ["paused"],
      originalPath: "/recordings/claimed-old-policy-missing.mp4",
      tombstonePath: "/recordings/.claimed-old-policy.tombstone",
      expectedBytes: 1024, expectedModifiedAtMilliseconds: 1_800_000_000_000,
      expectedDevice: 0, expectedInode: 0, expectedSha256: nil,
      reason: "未备份录像保留策略清理", completedState: "expired",
      completedErrorMessage: nil, expectedCleanupGeneration: oldSlice.generation
    ))

    try store.activateCleanupPolicy(unbackedRetentionDays: 30, backedRetentionDays: 30)
    XCTAssertTrue(try store.cleanupIntents().isEmpty)
    XCTAssertFalse(try store.isCleanupGenerationCurrent(oldSlice.generation))
    let replacementSlice = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 30
    )
    XCTAssertEqual(replacementSlice.unbackedRetentionDays, 30)
    XCTAssertEqual(replacementSlice.backedRetentionDays, 30)
    XCTAssertNotEqual(replacementSlice.generation, oldSlice.generation)

    // A stale worker may finish after the policy switch. Its generation CAS
    // must leave the replacement checkpoint untouched.
    XCTAssertTrue(try store.finishCleanupSlice(oldSlice))
    XCTAssertTrue(try store.isCleanupGenerationCurrent(replacementSlice.generation))
    let currentSlice = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 30
    )
    XCTAssertEqual(currentSlice.generation, replacementSlice.generation)
  }

  func testCleanupPolicySwitchCancelsClaimedButPreservesMovingIntentForRecovery()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    try store.activateCleanupPolicy(unbackedRetentionDays: 1, backedRetentionDays: 1)
    let oldSlice = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 1, backedRetentionDays: 1
    )
    for id in ["claimed-policy-switch", "moving-policy-switch"] {
      var job = makeBackupJob(id: id)
      job["state"] = "paused"
      try store.upsert(job)
      let claimed = try XCTUnwrap(store.beginCleanupIntent(
        jobId: id, expectedGeneration: "generation-\(id)",
        allowedStates: ["paused"], originalPath: "/recordings/\(id).mp4",
        tombstonePath: "/recordings/.\(id).tombstone", expectedBytes: 1024,
        expectedModifiedAtMilliseconds: 1_800_000_000_000,
        expectedDevice: 0, expectedInode: 0, expectedSha256: nil,
        reason: "未备份录像保留策略清理", completedState: "expired",
        completedErrorMessage: nil, expectedCleanupGeneration: oldSlice.generation
      ))
      if id == "moving-policy-switch" {
        XCTAssertNotNil(try store.activateCleanupIntent(token: claimed.token))
      }
    }

    try store.activateCleanupPolicy(unbackedRetentionDays: 30, backedRetentionDays: 30)
    let preserved = try store.cleanupIntents()
    XCTAssertEqual(preserved.count, 1)
    XCTAssertEqual(preserved.first?.jobId, "moving-policy-switch")
    XCTAssertEqual(preserved.first?.phase, "moving")

    let api = makeBackupApi(
      defaults: fixture.defaults, store: store,
      recordingsRoot: URL(fileURLWithPath: "/recordings", isDirectory: true)
    )
    try await api.performCleanup()
    XCTAssertTrue(try store.cleanupIntents().isEmpty)
    XCTAssertNotNil(try store.readJob(id: "moving-policy-switch")?["localDeletedAt"])
    XCTAssertNil(try store.readJob(id: "claimed-policy-switch")?["localDeletedAt"])
  }

  func testRetentionScheduleFailureDoesNotPublishDefaultsBeforeDatabaseActivation()
    throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    fixture.defaults.set(
      ["unbackedRetentionDays": 14, "backedRetentionDays": 7],
      forKey: "ios_backup_retention"
    )
    let api = IosBackupHostApi(
      eventApi: FakeBackupNativeEventApi(),
      defaults: fixture.defaults,
      credentialStore: IosBackupCredentialStore(
        defaults: fixture.defaults,
        keychain: FakeIosKeychainClient(),
        service: "RunnerTests.retention-failure.\(UUID().uuidString)",
        account: "access-key"
      ),
      jobStore: .failure(IosBackupStoreError(
        operation: "测试策略激活", code: SQLITE_IOERR,
        message: "模拟数据库策略激活失败"
      )),
      recordingsRoot: FileManager.default.temporaryDirectory
    )
    var updateResult: Result<Void, Error>?

    api.updateRetentionSchedule(request: [
      "unbackedRetentionDays": 30, "backedRetentionDays": 21,
    ]) { updateResult = $0 }

    guard case .failure(let error) = updateResult else {
      return XCTFail("数据库激活失败必须传回 failure")
    }
    XCTAssertTrue(error is IosBackupStoreError)
    let retained = try XCTUnwrap(
      fixture.defaults.dictionary(forKey: "ios_backup_retention")
    )
    XCTAssertEqual(retained["unbackedRetentionDays"] as? Int, 14)
    XCTAssertEqual(retained["backedRetentionDays"] as? Int, 7)
  }

  func testCleanupRecoverySliceIsBoundedAndPrecedesNewCandidates() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    for index in 0..<101 {
      let id = String(format: "recovery-bounded-%03d", index)
      var job = makeBackupJob(id: id)
      job["state"] = "paused"
      try store.upsert(job)
      let claimed = try XCTUnwrap(store.beginCleanupIntent(
        jobId: id, expectedGeneration: "generation-\(id)",
        allowedStates: ["paused"], originalPath: "/recordings/\(id).mp4",
        tombstonePath: "/recordings/.\(id).tombstone", expectedBytes: 1024,
        expectedModifiedAtMilliseconds: 1_800_000_000_000,
        expectedDevice: 0, expectedInode: 0, expectedSha256: nil,
        reason: "测试恢复", completedState: "expired", completedErrorMessage: nil
      ))
      XCTAssertNotNil(try store.activateCleanupIntent(token: claimed.token))
    }
    var candidate = makeBackupJob(id: "new-cleanup-candidate")
    candidate["state"] = "paused"
    candidate["fileCreatedAt"] = "2020-01-01T00:00:00Z"
    try store.upsert(candidate)

    let api = makeBackupApi(
      defaults: fixture.defaults, store: store,
      recordingsRoot: URL(fileURLWithPath: "/recordings", isDirectory: true)
    )
    try await api.performCleanup()

    let remaining = try store.cleanupIntents(limit: 100, recoverableOnly: true)
    XCTAssertEqual(remaining.count, 1)
    XCTAssertEqual(remaining.first?.phase, "moving")
    XCTAssertNil(try store.readJob(id: "new-cleanup-candidate")?["localDeletedAt"])

    try await api.performCleanup()
    XCTAssertTrue(try store.cleanupIntents(recoverableOnly: true).isEmpty)
    XCTAssertNil(try store.readJob(id: "new-cleanup-candidate")?["localDeletedAt"])

    try await api.performCleanup()
    XCTAssertNotNil(try store.readJob(id: "new-cleanup-candidate")?["localDeletedAt"])
  }

  func testCleanupTriggerAutomaticallyDrainsRecoveryBeforeEnteringCandidates()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    for index in 0..<101 {
      let id = String(format: "trigger-recovery-%03d", index)
      var job = makeBackupJob(id: id)
      job["state"] = "paused"
      try store.upsert(job)
      let claimed = try XCTUnwrap(store.beginCleanupIntent(
        jobId: id, expectedGeneration: "generation-\(id)",
        allowedStates: ["paused"], originalPath: "/recordings/\(id).mp4",
        tombstonePath: "/recordings/.\(id).tombstone", expectedBytes: 1024,
        expectedModifiedAtMilliseconds: 1_800_000_000_000,
        expectedDevice: 0, expectedInode: 0, expectedSha256: nil,
        reason: "测试自动恢复", completedState: "expired", completedErrorMessage: nil
      ))
      XCTAssertNotNil(try store.activateCleanupIntent(token: claimed.token))
    }
    let candidateId = "trigger-after-recovery-candidate"
    var candidate = makeBackupJob(id: candidateId)
    candidate["state"] = "paused"
    candidate["fileCreatedAt"] = "2020-01-01T00:00:00Z"
    try store.upsert(candidate)
    let candidateReached = expectation(description: "恢复清空后自动进入候选")
    let candidateCommitted = expectation(description: "自动候选清理完成")
    let api = makeBackupApi(
      defaults: fixture.defaults, store: store,
      recordingsRoot: URL(fileURLWithPath: "/recordings", isDirectory: true),
      beforeCleanupIntentClaimForTesting: { job in
        if job["id"] as? String == candidateId { candidateReached.fulfill() }
      },
      afterCleanupCommitForTesting: { intent in
        if intent.jobId == candidateId { candidateCommitted.fulfill() }
      }
    )

    api.initialize(request: [
      "unbackedRetentionDays": 0, "backedRetentionDays": 0,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }

    await fulfillment(of: [candidateReached], timeout: 5)
    let remainingRecoveryIds = Set(
      try store.cleanupIntents(recoverableOnly: true).map(\.jobId)
    ).filter { $0.hasPrefix("trigger-recovery-") }
    XCTAssertTrue(remainingRecoveryIds.isEmpty)
    await fulfillment(of: [candidateCommitted], timeout: 2)
    XCTAssertNotNil(try store.readJob(id: candidateId)?["localDeletedAt"])
  }

  func testRetentionPolicySwitchDoesNotWaitForLargeFileProofHash() async throws {
    let proofMayContinue = DispatchSemaphore(value: 0)
    let hookLock = NSLock()
    var blockedFirstProof = false
    let proofOpened = expectation(description: "大文件已打开且即将计算 SHA")
    let restartedCleanupFinished = expectation(description: "新策略清理已完成")
    let fixture = try makeRetentionCleanupFixture(
      id: "policy-during-large-proof",
      beforeCleanupFileProofForTesting: { _ in
        hookLock.lock()
        let shouldBlock = !blockedFirstProof
        blockedFirstProof = true
        hookLock.unlock()
        guard shouldBlock else { return }
        proofOpened.fulfill()
        proofMayContinue.wait()
      },
      afterCleanupCommitForTesting: { _ in restartedCleanupFinished.fulfill() }
    )
    defer {
      proofMayContinue.signal()
      removeRetentionCleanupFixture(fixture)
    }
    let contents = Data(repeating: 0x5a, count: 16 * 1024 * 1024)
    try contents.write(to: fixture.file)
    let snapshot = try IosBackupFileSnapshot.read(from: fixture.file)
    var job = fixture.job
    job["state"] = "paused"
    job["backupCompletedAt"] = nil
    job["totalBytes"] = snapshot.byteCount
    job["lastModified"] = snapshot.modifiedAtMilliseconds
    job["contentSha256"] = SHA256.hash(data: contents)
      .map { String(format: "%02x", $0) }.joined()
    try fixture.store.upsert(job)
    fixture.defaults.set(
      ["unbackedRetentionDays": 0, "backedRetentionDays": 0],
      forKey: "ios_backup_retention"
    )
    try fixture.store.activateCleanupPolicy(
      unbackedRetentionDays: 0, backedRetentionDays: 0
    )

    let cleanup = Task { try await fixture.api.performCleanup() }
    await fulfillment(of: [proofOpened], timeout: 2)
    let policyUpdated = expectation(
      description: "proof 读取暂停期间策略切换未被 cleanupPolicyLock 阻塞"
    )
    fixture.api.updateRetentionSchedule(request: [
      "unbackedRetentionDays": 0, "backedRetentionDays": 1,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
      policyUpdated.fulfill()
    }
    // 同样是等待真实回调，沿用 5 秒上限避免满负载下偶发超时。
    await fulfillment(of: [policyUpdated], timeout: 5)
    proofMayContinue.signal()
    try await cleanup.value
    await fulfillment(of: [restartedCleanupFinished], timeout: 3)
  }

  func testNoOpCleanupSliceDoesNotAdvanceSummaryRevision() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let before = try store.summaryValues()["revision"] as? Int64
    let slice = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 7
    )
    XCTAssertTrue(slice.jobs.isEmpty)
    XCTAssertFalse(try store.finishCleanupSlice(slice))
    XCTAssertEqual(try store.summaryValues()["revision"] as? Int64, before)
  }

  func testCleanupIntentPaginationIsBoundedAndKeysetBased() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    for index in 0..<101 {
      let id = String(format: "intent-%03d", index)
      var job = makeBackupJob(id: id)
      job["state"] = "paused"
      try store.upsert(job)
      XCTAssertNotNil(try store.beginCleanupIntent(
        jobId: id, expectedGeneration: "generation-\(id)",
        allowedStates: ["paused"], originalPath: "/recordings/\(id).mp4",
        tombstonePath: "/recordings/.\(id).tombstone", expectedBytes: 1024,
        expectedModifiedAtMilliseconds: 1_800_000_000_000,
        expectedDevice: 0, expectedInode: 0, expectedSha256: nil,
        reason: "测试清理", completedState: nil, completedErrorMessage: nil
      ))
    }

    let first = try store.cleanupIntents(limit: 100)
    let second = try store.cleanupIntents(afterToken: first.last?.token, limit: 100)
    XCTAssertEqual(first.count, 100)
    XCTAssertEqual(second.count, 1)
    XCTAssertThrowsError(try store.cleanupIntents(limit: 101))
  }

  func testActiveCleanupIntentBlocksDifferentJobUsingSamePath() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let sharedPath = "/recordings/shared-cleanup.mp4"
    var cleanupJob = makeBackupJob(id: "cleanup-owner")
    cleanupJob["state"] = "failed"
    cleanupJob["filePath"] = sharedPath
    cleanupJob["failureKind"] = "incompatible_version"
    cleanupJob["destinationComputerId"] = "cleanup-computer"
    var queuedJob = makeBackupJob(id: "same-path-queued")
    queuedJob["filePath"] = sharedPath
    var movableJob = makeBackupJob(id: "move-onto-cleanup-path")
    movableJob["state"] = "paused"
    try store.upsert(cleanupJob)
    try store.upsert(queuedJob)
    try store.upsert(movableJob)
    let claimed = try XCTUnwrap(store.beginCleanupIntent(
      jobId: "cleanup-owner", expectedGeneration: "generation-cleanup-owner",
      allowedStates: ["failed"], originalPath: sharedPath,
      tombstonePath: "/recordings/.shared-cleanup.tombstone",
      expectedBytes: 1024,
      expectedModifiedAtMilliseconds: 1_800_000_000_000,
      expectedDevice: 0, expectedInode: 0, expectedSha256: nil,
      reason: "测试同路径屏障", completedState: nil,
      completedErrorMessage: nil
    ))
    XCTAssertNotNil(try store.activateCleanupIntent(token: claimed.token))
    XCTAssertEqual(
      try store.recoverIncompatibleFailures(
        destinationComputerId: "cleanup-computer"
      ),
      0
    )
    XCTAssertEqual(
      try store.readJob(id: "cleanup-owner")?["state"] as? String,
      "failed"
    )

    var newJob = makeBackupJob(id: "same-path-new")
    newJob["filePath"] = sharedPath
    XCTAssertThrowsError(try store.upsert(newJob)) { error in
      XCTAssertEqual((error as? IosBackupStoreError)?.code, SQLITE_BUSY)
    }
    XCTAssertThrowsError(
      try store.updateJob(id: "move-onto-cleanup-path") {
        $0["filePath"] = sharedPath
      }
    ) { error in
      XCTAssertEqual((error as? IosBackupStoreError)?.code, SQLITE_BUSY)
    }
    XCTAssertNil(try store.claimNextUploadJob())
    XCTAssertEqual(
      try store.readJob(id: "same-path-queued")?["state"] as? String,
      "pending"
    )
  }

  func testBackupJobStoreRejectsUnopenableAndCorruptDatabases() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let directoryURL = fixture.root.appendingPathComponent("database-directory")
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true
    )
    XCTAssertThrowsError(
      try IosBackupJobStore(databaseURL: directoryURL, defaults: fixture.defaults)
    ) { error in
      XCTAssertTrue(error is IosBackupStoreError)
    }

    try Data("not-a-sqlite-database".utf8).write(to: fixture.databaseURL)
    XCTAssertThrowsError(
      try IosBackupJobStore(databaseURL: fixture.databaseURL, defaults: fixture.defaults)
    ) { error in
      XCTAssertTrue(error is IosBackupStoreError)
    }
  }

  func testBackupJobStoreCommitsLegacyMigrationBeforeDeletingSource() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    fixture.defaults.set(
      [makeBackupJob(id: "legacy-1")], forKey: "ios_backup_jobs"
    )

    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    XCTAssertEqual(try store.readJob(id: "legacy-1")?["id"] as? String, "legacy-1")
    XCTAssertNil(fixture.defaults.object(forKey: "ios_backup_jobs"))
  }

  func testBackupJobStoreRollsBackInterruptedLegacyMigration() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    var invalid = makeBackupJob(id: "legacy-invalid")
    invalid["sessions"] = [Date()]
    fixture.defaults.set(
      [makeBackupJob(id: "legacy-valid"), invalid],
      forKey: "ios_backup_jobs"
    )

    XCTAssertThrowsError(
      try IosBackupJobStore(databaseURL: fixture.databaseURL, defaults: fixture.defaults)
    ) { error in
      XCTAssertTrue(error is IosBackupStoreError)
    }
    XCTAssertNotNil(fixture.defaults.object(forKey: "ios_backup_jobs"))

    fixture.defaults.removeObject(forKey: "ios_backup_jobs")
    let reopened = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    XCTAssertEqual(try reopened.summaryValues()["totalCount"] as? Int64, 0)
  }

  func testBackupCredentialStoreMigratesAndScrubsLegacyCopies() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let keychain = FakeIosKeychainClient()
    fixture.defaults.set("legacy-access-key", forKey: "ios_backup_access_key")
    fixture.defaults.set(
      [
        "baseUrl": "http://192.168.1.2:3000",
        "computerId": "computer-1",
        "accessKey": "embedded-access-key",
      ],
      forKey: "ios_backup_connection"
    )
    let store = IosBackupCredentialStore(
      defaults: fixture.defaults,
      keychain: keychain,
      service: "RunnerTests.\(UUID().uuidString)",
      account: "access-key"
    )

    XCTAssertEqual(try store.load(), "legacy-access-key")
    XCTAssertEqual(keychain.data, Data("legacy-access-key".utf8))
    XCTAssertNil(fixture.defaults.object(forKey: "ios_backup_access_key"))
    let connection = try XCTUnwrap(
      fixture.defaults.dictionary(forKey: "ios_backup_connection")
    )
    XCTAssertNil(connection["accessKey"])
    XCTAssertEqual(connection["computerId"] as? String, "computer-1")
  }

  func testBackupCredentialStorePreservesLegacyCopiesWhenMigrationFails() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let keychain = FakeIosKeychainClient()
    keychain.saveError = IosBackupCredentialError(operation: "保存", status: -1)
    fixture.defaults.set("legacy-access-key", forKey: "ios_backup_access_key")
    fixture.defaults.set(
      ["computerId": "computer-1", "accessKey": "embedded-access-key"],
      forKey: "ios_backup_connection"
    )
    let store = IosBackupCredentialStore(
      defaults: fixture.defaults,
      keychain: keychain,
      service: "RunnerTests.\(UUID().uuidString)",
      account: "access-key"
    )

    XCTAssertThrowsError(try store.load())
    XCTAssertEqual(
      fixture.defaults.string(forKey: "ios_backup_access_key"),
      "legacy-access-key"
    )
    XCTAssertEqual(
      fixture.defaults.dictionary(forKey: "ios_backup_connection")?["accessKey"]
        as? String,
      "embedded-access-key"
    )
  }

  func testBackupCredentialStoreSavesLoadsAndDeletesSecureValue() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let keychain = FakeIosKeychainClient()
    let store = IosBackupCredentialStore(
      defaults: fixture.defaults,
      keychain: keychain,
      service: "RunnerTests.\(UUID().uuidString)",
      account: "access-key"
    )

    try store.save("secure-access-key")
    XCTAssertEqual(try store.load(), "secure-access-key")
    try store.delete()
    XCTAssertNil(try store.load())
  }

  func testBackupCleanupGateRequiresExactlyOneSession() {
    var job = makeBackupJob(id: "cleanup-cardinality")
    XCTAssertTrue(IosBackupCleanupGate.hasSingleSession(job))
    job["sessions"] = []
    XCTAssertFalse(IosBackupCleanupGate.hasSingleSession(job))
    job["sessions"] = [["id": "first"], ["id": "second"]]
    XCTAssertFalse(IosBackupCleanupGate.hasSingleSession(job))
    job.removeValue(forKey: "sessions")
    XCTAssertFalse(IosBackupCleanupGate.hasSingleSession(job))
  }

  func testBackupRetentionEvidenceRequiresLocallyVerifiedReceipt() {
    var job = makeBackupJob(id: "retention-receipt")
    job["contentSha256"] = String(repeating: "a", count: 64)
    job["verificationVersion"] = 3
    job["remoteRecordId"] = NSNumber(value: 42)
    job["totalBytes"] = Int64(1_024)

    XCTAssertFalse(
      IosBackupCleanupGate.hasVerifiedRetentionEvidence(job, minimumVersion: 3)
    )
    job["verificationReceipt"] = "verified-receipt"
    XCTAssertTrue(
      IosBackupCleanupGate.hasVerifiedRetentionEvidence(job, minimumVersion: 3)
    )
    for key in [
      "contentSha256", "verificationVersion", "remoteRecordId", "totalBytes",
      "verificationReceipt", "sessions",
    ] {
      var missing = job
      missing.removeValue(forKey: key)
      XCTAssertFalse(
        IosBackupCleanupGate.hasVerifiedRetentionEvidence(missing, minimumVersion: 3),
        key
      )
    }
    job["sessions"] = []
    XCTAssertFalse(
      IosBackupCleanupGate.hasVerifiedRetentionEvidence(job, minimumVersion: 3)
    )
  }

  func testRetentionCleanupKeepsLegacyPseudoVerifiedFileWithoutReceipt()
    async throws
  {
    let fixture = try makeRetentionCleanupFixture(id: "legacy-pseudo-verified")
    defer { removeRetentionCleanupFixture(fixture) }
    var job = fixture.job
    job["verificationVersion"] = 3
    job["remoteRecordId"] = NSNumber(value: 42)
    try fixture.store.upsert(job)

    try await fixture.api.performCleanup()

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    let updated = try XCTUnwrap(fixture.store.readJob(id: "legacy-pseudo-verified"))
    XCTAssertEqual(updated["waitingCleanup"] as? Bool, true)
    XCTAssertNil(updated["localDeletedAt"])
    XCTAssertEqual(
      updated["errorMessage"] as? String,
      "备份记录缺少安全校验信息，需重新备份后才能自动清理"
    )
  }

  func testCleanupReturnDrainsImmediateAndThrottledSummaryWork() async throws {
    let countQueue = DispatchQueue(label: "RunnerTests.cleanup-summary-count")
    var summaryCount = 0
    let fixture = try makeRetentionCleanupFixture(
      id: "cleanup-summary-drain",
      onSnapshot: { _ in
        countQueue.sync { summaryCount += 1 }
      }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    var job = fixture.job
    job["verificationVersion"] = 3
    job["remoteRecordId"] = NSNumber(value: 42)
    try fixture.store.upsert(job)

    fixture.api.emitProgressSummaryForTesting()
    try await fixture.api.performCleanup()
    let countAfterCleanup = countQueue.sync { summaryCount }
    XCTAssertGreaterThan(countAfterCleanup, 0)

    try FileManager.default.removeItem(at: fixture.root)
    try await Task.sleep(nanoseconds: 1_200_000_000)
    XCTAssertEqual(countQueue.sync { summaryCount }, countAfterCleanup)
  }

  func testRetentionCleanupKeepsVerifiedFileWhenRemoteIsUnreachable()
    async throws
  {
    let fixture = try makeRetentionCleanupFixture(id: "remote-unreachable")
    defer { removeRetentionCleanupFixture(fixture) }
    var job = fixture.job
    job["verificationVersion"] = 3
    job["verificationReceipt"] = "locally-verified-receipt"
    job["remoteRecordId"] = NSNumber(value: 42)
    try fixture.store.upsert(job)

    try await fixture.api.performCleanup()

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    let updated = try XCTUnwrap(fixture.store.readJob(id: "remote-unreachable"))
    XCTAssertEqual(updated["waitingCleanup"] as? Bool, true)
    XCTAssertNil(updated["localDeletedAt"])
    XCTAssertEqual(
      updated["errorMessage"] as? String,
      "暂时无法向电脑确认备份，已保留本地录像"
    )
  }

  func testStorageReclaimKeepsLegacyJobWithoutContentSha256() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-missing-sha",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "unexpected-receipt" }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job.removeValue(forKey: "contentSha256")
    try fixture.store.upsert(job)

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    XCTAssertNil(
      try fixture.store.readJob(id: "storage-reclaim-missing-sha")?["localDeletedAt"]
    )
  }

  func testStorageReclaimDoesNotEmitSnapshotWhenJobsStayUnchanged() async throws {
    let emitted = expectation(description: "未变更任务不推送快照")
    emitted.isInverted = true
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-no-change",
      availableStorageBytesOverride: { 4 * 1024 * 1024 * 1024 },
      onSnapshot: { _ in emitted.fulfill() }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedStorageReclaimJob(fixture.job))

    _ = try await awaitStorageReclaim(fixture.api)

    await fulfillment(of: [emitted], timeout: 0.5)
  }

  func testAvailableRecordingStorageBytesReadsRecordingVolumeWithoutReclaim() async throws {
    let expected: Int64 = 3 * 1024 * 1024 * 1024
    let fixture = try makeRetentionCleanupFixture(
      id: "available-recording-storage",
      availableStorageBytesOverride: { expected }
    )
    defer { removeRetentionCleanupFixture(fixture) }

    let available = try await awaitAvailableRecordingStorageBytes(fixture.api)

    XCTAssertEqual(available, expected)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
  }

  func testStorageReclaimEmitsSnapshotWhenJobErrorChanges() async throws {
    let emitted = expectation(description: "任务错误变化后推送快照")
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-error-change",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "unexpected-receipt" },
      onSnapshot: { _ in emitted.fulfill() }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job["contentSha256"] = String(repeating: "f", count: 64)
    try fixture.store.upsert(job)

    _ = try await awaitStorageReclaim(fixture.api)

    await fulfillment(of: [emitted], timeout: 2)
  }

  func testStorageReclaimKeepsFileWhenContentSha256Mismatches() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-sha-mismatch",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "unexpected-receipt" }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job["contentSha256"] = String(repeating: "f", count: 64)
    try fixture.store.upsert(job)

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    let updated = try XCTUnwrap(fixture.store.readJob(id: "storage-reclaim-sha-mismatch"))
    XCTAssertNil(updated["localDeletedAt"])
    XCTAssertEqual(
      updated["errorMessage"] as? String,
      "录像文件已被替换，已取消空间清理"
    )
  }

  func testStorageReclaimKeepsMixedSessionJob() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-mixed-sessions",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "unexpected-receipt" }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job["sessions"] = [["id": "first"], ["id": "second"]]
    try fixture.store.upsert(job)

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    XCTAssertNil(
      try fixture.store.readJob(id: "storage-reclaim-mixed-sessions")?["localDeletedAt"]
    )
  }

  func testStorageReclaimKeepsFileWhenRemoteEvidenceIsInvalid() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-invalid-evidence",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in nil }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job["verificationReceipt"] = "forged-receipt"
    try fixture.store.upsert(job)

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    let updated = try XCTUnwrap(fixture.store.readJob(id: "storage-reclaim-invalid-evidence"))
    XCTAssertNil(updated["localDeletedAt"])
    XCTAssertEqual(
      updated["errorMessage"] as? String,
      "暂时无法向电脑确认备份，已保留本地录像"
    )
  }

  func testStorageReclaimDeletesOnlyAfterFreshRemoteAttestation() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-confirmed",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "fresh-signed-receipt" }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedStorageReclaimJob(fixture.job))

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertEqual(result["deletedCount"] as? Int, 1)
    let updated = try XCTUnwrap(fixture.store.readJob(id: "storage-reclaim-confirmed"))
    XCTAssertNotNil(updated["localDeletedAt"])
    XCTAssertEqual(updated["verificationReceipt"] as? String, "fresh-signed-receipt")
  }

  func testStorageReclaimRenewsExpiredComputerConfirmation() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-expired-confirmation",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "renewed-signed-receipt" }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    let expiredAttestedAt = ISO8601DateFormatter().string(
      from: Date().addingTimeInterval(-3_600)
    )
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job["lastAttestedAt"] = expiredAttestedAt
    try fixture.store.upsert(job)

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertEqual(result["deletedCount"] as? Int, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    let updated = try XCTUnwrap(
      fixture.store.readJob(id: "storage-reclaim-expired-confirmation")
    )
    XCTAssertNotNil(updated["localDeletedAt"])
    XCTAssertEqual(updated["verificationReceipt"] as? String, "renewed-signed-receipt")
    XCTAssertNotEqual(updated["lastAttestedAt"] as? String, expiredAttestedAt)
  }

  func testStorageReclaimStopsConfirmingAfterComputerIsUnreachable() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-unreachable",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in nil }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    let expiredAttestedAt = ISO8601DateFormatter().string(
      from: Date().addingTimeInterval(-3_600)
    )
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job["lastAttestedAt"] = expiredAttestedAt
    try fixture.store.upsert(job)
    let secondFile = try addVerifiedStorageReclaimJob(
      fixture,
      id: "storage-reclaim-unreachable-2",
      lastAttestedAt: expiredAttestedAt
    )

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))
    let messages = [
      try XCTUnwrap(fixture.store.readJob(id: "storage-reclaim-unreachable")),
      try XCTUnwrap(fixture.store.readJob(id: "storage-reclaim-unreachable-2")),
    ].compactMap { $0["errorMessage"] as? String }
    XCTAssertEqual(messages, ["暂时无法向电脑确认备份，已保留本地录像"])
  }

  func testStorageReclaimConfirmationAttemptsAreBoundedPerRun() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-bounded",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "renewed-signed-receipt" },
      storageReclaimConfirmationLimitOverride: 1
    )
    defer { removeRetentionCleanupFixture(fixture) }
    let expiredAttestedAt = ISO8601DateFormatter().string(
      from: Date().addingTimeInterval(-3_600)
    )
    var job = makeVerifiedStorageReclaimJob(fixture.job)
    job["lastAttestedAt"] = expiredAttestedAt
    try fixture.store.upsert(job)
    let secondFile = try addVerifiedStorageReclaimJob(
      fixture,
      id: "storage-reclaim-bounded-2",
      lastAttestedAt: expiredAttestedAt
    )

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertEqual(result["deletedCount"] as? Int, 1)
    let remaining = [fixture.file, secondFile].filter {
      FileManager.default.fileExists(atPath: $0.path)
    }
    XCTAssertEqual(remaining.count, 1)
  }

  func testStorageReclaimFollowsPolicyPushedFromDart() async throws {
    let availableBytes: Int64 = 1536 * 1024 * 1024
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-pushed-policy",
      availableStorageBytesOverride: { availableBytes }
    )
    defer { removeRetentionCleanupFixture(fixture) }

    // 未下发策略时使用兜底阈值（2GB），1.5GB 判为空间不足。
    let fallbackResult = try await awaitStorageReclaim(fixture.api)
    XCTAssertEqual(fallbackResult["insufficient"] as? Bool, true)
    XCTAssertEqual(fallbackResult["warning"] as? Bool, true)

    _ = try await withCheckedThrowingContinuation { continuation in
      fixture.api.initialize(
        request: [
          "autoEnabled": false,
          "storageMinimumBytes": 1 * 1024 * 1024 * 1024,
          "storageWarningBytes": 1 * 1024 * 1024 * 1024 + 1,
          "storageTargetBytes": 1 * 1024 * 1024 * 1024 + 1,
        ]
      ) { result in
        continuation.resume(with: result)
      }
    }

    // 阈值改由下发值决定后，同一剩余空间不再算不足。
    let pushedResult = try await awaitStorageReclaim(fixture.api)
    XCTAssertEqual(pushedResult["insufficient"] as? Bool, false)
    XCTAssertEqual(pushedResult["warning"] as? Bool, false)
  }

  func testStorageReclaimReconcilesDeletionCommittedBeforeJobTransaction()
    async throws
  {
    let fixture = try makeRetentionCleanupFixture(
      id: "storage-reclaim-interrupted-after-delete",
      availableStorageBytesOverride: { 0 }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedStorageReclaimJob(fixture.job))
    try FileManager.default.removeItem(at: fixture.file)

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    XCTAssertEqual(result["freedBytes"] as? Int64, 0)
    let updated = try XCTUnwrap(
      fixture.store.readJob(id: "storage-reclaim-interrupted-after-delete")
    )
    XCTAssertNotNil(updated["localDeletedAt"])
    XCTAssertEqual(updated["cleanupReason"] as? String, "存储空间不足提前清理")
    let events = try fixture.store.cleanupEvents(afterRevision: 0, limit: 10).events
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?["jobId"] as? String, updated["id"] as? String)
  }

  func testRetentionCleanupRejectsRetryThatWinsBeforeIntentClaim() async throws {
    var fixture: RetentionCleanupFixture!
    fixture = try makeRetentionCleanupFixture(
      id: "cleanup-retry-before-claim",
      beforeCleanupIntentClaimForTesting: { job in
        _ = try? fixture.store.updateJob(id: job["id"] as? String ?? "") { current in
          current["generation"] = "retry-generation"
          current["state"] = "pending"
        }
      }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedRetentionCleanupJob(fixture.job))

    try await fixture.api.performCleanup()

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    let current = try XCTUnwrap(fixture.store.readJob(id: "cleanup-retry-before-claim"))
    XCTAssertEqual(current["generation"] as? String, "retry-generation")
    XCTAssertEqual(current["state"] as? String, "pending")
    XCTAssertNil(current["localDeletedAt"])
  }

  func testRetentionCleanupNeverClaimsUploadingJob() async throws {
    let fixture = try makeRetentionCleanupFixture(id: "cleanup-uploading")
    defer { removeRetentionCleanupFixture(fixture) }
    var job = fixture.job
    job["state"] = "uploading"
    try fixture.store.upsert(job)

    try await fixture.api.performCleanup()

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertNil(try fixture.store.readJob(id: "cleanup-uploading")?["localDeletedAt"])
  }

  func testRetentionCleanupRejectsSameSizeAndMtimePathReplacement() async throws {
    var fixture: RetentionCleanupFixture!
    fixture = try makeRetentionCleanupFixture(
      id: "cleanup-same-stat-replacement",
      beforeCleanupIntentClaimForTesting: { _ in
        let original = try? Data(contentsOf: fixture.file)
        let attributes = try? FileManager.default.attributesOfItem(
          atPath: fixture.file.path
        )
        let modified = attributes?[.modificationDate] as? Date
        var replacement = original ?? Data()
        if !replacement.isEmpty { replacement[0] ^= 0xff }
        try? FileManager.default.removeItem(at: fixture.file)
        try? replacement.write(to: fixture.file)
        if let modified {
          try? FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: fixture.file.path
          )
        }
        let replacedSnapshot = try? IosBackupFileSnapshot.read(from: fixture.file)
        XCTAssertEqual(replacedSnapshot?.byteCount, fixture.job["totalBytes"] as? Int64)
        XCTAssertEqual(
          replacedSnapshot?.modifiedAtMilliseconds,
          fixture.job["lastModified"] as? Int64
        )
        XCTAssertNotEqual(replacement, original)
      }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedRetentionCleanupJob(fixture.job))

    try await fixture.api.performCleanup()

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertEqual(
      try Data(contentsOf: fixture.file).count,
      (fixture.job["totalBytes"] as? Int64).map(Int.init)
    )
    XCTAssertNil(
      try fixture.store.readJob(id: "cleanup-same-stat-replacement")?["localDeletedAt"]
    )
  }

  func testRetentionCleanupRejectsInPlaceMutationAfterHash() async throws {
    var fixture: RetentionCleanupFixture!
    fixture = try makeRetentionCleanupFixture(
      id: "cleanup-in-place-mutation",
      beforeCleanupIntentClaimForTesting: { _ in
        if let handle = try? FileHandle(forWritingTo: fixture.file) {
          _ = try? handle.seekToEnd()
          try? handle.write(contentsOf: Data("changed-after-hash".utf8))
          try? handle.close()
        }
      }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedRetentionCleanupJob(fixture.job))

    try await fixture.api.performCleanup()

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertGreaterThan(
      try Data(contentsOf: fixture.file).count,
      Int(fixture.job["totalBytes"] as? Int64 ?? 0)
    )
    XCTAssertNil(
      try fixture.store.readJob(id: "cleanup-in-place-mutation")?["localDeletedAt"]
    )
  }

  func testCleanupRecoversRenameCrashAndEmitsExactlyOneEvent() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "cleanup-rename-crash",
      afterCleanupRenameForTesting: { _ in throw MaintenanceTestError.expected }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedRetentionCleanupJob(fixture.job))

    do {
      try await fixture.api.performCleanup()
      XCTFail("rename 后注入崩溃必须中断提交")
    } catch {
      // broad-catch: 测试在下方断言注入错误的具体类型
      XCTAssertTrue(error is MaintenanceTestError)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    XCTAssertNil(try fixture.store.readJob(id: "cleanup-rename-crash")?["localDeletedAt"])

    let recoveredApi = makeBackupApi(
      defaults: fixture.defaults, store: fixture.store,
      cleanupConfigured: nil,
      recordingsRoot: fixture.root.appendingPathComponent("recordings")
    )
    try await recoveredApi.performCleanup()
    try await recoveredApi.performCleanup()

    XCTAssertNotNil(try fixture.store.readJob(id: "cleanup-rename-crash")?["localDeletedAt"])
    let events = try fixture.store.cleanupEvents(afterRevision: 0, limit: 10).events
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?["jobId"] as? String, "cleanup-rename-crash")
  }

  func testCleanupRecoveryPreservesBothPathsConflict() async throws {
    var fixture: RetentionCleanupFixture!
    fixture = try makeRetentionCleanupFixture(
      id: "cleanup-both-paths",
      afterCleanupRenameForTesting: { intent in
        try Data("new-recording-must-survive".utf8).write(
          to: URL(fileURLWithPath: intent.originalPath)
        )
        throw MaintenanceTestError.expected
      }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedRetentionCleanupJob(fixture.job))
    try? await fixture.api.performCleanup()

    let recoveredApi = makeBackupApi(
      defaults: fixture.defaults, store: fixture.store,
      recordingsRoot: fixture.root.appendingPathComponent("recordings")
    )
    try await recoveredApi.performCleanup()

    XCTAssertEqual(
      try Data(contentsOf: fixture.file), Data("new-recording-must-survive".utf8)
    )
    XCTAssertNil(try fixture.store.readJob(id: "cleanup-both-paths")?["localDeletedAt"])
    let intent = try XCTUnwrap(fixture.store.cleanupIntents().first)
    XCTAssertEqual(intent.phase, "conflict")
  }

  func testRenamedRecoveryNeverCommitsWhenOriginalPathReappears() async throws {
    var fixture: RetentionCleanupFixture!
    fixture = try makeRetentionCleanupFixture(
      id: "cleanup-renamed-original-only",
      afterCleanupRenameForTesting: { intent in
        try FileManager.default.removeItem(
          at: URL(fileURLWithPath: intent.tombstonePath)
        )
        try Data("replacement-recording".utf8).write(
          to: URL(fileURLWithPath: intent.originalPath)
        )
        throw MaintenanceTestError.expected
      }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedRetentionCleanupJob(fixture.job))
    try? await fixture.api.performCleanup()

    let recoveredApi = makeBackupApi(
      defaults: fixture.defaults, store: fixture.store,
      recordingsRoot: fixture.root.appendingPathComponent("recordings")
    )
    try await recoveredApi.performCleanup()

    XCTAssertEqual(
      try Data(contentsOf: fixture.file), Data("replacement-recording".utf8)
    )
    XCTAssertNil(
      try fixture.store.readJob(id: "cleanup-renamed-original-only")?["localDeletedAt"]
    )
    XCTAssertEqual(try fixture.store.cleanupIntents().first?.phase, "conflict")
  }

  func testMovingIntentRejectsGenerationChange() async throws {
    var fixture: RetentionCleanupFixture!
    var rejected = false
    var enqueueError: Error?
    fixture = try makeRetentionCleanupFixture(
      id: "cleanup-moving-generation",
      beforeCleanupRenameForTesting: { _ in
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        do {
          _ = try fixture.store.updateJob(id: "cleanup-moving-generation") {
            $0["generation"] = "must-not-win"
            $0["state"] = "pending"
          }
        } catch {
          // broad-catch: 并发压力测试只记录事务是否按预期被拒绝
          rejected = true
        }
        fixture.api.enqueueJob(
          request: [
            "id": "different-job-same-path",
            "filePath": fixture.file.path,
            "sessions": [["id": "different-session"]],
            "startUpload": false,
          ]
        ) { result in
          if case .failure(let error) = result { enqueueError = error }
        }
        throw MaintenanceTestError.expected
      }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedRetentionCleanupJob(fixture.job))

    try? await fixture.api.performCleanup()

    XCTAssertTrue(rejected)
    XCTAssertEqual((enqueueError as? IosBackupStoreError)?.code, SQLITE_BUSY)
    XCTAssertNil(try fixture.store.readJob(id: "different-job-same-path"))
    XCTAssertEqual(
      try fixture.store.readJob(id: "cleanup-moving-generation")?["generation"] as? String,
      fixture.job["generation"] as? String
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    let recoveredApi = makeBackupApi(
      defaults: fixture.defaults, store: fixture.store,
      recordingsRoot: fixture.root.appendingPathComponent("recordings")
    )
    try await recoveredApi.performCleanup()
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
  }

  func testCleanupRecoversCommitBeforeTombstoneUnlinkExactlyOnce() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "cleanup-commit-crash",
      afterCleanupCommitForTesting: { _ in throw MaintenanceTestError.expected }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedRetentionCleanupJob(fixture.job))
    try? await fixture.api.performCleanup()

    XCTAssertNotNil(try fixture.store.readJob(id: "cleanup-commit-crash")?["localDeletedAt"])
    XCTAssertEqual(try fixture.store.cleanupEvents(afterRevision: 0, limit: 10).events.count, 1)
    XCTAssertEqual(try fixture.store.cleanupIntents().first?.phase, "committed")

    let recoveredApi = makeBackupApi(
      defaults: fixture.defaults, store: fixture.store,
      recordingsRoot: fixture.root.appendingPathComponent("recordings")
    )
    try await recoveredApi.performCleanup()
    try await recoveredApi.performCleanup()

    XCTAssertTrue(try fixture.store.cleanupIntents().isEmpty)
    XCTAssertEqual(try fixture.store.cleanupEvents(afterRevision: 0, limit: 10).events.count, 1)
  }

  func testStorageReclaimRejectsRetryBeforeIntentClaim() async throws {
    var fixture: RetentionCleanupFixture!
    fixture = try makeRetentionCleanupFixture(
      id: "storage-retry-before-claim",
      availableStorageBytesOverride: { 0 },
      storageAttestationOverride: { _, _, _ in "fresh-signed-receipt" },
      beforeCleanupIntentClaimForTesting: { job in
        _ = try? fixture.store.updateJob(id: job["id"] as? String ?? "") { current in
          current["generation"] = "storage-retry-generation"
          current["state"] = "pending"
        }
      }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    try fixture.store.upsert(makeVerifiedStorageReclaimJob(fixture.job))

    let result = try await awaitStorageReclaim(fixture.api)

    XCTAssertEqual(result["deletedCount"] as? Int, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    let current = try XCTUnwrap(fixture.store.readJob(id: "storage-retry-before-claim"))
    XCTAssertEqual(current["state"] as? String, "pending")
    XCTAssertNil(current["localDeletedAt"])
  }

  func testMaintenanceCoordinatorSerializesOneThousandMixedOperations()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      storageReclaimOperationOverride: {
        let invocation = await tracker.begin()
        await Task.yield()
        await tracker.finish()
        return ["invocation": invocation]
      },
      cleanupOperationOverride: {
        _ = await tracker.begin()
        await Task.yield()
        await tracker.finish()
      }
    )

    let completed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
      for index in 0..<1_000 {
        group.addTask {
          do {
            if index.isMultiple(of: 2) {
              let result: [String?: Any?] = try await withCheckedThrowingContinuation {
                continuation in
                api.reclaimStorageIfNeeded { continuation.resume(with: $0) }
              }
              return result["invocation"] is Int
            }
            try await api.performCleanup()
            return true
          } catch {
            // broad-catch: 竞态测试把任意清理错误折叠为失败结果后统一断言
            return false
          }
        }
      }
      var count = 0
      for await succeeded in group where succeeded { count += 1 }
      return count
    }
    let counts = await tracker.counts()

    XCTAssertEqual(completed, 1_000)
    XCTAssertEqual(counts.started, 1_000)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testCleanupTriggerWhileRunningSchedulesASecondInvocation() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let hold = AsyncTestGate()
    let firstStarted = expectation(description: "首个清理任务已启动")
    let secondStarted = expectation(description: "运行中请求未丢失")
    let api = makeBackupApi(
      defaults: fixture.defaults, store: store,
      cleanupOperationOverride: {
        let invocation = await tracker.begin()
        if invocation == 1 {
          firstStarted.fulfill()
          await hold.wait()
        } else if invocation == 2 {
          secondStarted.fulfill()
        }
        await tracker.finish()
      }
    )

    api.initialize(request: [
      "unbackedRetentionDays": 30, "backedRetentionDays": 7,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    await fulfillment(of: [firstStarted], timeout: 2)
    api.updateRetentionSchedule(request: [
      "unbackedRetentionDays": 31, "backedRetentionDays": 8,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    await hold.open()
    await fulfillment(of: [secondStarted], timeout: 2)
    let counts = await tracker.counts()
    XCTAssertGreaterThanOrEqual(counts.started, 2)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testCleanupRunnerPausesDuringRecordingAndResumesAutomatically() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let activity = IosRecordingActivityState()
    let owner = UUID()
    let tracker = AsyncMaintenanceTracker()
    let resumed = expectation(description: "工作结束后清理自动恢复")
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      cleanupOperationOverride: {
        _ = await tracker.begin()
        await tracker.finish()
        resumed.fulfill()
      },
      recordingActivityState: activity,
      cleanupWorkPauseNanoseconds: 5_000_000,
      cleanupSliceIntervalNanoseconds: 1_000_000
    )
    activity.setActive(true, owner: owner)

    api.triggerCleanupForTesting()
    try await Task.sleep(nanoseconds: 50_000_000)
    let pausedCounts = await tracker.counts()
    XCTAssertEqual(pausedCounts.started, 0)

    activity.setActive(false, owner: owner)
    await fulfillment(of: [resumed], timeout: 2)
    let resumedCounts = await tracker.counts()
    XCTAssertEqual(resumedCounts.started, 1)
  }

  func testCleanupRunnerStaysIdleInBackgroundAndResumesOnForeground() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let resumed = expectation(description: "回到前台后补跑清理")
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      cleanupOperationOverride: {
        _ = await tracker.begin()
        await tracker.finish()
        resumed.fulfill()
      },
      cleanupWorkPauseNanoseconds: 5_000_000,
      cleanupSliceIntervalNanoseconds: 1_000_000,
      hostForeground: false
    )

    for _ in 0..<1_000 { api.triggerCleanupForTesting() }
    try await Task.sleep(nanoseconds: 50_000_000)
    let backgroundCounts = await tracker.counts()
    XCTAssertEqual(backgroundCounts.started, 0)

    api.onHostForeground()
    await fulfillment(of: [resumed], timeout: 2)
    let foregroundCounts = await tracker.counts()
    XCTAssertEqual(foregroundCounts.started, 1)
    XCTAssertEqual(foregroundCounts.maximumActive, 1)
  }

  func testRunningCleanupRunnerStopsAfterEnteringBackground() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let backgrounded = expectation(description: "清理进行中切到后台")
    final class ApiBox: @unchecked Sendable { weak var api: IosBackupHostApi? }
    let box = ApiBox()
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      cleanupOperationOverride: {
        _ = await tracker.begin()
        await tracker.finish()
        // 持续请求下一片，若不按前台状态收敛 runner 就会一直轮询下去
        box.api?.triggerCleanupForTesting()
        if await tracker.counts().started == 1 {
          box.api?.onHostBackground()
          backgrounded.fulfill()
        }
      },
      cleanupWorkPauseNanoseconds: 5_000_000,
      cleanupSliceIntervalNanoseconds: 1_000_000
    )
    box.api = api

    api.triggerCleanupForTesting()
    await fulfillment(of: [backgrounded], timeout: 2)
    try await Task.sleep(nanoseconds: 100_000_000)
    let counts = await tracker.counts()
    XCTAssertLessThanOrEqual(counts.started, 2)
  }

  func testUnconfiguredBackupSkipsTenThousandCleanupAndSummaryTriggers()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      cleanupOperationOverride: {
        _ = await tracker.begin()
        await tracker.finish()
      },
      cleanupConfigured: nil
    )

    api.initialize(request: [
      "unbackedRetentionDays": 30, "backedRetentionDays": 7,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    for index in 0..<10_000 {
      if index.isMultiple(of: 2) {
        api.triggerCleanupForTesting()
      } else {
        api.summary { result in
          if case .failure(let error) = result { XCTFail(error.localizedDescription) }
        }
      }
    }
    try await Task.sleep(nanoseconds: 100_000_000)

    let counts = await tracker.counts()
    XCTAssertEqual(counts.started, 0)
    api.drainSummaryQueueForTesting()
  }

  func testTenThousandCleanupTriggersDuringRecordingSharePausedRunner()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let activity = IosRecordingActivityState()
    let owner = UUID()
    let tracker = AsyncMaintenanceTracker()
    let resumed = expectation(description: "暂停 runner 恢复并合并触发")
    resumed.expectedFulfillmentCount = 2
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      cleanupOperationOverride: {
        _ = await tracker.begin()
        await tracker.finish()
        resumed.fulfill()
      },
      recordingActivityState: activity,
      cleanupWorkPauseNanoseconds: 5_000_000,
      cleanupSliceIntervalNanoseconds: 1_000_000
    )
    activity.setActive(true, owner: owner)

    for _ in 0..<10_000 { api.triggerCleanupForTesting() }
    try await Task.sleep(nanoseconds: 50_000_000)
    let pausedCounts = await tracker.counts()
    XCTAssertEqual(pausedCounts.started, 0)

    activity.setActive(false, owner: owner)
    await fulfillment(of: [resumed], timeout: 2)
    try await Task.sleep(nanoseconds: 50_000_000)
    let counts = await tracker.counts()
    XCTAssertEqual(counts.started, 2)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testCleanupStartingBeforeRecordingDoesNotAdvancePastUnprocessedJobs()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    for id in ["mid-slice-001", "mid-slice-002"] {
      var job = makeBackupJob(id: id)
      job["state"] = "paused"
      try store.upsert(job)
    }
    let activity = IosRecordingActivityState()
    let owner = UUID()
    let firstCandidateEntered = expectation(description: "清理已进入首个候选")
    let hookCount = LockedTestCounter()
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      recordingActivityState: activity,
      cleanupWorkPauseNanoseconds: 5_000_000,
      cleanupSliceIntervalNanoseconds: 1_000_000,
      beforeCleanupCandidateForTesting: { _ in
        let isFirst = hookCount.increment() == 1
        if isFirst {
          activity.setActive(true, owner: owner)
          firstCandidateEntered.fulfill()
        }
      }
    )

    api.initialize(request: [
      "unbackedRetentionDays": 30, "backedRetentionDays": 7,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    await fulfillment(of: [firstCandidateEntered], timeout: 2)
    try await Task.sleep(nanoseconds: 50_000_000)

    let persisted = try store.cleanupCandidateJobsSlice(
      unbackedRetentionDays: 30, backedRetentionDays: 7
    )
    XCTAssertEqual(
      persisted.jobs.compactMap { $0["id"] as? String },
      ["mid-slice-001", "mid-slice-002"]
    )
    XCTAssertEqual(hookCount.value, 1)
    activity.setActive(false, owner: owner)
  }

  func testCleanupDispatcherRetriesOneFailureThenStopsAfterSuccess() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let retrySucceeded = expectation(description: "首次异常后自动续跑成功")
    let unexpectedExtraRun = expectation(description: "成功后不得无限续跑")
    unexpectedExtraRun.isInverted = true
    let api = makeBackupApi(
      defaults: fixture.defaults, store: store,
      cleanupOperationOverride: {
        let invocation = await tracker.begin()
        await tracker.finish()
        if invocation == 1 { throw MaintenanceTestError.expected }
        if invocation == 2 {
          retrySucceeded.fulfill()
        } else {
          unexpectedExtraRun.fulfill()
        }
      }
    )

    api.initialize(request: [
      "unbackedRetentionDays": 30, "backedRetentionDays": 7,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    await fulfillment(of: [retrySucceeded], timeout: 3)
    await fulfillment(of: [unexpectedExtraRun], timeout: 0.3)
    let counts = await tracker.counts()
    XCTAssertEqual(counts.started, 2)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testCleanupTriggersDuringBackoffShareOneRunnerAndCollapseToOneHandoff()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let firstFailed = expectation(description: "首轮失败并进入退避")
    let retrySucceeded = expectation(description: "单一 runner 完成退避重试")
    let stickyHandoffFinished = expectation(description: "多次触发合并为一次 handoff")
    let unexpectedFourth = expectation(description: "不得创建额外 runner 或 sleeper")
    unexpectedFourth.isInverted = true
    let api = makeBackupApi(
      defaults: fixture.defaults, store: store,
      cleanupOperationOverride: {
        let invocation = await tracker.begin()
        await tracker.finish()
        switch invocation {
        case 1:
          firstFailed.fulfill()
          throw MaintenanceTestError.expected
        case 2: retrySucceeded.fulfill()
        case 3: stickyHandoffFinished.fulfill()
        default: unexpectedFourth.fulfill()
        }
      },
      cleanupRetryDelaysNanoseconds: [1_000_000_000]
    )

    api.initialize(request: [
      "unbackedRetentionDays": 30, "backedRetentionDays": 7,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    await fulfillment(of: [firstFailed], timeout: 2)
    for index in 0..<20 {
      api.updateRetentionSchedule(request: [
        "unbackedRetentionDays": 31 + index,
        "backedRetentionDays": 8 + index,
      ]) { result in
        if case .failure(let error) = result { XCTFail(error.localizedDescription) }
      }
    }

    await fulfillment(of: [retrySucceeded, stickyHandoffFinished], timeout: 3)
    await fulfillment(of: [unexpectedFourth], timeout: 0.3)
    let counts = await tracker.counts()
    XCTAssertEqual(counts.started, 3)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testCleanupDispatcherStopsAfterInitialFailureAndFiveBackoffRetries()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let sixthFailure = expectation(description: "初始执行加五次退避重试")
    let unexpectedSeventh = expectation(description: "第六次失败后必须停止")
    unexpectedSeventh.isInverted = true
    let scaledRetryDelays = [1, 2, 4, 8, 16].map { UInt64($0) * 1_000_000 }
    let api = makeBackupApi(
      defaults: fixture.defaults, store: store,
      cleanupOperationOverride: {
        let invocation = await tracker.begin()
        await tracker.finish()
        if invocation == 6 {
          sixthFailure.fulfill()
        } else if invocation > 6 {
          unexpectedSeventh.fulfill()
        }
        throw MaintenanceTestError.expected
      },
      cleanupRetryDelaysNanoseconds: scaledRetryDelays
    )

    api.initialize(request: [
      "unbackedRetentionDays": 30, "backedRetentionDays": 7,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    await fulfillment(of: [sixthFailure], timeout: 2)
    await fulfillment(of: [unexpectedSeventh], timeout: 0.2)
    let counts = await tracker.counts()
    XCTAssertEqual(counts.started, 6)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testCleanupSuccessInvalidatesFailedAttemptSleeperAndToken() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let retrySucceeded = expectation(description: "退避后的唯一重试成功")
    let staleWakeup = expectation(description: "旧 sleeper 或 token 不得再次唤醒")
    staleWakeup.isInverted = true
    let api = makeBackupApi(
      defaults: fixture.defaults, store: store,
      cleanupOperationOverride: {
        let invocation = await tracker.begin()
        await tracker.finish()
        if invocation == 1 { throw MaintenanceTestError.expected }
        if invocation == 2 {
          retrySucceeded.fulfill()
        } else {
          staleWakeup.fulfill()
        }
      },
      cleanupRetryDelaysNanoseconds: [100_000_000]
    )

    api.initialize(request: [
      "unbackedRetentionDays": 30, "backedRetentionDays": 7,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    await fulfillment(of: [retrySucceeded], timeout: 2)
    await fulfillment(of: [staleWakeup], timeout: 0.3)
    let counts = await tracker.counts()
    XCTAssertEqual(counts.started, 2)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testCleanupTriggerAtSuccessfulStopDecisionIsNotLost() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let decisionReached = expectation(description: "首轮成功后已完成停止决策")
    let secondFinished = expectation(description: "决策点触发的清理未丢失")
    let unexpectedThird = expectation(description: "不得创建第三个 runner")
    unexpectedThird.isInverted = true
    let allowDecision = DispatchSemaphore(value: 0)
    let hookLock = NSLock()
    var blockedFirstDecision = false
    let api = makeBackupApi(
      defaults: fixture.defaults, store: store,
      cleanupOperationOverride: {
        let invocation = await tracker.begin()
        await tracker.finish()
        if invocation == 2 {
          secondFinished.fulfill()
        } else if invocation > 2 {
          unexpectedThird.fulfill()
        }
      },
      afterCleanupRunnerDecisionForTesting: {
        hookLock.lock()
        let shouldBlock = !blockedFirstDecision
        blockedFirstDecision = true
        hookLock.unlock()
        guard shouldBlock else { return }
        decisionReached.fulfill()
        allowDecision.wait()
      }
    )
    defer { allowDecision.signal() }

    api.initialize(request: [
      "unbackedRetentionDays": 30, "backedRetentionDays": 7,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    await fulfillment(of: [decisionReached], timeout: 2)
    api.updateRetentionSchedule(request: [
      "unbackedRetentionDays": 31, "backedRetentionDays": 8,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    allowDecision.signal()

    await fulfillment(of: [secondFinished], timeout: 2)
    await fulfillment(of: [unexpectedThird], timeout: 0.2)
    let counts = await tracker.counts()
    XCTAssertEqual(counts.started, 2)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testCleanupTriggerAtRetryLimitStopDecisionIsNotLost() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let decisionReached = expectation(description: "失败后已完成重试耗尽决策")
    let handoffFinished = expectation(description: "耗尽临界点触发的新 runner 已完成")
    let unexpectedThird = expectation(description: "重试耗尽不得创建额外 runner")
    unexpectedThird.isInverted = true
    let allowDecision = DispatchSemaphore(value: 0)
    let hookLock = NSLock()
    var blockedFirstDecision = false
    let api = makeBackupApi(
      defaults: fixture.defaults, store: store,
      cleanupOperationOverride: {
        let invocation = await tracker.begin()
        await tracker.finish()
        if invocation == 1 {
          throw MaintenanceTestError.expected
        } else if invocation == 2 {
          handoffFinished.fulfill()
        } else {
          unexpectedThird.fulfill()
        }
      },
      cleanupRetryDelaysNanoseconds: [],
      afterCleanupRunnerDecisionForTesting: {
        hookLock.lock()
        let shouldBlock = !blockedFirstDecision
        blockedFirstDecision = true
        hookLock.unlock()
        guard shouldBlock else { return }
        decisionReached.fulfill()
        allowDecision.wait()
      }
    )
    defer { allowDecision.signal() }

    api.initialize(request: [
      "unbackedRetentionDays": 30, "backedRetentionDays": 7,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    await fulfillment(of: [decisionReached], timeout: 2)
    api.updateRetentionSchedule(request: [
      "unbackedRetentionDays": 31, "backedRetentionDays": 8,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    allowDecision.signal()

    await fulfillment(of: [handoffFinished], timeout: 2)
    await fulfillment(of: [unexpectedThird], timeout: 0.2)
    let counts = await tracker.counts()
    XCTAssertEqual(counts.started, 2)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testCleanupRetrySleeperDoesNotRetainReleasedApi() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let retrySleepReached = expectation(description: "首次失败已进入长退避")
    var api: IosBackupHostApi? = makeBackupApi(
      defaults: fixture.defaults, store: store,
      cleanupOperationOverride: {
        _ = await tracker.begin()
        await tracker.finish()
        throw MaintenanceTestError.expected
      },
      cleanupRetryDelaysNanoseconds: [5_000_000_000],
      beforeCleanupRetrySleepForTesting: { attempt, delay in
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(delay, 5_000_000_000)
        retrySleepReached.fulfill()
      }
    )
    weak var weakApi = api

    api?.initialize(request: [
      "unbackedRetentionDays": 30, "backedRetentionDays": 7,
    ]) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
    }
    await fulfillment(of: [retrySleepReached], timeout: 2)
    api = nil

    for _ in 0..<50 where weakApi != nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNil(weakApi, "退避 sleeper 不应持有 API 的唯一强引用")
    try await Task.sleep(nanoseconds: 150_000_000)
    let counts = await tracker.counts()
    XCTAssertEqual(counts.started, 1)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testMaintenanceCoordinatorPropagatesReclaimAndCleanupErrors()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      storageReclaimOperationOverride: {
        throw MaintenanceTestError.expected
      },
      cleanupOperationOverride: {
        throw MaintenanceTestError.expected
      }
    )

    do {
      _ = try await awaitStorageReclaim(api)
      XCTFail("空间回收错误不得伪装成功")
    } catch {
      // broad-catch: 测试在下方断言注入错误的具体类型
      XCTAssertTrue(error is MaintenanceTestError)
    }
    do {
      try await api.performCleanup()
      XCTFail("保留策略清理错误不得伪装成功")
    } catch {
      // broad-catch: 测试在下方断言注入错误的具体类型
      XCTAssertTrue(error is MaintenanceTestError)
    }
  }

  func testCancelledMaintenanceWaiterReleasesQueueForFollowingOperation()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let tracker = AsyncMaintenanceTracker()
    let hold = AsyncTestGate()
    let firstStarted = expectation(description: "首个维护任务占用协调器")
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      cleanupOperationOverride: {
        let invocation = await tracker.begin()
        if invocation == 1 {
          firstStarted.fulfill()
          await hold.wait()
        }
        await tracker.finish()
      }
    )

    let first = Task { try await api.performCleanup() }
    await fulfillment(of: [firstStarted], timeout: 2)
    let cancelled = Task { try await api.performCleanup() }
    cancelled.cancel()
    await hold.open()
    try await first.value
    do {
      try await cancelled.value
      XCTFail("取消的等待任务不应执行维护操作")
    } catch {
      // broad-catch: 测试在下方断言任务取消的具体类型
      XCTAssertTrue(error is CancellationError)
    }

    try await api.performCleanup()
    let counts = await tracker.counts()
    XCTAssertEqual(counts.started, 2)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.maximumActive, 1)
  }

  func testCancelAndRequeueRejectOldUploadStateWrites() async throws {
    let fixture = try makeRetentionCleanupFixture(id: "generation-lifecycle")
    defer { removeRetentionCleanupFixture(fixture) }
    var job = fixture.job
    job["state"] = "uploading"
    let initialGeneration = try XCTUnwrap(job["generation"] as? String)
    try fixture.store.upsert(job)

    try await awaitVoidResult { completion in
      fixture.api.cancelJob(jobId: "generation-lifecycle", completion: completion)
    }
    let cancelled = try XCTUnwrap(fixture.store.readJob(id: "generation-lifecycle"))
    let cancelledGeneration = try XCTUnwrap(cancelled["generation"] as? String)
    XCTAssertNotEqual(cancelledGeneration, initialGeneration)
    XCTAssertEqual(cancelled["state"] as? String, "paused")
    XCTAssertFalse(
      try fixture.api.updateUploadJob(
        "generation-lifecycle",
        expectedGeneration: initialGeneration
      ) { current in
        current["state"] = "completed"
      }
    )
    let afterStaleCompletion = try fixture.store.readJob(id: "generation-lifecycle")
    XCTAssertEqual(
      afterStaleCompletion?["state"] as? String,
      "paused"
    )

    try await awaitVoidResult { completion in
      fixture.api.requeueJob(jobId: "generation-lifecycle", completion: completion)
    }
    let requeued = try XCTUnwrap(fixture.store.readJob(id: "generation-lifecycle"))
    let requeuedGeneration = try XCTUnwrap(requeued["generation"] as? String)
    XCTAssertNotEqual(requeuedGeneration, cancelledGeneration)
    XCTAssertEqual(requeued["state"] as? String, "pending")
    XCTAssertFalse(
      try fixture.api.updateUploadJob(
        "generation-lifecycle",
        expectedGeneration: cancelledGeneration
      ) { current in
        current["state"] = "paused"
        current["errorMessage"] = "旧任务失败"
      }
    )
    let current = try XCTUnwrap(fixture.store.readJob(id: "generation-lifecycle"))
    XCTAssertEqual(current["generation"] as? String, requeuedGeneration)
    XCTAssertEqual(current["state"] as? String, "pending")
    XCTAssertNil(current["errorMessage"])
  }

  func testEnqueueReplacesCallerProvidedGeneration() async throws {
    let fixture = try makeRetentionCleanupFixture(
      id: "generation-enqueue", autoEnabled: true
    )
    defer { removeRetentionCleanupFixture(fixture) }
    let request: [String?: Any?] = [
      "id": "generation-enqueue",
      "generation": "caller-provided-generation",
      "filePath": fixture.file.path,
      "lastModified": fixture.job["lastModified"],
      "sessions": fixture.job["sessions"],
      "startUpload": false,
    ]

    try await awaitVoidResult { completion in
      fixture.api.enqueueJob(request: request, completion: completion)
    }

    let current = try XCTUnwrap(fixture.store.readJob(id: "generation-enqueue"))
    XCTAssertNotEqual(
      current["generation"] as? String,
      "caller-provided-generation"
    )
    XCTAssertFalse((current["generation"] as? String)?.isEmpty ?? true)
    XCTAssertEqual(current["state"] as? String, "pending")
  }

  func testRetentionRegistrationDoesNotStartUploadAndEmitsSummary() async throws {
    let emitted = expectation(description: "登记后推送固定摘要")
    let fixture = try makeRetentionCleanupFixture(
      id: "retention-registration",
      autoEnabled: true,
      onSnapshot: { _ in emitted.fulfill() }
    )
    defer { removeRetentionCleanupFixture(fixture) }
    let request: [String?: Any?] = [
      "id": "retention-registration",
      "filePath": fixture.file.path,
      "lastModified": fixture.job["lastModified"],
      "sessions": fixture.job["sessions"],
      "startUpload": false,
    ]

    try await awaitVoidResult { completion in
      fixture.api.enqueueJob(request: request, completion: completion)
    }

    // 等的是真实快照回调，不是“不应发生”的反向期望：满负载跑全量套件时
    // 0.5 秒会偶发超时，期望一旦满足就立即返回，放宽超时不会拖慢用例。
    await fulfillment(of: [emitted], timeout: 5)
    let current = try XCTUnwrap(fixture.store.readJob(id: "retention-registration"))
    XCTAssertEqual(current["state"] as? String, "pending")
  }

  func testBackupSourceFailuresPersistStorageUnavailableState() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let api = makeBackupApi(defaults: fixture.defaults, store: store)

    func assertPersistedSourceFailure(
      id: String,
      error: Error,
      message: String
    ) throws {
      try store.upsert(makeBackupJob(id: id))
      XCTAssertEqual(
        api.handleUploadFailure(
          jobId: id,
          expectedGeneration: "generation-\(id)",
          error: error
        ),
        .persisted
      )
      let current = try XCTUnwrap(store.readJob(id: id))
      XCTAssertEqual(current["state"] as? String, "paused")
      XCTAssertEqual(current["failureKind"] as? String, "storage_unavailable")
      XCTAssertEqual(current["errorMessage"] as? String, message)
    }

    let missing = fixture.root.appendingPathComponent("missing.mp4")
    var missingError: Error?
    XCTAssertThrowsError(try IosBackupFileReader(url: missing)) {
      missingError = $0
    }
    try assertPersistedSourceFailure(
      id: "source-missing",
      error: try XCTUnwrap(missingError),
      message: "无法读取录像文件信息"
    )

    let replaced = fixture.root.appendingPathComponent("replaced.mp4")
    try Data(repeating: 1, count: 32).write(to: replaced)
    let replacedReader = try IosBackupFileReader(url: replaced)
    try Data(repeating: 2, count: 64).write(to: replaced)
    var replacedError: Error?
    XCTAssertThrowsError(try replacedReader.read(offset: 0, count: 8)) {
      replacedError = $0
    }
    try assertPersistedSourceFailure(
      id: "source-replaced",
      error: try XCTUnwrap(replacedError),
      message: "录像文件已被替换，已停止备份"
    )

    let unreadable = fixture.root.appendingPathComponent("unreadable.mp4")
    try Data(repeating: 3, count: 32).write(to: unreadable)
    let closedHandle = try FileHandle(forReadingFrom: unreadable)
    let unreadableReader = try IosBackupFileReader(
      url: unreadable,
      handleOverride: closedHandle
    )
    try closedHandle.close()
    var readError: Error?
    XCTAssertThrowsError(try unreadableReader.sha256()) {
      readError = $0
    }
    try assertPersistedSourceFailure(
      id: "source-read-failed",
      error: try XCTUnwrap(readError),
      message: "无法读取录像文件"
    )
  }

  func testUploadFailurePersistenceErrorIsReportedAndVisibleInSnapshot()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let id = "failure-persistence"
    try store.upsert(makeBackupJob(id: id))
    var reportedJobId: String?
    var reportedGeneration: String?
    var reportedError: Error?
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadFailureUpdateOverride: { _, _ in
        throw IosBackupStoreError(
          operation: "测试写入",
          code: 10,
          message: "只读数据库"
        )
      },
      uploadPersistenceFailureReporter: { jobId, generation, error in
        reportedJobId = jobId
        reportedGeneration = generation
        reportedError = error
      }
    )

    XCTAssertEqual(
      api.handleUploadFailure(
        jobId: id,
        expectedGeneration: "generation-\(id)",
        error: BackupSourceError(message: "录像文件不存在或为空")
      ),
      .persistenceFailed
    )
    XCTAssertEqual(reportedJobId, id)
    XCTAssertEqual(reportedGeneration, "generation-\(id)")
    XCTAssertTrue(reportedError is IosBackupStoreError)
    XCTAssertEqual(try store.readJob(id: id)?["state"] as? String, "pending")

    let summary = try await awaitSummaryResult(api)
    let visible = try XCTUnwrap(summary.problemJob)
    XCTAssertEqual(visible.state, "paused")
    XCTAssertEqual(visible.failureKind, "storage_unavailable")
    XCTAssertTrue(
      visible.errorMessage?.contains("任务状态写入失败") ?? false
    )
  }

  func testBackupSnapshotDoesNotReadCredentials() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let keychain = FakeIosKeychainClient()
    keychain.readError = IosBackupCredentialError(operation: "测试读取", status: -1)
    let api = IosBackupHostApi(
      eventApi: FakeBackupNativeEventApi(),
      defaults: fixture.defaults,
      credentialStore: IosBackupCredentialStore(
        defaults: fixture.defaults,
        keychain: keychain,
        service: "RunnerTests.snapshot-no-credential.\(UUID().uuidString)",
        account: "access-key"
      ),
      jobStore: .success(store),
      recordingsRoot: FileManager.default.temporaryDirectory
    )

    _ = try await awaitSummaryResult(api)
    XCTAssertEqual(keychain.readCount, 0)
  }

  func testBackupSnapshotCompletesOffMainThread() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let api = makeBackupApi(defaults: fixture.defaults, store: store)
    let completed = expectation(description: "后台生成备份快照")

    api.summary { result in
      if case .failure(let error) = result {
        XCTFail("生成备份快照失败：\(error)")
      }
      XCTAssertFalse(Thread.isMainThread)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 10)
  }

  func testBackupSnapshotEventIsBuiltAndSentOffMainThread() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let id = "background-snapshot-event"
    try store.upsert(makeBackupJob(id: id))
    let emitted = expectation(description: "后台推送备份快照")
    let eventApi = FakeBackupNativeEventApi { summary in
      XCTAssertFalse(Thread.isMainThread)
      XCTAssertEqual(summary.problemJob?.id, id)
      emitted.fulfill()
    }
    let api = IosBackupHostApi(
      eventApi: eventApi,
      defaults: fixture.defaults,
      credentialStore: IosBackupCredentialStore(
        defaults: fixture.defaults,
        keychain: FakeIosKeychainClient(),
        service: "RunnerTests.background-snapshot.\(UUID().uuidString)",
        account: "access-key"
      ),
      jobStore: .success(store),
      recordingsRoot: FileManager.default.temporaryDirectory
    )

    XCTAssertEqual(
      api.handleUploadFailure(
        jobId: id,
        expectedGeneration: "generation-\(id)",
        error: BackupSourceError(message: "测试失败")
      ),
      .persisted
    )
    wait(for: [emitted], timeout: 10)
  }

  func testTenThousandProgressEventsAreCoalescedLatestWins() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let emitted = expectation(description: "合并后的进度摘要")
    let countLock = NSLock()
    var count = 0
    let eventApi = FakeBackupNativeEventApi { _ in
      countLock.lock()
      count += 1
      let first = count == 1
      countLock.unlock()
      if first { emitted.fulfill() }
    }
    let api = IosBackupHostApi(
      eventApi: eventApi,
      defaults: fixture.defaults,
      credentialStore: IosBackupCredentialStore(
        defaults: fixture.defaults,
        keychain: FakeIosKeychainClient(),
        service: "RunnerTests.progress-summary.\(UUID().uuidString)",
        account: "access-key"
      ),
      jobStore: .success(store),
      recordingsRoot: FileManager.default.temporaryDirectory
    )

    for _ in 0..<10_000 { api.emitProgressSummaryForTesting() }
    wait(for: [emitted], timeout: 2)
    Thread.sleep(forTimeInterval: 1.2)

    countLock.lock()
    let delivered = count
    countLock.unlock()
    XCTAssertLessThanOrEqual(delivered, 2)
  }

  func testOldWorkerFailureCannotOverrideReplacementGeneration() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let id = "stale-failure-worker"
    var replacement = makeBackupJob(id: id)
    replacement["generation"] = "replacement-generation"
    try store.upsert(replacement)
    let api = makeBackupApi(defaults: fixture.defaults, store: store)

    XCTAssertEqual(
      api.handleUploadFailure(
        jobId: id,
        expectedGeneration: "old-generation",
        error: BackupSourceError(message: "录像文件已被替换，已停止备份")
      ),
      .staleGeneration
    )
    let stored = try XCTUnwrap(store.readJob(id: id))
    XCTAssertEqual(stored["generation"] as? String, "replacement-generation")
    XCTAssertEqual(stored["state"] as? String, "pending")
    XCTAssertNil(stored["errorMessage"])

    let summary = try await awaitSummaryResult(api)
    let visible = try XCTUnwrap(summary.activeJob)
    XCTAssertEqual(visible.id, id)
    XCTAssertEqual(visible.state, "pending")
    XCTAssertNil(visible.errorMessage)
  }

  func testFinishedUploadIdentityCannotRemoveReplacement() {
    let old = IosBackupUploadIdentity(
      generation: "old-generation",
      token: UUID()
    )
    let replacement = IosBackupUploadIdentity(
      generation: "new-generation",
      token: UUID()
    )

    XCTAssertFalse(
      IosBackupActiveUploadGate.shouldRemove(active: replacement, finished: old)
    )
    XCTAssertTrue(
      IosBackupActiveUploadGate.shouldRemove(
        active: replacement,
        finished: replacement
      )
    )
  }

  func testTenThousandQueuedUploadsAndWakeupsKeepTasksBounded() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    try executeBackupStoreSql(
      """
      WITH RECURSIVE counter(value) AS (
        SELECT 0
        UNION ALL
        SELECT value + 1 FROM counter WHERE value < 9999
      )
      INSERT INTO backup_jobs(
        id, generation, file_path, state, sessions, revision
      )
      SELECT
        printf('bounded-%05d', value),
        printf('generation-%05d', value),
        printf('/recordings/bounded-%05d.mp4', value),
        'pending', '[]', value
      FROM counter;
      UPDATE backup_meta SET int_value = 10000
      WHERE key IN ('summary_total_count', 'summary_pending_count');
      UPDATE backup_meta SET int_value = 9999
      WHERE key = 'global_revision';
      """,
      databaseURL: fixture.databaseURL
    )
    let started = expectation(description: "唯一上传 worker 已启动")
    let gate = AsyncTestGate()
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadOperationOverride: { _, _ in
        started.fulfill()
        await gate.wait()
      }
    )

    try await awaitVoidResult {
      api.setAutoEnabled(enabled: true, completion: $0)
    }
    api.requestUploadDispatchForTesting()
    await fulfillment(of: [started], timeout: 5)
    for _ in 0..<10_000 { api.requestUploadDispatchForTesting() }
    let running = api.uploadTaskCountsForTesting()
    XCTAssertEqual(running.dispatcher, 1)
    XCTAssertEqual(running.active, 1)

    try await awaitVoidResult {
      api.setAutoEnabled(enabled: false, completion: $0)
    }
    await gate.open()
    await api.waitForUploadDispatcherForTesting()
    let finished = api.uploadTaskCountsForTesting()
    XCTAssertEqual(finished.dispatcher, 0)
    XCTAssertEqual(finished.active, 0)
  }

  func testUploadDispatcherRecoversInterruptedAndContinuesClaiming() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    var interrupted = makeBackupJob(id: "interrupted")
    interrupted["state"] = "uploading"
    try store.upsert(interrupted)
    try store.upsert(makeBackupJob(id: "pending-after-restart"))
    let completed = expectation(description: "恢复并继续领取后续任务")
    completed.expectedFulfillmentCount = 2
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadOperationOverride: { job, identity in
        _ = try? store.updateJob(
          id: job["id"] as? String ?? "",
          expectedGeneration: identity.generation
        ) { $0["state"] = "completed" }
        completed.fulfill()
      }
    )

    _ = try await awaitInitializeResult(api, autoEnabled: true)
    await fulfillment(of: [completed], timeout: 5)
    await api.waitForUploadDispatcherForTesting()

    XCTAssertEqual(try store.summaryValues()["completedCount"] as? Int64, 2)
    XCTAssertEqual(api.uploadTaskCountsForTesting().active, 0)
  }

  func testUploadDispatcherWaitsForHostForeground() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    fixture.defaults.set(true, forKey: "ios_backup_auto_enabled")
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let id = "foreground-gated"
    try store.upsert(makeBackupJob(id: id))
    let started = expectation(description: "返回前台后开始上传")
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadOperationOverride: { job, identity in
        _ = try? store.updateJob(
          id: job["id"] as? String ?? "",
          expectedGeneration: identity.generation
        ) { $0["state"] = "completed" }
        started.fulfill()
      },
      hostForeground: false
    )

    api.requestUploadDispatchForTesting()
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(api.uploadTaskCountsForTesting().dispatcher, 0)
    XCTAssertEqual(try store.readJob(id: id)?["state"] as? String, "pending")

    api.onHostForeground()
    await fulfillment(of: [started], timeout: 5)
    await api.waitForUploadDispatcherForTesting()

    XCTAssertEqual(try store.readJob(id: id)?["state"] as? String, "completed")
  }

  func testUploadDispatcherStopsClaimingAfterHostBackground() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    fixture.defaults.set(true, forKey: "ios_backup_auto_enabled")
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    try store.upsert(makeBackupJob(id: "first-before-background"))
    try store.upsert(makeBackupJob(id: "second-after-background"))
    let firstStarted = expectation(description: "首条前台上传已启动")
    let secondStarted = expectation(description: "返回前台后启动第二条")
    let firstGate = AsyncTestGate()
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadOperationOverride: { job, identity in
        let id = job["id"] as? String ?? ""
        if id == "first-before-background" {
          firstStarted.fulfill()
          await firstGate.wait()
        } else {
          secondStarted.fulfill()
        }
        _ = try? store.updateJob(
          id: id,
          expectedGeneration: identity.generation
        ) { $0["state"] = "completed" }
      }
    )

    api.requestUploadDispatchForTesting()
    await fulfillment(of: [firstStarted], timeout: 5)
    api.onHostBackground()
    await firstGate.open()
    await api.waitForUploadDispatcherForTesting()

    XCTAssertEqual(
      try store.readJob(id: "second-after-background")?["state"] as? String,
      "pending"
    )

    api.onHostForeground()
    await fulfillment(of: [secondStarted], timeout: 5)
    await api.waitForUploadDispatcherForTesting()

    XCTAssertEqual(
      try store.readJob(id: "second-after-background")?["state"] as? String,
      "completed"
    )
  }

  func testUploadDispatcherDoesNotLoseForegroundWakeupWhileStopping()
    async throws
  {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    fixture.defaults.set(true, forKey: "ios_backup_auto_enabled")
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    try store.upsert(makeBackupJob(id: "foreground-race"))
    let uploaded = expectation(description: "退出竞态后重新调度上传")
    var api: IosBackupHostApi!
    var restoredForeground = false
    api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadOperationOverride: { job, identity in
        _ = try? store.updateJob(
          id: job["id"] as? String ?? "",
          expectedGeneration: identity.generation
        ) { $0["state"] = "completed" }
        uploaded.fulfill()
      },
      hostForeground: false,
      beforeUploadDispatcherFinalizationForTesting: {
        guard !restoredForeground else { return }
        restoredForeground = true
        api.onHostForeground()
      }
    )

    api.finishUploadDispatcherForTesting()
    await fulfillment(of: [uploaded], timeout: 5)
    await api.waitForUploadDispatcherForTesting()

    XCTAssertEqual(
      try store.readJob(id: "foreground-race")?["state"] as? String,
      "completed"
    )
    XCTAssertEqual(api.uploadTaskCountsForTesting().dispatcher, 0)
  }

  func testUploadDispatcherCancelsAndRunsReplacementGeneration() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    fixture.defaults.set(true, forKey: "ios_backup_auto_enabled")
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let id = "dispatcher-replacement"
    let original = makeBackupJob(id: id)
    try store.upsert(original)
    let originalStarted = expectation(description: "旧代次已启动")
    let replacementCompleted = expectation(description: "新代次已完成")
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadOperationOverride: { job, identity in
        if identity.generation == original["generation"] as? String {
          originalStarted.fulfill()
          while !Task.isCancelled { await Task.yield() }
          return
        }
        _ = try? store.updateJob(
          id: job["id"] as? String ?? "",
          expectedGeneration: identity.generation
        ) { $0["state"] = "completed" }
        replacementCompleted.fulfill()
      }
    )

    api.requestUploadDispatchForTesting()
    await fulfillment(of: [originalStarted], timeout: 5)
    try await awaitVoidResult { api.requeueJob(jobId: id, completion: $0) }
    await fulfillment(of: [replacementCompleted], timeout: 5)
    await api.waitForUploadDispatcherForTesting()

    let stored = try XCTUnwrap(store.readJob(id: id))
    XCTAssertNotEqual(stored["generation"] as? String, original["generation"] as? String)
    XCTAssertEqual(stored["state"] as? String, "completed")
    XCTAssertEqual(api.uploadTaskCountsForTesting().active, 0)
  }

  func testUploadDispatcherCancelLeavesJobPausedAndStopsWorker() async throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    fixture.defaults.set(true, forKey: "ios_backup_auto_enabled")
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL,
      defaults: fixture.defaults
    )
    let id = "dispatcher-cancel"
    try store.upsert(makeBackupJob(id: id))
    let started = expectation(description: "待取消上传已启动")
    let api = makeBackupApi(
      defaults: fixture.defaults,
      store: store,
      uploadOperationOverride: { _, _ in
        started.fulfill()
        while !Task.isCancelled { await Task.yield() }
      }
    )

    api.requestUploadDispatchForTesting()
    await fulfillment(of: [started], timeout: 5)
    try await awaitVoidResult { api.cancelJob(jobId: id, completion: $0) }
    await api.waitForUploadDispatcherForTesting()

    XCTAssertEqual(try store.readJob(id: id)?["state"] as? String, "paused")
    XCTAssertEqual(api.uploadTaskCountsForTesting().active, 0)
  }

  func testLanBackupHostResolverKeepsLargeProbeSetAtFourConcurrentTasks()
    async
  {
    let candidates = (0..<1_000).map { "http://candidate-\($0):5280" }
    let tracker = AsyncProbeTracker()
    let resolver = IosLanBackupHostResolver(
      candidateProvider: { candidates },
      probeOperation: { baseUrl, _ in
        guard baseUrl != "http://current:5280" else { return nil }
        await tracker.begin()
        try? await Task.sleep(nanoseconds: 100_000)
        await tracker.finish()
        return nil
      }
    )

    let result = await resolver.resolve(
      currentBaseUrl: "http://current:5280",
      expectedNodeId: "expected-node"
    )
    let counts = await tracker.counts()

    XCTAssertNil(result)
    XCTAssertEqual(counts.started, candidates.count)
    XCTAssertEqual(counts.active, 0)
    XCTAssertLessThanOrEqual(counts.maximumActive, 4)
  }

  func testLanBackupHostResolverCancelsRemainingProbesAfterMatch() async {
    let candidates = ["slow-0", "match", "slow-1", "slow-2"]
      + (3..<1_000).map { "slow-\($0)" }
    let tracker = AsyncProbeTracker()
    let resolver = IosLanBackupHostResolver(
      candidateProvider: { candidates },
      probeOperation: { baseUrl, _ in
        guard baseUrl != "current" else { return nil }
        await tracker.begin()
        if baseUrl == "match" {
          await tracker.waitUntilStarted(4)
          await tracker.finish()
          return baseUrl
        }
        do {
          try await Task.sleep(nanoseconds: 5_000_000_000)
          await tracker.finish()
          return nil
        } catch {
          // broad-catch: 压力测试把取消转换为 tracker 的取消计数
          await tracker.cancelAndFinish()
          return nil
        }
      }
    )

    let result = await resolver.resolve(
      currentBaseUrl: "current",
      expectedNodeId: "expected-node"
    )
    let counts = await tracker.counts()

    XCTAssertEqual(result, "match")
    XCTAssertEqual(counts.active, 0)
    XCTAssertGreaterThan(counts.cancelled, 0)
    XCTAssertLessThanOrEqual(counts.started, 4)
    XCTAssertLessThanOrEqual(counts.maximumActive, 4)
  }

  func testLanBackupHostResolverCompletesAllCandidatesWhenNothingMatches()
    async
  {
    let candidates = (0..<257).map { "candidate-\($0)" }
    let tracker = AsyncProbeTracker()
    let resolver = IosLanBackupHostResolver(
      candidateProvider: { candidates },
      probeOperation: { baseUrl, _ in
        guard baseUrl != "current" else { return nil }
        await tracker.begin()
        await Task.yield()
        await tracker.finish()
        return nil
      }
    )

    let result = await resolver.resolve(
      currentBaseUrl: "current",
      expectedNodeId: "expected-node"
    )
    let counts = await tracker.counts()

    XCTAssertNil(result)
    XCTAssertEqual(counts.started, candidates.count)
    XCTAssertEqual(counts.active, 0)
    XCTAssertEqual(counts.cancelled, 0)
    XCTAssertLessThanOrEqual(counts.maximumActive, 4)
  }

  func testSystemIosKeychainClientRoundTrip() throws {
    let client = SystemIosKeychainClient()
    let service = "RunnerTests.keychain.\(UUID().uuidString)"
    let account = "access-key"
    defer { try? client.delete(service: service, account: account) }

    do {
      try client.save(
        Data("system-keychain-value".utf8), service: service, account: account
      )
    } catch let error as IosBackupCredentialError where error.status == -34_018 {
      throw XCTSkip("未签名测试包没有 Keychain entitlement")
    }
    XCTAssertEqual(
      try client.read(service: service, account: account),
      Data("system-keychain-value".utf8)
    )
    try client.delete(service: service, account: account)
    XCTAssertNil(try client.read(service: service, account: account))
  }

  private typealias ReceiptFixture = (
    response: [String: Any], accessKey: String, host: String, device: String,
    session: String, sha256: String, fileSize: Int64, recordId: Int64, now: Int64
  )

  private func makeReceiptFixture() -> ReceiptFixture {
    let accessKey = "test-backup-access-key"
    let host = "HOST-123"
    let device = "DEVICE-456"
    let session = "session-789"
    let sha256 = String(repeating: "a", count: 64)
    let fileSize: Int64 = 12_345
    let recordId: Int64 = 678
    let now: Int64 = 1_800_000_000
    let canonical = [
      "packingproof-verified-receipt-v3", host.lowercased(), device.lowercased(),
      session, sha256, String(fileSize), String(recordId), String(now),
    ].joined(separator: "\n")
    let key = SymmetricKey(data: Data(accessKey.utf8))
    let signature = HMAC<SHA256>.authenticationCode(
      for: Data(canonical.utf8), using: key
    ).map { String(format: "%02x", $0) }.joined()
    return (
      [
        "status": "verified",
        "authVersion": 3,
        "verifiedAtUnixSeconds": now,
        "hostNodeId": host,
        "sourceDeviceId": device,
        "sourceSessionId": session,
        "fileSha256": sha256,
        "fileSizeBytes": fileSize,
        "recordId": recordId,
        "receiptSignature": signature,
      ],
      accessKey, host, device, session, sha256, fileSize, recordId, now
    )
  }

  private func verifyReceipt(
    _ response: [String: Any], fixture: ReceiptFixture
  ) -> Bool {
    IosBackupReceiptVerifier.verify(
      response,
      accessKey: fixture.accessKey,
      hostNodeId: fixture.host,
      sourceDeviceId: fixture.device,
      sourceSessionId: fixture.session,
      fileSha256: fixture.sha256,
      fileSizeBytes: fixture.fileSize,
      recordId: fixture.recordId,
      now: Date(timeIntervalSince1970: TimeInterval(fixture.now))
    )
  }

  private typealias BackupStoreFixture = (
    root: URL, databaseURL: URL, defaults: UserDefaults, suiteName: String
  )

  private func makeBackupStoreFixture() throws -> BackupStoreFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("backup-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "RunnerTests.backup-store.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (root, root.appendingPathComponent("lan_backup.db"), defaults, suiteName)
  }

  private func removeBackupStoreFixture(_ fixture: BackupStoreFixture) {
    fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    try? FileManager.default.removeItem(at: fixture.root)
  }

  private func executeBackupStoreSql(_ sql: String, databaseURL: URL) throws {
    var database: OpaquePointer?
    let openCode = sqlite3_open_v2(
      databaseURL.path,
      &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openCode == SQLITE_OK else {
      sqlite3_close(database)
      throw IosBackupStoreError(
        operation: "测试打开", code: openCode, message: "无法打开测试数据库"
      )
    }
    defer { sqlite3_close(database) }
    let executeCode = sqlite3_exec(database, sql, nil, nil, nil)
    guard executeCode == SQLITE_OK else {
      throw IosBackupStoreError(
        operation: "测试写入", code: executeCode, message: "无法修改测试数据库"
      )
    }
  }

  func testBackupRecordingPathRelocatesLegacyContainerPath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "backup-path-relocation-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let documents = root.appendingPathComponent("Documents", isDirectory: true)
    let target = documents.appendingPathComponent(
      "recordings/2026-08-23/example.mp4"
    )
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(repeating: 7, count: 32).write(to: target)
    let legacy = "/var/mobile/Containers/Data/Application/OLD-CONTAINER/" +
      "Documents/recordings/2026-08-23/example.mp4"

    let resolved = try IosBackupRecordingPath.resolve(
      storedPath: legacy, documentsDirectory: documents
    )

    XCTAssertEqual(resolved.standardizedFileURL, target.standardizedFileURL)
    XCTAssertEqual(try IosBackupFileSnapshot.read(from: resolved).byteCount, 32)
  }

  func testBackupRecordingPathRejectsTraversalOutsideRecordings() throws {
    let documents = FileManager.default.temporaryDirectory
      .appendingPathComponent("Documents-\(UUID().uuidString)", isDirectory: true)
    let legacy = "/var/mobile/Containers/Data/Application/OLD-CONTAINER/" +
      "Documents/recordings/../../outside.mp4"

    XCTAssertThrowsError(
      try IosBackupRecordingPath.resolve(
        storedPath: legacy, documentsDirectory: documents
      )
    )
  }

  func testBackupRecordingIdentityIgnoresContainerUuid() {
    let suffix = "Documents/recordings/2026-08-23/example.mp4"
    let first = IosBackupRecordingPath.stableIdentity(
      storedPath: "/var/mobile/Containers/Data/Application/FIRST/\(suffix)"
    )
    let second = IosBackupRecordingPath.stableIdentity(
      storedPath: "/var/mobile/Containers/Data/Application/SECOND/\(suffix)"
    )

    XCTAssertEqual(first, "Documents/recordings/2026-08-23/example.mp4")
    XCTAssertEqual(first, second)
  }

  private func backupStoreQueryPlan(
    _ sql: String, databaseURL: URL
  ) throws -> [String] {
    var database: OpaquePointer?
    let openCode = sqlite3_open_v2(
      databaseURL.path,
      &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openCode == SQLITE_OK else {
      sqlite3_close(database)
      throw IosBackupStoreError(
        operation: "测试打开查询计划", code: openCode, message: "无法打开测试数据库"
      )
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    let prepareCode = sqlite3_prepare_v2(
      database, "EXPLAIN QUERY PLAN \(sql)", -1, &statement, nil
    )
    guard prepareCode == SQLITE_OK else {
      sqlite3_finalize(statement)
      throw IosBackupStoreError(
        operation: "测试准备查询计划", code: prepareCode, message: "无法生成查询计划"
      )
    }
    defer { sqlite3_finalize(statement) }
    var result: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let value = sqlite3_column_text(statement, 3) else { continue }
      result.append(String(cString: value))
    }
    return result
  }

  private func makeBackupApi(
    defaults: UserDefaults,
    store: IosBackupJobStore,
    uploadFailureUpdateOverride: ((String, String) throws -> Bool)? = nil,
    uploadPersistenceFailureReporter:
      ((String, String, Error) -> Void)? = nil,
    uploadOperationOverride:
      (([String: Any], IosBackupUploadIdentity) async -> Void)? = nil,
    storageReclaimOperationOverride:
      (() async throws -> [String?: Any?])? = nil,
    cleanupOperationOverride: (() async throws -> Void)? = nil,
    cleanupConfigured: Bool? = true,
    cleanupRetryDelaysNanoseconds: [UInt64]? = nil,
    recordingActivityState: IosRecordingActivityState = IosRecordingActivityState(),
    cleanupWorkPauseNanoseconds: UInt64? = nil,
    cleanupSliceIntervalNanoseconds: UInt64? = nil,
    hostForeground: Bool = true,
    beforeUploadDispatcherFinalizationForTesting: (() -> Void)? = nil,
    afterCleanupRunnerDecisionForTesting: (() -> Void)? = nil,
    beforeCleanupRetrySleepForTesting: ((Int, UInt64) -> Void)? = nil,
    beforeCleanupCandidateForTesting: (([String: Any]) -> Void)? = nil,
    recordingsRoot: URL? = nil,
    beforeCleanupIntentClaimForTesting: (([String: Any]) -> Void)? = nil,
    afterCleanupCommitForTesting: ((IosBackupCleanupIntent) throws -> Void)? = nil
  ) -> IosBackupHostApi {
    IosBackupHostApi(
      eventApi: FakeBackupNativeEventApi(),
      defaults: defaults,
      credentialStore: IosBackupCredentialStore(
        defaults: defaults,
        keychain: FakeIosKeychainClient(),
        service: "RunnerTests.backup-api.\(UUID().uuidString)",
        account: "access-key"
      ),
      jobStore: .success(store),
      recordingsRoot: recordingsRoot ?? FileManager.default.temporaryDirectory,
      uploadFailureUpdateOverride: uploadFailureUpdateOverride,
      uploadPersistenceFailureReporter: uploadPersistenceFailureReporter,
      uploadOperationOverride: uploadOperationOverride,
      storageReclaimOperationOverride: storageReclaimOperationOverride,
      cleanupOperationOverride: cleanupOperationOverride,
      cleanupConfigurationOverride: cleanupConfigured.map { value in
        { value }
      },
      cleanupRetryDelaysNanoseconds: cleanupRetryDelaysNanoseconds,
      recordingActivityState: recordingActivityState,
      cleanupWorkPauseNanoseconds: cleanupWorkPauseNanoseconds,
      cleanupSliceIntervalNanoseconds: cleanupSliceIntervalNanoseconds,
      hostForeground: hostForeground,
      beforeUploadDispatcherFinalizationForTesting:
        beforeUploadDispatcherFinalizationForTesting,
      afterCleanupRunnerDecisionForTesting:
        afterCleanupRunnerDecisionForTesting,
      beforeCleanupRetrySleepForTesting: beforeCleanupRetrySleepForTesting,
      beforeCleanupCandidateForTesting: beforeCleanupCandidateForTesting,
      beforeCleanupIntentClaimForTesting: beforeCleanupIntentClaimForTesting,
      afterCleanupCommitForTesting: afterCleanupCommitForTesting
    )
  }

  private typealias RetentionCleanupFixture = (
    root: URL, defaults: UserDefaults, suiteName: String, store: IosBackupJobStore,
    api: IosBackupHostApi, file: URL, job: [String: Any]
  )

  private func makeRetentionCleanupFixture(
    id: String,
    autoEnabled: Bool = false,
    availableStorageBytesOverride: (() -> Int64)? = nil,
    storageAttestationOverride:
      (([String: Any], String, Int64) async -> String?)? = nil,
    storageReclaimConfirmationLimitOverride: Int? = nil,
    onSnapshot: ((BackupSummaryDto) -> Void)? = nil,
    beforeCleanupFileProofForTesting: (([String: Any]) -> Void)? = nil,
    beforeCleanupIntentClaimForTesting: (([String: Any]) -> Void)? = nil,
    beforeCleanupRenameForTesting: ((IosBackupCleanupIntent) throws -> Void)? = nil,
    afterCleanupRenameForTesting: ((IosBackupCleanupIntent) throws -> Void)? = nil,
    afterCleanupCommitForTesting: ((IosBackupCleanupIntent) throws -> Void)? = nil
  ) throws -> RetentionCleanupFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "retention-cleanup-\(UUID().uuidString)", isDirectory: true
      )
    let recordings = root.appendingPathComponent("recordings", isDirectory: true)
    try FileManager.default.createDirectory(
      at: recordings, withIntermediateDirectories: true
    )
    let file = recordings.appendingPathComponent("\(id).mp4")
    let contents = Data("retention-cleanup-fixture".utf8)
    try contents.write(to: file)
    let snapshot = try IosBackupFileSnapshot.read(from: file)
    let suiteName = "RunnerTests.retention-cleanup.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(autoEnabled, forKey: "ios_backup_auto_enabled")
    let store = try IosBackupJobStore(
      databaseURL: root.appendingPathComponent("lan_backup.db"), defaults: defaults
    )
    let credentialStore = IosBackupCredentialStore(
      defaults: defaults,
      keychain: FakeIosKeychainClient(),
      service: suiteName,
      account: "access-key"
    )
    let api = IosBackupHostApi(
      eventApi: FakeBackupNativeEventApi(onSnapshot: onSnapshot),
      defaults: defaults,
      credentialStore: credentialStore,
      jobStore: .success(store),
      recordingsRoot: recordings,
      availableStorageBytesOverride: availableStorageBytesOverride,
      storageAttestationOverride: storageAttestationOverride,
      storageReclaimConfirmationLimitOverride: storageReclaimConfirmationLimitOverride,
      cleanupConfigurationOverride: { true },
      beforeCleanupFileProofForTesting: beforeCleanupFileProofForTesting,
      beforeCleanupIntentClaimForTesting: beforeCleanupIntentClaimForTesting,
      beforeCleanupRenameForTesting: beforeCleanupRenameForTesting,
      afterCleanupRenameForTesting: afterCleanupRenameForTesting,
      afterCleanupCommitForTesting: afterCleanupCommitForTesting
    )
    var job = makeBackupJob(id: id)
    job["filePath"] = file.path
    job["state"] = "completed"
    job["totalBytes"] = snapshot.byteCount
    job["lastModified"] = snapshot.modifiedAtMilliseconds
    job["contentSha256"] = SHA256.hash(data: contents)
      .map { String(format: "%02x", $0) }.joined()
    job["backupCompletedAt"] = "2020-01-01T00:00:00Z"
    return (root, defaults, suiteName, store, api, file, job)
  }

  private func makeVerifiedStorageReclaimJob(
    _ source: [String: Any]
  ) -> [String: Any] {
    makeVerifiedRetentionCleanupJob(source)
  }

  private func makeVerifiedRetentionCleanupJob(
    _ source: [String: Any]
  ) -> [String: Any] {
    var job = source
    job["verificationVersion"] = 3
    job["verificationReceipt"] = "stored-signed-receipt"
    job["remoteRecordId"] = NSNumber(value: 42)
    job["lastAttestedAt"] = ISO8601DateFormatter().string(from: Date())
    return job
  }

  /// 追加一段已完成电脑校验的录像，用于验证一次空间回收里的多条候选行为。
  private func addVerifiedStorageReclaimJob(
    _ fixture: RetentionCleanupFixture,
    id: String,
    lastAttestedAt: String
  ) throws -> URL {
    let file = fixture.root.appendingPathComponent("recordings/\(id).mp4")
    let contents = Data("retention-cleanup-fixture-\(id)".utf8)
    try contents.write(to: file)
    let snapshot = try IosBackupFileSnapshot.read(from: file)
    var job = makeBackupJob(id: id)
    job["filePath"] = file.path
    job["state"] = "completed"
    job["totalBytes"] = snapshot.byteCount
    job["lastModified"] = snapshot.modifiedAtMilliseconds
    job["contentSha256"] = SHA256.hash(data: contents)
      .map { String(format: "%02x", $0) }.joined()
    job["backupCompletedAt"] = "2020-01-01T00:00:00Z"
    job = makeVerifiedStorageReclaimJob(job)
    job["lastAttestedAt"] = lastAttestedAt
    try fixture.store.upsert(job)
    return file
  }

  private func removeRetentionCleanupFixture(_ fixture: RetentionCleanupFixture) {
    fixture.api.drainSummaryQueueForTesting()
    fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    try? FileManager.default.removeItem(at: fixture.root)
  }

  private func awaitVoidResult(
    _ operation: (@escaping (Result<Void, Error>) -> Void) -> Void
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      operation { result in
        continuation.resume(with: result)
      }
    }
  }

  private func awaitSummaryResult(
    _ api: IosBackupHostApi
  ) async throws -> BackupSummaryDto {
    try await withCheckedThrowingContinuation { continuation in
      api.summary { result in
        continuation.resume(with: result)
      }
    }
  }

  private func awaitInitializeResult(
    _ api: IosBackupHostApi,
    autoEnabled: Bool = false
  ) async throws -> BackupSummaryDto {
    try await withCheckedThrowingContinuation { continuation in
      api.initialize(request: ["autoEnabled": autoEnabled]) { result in
        continuation.resume(with: result)
      }
    }
  }

  private func awaitStorageReclaim(
    _ api: IosBackupHostApi
  ) async throws -> [String?: Any?] {
    try await withCheckedThrowingContinuation { continuation in
      api.reclaimStorageIfNeeded { result in
        continuation.resume(with: result)
      }
    }
  }

  private func awaitAvailableRecordingStorageBytes(
    _ api: IosBackupHostApi
  ) async throws -> Int64? {
    try await withCheckedThrowingContinuation { continuation in
      api.availableRecordingStorageBytes { result in
        continuation.resume(with: result)
      }
    }
  }

  private func makeBackupJob(id: String) -> [String: Any] {
    [
      "id": id,
      "generation": "generation-\(id)",
      "filePath": "/recordings/\(id).mp4",
      "state": "pending",
      "uploadedBytes": 0,
      "totalBytes": 1024,
      "lastModified": 1_800_000_000_000,
      "sessions": [["id": "session-\(id)", "trackingNumber": "tracking-\(id)"]],
    ]
  }

}

private final class FakeBackupNativeEventApi: BackupNativeEventApiProtocol {
  private let onSnapshot: ((BackupSummaryDto) -> Void)?

  init(onSnapshot: ((BackupSummaryDto) -> Void)? = nil) {
    self.onSnapshot = onSnapshot
  }

  func summaryChanged(
    summary: BackupSummaryDto,
    completion: @escaping (Result<Void, PigeonError>) -> Void
  ) {
    onSnapshot?(summary)
    completion(.success(()))
  }
}

private final class FakeIosKeychainClient: IosKeychainClient {
  var data: Data?
  var readCount = 0
  var readError: Error?
  var saveError: Error?
  var deleteError: Error?

  func read(service: String, account: String) throws -> Data? {
    readCount += 1
    if let readError { throw readError }
    return data
  }

  func save(_ data: Data, service: String, account: String) throws {
    if let saveError { throw saveError }
    self.data = data
  }

  func delete(service: String, account: String) throws {
    if let deleteError { throw deleteError }
    data = nil
  }
}

private actor AsyncTestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for continuation in pending { continuation.resume() }
  }
}

private actor AsyncProbeTracker {
  private var started = 0
  private var active = 0
  private var maximumActive = 0
  private var cancelled = 0
  private var startWaiters: [(
    count: Int, continuation: CheckedContinuation<Void, Never>
  )] = []

  func begin() {
    started += 1
    active += 1
    maximumActive = max(maximumActive, active)
    let ready = startWaiters.filter { started >= $0.count }
    startWaiters.removeAll { started >= $0.count }
    for waiter in ready { waiter.continuation.resume() }
  }

  func waitUntilStarted(_ count: Int) async {
    if started >= count { return }
    await withCheckedContinuation { continuation in
      startWaiters.append((count, continuation))
    }
  }

  func finish() {
    active -= 1
  }

  func cancelAndFinish() {
    cancelled += 1
    active -= 1
  }

  func counts() -> (
    started: Int, active: Int, maximumActive: Int, cancelled: Int
  ) {
    (started, active, maximumActive, cancelled)
  }
}

private enum MaintenanceTestError: Error {
  case expected
}

private actor AsyncMaintenanceTracker {
  private var started = 0
  private var active = 0
  private var maximumActive = 0

  func begin() -> Int {
    started += 1
    active += 1
    maximumActive = max(maximumActive, active)
    return started
  }

  func finish() {
    active -= 1
  }

  func counts() -> (started: Int, active: Int, maximumActive: Int) {
    (started, active, maximumActive)
  }
}


private final class TtsTestMessenger: NSObject, FlutterBinaryMessenger {
  var onCall: ((FlutterMethodCall) -> Void)?

  func send(onChannel channel: String, message: Data?) {
    XCTAssertTrue(Thread.isMainThread)
    if let message = message {
      onCall?(FlutterStandardMethodCodec.sharedInstance().decodeMethodCall(message))
    }
  }

  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {
    send(onChannel: channel, message: message)
    callback?(nil)
  }

  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection { 0 }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}

final class IosTtsThreadingTests: XCTestCase {
  @MainActor
  func testBackgroundDelegateCompletionReturnsToMainActor() async {
    let messenger = TtsTestMessenger()
    let plugin = SwiftFlutterTtsPlugin(channel: FlutterMethodChannel(name: "tts-test", binaryMessenger: messenger))
    plugin.autoStopSharedSession = false
    plugin.awaitSpeakCompletion = true
    let result = expectation(description: "completion result on main thread")
    plugin.speakResult = { value in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(value as? Int, 1)
      result.fulfill()
    }
    let event = expectation(description: "completion event on main thread")
    messenger.onCall = { call in
      XCTAssertEqual(call.method, "speak.onComplete")
      event.fulfill()
    }
    DispatchQueue.global().async {
      plugin.speechSynthesizer(AVSpeechSynthesizer(), didFinish: AVSpeechUtterance(string: "测试"))
    }
    await fulfillment(of: [result, event], timeout: 5)
    XCTAssertNil(plugin.speakResult)
  }

  @MainActor
  func testBackgroundProgressCopiesTextBeforeReturningToMainActor() async {
    let messenger = TtsTestMessenger()
    let plugin = SwiftFlutterTtsPlugin(channel: FlutterMethodChannel(name: "tts-test", binaryMessenger: messenger))
    let event = expectation(description: "progress event on main thread")
    messenger.onCall = { call in
      XCTAssertEqual(call.method, "speak.onProgress")
      XCTAssertEqual(call.arguments as? [String: String], ["text": "测试播报", "word": "测试", "start": "0", "end": "2"])
      event.fulfill()
    }
    DispatchQueue.global().async {
      plugin.speechSynthesizer(AVSpeechSynthesizer(), willSpeakRangeOfSpeechString: NSRange(location: 0, length: 2), utterance: AVSpeechUtterance(string: "测试播报"))
    }
    await fulfillment(of: [event], timeout: 5)
  }

  func testBluetoothOptionKeepsHfpFlag() {
    XCTAssertEqual(AudioCategoryOptions.iosAudioCategoryOptionsAllowBluetooth.toAVAudioSessionCategoryOptions(), .allowBluetoothHFP)
    XCTAssertEqual(AVAudioSession.CategoryOptions.allowBluetoothHFP.rawValue, 4)
  }
}
