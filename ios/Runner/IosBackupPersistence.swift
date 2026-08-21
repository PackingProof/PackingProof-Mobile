import Foundation
import Security
import SQLite3

/// 备份任务的 SQLite 存储：与 Android 端 `backup_jobs` 表保持同一 schema 与字段语义，
/// 替代旧版把全部任务塞进一个 UserDefaults 数组、每次写入全量重写的方式。
struct IosBackupStoreError: Error, LocalizedError {
  let operation: String
  let code: Int32
  let message: String

  var errorDescription: String? {
    "iOS 备份数据库\(operation)失败（SQLite \(code)：\(message)）"
  }
}

struct IosBackupCredentialError: Error, LocalizedError {
  let operation: String
  let status: OSStatus

  var errorDescription: String? {
    "iOS 备份凭据\(operation)失败（Keychain \(status)）"
  }
}

protocol IosKeychainClient {
  func read(service: String, account: String) throws -> Data?
  func save(_ data: Data, service: String, account: String) throws
  func delete(service: String, account: String) throws
}

struct SystemIosKeychainClient: IosKeychainClient {
  func read(service: String, account: String) throws -> Data? {
    let query = baseQuery(service: service, account: account).merging(
      [
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ],
      uniquingKeysWith: { _, new in new }
    )
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
      throw IosBackupCredentialError(operation: "读取", status: status)
    }
    guard let data = result as? Data else {
      throw IosBackupCredentialError(operation: "解码", status: errSecDecode)
    }
    return data
  }

  func save(_ data: Data, service: String, account: String) throws {
    let query = baseQuery(service: service, account: account)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var addition = query
    addition.merge(attributes, uniquingKeysWith: { _, new in new })
    let addStatus = SecItemAdd(addition as CFDictionary, nil)
    if addStatus == errSecDuplicateItem {
      let updateStatus = SecItemUpdate(
        query as CFDictionary, attributes as CFDictionary
      )
      guard updateStatus == errSecSuccess else {
        throw IosBackupCredentialError(operation: "更新", status: updateStatus)
      }
      return
    }
    guard addStatus == errSecSuccess else {
      throw IosBackupCredentialError(operation: "保存", status: addStatus)
    }
  }

  func delete(service: String, account: String) throws {
    let status = SecItemDelete(
      baseQuery(service: service, account: account) as CFDictionary
    )
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw IosBackupCredentialError(operation: "删除", status: status)
    }
  }

  private func baseQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

final class IosBackupCredentialStore {
  private static let legacyAccessKey = "ios_backup_access_key"
  private static let legacyConnectionKey = "ios_backup_connection"

  private let defaults: UserDefaults
  private let keychain: IosKeychainClient
  private let service: String
  private let account: String

  init(
    defaults: UserDefaults = .standard,
    keychain: IosKeychainClient = SystemIosKeychainClient(),
    service: String = "\(Bundle.main.bundleIdentifier ?? "app.packingproof.mobile").lan-backup",
    account: String = "access-key"
  ) {
    self.defaults = defaults
    self.keychain = keychain
    self.service = service
    self.account = account
  }

  func load() throws -> String? {
    if let secured = try keychain.read(service: service, account: account) {
      let accessKey = try decode(secured)
      removeLegacyCopies()
      return accessKey
    }
    let connection = defaults.dictionary(forKey: Self.legacyConnectionKey)
    let legacy = [
      defaults.string(forKey: Self.legacyAccessKey),
      connection?["accessKey"] as? String,
    ].compactMap { $0 }.first {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard let legacy
    else { return nil }
    try save(legacy)
    return legacy
  }

  func save(_ accessKey: String) throws {
    guard !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw IosBackupCredentialError(operation: "校验", status: errSecParam)
    }
    let data = Data(accessKey.utf8)
    try keychain.save(data, service: service, account: account)
    guard try keychain.read(service: service, account: account) == data else {
      throw IosBackupCredentialError(operation: "校验", status: errSecDecode)
    }
    removeLegacyCopies()
  }

  func delete() throws {
    try keychain.delete(service: service, account: account)
    removeLegacyCopies()
  }

  private func decode(_ data: Data) throws -> String {
    guard let value = String(data: data, encoding: .utf8),
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw IosBackupCredentialError(operation: "解码", status: errSecDecode)
    }
    return value
  }

  private func removeLegacyCopies() {
    defaults.removeObject(forKey: Self.legacyAccessKey)
    guard var connection = defaults.dictionary(forKey: Self.legacyConnectionKey),
          connection.removeValue(forKey: "accessKey") != nil
    else { return }
    defaults.set(connection, forKey: Self.legacyConnectionKey)
  }
}

final class IosBackupJobStore {
  private static let legacyDefaultsKey = "ios_backup_jobs"
  private static let isoFormatter = ISO8601DateFormatter()
  private static let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
  )

  private var db: OpaquePointer?
  private let lock = NSLock()
  private let defaults: UserDefaults

  convenience init() throws {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
      )
    } catch {
      throw IosBackupStoreError(
        operation: "创建目录", code: SQLITE_CANTOPEN, message: error.localizedDescription
      )
    }
    try self.init(
      databaseURL: directory.appendingPathComponent("lan_backup.db"),
      defaults: .standard
    )
  }

  init(databaseURL: URL, defaults: UserDefaults) throws {
    self.defaults = defaults
    let openCode = sqlite3_open_v2(
      databaseURL.path, &db,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
    )
    guard openCode == SQLITE_OK else {
      let error = databaseError(operation: "打开", code: openCode)
      sqlite3_close(db)
      db = nil
      throw error
    }
    do {
      try createSchema()
      try migrateLegacyJobsIfNeeded()
    } catch {
      sqlite3_close(db)
      db = nil
      throw error
    }
  }

  deinit {
    sqlite3_close(db)
  }

  func allJobs() throws -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    return try queryJobsUnlocked()
  }

  func upsert(_ rawJob: [String: Any]) throws {
    lock.lock()
    defer { lock.unlock() }
    try upsertUnlocked(rawJob)
  }

  func updateJob(id: String, mutate: (inout [String: Any]) -> Void) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard var job = try readJobUnlocked(id) else { return false }
    mutate(&job)
    try upsertUnlocked(job)
    return true
  }

  /// 在同一 SQLite 写事务内校验并更新任务代次，避免旧上传任务覆盖新状态。
  func updateJob(
    id: String,
    expectedGeneration: String,
    mutate: (inout [String: Any]) -> Void
  ) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE", operation: "开始按代次更新任务")
    do {
      guard var job = try readJobUnlocked(id),
            job["generation"] as? String == expectedGeneration
      else {
        try execute("ROLLBACK", operation: "取消过期任务更新")
        return false
      }
      mutate(&job)
      guard job["generation"] as? String == expectedGeneration else {
        throw IosBackupStoreError(
          operation: "校验任务代次", code: SQLITE_CONSTRAINT,
          message: "按代次更新不得修改 generation"
        )
      }
      try upsertUnlocked(job)
      try execute("COMMIT", operation: "提交按代次任务更新")
      return true
    } catch {
      try? execute("ROLLBACK", operation: "回滚按代次任务更新")
      throw error
    }
  }

  func deleteJob(id: String) throws {
    lock.lock()
    defer { lock.unlock() }
    try deleteUnlocked(id)
  }

  private func createSchema() throws {
    let sql = """
      CREATE TABLE IF NOT EXISTS backup_jobs (
        id TEXT PRIMARY KEY,
        generation TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_name TEXT,
        destination_computer_id TEXT,
        state TEXT NOT NULL,
        uploaded_bytes INTEGER NOT NULL DEFAULT 0,
        total_bytes INTEGER NOT NULL DEFAULT 0,
        last_modified INTEGER NOT NULL DEFAULT 0,
        file_created_at TEXT,
        backup_completed_at TEXT,
        scheduled_cleanup_at TEXT,
        local_deleted_at TEXT,
        waiting_cleanup INTEGER NOT NULL DEFAULT 0,
        remote_record_ids TEXT,
        content_sha256 TEXT,
        verification_version INTEGER NOT NULL DEFAULT 0,
        verification_receipt TEXT,
        last_attested_at TEXT,
        cleanup_reason TEXT,
        error_message TEXT,
        failure_kind TEXT,
        sessions TEXT
      );
    """
    try execute(sql, operation: "建表")
  }

  private func migrateLegacyJobsIfNeeded() throws {
    lock.lock()
    defer { lock.unlock() }
    guard
      let legacy = defaults.array(
        forKey: Self.legacyDefaultsKey
      ) as? [[String: Any]],
      !legacy.isEmpty
    else { return }
    try execute("BEGIN IMMEDIATE", operation: "开始旧任务迁移")
    do {
      for job in legacy {
        try upsertUnlocked(job)
      }
      let migratedIds = Set(try queryJobsUnlocked().compactMap { $0["id"] as? String })
      let expectedIds = Set(legacy.compactMap { $0["id"] as? String })
      guard expectedIds.count == legacy.count,
            !expectedIds.contains(""),
            expectedIds.isSubset(of: migratedIds)
      else {
        throw IosBackupStoreError(
          operation: "校验旧任务迁移", code: SQLITE_CORRUPT,
          message: "迁移后的任务数量或 ID 不完整"
        )
      }
      try execute("COMMIT", operation: "提交旧任务迁移")
    } catch {
      try? execute("ROLLBACK", operation: "回滚旧任务迁移")
      throw error
    }
    defaults.removeObject(forKey: Self.legacyDefaultsKey)
  }

  private func readJobUnlocked(_ id: String) throws -> [String: Any]? {
    let sql = "SELECT * FROM backup_jobs WHERE id = ? LIMIT 1"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "读取任务")
    try bindText(stmt, 1, id, operation: "绑定任务 ID")
    defer { sqlite3_finalize(stmt) }
    let stepCode = sqlite3_step(stmt)
    if stepCode == SQLITE_DONE { return nil }
    guard stepCode == SQLITE_ROW else {
      throw databaseError(operation: "读取任务", code: stepCode)
    }
    return try jobFromRow(stmt)
  }

  private func queryJobsUnlocked() throws -> [[String: Any]] {
    let sql = "SELECT * FROM backup_jobs ORDER BY last_modified DESC"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "查询任务")
    defer { sqlite3_finalize(stmt) }
    var jobs: [[String: Any]] = []
    while true {
      let stepCode = sqlite3_step(stmt)
      if stepCode == SQLITE_DONE { break }
      guard stepCode == SQLITE_ROW else {
        throw databaseError(operation: "查询任务", code: stepCode)
      }
      jobs.append(try jobFromRow(stmt))
    }
    return jobs
  }

  private func upsertUnlocked(_ rawJob: [String: Any]) throws {
    let job = Self.migratedJob(rawJob)
    let sql = """
      INSERT OR REPLACE INTO backup_jobs (
        id, generation, file_path, file_name, destination_computer_id, state,
        uploaded_bytes, total_bytes, last_modified, file_created_at,
        backup_completed_at, scheduled_cleanup_at, local_deleted_at,
        waiting_cleanup, remote_record_ids, content_sha256, verification_version,
        verification_receipt, last_attested_at, cleanup_reason, error_message,
        failure_kind, sessions
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "保存任务")
    defer { sqlite3_finalize(stmt) }
    let row = try jobRow(job)
    try bindText(stmt, 1, row["id"] as? String)
    try bindText(stmt, 2, row["generation"] as? String)
    try bindText(stmt, 3, row["file_path"] as? String)
    try bindText(stmt, 4, row["file_name"] as? String)
    try bindText(stmt, 5, row["destination_computer_id"] as? String)
    try bindText(stmt, 6, row["state"] as? String)
    try bindInt(stmt, 7, (row["uploaded_bytes"] as? NSNumber)?.int64Value ?? 0)
    try bindInt(stmt, 8, (row["total_bytes"] as? NSNumber)?.int64Value ?? 0)
    try bindInt(stmt, 9, (row["last_modified"] as? NSNumber)?.int64Value ?? 0)
    try bindText(stmt, 10, row["file_created_at"] as? String)
    try bindText(stmt, 11, row["backup_completed_at"] as? String)
    try bindText(stmt, 12, row["scheduled_cleanup_at"] as? String)
    try bindText(stmt, 13, row["local_deleted_at"] as? String)
    try bindInt(stmt, 14, ((row["waiting_cleanup"] as? Bool) ?? false) ? 1 : 0)
    try bindText(stmt, 15, row["remote_record_ids"] as? String)
    try bindText(stmt, 16, row["content_sha256"] as? String)
    try bindInt(stmt, 17, Int64((row["verification_version"] as? NSNumber)?.intValue ?? 0))
    try bindText(stmt, 18, row["verification_receipt"] as? String)
    try bindText(stmt, 19, row["last_attested_at"] as? String)
    try bindText(stmt, 20, row["cleanup_reason"] as? String)
    try bindText(stmt, 21, row["error_message"] as? String)
    try bindText(stmt, 22, row["failure_kind"] as? String)
    try bindText(stmt, 23, row["sessions"] as? String)
    let stepCode = sqlite3_step(stmt)
    guard stepCode == SQLITE_DONE else {
      throw databaseError(operation: "保存任务", code: stepCode)
    }
  }

  /// 旧版本任务字段补齐：fileCreatedAt 用文件 lastModified（与 Android 一致），
  /// 其余用文件元数据或默认值回填，避免旧任务被误判为未备份/可清理。
  private static func migratedJob(_ job: [String: Any]) -> [String: Any] {
    var result = job
    let path = job["filePath"] as? String ?? ""
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let modified = attributes?[.modificationDate] as? Date
    let size = (attributes?[.size] as? NSNumber)?.int64Value

    if result["fileCreatedAt"] == nil, let modified {
      result["fileCreatedAt"] = isoFormatter.string(from: modified)
    }
    if result["lastModified"] == nil, let modified {
      result["lastModified"] = Int64(modified.timeIntervalSince1970 * 1000)
    }
    if (result["totalBytes"] as? Int64 ?? 0) <= 0, let size {
      result["totalBytes"] = size
    }
    if result["generation"] == nil {
      result["generation"] = UUID().uuidString
    }
    if result["verificationVersion"] == nil {
      result["verificationVersion"] = 0
    }
    if result["remoteRecordId"] == nil,
       let legacyIds = result["remoteRecordIds"] as? [Any],
       legacyIds.count == 1,
       let legacyId = legacyIds.first as? NSNumber {
      result["remoteRecordId"] = legacyId
    }
    result.removeValue(forKey: "remoteRecordIds")
    return result
  }

  private func deleteUnlocked(_ id: String) throws {
    let sql = "DELETE FROM backup_jobs WHERE id = ?"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "删除任务")
    defer { sqlite3_finalize(stmt) }
    try bindText(stmt, 1, id)
    let stepCode = sqlite3_step(stmt)
    guard stepCode == SQLITE_DONE else {
      throw databaseError(operation: "删除任务", code: stepCode)
    }
  }

  private func jobRow(_ job: [String: Any]) throws -> [String: Any?] {
    guard let id = nonEmptyText(job["id"]),
          let generation = nonEmptyText(job["generation"]),
          let filePath = nonEmptyText(job["filePath"]),
          let state = nonEmptyText(job["state"])
    else {
      throw IosBackupStoreError(
        operation: "校验任务", code: SQLITE_CONSTRAINT,
        message: "任务缺少 id、generation、filePath 或 state"
      )
    }
    return [
      "id": id,
      "generation": generation,
      "file_path": filePath,
      "file_name": job["fileName"] as? String,
      "destination_computer_id": job["destinationComputerId"] as? String,
      "state": state,
      "uploaded_bytes": (job["uploadedBytes"] as? NSNumber)?.int64Value ?? 0,
      "total_bytes": (job["totalBytes"] as? NSNumber)?.int64Value ?? 0,
      "last_modified": (job["lastModified"] as? NSNumber)?.int64Value ?? 0,
      "file_created_at": job["fileCreatedAt"] as? String,
      "backup_completed_at": job["backupCompletedAt"] as? String,
      "scheduled_cleanup_at": job["scheduledCleanupAt"] as? String,
      "local_deleted_at": job["localDeletedAt"] as? String,
      "waiting_cleanup": (job["waitingCleanup"] as? Bool) ?? false,
      "remote_record_ids": (job["remoteRecordId"] as? NSNumber)?.stringValue,
      "content_sha256": job["contentSha256"] as? String,
      "verification_version": (job["verificationVersion"] as? NSNumber)?.intValue ?? 0,
      "verification_receipt": job["verificationReceipt"] as? String,
      "last_attested_at": job["lastAttestedAt"] as? String,
      "cleanup_reason": job["cleanupReason"] as? String,
      "error_message": job["errorMessage"] as? String,
      "failure_kind": job["failureKind"] as? String,
      "sessions": try Self.jsonText(job["sessions"]),
    ]
  }

  private func jobFromRow(_ stmt: OpaquePointer?) throws -> [String: Any] {
    var job: [String: Any] = [:]
    job["id"] = text(stmt, 0) ?? ""
    job["generation"] = text(stmt, 1) ?? ""
    job["filePath"] = text(stmt, 2) ?? ""
    job["fileName"] = text(stmt, 3)
    job["destinationComputerId"] = text(stmt, 4)
    job["state"] = text(stmt, 5) ?? ""
    job["uploadedBytes"] = integer(stmt, 6)
    job["totalBytes"] = integer(stmt, 7)
    job["lastModified"] = integer(stmt, 8)
    job["fileCreatedAt"] = text(stmt, 9)
    job["backupCompletedAt"] = text(stmt, 10)
    job["scheduledCleanupAt"] = text(stmt, 11)
    job["localDeletedAt"] = text(stmt, 12)
    job["waitingCleanup"] = integer(stmt, 13) != 0
    job["remoteRecordId"] = Self.recordId(text(stmt, 14))
    job["contentSha256"] = text(stmt, 15)
    job["verificationVersion"] = Int(integer(stmt, 16))
    job["verificationReceipt"] = text(stmt, 17)
    job["lastAttestedAt"] = text(stmt, 18)
    job["cleanupReason"] = text(stmt, 19)
    job["errorMessage"] = text(stmt, 20)
    job["failureKind"] = text(stmt, 21)
    job["sessions"] = try Self.jsonArray(text(stmt, 22))
    return job
  }

  private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: value)
  }

  private func integer(_ stmt: OpaquePointer?, _ index: Int32) -> Int64 {
    sqlite3_column_int64(stmt, index)
  }

  private func bindText(
    _ stmt: OpaquePointer?, _ index: Int32, _ value: String?,
    operation: String = "绑定文本"
  ) throws {
    guard let stmt else {
      throw databaseError(operation: operation, code: SQLITE_MISUSE)
    }
    let code: Int32
    if let value {
      code = sqlite3_bind_text(stmt, index, value, -1, Self.sqliteTransient)
    } else {
      code = sqlite3_bind_null(stmt, index)
    }
    guard code == SQLITE_OK else {
      throw databaseError(operation: operation, code: code)
    }
  }

  private func bindInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64) throws {
    guard let stmt else {
      throw databaseError(operation: "绑定整数", code: SQLITE_MISUSE)
    }
    let code = sqlite3_bind_int64(stmt, index, value)
    guard code == SQLITE_OK else {
      throw databaseError(operation: "绑定整数", code: code)
    }
  }

  private static func jsonText(_ value: Any?) throws -> String? {
    guard let value else { return nil }
    guard value is [Any], JSONSerialization.isValidJSONObject(value) else {
      throw IosBackupStoreError(
        operation: "编码任务", code: SQLITE_MISMATCH, message: "sessions 不是有效的 JSON 数组"
      )
    }
    let data = try JSONSerialization.data(withJSONObject: value)
    guard let text = String(data: data, encoding: .utf8) else {
      throw IosBackupStoreError(
        operation: "编码任务", code: SQLITE_MISMATCH, message: "JSON 不是 UTF-8"
      )
    }
    return text
  }

  private static func jsonArray(_ value: String?) throws -> [Any] {
    guard let value else { return [] }
    guard let data = value.data(using: .utf8) else {
      throw IosBackupStoreError(
        operation: "解码任务", code: SQLITE_CORRUPT, message: "sessions 不是 UTF-8"
      )
    }
    do {
      guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
        throw IosBackupStoreError(
          operation: "解码任务", code: SQLITE_CORRUPT, message: "sessions 不是 JSON 数组"
        )
      }
      return array
    } catch let error as IosBackupStoreError {
      throw error
    } catch {
      throw IosBackupStoreError(
        operation: "解码任务", code: SQLITE_CORRUPT, message: "sessions JSON 已损坏"
      )
    }
  }

  private static func recordId(_ value: String?) -> NSNumber? {
    guard let value else { return nil }
    if let number = Int64(value) { return NSNumber(value: number) }
    guard let data = value.data(using: .utf8),
          let legacy = try? JSONSerialization.jsonObject(with: data) as? [Any],
          legacy.count == 1,
          let number = legacy.first as? NSNumber
    else { return nil }
    return number
  }

  private func nonEmptyText(_ value: Any?) -> String? {
    guard let text = value as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return text
  }

  private func execute(_ sql: String, operation: String) throws {
    let code = sqlite3_exec(db, sql, nil, nil, nil)
    guard code == SQLITE_OK else {
      throw databaseError(operation: operation, code: code)
    }
  }

  private func prepare(
    _ sql: String,
    statement: inout OpaquePointer?,
    operation: String
  ) throws {
    let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard code == SQLITE_OK else {
      throw databaseError(operation: operation, code: code)
    }
  }

  private func databaseError(operation: String, code: Int32) -> IosBackupStoreError {
    let message = db.map { String(cString: sqlite3_errmsg($0)) }
      ?? String(cString: sqlite3_errstr(code))
    return IosBackupStoreError(operation: operation, code: code, message: message)
  }
}
