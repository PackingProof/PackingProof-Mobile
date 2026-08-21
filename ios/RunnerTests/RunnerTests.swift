import Flutter
import CryptoKit
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testLanBackupVersionComparison() {
    XCTAssertEqual(compareLanBackupVersions("v0.5.11+11011", "0.5.11"), 0)
    XCTAssertGreaterThan(compareLanBackupVersions("0.5.12", "0.5.11"), 0)
    XCTAssertLessThan(compareLanBackupVersions("0.5.10", "0.5.11"), 0)
    XCTAssertLessThan(compareLanBackupVersions("invalid", "0.5.11"), 0)
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
