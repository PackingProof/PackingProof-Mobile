import XCTest

final class IosDeviceSecurityTests: XCTestCase {
  func testSystemKeychainRoundTripUsesIsolatedNamespace() throws {
    let client = SystemIosKeychainClient()
    let service = isolatedService()
    let account = "access-key-\(UUID().uuidString)"
    defer { try? client.delete(service: service, account: account) }
    let expected = Data("device-test-access-key".utf8)

    try client.save(expected, service: service, account: account)
    XCTAssertEqual(try client.read(service: service, account: account), expected)
    try client.delete(service: service, account: account)
    XCTAssertNil(try client.read(service: service, account: account))
  }

  func testCredentialStoreMigratesAndScrubsIsolatedLegacyCopies() throws {
    let client = SystemIosKeychainClient()
    let service = isolatedService()
    let account = "access-key-\(UUID().uuidString)"
    let suiteName = "app.packingproof.mobile.devicetest.defaults.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      try? client.delete(service: service, account: account)
      defaults.removePersistentDomain(forName: suiteName)
    }
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("legacy-access-key", forKey: "ios_backup_access_key")
    defaults.set(
      ["accessKey": "legacy-connection-key", "baseUrl": "http://test.invalid"],
      forKey: "ios_backup_connection"
    )
    let store = IosBackupCredentialStore(
      defaults: defaults,
      keychain: client,
      service: service,
      account: account
    )

    XCTAssertEqual(try store.load(), "legacy-access-key")
    XCTAssertEqual(
      try client.read(service: service, account: account),
      Data("legacy-access-key".utf8)
    )
    XCTAssertNil(defaults.object(forKey: "ios_backup_access_key"))
    let connection = try XCTUnwrap(
      defaults.dictionary(forKey: "ios_backup_connection")
    )
    XCTAssertNil(connection["accessKey"])
    XCTAssertEqual(connection["baseUrl"] as? String, "http://test.invalid")

    try store.delete()
    XCTAssertNil(try client.read(service: service, account: account))
  }

  private func isolatedService() -> String {
    "app.packingproof.mobile.devicetest.lan-backup.\(UUID().uuidString)"
  }
}
