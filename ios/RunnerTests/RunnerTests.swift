import Flutter
import CryptoKit
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

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
    XCTAssertEqual(actualSession as NSDictionary, expectedSession as NSDictionary)
    XCTAssertEqual((response["recordId"] as? NSNumber)?.int64Value, 42)
    XCTAssertNil(response["recordIds"])
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
        layout.renderSize.height * 0.1
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
    let source = Data((0..<(2 * 1024 * 1024 + 17)).map { UInt8($0 % 251) })
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
      XCTAssertEqual(try store.allJobs().count, 1)
      XCTAssertTrue(try store.updateJob(id: "job-1") { current in
        current["state"] = "paused"
        current["uploadedBytes"] = 512
      })
      XCTAssertFalse(try store.updateJob(id: "missing") { _ in })
    }

    let reopened = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let restored = try XCTUnwrap(reopened.allJobs().first)
    XCTAssertEqual(restored["state"] as? String, "paused")
    XCTAssertEqual((restored["uploadedBytes"] as? NSNumber)?.int64Value, 512)
    XCTAssertEqual((restored["sessions"] as? [Any])?.count, 1)
    try reopened.deleteJob(id: "job-1")
    XCTAssertTrue(try reopened.allJobs().isEmpty)
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
    let current = try XCTUnwrap(store.allJobs().first)
    XCTAssertEqual(current["generation"] as? String, "replacement-generation")
    XCTAssertEqual(current["state"] as? String, "pending")
    XCTAssertEqual((current["uploadedBytes"] as? NSNumber)?.int64Value, 512)
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
    XCTAssertEqual(try store.allJobs().first?["id"] as? String, "legacy-1")
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
    XCTAssertTrue(try reopened.allJobs().isEmpty)
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
    let updated = try XCTUnwrap(fixture.store.allJobs().first)
    XCTAssertEqual(updated["waitingCleanup"] as? Bool, true)
    XCTAssertNil(updated["localDeletedAt"])
    XCTAssertEqual(
      updated["errorMessage"] as? String,
      "备份记录缺少安全校验信息，需重新备份后才能自动清理"
    )
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
    let updated = try XCTUnwrap(fixture.store.allJobs().first)
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
    XCTAssertNil(try fixture.store.allJobs().first?["localDeletedAt"])
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
    let updated = try XCTUnwrap(fixture.store.allJobs().first)
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
    XCTAssertNil(try fixture.store.allJobs().first?["localDeletedAt"])
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
    let updated = try XCTUnwrap(fixture.store.allJobs().first)
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
    let updated = try XCTUnwrap(fixture.store.allJobs().first)
    XCTAssertNotNil(updated["localDeletedAt"])
    XCTAssertEqual(updated["verificationReceipt"] as? String, "fresh-signed-receipt")
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
    let cancelled = try XCTUnwrap(fixture.store.allJobs().first)
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
    let afterStaleCompletion = try fixture.store.allJobs().first
    XCTAssertEqual(
      afterStaleCompletion?["state"] as? String,
      "paused"
    )

    try await awaitVoidResult { completion in
      fixture.api.requeueJob(jobId: "generation-lifecycle", completion: completion)
    }
    let requeued = try XCTUnwrap(fixture.store.allJobs().first)
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
    let current = try XCTUnwrap(fixture.store.allJobs().first)
    XCTAssertEqual(current["generation"] as? String, requeuedGeneration)
    XCTAssertEqual(current["state"] as? String, "pending")
    XCTAssertNil(current["errorMessage"])
  }

  func testEnqueueReplacesCallerProvidedGeneration() async throws {
    let fixture = try makeRetentionCleanupFixture(id: "generation-enqueue")
    defer { removeRetentionCleanupFixture(fixture) }
    let request: [String?: Any?] = [
      "id": "generation-enqueue",
      "generation": "caller-provided-generation",
      "filePath": fixture.file.path,
      "lastModified": fixture.job["lastModified"],
      "sessions": fixture.job["sessions"],
    ]

    try await awaitVoidResult { completion in
      fixture.api.enqueueJob(request: request, completion: completion)
    }

    let current = try XCTUnwrap(fixture.store.allJobs().first)
    XCTAssertNotEqual(
      current["generation"] as? String,
      "caller-provided-generation"
    )
    XCTAssertFalse((current["generation"] as? String)?.isEmpty ?? true)
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
      let current = try XCTUnwrap(
        store.allJobs().first { $0["id"] as? String == id }
      )
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
    XCTAssertEqual(try store.allJobs().first?["state"] as? String, "pending")

    let snapshot = try await awaitSnapshotResult(api)
    let jobs = try XCTUnwrap(snapshot["jobs"] as? [[String: Any]])
    let visible = try XCTUnwrap(jobs.first { $0["id"] as? String == id })
    XCTAssertEqual(visible["state"] as? String, "paused")
    XCTAssertEqual(visible["failureKind"] as? String, "storage_unavailable")
    XCTAssertTrue(
      (visible["errorMessage"] as? String)?.contains("任务状态写入失败") ?? false
    )
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
    let stored = try XCTUnwrap(store.allJobs().first)
    XCTAssertEqual(stored["generation"] as? String, "replacement-generation")
    XCTAssertEqual(stored["state"] as? String, "pending")
    XCTAssertNil(stored["errorMessage"])

    let snapshot = try await awaitSnapshotResult(api)
    let jobs = try XCTUnwrap(snapshot["jobs"] as? [[String: Any]])
    let visible = try XCTUnwrap(jobs.first)
    XCTAssertEqual(visible["id"] as? String, id)
    XCTAssertEqual(visible["state"] as? String, "pending")
    XCTAssertNil(visible["errorMessage"])
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

  private func makeBackupApi(
    defaults: UserDefaults,
    store: IosBackupJobStore,
    uploadFailureUpdateOverride: ((String, String) throws -> Bool)? = nil,
    uploadPersistenceFailureReporter:
      ((String, String, Error) -> Void)? = nil
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
      recordingsRoot: FileManager.default.temporaryDirectory,
      uploadFailureUpdateOverride: uploadFailureUpdateOverride,
      uploadPersistenceFailureReporter: uploadPersistenceFailureReporter
    )
  }

  private typealias RetentionCleanupFixture = (
    root: URL, defaults: UserDefaults, suiteName: String, store: IosBackupJobStore,
    api: IosBackupHostApi, file: URL, job: [String: Any]
  )

  private func makeRetentionCleanupFixture(
    id: String,
    availableStorageBytesOverride: (() -> Int64)? = nil,
    storageAttestationOverride:
      (([String: Any], String, Int64) async -> String?)? = nil
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
      eventApi: FakeBackupNativeEventApi(),
      defaults: defaults,
      credentialStore: credentialStore,
      jobStore: .success(store),
      recordingsRoot: recordings,
      availableStorageBytesOverride: availableStorageBytesOverride,
      storageAttestationOverride: storageAttestationOverride
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
    var job = source
    job["verificationVersion"] = 3
    job["verificationReceipt"] = "stored-signed-receipt"
    job["remoteRecordId"] = NSNumber(value: 42)
    job["lastAttestedAt"] = ISO8601DateFormatter().string(from: Date())
    return job
  }

  private func removeRetentionCleanupFixture(_ fixture: RetentionCleanupFixture) {
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

  private func awaitSnapshotResult(
    _ api: IosBackupHostApi
  ) async throws -> [String?: Any?] {
    try await withCheckedThrowingContinuation { continuation in
      api.snapshot { result in
        continuation.resume(with: result.map { $0 ?? [:] })
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
  func snapshotChanged(
    snapshot: [String?: Any?],
    completion: @escaping (Result<Void, PigeonError>) -> Void
  ) {
    completion(.success(()))
  }
}

private final class FakeIosKeychainClient: IosKeychainClient {
  var data: Data?
  var readError: Error?
  var saveError: Error?
  var deleteError: Error?

  func read(service: String, account: String) throws -> Data? {
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
