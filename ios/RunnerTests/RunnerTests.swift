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

}
