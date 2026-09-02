import Foundation
import Security
import SQLite3
import Darwin

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

struct IosBackupCleanupIntent: Equatable {
  let token: String
  let jobId: String
  let generation: String
  let originalPath: String
  let tombstonePath: String
  let expectedBytes: Int64
  let expectedModifiedAtMilliseconds: Int64
  let expectedDevice: UInt64
  let expectedInode: UInt64
  let expectedSha256: String?
  let reason: String
  let completedState: String?
  let completedErrorMessage: String?
  let allowedStates: Set<String>
  let phase: String
}

struct IosBackupCleanupSlice {
  let generation: String
  let unbackedRetentionDays: Int
  let backedRetentionDays: Int
  let jobs: [[String: Any]]
  let hasMore: Bool
  let evaluationNow: Date
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
  private static let summaryCounters = [
    (meta: "summary_total_count", value: "totalCount"),
    (meta: "summary_pending_count", value: "pendingCount"),
    (meta: "summary_uploading_count", value: "uploadingCount"),
    (meta: "summary_paused_count", value: "pausedCount"),
    (meta: "summary_completed_count", value: "completedCount"),
    (meta: "summary_failed_count", value: "failedCount"),
    (meta: "summary_waiting_cleanup_count", value: "waitingCleanupCount"),
    (meta: "summary_local_deleted_count", value: "localDeletedCount"),
    (meta: "summary_unfinished_uploaded_bytes", value: "unfinishedUploadedBytes"),
    (meta: "summary_unfinished_total_bytes", value: "unfinishedTotalBytes"),
  ]
  private static let dominantFailurePriority = [
    "credential_invalid",
    "not_backup_host",
    "incompatible_version",
    "verification_failed",
    "storage_unavailable",
    "upload_expired",
    "temporary_service",
    "offline_or_timeout",
    "unknown",
  ]
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

  func readJob(id: String) throws -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    return try readJobUnlocked(id)
  }

  func upsert(_ rawJob: [String: Any]) throws {
    lock.lock()
    defer { lock.unlock() }
    try writeTransactionUnlocked(operation: "保存任务") {
      if let id = rawJob["id"] as? String,
         try prepareJobMutationUnlocked(
           jobId: id, filePath: rawJob["filePath"] as? String
         ) == false {
        throw IosBackupStoreError(
          operation: "保存任务", code: SQLITE_BUSY,
          message: "录像正在完成原子清理，请稍后重试"
        )
      }
      try writeJobUnlocked(rawJob)
    }
  }

  func upsert(_ rawJobs: [[String: Any]]) throws {
    precondition(rawJobs.count <= 100, "单次最多入队 100 个备份任务")
    lock.lock()
    defer { lock.unlock() }
    try writeTransactionUnlocked(operation: "批量保存任务") {
      for rawJob in rawJobs {
        guard let id = rawJob["id"] as? String,
              try prepareJobMutationUnlocked(
                jobId: id, filePath: rawJob["filePath"] as? String
              )
        else {
          throw IosBackupStoreError(
            operation: "批量保存任务", code: SQLITE_BUSY,
            message: "录像正在完成原子清理，请稍后重试"
          )
        }
        try writeJobUnlocked(rawJob)
      }
    }
  }

  func updateJob(id: String, mutate: (inout [String: Any]) -> Void) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    var updated = false
    try writeTransactionUnlocked(operation: "更新任务") {
      guard var job = try readJobUnlocked(id) else { return }
      guard try prepareJobMutationUnlocked(
        jobId: id, filePath: job["filePath"] as? String
      ) else {
        throw IosBackupStoreError(
          operation: "更新任务", code: SQLITE_BUSY,
          message: "录像正在完成原子清理，请稍后重试"
        )
      }
      mutate(&job)
      guard try prepareJobMutationUnlocked(
        jobId: id, filePath: job["filePath"] as? String
      ) else {
        throw IosBackupStoreError(
          operation: "更新任务路径", code: SQLITE_BUSY,
          message: "录像路径正在完成原子清理，请稍后重试"
        )
      }
      try writeJobUnlocked(job)
      updated = true
    }
    return updated
  }

  func recoverIncompatibleFailures(destinationComputerId: String) throws -> Int {
    let destination = destinationComputerId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destination.isEmpty else { return 0 }
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE", operation: "开始恢复兼容任务")
    do {
      let selection =
        "destination_computer_id = ? AND state = 'failed' "
        + "AND failure_kind = 'incompatible_version' "
        + "AND NOT EXISTS (SELECT 1 FROM backup_cleanup_intents i "
        + "WHERE (i.job_id = backup_jobs.id "
        + "OR i.original_path = backup_jobs.file_path) "
        + "AND i.phase IN ('moving','renamed'))"
      func failureCount() throws -> Int {
        var statement: OpaquePointer?
        try prepare(
          "SELECT COUNT(*) FROM backup_jobs WHERE \(selection)",
          statement: &statement,
          operation: "统计兼容失败任务"
        )
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, destination)
        return sqlite3_step(statement) == SQLITE_ROW
          ? Int(integer(statement, 0))
          : 0
      }
      let count = try failureCount()
      guard count > 0 else {
        try execute("COMMIT", operation: "提交空恢复任务")
        return 0
      }

      let revision = try nextRevisionUnlocked()
      func recoverFailures() throws {
        var statement: OpaquePointer?
        try prepare(
          "UPDATE backup_jobs SET state = 'pending', error_message = NULL, " +
            "failure_kind = NULL, revision = ? WHERE \(selection)",
          statement: &statement,
          operation: "恢复兼容失败任务"
        )
        defer { sqlite3_finalize(statement) }
        try bindInt(statement, 1, revision)
        try bindText(statement, 2, destination)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
          throw databaseError(operation: "恢复兼容失败任务", code: code)
        }
      }
      try recoverFailures()
      try setMetaValueUnlocked(
        "summary_pending_count",
        try metaValueUnlocked("summary_pending_count") + Int64(count)
      )
      try setMetaValueUnlocked(
        "summary_failed_count",
        try metaValueUnlocked("summary_failed_count") - Int64(count)
      )
      try execute("COMMIT", operation: "提交恢复兼容任务")
      return count
    } catch {
      try? execute("ROLLBACK", operation: "回滚恢复兼容任务")
      throw error
    }
  }

  /// 在同一 SQLite 写事务内校验并更新任务代次，避免旧上传任务覆盖新状态。
  func updateJob(
    id: String,
    expectedGeneration: String,
    expectedCleanupGeneration: String? = nil,
    mutate: (inout [String: Any]) -> Void
  ) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE", operation: "开始按代次更新任务")
    do {
      let activeCleanupGeneration = try cleanupCheckpointUnlocked()?.generation
      let cleanupGenerationMatches = expectedCleanupGeneration == nil
        || activeCleanupGeneration == expectedCleanupGeneration
      guard cleanupGenerationMatches,
            var job = try readJobUnlocked(id),
            job["generation"] as? String == expectedGeneration
      else {
        try execute("ROLLBACK", operation: "取消过期任务更新")
        return false
      }
      guard try prepareJobMutationUnlocked(
        jobId: id, filePath: job["filePath"] as? String
      ) else {
        try execute("ROLLBACK", operation: "取消清理中的任务更新")
        return false
      }
      mutate(&job)
      guard job["generation"] as? String == expectedGeneration else {
        throw IosBackupStoreError(
          operation: "校验任务代次", code: SQLITE_CONSTRAINT,
          message: "按代次更新不得修改 generation"
        )
      }
      guard try prepareJobMutationUnlocked(
        jobId: id, filePath: job["filePath"] as? String
      ) else {
        try execute("ROLLBACK", operation: "取消清理路径中的任务更新")
        return false
      }
      try writeJobUnlocked(job)
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
    try writeTransactionUnlocked(operation: "删除任务") {
      let current = try readJobUnlocked(id)
      guard try prepareJobMutationUnlocked(
        jobId: id, filePath: current?["filePath"] as? String
      ) else {
        throw IosBackupStoreError(
          operation: "删除任务", code: SQLITE_BUSY,
          message: "录像正在完成原子清理，请稍后重试"
        )
      }
      guard let current else { return }
      _ = try nextRevisionUnlocked()
      try deleteUnlocked(id)
      try adjustSummaryCountersUnlocked(previous: current, current: nil)
    }
  }

  func jobsForPaths(_ paths: [String]) throws -> (revision: Int64, jobs: [[String: Any]]) {
    lock.lock()
    defer { lock.unlock() }
    guard !paths.isEmpty else { return (try metaValueUnlocked("global_revision"), []) }
    let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ",")
    let sql = "\(summaryJobSelect) WHERE file_path IN (\(placeholders)) ORDER BY last_modified DESC"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "按路径查询任务")
    defer { sqlite3_finalize(stmt) }
    for (index, path) in paths.enumerated() {
      try bindText(stmt, Int32(index + 1), path)
    }
    var jobs: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW { jobs.append(summaryJobFromRow(stmt)) }
    return (try metaValueUnlocked("global_revision"), jobs)
  }

  func latestJob(filePathSuffix: String) throws -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    guard !filePathSuffix.isEmpty else { return nil }
    let escaped = filePathSuffix
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    var stmt: OpaquePointer?
    try prepare(
      "\(summaryJobSelect) WHERE file_path LIKE ? ESCAPE '\\' ORDER BY last_modified DESC, revision DESC LIMIT 1",
      statement: &stmt, operation: "按录像相对路径查询任务"
    )
    defer { sqlite3_finalize(stmt) }
    try bindText(stmt, 1, "%\(escaped)")
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return summaryJobFromRow(stmt)
  }

  /// 原子领取一条待上传任务。SQLite 是等待队列的唯一事实源；调用方只为
  /// 实际领取到的任务创建上传 Task，不能为其余 pending 行建立等待 Task。
  func claimNextUploadJob() throws -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE", operation: "开始领取上传任务")
    do {
      let uploading = try firstJobUnlocked(
        whereClause: "state = 'uploading' AND local_deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM backup_cleanup_intents i WHERE (i.job_id = backup_jobs.id OR i.original_path = backup_jobs.file_path) AND i.phase IN ('moving','renamed'))",
        orderBy: "revision ASC, id ASC"
      )
      guard var job = try uploading ?? firstJobUnlocked(
        whereClause: "state = 'pending' AND local_deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM backup_cleanup_intents i WHERE (i.job_id = backup_jobs.id OR i.original_path = backup_jobs.file_path) AND i.phase IN ('moving','renamed'))",
        orderBy: "revision ASC, id ASC"
      ) else {
        try execute("COMMIT", operation: "提交空上传队列领取")
        return nil
      }
      if job["state"] as? String == "pending" {
        job["state"] = "uploading"
        try writeJobUnlocked(job)
      }
      try execute("COMMIT", operation: "提交上传任务领取")
      return job
    } catch {
      try? execute("ROLLBACK", operation: "回滚上传任务领取")
      throw error
    }
  }

  /// Atomically pauses or resumes all unfinished upload work. No recording or
  /// upload progress is removed; generations rotate so late completions from a
  /// cancelled transfer cannot overwrite the paused state.
  func setUploadsEnabled(_ enabled: Bool) throws -> Int {
    lock.lock()
    defer { lock.unlock() }
    let sourceStates = enabled ? "'paused'" : "'pending','uploading'"
    let failureGuard = enabled
      ? " AND (failure_kind IS NULL OR failure_kind = 'storage_unavailable')"
      : ""
    var countStatement: OpaquePointer?
    try prepare(
      "SELECT COUNT(*) FROM backup_jobs WHERE state IN (\(sourceStates))\(failureGuard)",
      statement: &countStatement, operation: "统计待切换备份任务"
    )
    defer { sqlite3_finalize(countStatement) }
    guard sqlite3_step(countStatement) == SQLITE_ROW else {
      throw databaseError(operation: "统计待切换备份任务", code: sqlite3_errcode(db))
    }
    let changed = Int(integer(countStatement, 0))
    guard changed > 0 else { return 0 }
    try writeTransactionUnlocked(operation: enabled ? "恢复备份队列" : "暂停备份队列") {
      let revision = try nextRevisionUnlocked()
      let targetState = enabled ? "pending" : "paused"
      try execute(
        "UPDATE backup_jobs SET state='\(targetState)', generation=lower(hex(randomblob(16))), error_message=NULL, failure_kind=NULL, revision=\(revision) WHERE state IN (\(sourceStates))\(failureGuard)",
        operation: enabled ? "恢复备份任务" : "暂停备份任务"
      )
      if enabled {
        try setMetaValueUnlocked(
          "summary_pending_count",
          try metaValueUnlocked("summary_pending_count") + Int64(changed)
        )
        try setMetaValueUnlocked(
          "summary_paused_count",
          try metaValueUnlocked("summary_paused_count") - Int64(changed)
        )
      } else {
        let pending = try metaValueUnlocked("summary_pending_count")
        let uploading = try metaValueUnlocked("summary_uploading_count")
        try setMetaValueUnlocked("summary_pending_count", 0)
        try setMetaValueUnlocked("summary_uploading_count", 0)
        try setMetaValueUnlocked(
          "summary_paused_count",
          try metaValueUnlocked("summary_paused_count") + pending + uploading
        )
      }
    }
    return changed
  }

  func cleanupCandidateJobsPage(
    afterId: String?, limit: Int = 100
  ) throws -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    guard (1...100).contains(limit) else {
      throw IosBackupStoreError(
        operation: "校验清理分页", code: SQLITE_RANGE, message: "单页数量必须为 1 到 100"
      )
    }
    let cursorClause = afterId == nil ? "" : " AND id > ?"
    let sql = "SELECT * FROM backup_jobs WHERE local_deleted_at IS NULL "
      + "AND state NOT IN ('pending', 'uploading')\(cursorClause) "
      + "AND NOT EXISTS (SELECT 1 FROM backup_cleanup_intents i WHERE i.job_id = backup_jobs.id AND i.phase IN ('claimed','moving','renamed')) "
      + "AND NOT EXISTS (SELECT 1 FROM backup_cleanup_intents i WHERE i.original_path = backup_jobs.file_path AND i.phase IN ('claimed','moving','renamed')) "
      + "ORDER BY id ASC LIMIT \(limit)"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "分页查询清理候选")
    defer { sqlite3_finalize(stmt) }
    if let afterId { try bindText(stmt, 1, afterId, operation: "绑定清理分页游标") }
    var jobs: [[String: Any]] = []
    while true {
      let code = sqlite3_step(stmt)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else {
        throw databaseError(operation: "分页查询清理候选", code: code)
      }
      jobs.append(try jobFromRow(stmt))
    }
    return jobs
  }

  func cleanupCandidateJobsSlice(
    unbackedRetentionDays: Int, backedRetentionDays: Int, limit: Int = 100
  ) throws -> IosBackupCleanupSlice {
    lock.lock()
    defer { lock.unlock() }
    guard (1...100).contains(limit) else {
      throw IosBackupStoreError(
        operation: "校验清理分片", code: SQLITE_RANGE,
        message: "单片数量必须为 1 到 100"
      )
    }
    try execute("BEGIN IMMEDIATE", operation: "开始读取清理分片")
    do {
      var checkpoint = try cleanupCheckpointUnlocked()
      if checkpoint == nil
          || checkpoint!.unbackedDays != unbackedRetentionDays
          || checkpoint!.backedDays != backedRetentionDays
          || checkpoint!.exhausted {
        checkpoint = try newCleanupCheckpointUnlocked(
          unbackedDays: unbackedRetentionDays, backedDays: backedRetentionDays
        )
        try writeCleanupCheckpointUnlocked(checkpoint!)
      }
      let current = checkpoint!
      let cursorClause = current.afterId == nil ? "" : " AND id > ?"
      let predicate = "local_deleted_at IS NULL AND state NOT IN ('pending', 'uploading') "
        + "AND NOT EXISTS (SELECT 1 FROM backup_cleanup_intents i WHERE i.job_id = backup_jobs.id AND i.phase IN ('claimed','moving','renamed')) "
        + "AND NOT EXISTS (SELECT 1 FROM backup_cleanup_intents i WHERE i.original_path = backup_jobs.file_path AND i.phase IN ('claimed','moving','renamed'))"
      var statement: OpaquePointer?
      try prepare(
        "SELECT * FROM backup_jobs WHERE \(predicate)\(cursorClause) ORDER BY id ASC LIMIT \(limit + 1)",
        statement: &statement, operation: "读取清理分片"
      )
      defer { sqlite3_finalize(statement) }
      if let afterId = current.afterId {
        try bindText(statement, 1, afterId, operation: "绑定清理分片游标")
      }
      var jobs: [[String: Any]] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { break }
        guard code == SQLITE_ROW else {
          throw databaseError(operation: "读取清理分片", code: code)
        }
        jobs.append(try jobFromRow(statement))
      }
      let hasMore = jobs.count > limit
      if hasMore { jobs.removeLast() }
      try execute("COMMIT", operation: "提交读取清理分片")
      return IosBackupCleanupSlice(
        generation: current.generation,
        unbackedRetentionDays: current.unbackedDays,
        backedRetentionDays: current.backedDays,
        jobs: jobs, hasMore: hasMore,
        evaluationNow: Date(
          timeIntervalSince1970: Double(current.evaluationNowMilliseconds) / 1000
        )
      )
    } catch {
      try? execute("ROLLBACK", operation: "回滚读取清理分片")
      throw error
    }
  }

  func activateCleanupPolicy(
    unbackedRetentionDays: Int, backedRetentionDays: Int, forceReset: Bool = false
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE", operation: "开始切换清理策略")
    do {
      let current = try cleanupCheckpointUnlocked()
      if forceReset || current == nil
          || current!.unbackedDays != unbackedRetentionDays
          || current!.backedDays != backedRetentionDays {
        // A claimed retention intent has not crossed the irreversible moving
        // barrier yet. Drop it in the same policy-switch transaction so crash
        // recovery cannot apply an older, shorter policy. Storage-pressure
        // intents intentionally use a different reason and are preserved.
        try execute(
          "DELETE FROM backup_cleanup_intents WHERE phase = 'claimed' AND reason IN ('未备份录像保留策略清理','已备份录像保留策略清理')",
          operation: "取消旧策略待执行清理"
        )
        try writeCleanupCheckpointUnlocked(
          try newCleanupCheckpointUnlocked(
            unbackedDays: unbackedRetentionDays, backedDays: backedRetentionDays
          )
        )
      }
      try execute("COMMIT", operation: "提交切换清理策略")
    } catch {
      try? execute("ROLLBACK", operation: "回滚切换清理策略")
      throw error
    }
  }

  /// Advances with generation CAS. When inputs changed behind the cursor, a
  /// fresh sweep is installed atomically instead of declaring the scan done.
  func finishCleanupSlice(_ slice: IosBackupCleanupSlice) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE", operation: "开始推进清理分片")
    do {
      guard let current = try cleanupCheckpointUnlocked(),
            current.generation == slice.generation,
            current.unbackedDays == slice.unbackedRetentionDays,
            current.backedDays == slice.backedRetentionDays
      else {
        try execute("ROLLBACK", operation: "取消过期清理分片")
        return true
      }
      if slice.hasMore, let afterId = slice.jobs.last?["id"] as? String {
        try writeCleanupCheckpointUnlocked((
          current.generation, current.unbackedDays, current.backedDays, afterId,
          current.sweepStartSequence, current.evaluationNowMilliseconds, false
        ))
        try execute("COMMIT", operation: "提交清理分片游标")
        return true
      }
      if try metaValueUnlocked("cleanup_input_sequence") != current.sweepStartSequence {
        try writeCleanupCheckpointUnlocked(
          try newCleanupCheckpointUnlocked(
            unbackedDays: current.unbackedDays, backedDays: current.backedDays
          )
        )
        try execute("COMMIT", operation: "提交重启清理扫描")
        return true
      }
      try writeCleanupCheckpointUnlocked((
        current.generation, current.unbackedDays, current.backedDays,
        slice.jobs.last?["id"] as? String ?? current.afterId,
        current.sweepStartSequence, current.evaluationNowMilliseconds, true
      ))
      try execute("COMMIT", operation: "提交清理扫描完成")
      return false
    } catch {
      try? execute("ROLLBACK", operation: "回滚推进清理分片")
      throw error
    }
  }

  func isCleanupGenerationCurrent(_ generation: String) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return try cleanupCheckpointUnlocked()?.generation == generation
  }

  func beginCleanupIntent(
    jobId: String, expectedGeneration: String, allowedStates: Set<String>,
    originalPath: String, tombstonePath: String, expectedBytes: Int64,
    expectedModifiedAtMilliseconds: Int64, expectedDevice: UInt64,
    expectedInode: UInt64, expectedSha256: String?, reason: String,
    completedState: String?, completedErrorMessage: String?,
    expectedCleanupGeneration: String? = nil
  ) throws -> IosBackupCleanupIntent? {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE", operation: "开始领取清理任务")
    do {
      let activeCleanupGeneration = try cleanupCheckpointUnlocked()?.generation
      let cleanupGenerationMatches = expectedCleanupGeneration == nil
        || activeCleanupGeneration == expectedCleanupGeneration
      guard cleanupGenerationMatches,
            let job = try readJobUnlocked(jobId),
            job["generation"] as? String == expectedGeneration,
            let state = job["state"] as? String,
            allowedStates.contains(state), job["localDeletedAt"] as? String == nil,
            job["filePath"] as? String == originalPath,
            job["totalBytes"] as? Int64 == expectedBytes,
            job["lastModified"] as? Int64 == expectedModifiedAtMilliseconds,
            job["contentSha256"] == nil
              || job["contentSha256"] as? String == expectedSha256,
            try prepareJobMutationUnlocked(jobId: jobId, filePath: originalPath)
      else {
        try execute("ROLLBACK", operation: "取消过期清理领取")
        return nil
      }
      if expectedDevice != 0 || expectedInode != 0 {
        var fileInfo = stat()
        guard lstat(originalPath, &fileInfo) == 0,
              UInt64(fileInfo.st_dev) == expectedDevice,
              UInt64(fileInfo.st_ino) == expectedInode,
              Int64(fileInfo.st_size) == expectedBytes,
              Int64(fileInfo.st_mtimespec.tv_sec) * 1000
                + Int64(fileInfo.st_mtimespec.tv_nsec) / 1_000_000
                == expectedModifiedAtMilliseconds
        else {
          try execute("ROLLBACK", operation: "取消已替换文件清理领取")
          return nil
        }
      } else if FileManager.default.fileExists(atPath: originalPath) {
        try execute("ROLLBACK", operation: "取消重新出现文件清理领取")
        return nil
      }
      let intent = IosBackupCleanupIntent(
        token: UUID().uuidString, jobId: jobId, generation: expectedGeneration,
        originalPath: originalPath, tombstonePath: tombstonePath,
        expectedBytes: expectedBytes,
        expectedModifiedAtMilliseconds: expectedModifiedAtMilliseconds,
        expectedDevice: expectedDevice, expectedInode: expectedInode,
        expectedSha256: expectedSha256, reason: reason,
        completedState: completedState,
        completedErrorMessage: completedErrorMessage,
        allowedStates: allowedStates, phase: "claimed"
      )
      try insertCleanupIntentUnlocked(intent)
      try execute("COMMIT", operation: "提交清理任务领取")
      return intent
    } catch {
      try? execute("ROLLBACK", operation: "回滚清理任务领取")
      throw error
    }
  }

  func activateCleanupIntent(token: String) throws -> IosBackupCleanupIntent? {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE", operation: "开始激活清理意图")
    do {
      guard let intent = try cleanupIntentUnlocked(token: token),
            intent.phase == "claimed",
            let job = try readJobUnlocked(intent.jobId),
            job["generation"] as? String == intent.generation,
            intent.allowedStates.contains(job["state"] as? String ?? ""),
            job["localDeletedAt"] as? String == nil,
            job["filePath"] as? String == intent.originalPath,
            job["totalBytes"] as? Int64 == intent.expectedBytes,
            job["lastModified"] as? Int64 == intent.expectedModifiedAtMilliseconds,
            job["contentSha256"] == nil
              || job["contentSha256"] as? String == intent.expectedSha256
      else {
        try execute("ROLLBACK", operation: "取消过期清理激活")
        return nil
      }
      if intent.expectedDevice != 0 || intent.expectedInode != 0 {
        var fileInfo = stat()
        guard lstat(intent.originalPath, &fileInfo) == 0,
              UInt64(fileInfo.st_dev) == intent.expectedDevice,
              UInt64(fileInfo.st_ino) == intent.expectedInode,
              Int64(fileInfo.st_size) == intent.expectedBytes,
              Int64(fileInfo.st_mtimespec.tv_sec) * 1000
                + Int64(fileInfo.st_mtimespec.tv_nsec) / 1_000_000
                == intent.expectedModifiedAtMilliseconds
        else {
          try execute("ROLLBACK", operation: "取消已替换文件清理激活")
          return nil
        }
      } else if FileManager.default.fileExists(atPath: intent.originalPath) {
        try execute("ROLLBACK", operation: "取消重新出现文件清理激活")
        return nil
      }
      var statement: OpaquePointer?
      try prepare(
        "UPDATE backup_cleanup_intents SET phase = 'moving' WHERE token = ? AND phase = 'claimed'",
        statement: &statement, operation: "激活清理意图"
      )
      defer { sqlite3_finalize(statement) }
      try bindText(statement, 1, token)
      guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
        throw databaseError(operation: "激活清理意图", code: sqlite3_errcode(db))
      }
      try execute("COMMIT", operation: "提交清理意图激活")
      return IosBackupCleanupIntent(
        token: intent.token, jobId: intent.jobId, generation: intent.generation,
        originalPath: intent.originalPath, tombstonePath: intent.tombstonePath,
        expectedBytes: intent.expectedBytes,
        expectedModifiedAtMilliseconds: intent.expectedModifiedAtMilliseconds,
        expectedDevice: intent.expectedDevice, expectedInode: intent.expectedInode,
        expectedSha256: intent.expectedSha256, reason: intent.reason,
        completedState: intent.completedState,
        completedErrorMessage: intent.completedErrorMessage,
        allowedStates: intent.allowedStates, phase: "moving"
      )
    } catch {
      try? execute("ROLLBACK", operation: "回滚清理意图激活")
      throw error
    }
  }

  func updateCleanupIntentPhase(token: String, from: String, to: String) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    var statement: OpaquePointer?
    try prepare(
      "UPDATE backup_cleanup_intents SET phase = ? WHERE token = ? AND phase = ?",
      statement: &statement, operation: "更新清理阶段"
    )
    defer { sqlite3_finalize(statement) }
    try bindText(statement, 1, to)
    try bindText(statement, 2, token)
    try bindText(statement, 3, from)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw databaseError(operation: "更新清理阶段", code: sqlite3_errcode(db))
    }
    return sqlite3_changes(db) == 1
  }

  func cleanupIntents(
    afterToken: String? = nil, limit: Int = 100,
    recoverableOnly: Bool = false
  ) throws -> [IosBackupCleanupIntent] {
    lock.lock()
    defer { lock.unlock() }
    guard (1...100).contains(limit) else {
      throw IosBackupStoreError(
        operation: "校验清理意图分页", code: SQLITE_RANGE,
        message: "单页数量必须为 1 到 100"
      )
    }
    var statement: OpaquePointer?
    let phaseClause = recoverableOnly
      ? "phase IN ('claimed','moving','renamed','committed')" : "1 = 1"
    try prepare(
      "SELECT token,job_id,generation,original_path,tombstone_path,expected_bytes,expected_modified_ms,expected_device,expected_inode,expected_sha256,reason,completed_state,completed_error_message,allowed_states,phase FROM backup_cleanup_intents WHERE \(phaseClause) AND (? IS NULL OR token > ?) ORDER BY token LIMIT \(limit)",
      statement: &statement, operation: "读取清理意图"
    )
    defer { sqlite3_finalize(statement) }
    try bindText(statement, 1, afterToken)
    try bindText(statement, 2, afterToken)
    var intents: [IosBackupCleanupIntent] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      intents.append(cleanupIntentFromRow(statement))
    }
    return intents
  }

  func abandonCleanupIntent(token: String) throws {
    lock.lock()
    defer { lock.unlock() }
    try deleteCleanupIntentUnlocked(token: token)
  }

  func commitCleanupIntent(token: String, deletedAt: Date = Date()) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE", operation: "开始提交清理结果")
    do {
      guard let intent = try cleanupIntentUnlocked(token: token) else {
        try execute("COMMIT", operation: "提交已完成清理结果")
        return false
      }
      guard intent.phase == "renamed" || intent.phase == "committed",
            var job = try readJobUnlocked(intent.jobId),
            job["generation"] as? String == intent.generation,
            intent.allowedStates.contains(job["state"] as? String ?? ""),
            job["filePath"] as? String == intent.originalPath,
            job["localDeletedAt"] as? String == nil
      else {
        try execute("ROLLBACK", operation: "取消过期清理结果")
        return false
      }
      if job["localDeletedAt"] as? String == nil {
        job["localDeletedAt"] = Self.isoFormatter.string(from: deletedAt)
        job["scheduledCleanupAt"] = nil
        job["waitingCleanup"] = false
        job["cleanupReason"] = intent.reason
        if let state = intent.completedState { job["state"] = state }
        if let message = intent.completedErrorMessage { job["errorMessage"] = message }
        try writeJobUnlocked(job)
      }
      var statement: OpaquePointer?
      try prepare(
        "UPDATE backup_cleanup_intents SET phase = 'committed' WHERE token = ?",
        statement: &statement, operation: "提交清理意图"
      )
      defer { sqlite3_finalize(statement) }
      try bindText(statement, 1, token)
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw databaseError(operation: "提交清理意图", code: sqlite3_errcode(db))
      }
      try execute("COMMIT", operation: "提交清理结果")
      return true
    } catch {
      try? execute("ROLLBACK", operation: "回滚清理结果")
      throw error
    }
  }

  func finishCleanupIntent(token: String) throws {
    lock.lock()
    defer { lock.unlock() }
    try deleteCleanupIntentUnlocked(token: token)
  }

  func storageRecoveryJobsPage(
    afterCreatedAtKey: String?,
    afterId: String?,
    minimumVerificationVersion: Int,
    limit: Int = 100
  ) throws -> (jobs: [[String: Any]], nextCreatedAtKey: String?, nextId: String?) {
    lock.lock()
    defer { lock.unlock() }
    guard (1...100).contains(limit), (afterCreatedAtKey == nil) == (afterId == nil) else {
      throw IosBackupStoreError(
        operation: "校验空间回收分页", code: SQLITE_RANGE,
        message: "分页数量必须为 1 到 100 且游标必须完整"
      )
    }
    let createdAtExpression = "COALESCE(file_created_at, '9999-12-31T23:59:59Z')"
    let cursorClause = afterCreatedAtKey == nil
      ? ""
      : " AND (\(createdAtExpression) > ? OR (\(createdAtExpression) = ? AND id > ?))"
    let sql = "SELECT * FROM backup_jobs WHERE state = 'completed' "
      + "AND backup_completed_at IS NOT NULL AND content_sha256 IS NOT NULL "
      + "AND verification_version >= ? AND last_attested_at IS NOT NULL "
      + "AND local_deleted_at IS NULL\(cursorClause) "
      + "AND NOT EXISTS (SELECT 1 FROM backup_cleanup_intents i WHERE (i.job_id = backup_jobs.id OR i.original_path = backup_jobs.file_path) AND i.phase IN ('claimed','moving','renamed')) "
      + "ORDER BY \(createdAtExpression) ASC, id ASC LIMIT \(limit)"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "分页查询空间回收候选")
    defer { sqlite3_finalize(stmt) }
    try bindInt(stmt, 1, Int64(minimumVerificationVersion))
    if let afterCreatedAtKey, let afterId {
      try bindText(stmt, 2, afterCreatedAtKey)
      try bindText(stmt, 3, afterCreatedAtKey)
      try bindText(stmt, 4, afterId)
    }
    var jobs: [[String: Any]] = []
    while true {
      let code = sqlite3_step(stmt)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else {
        throw databaseError(operation: "分页查询空间回收候选", code: code)
      }
      jobs.append(try jobFromRow(stmt))
    }
    let last = jobs.last
    return (
      jobs,
      (last?["fileCreatedAt"] as? String) ?? (last == nil ? nil : "9999-12-31T23:59:59Z"),
      last?["id"] as? String
    )
  }

  func summaryValues() throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    var values: [String: Any] = [
      "revision": try metaValueUnlocked("global_revision"),
      "completedRevision": try metaValueUnlocked("completed_revision"),
      "cleanupHighWatermark": try metaValueUnlocked("cleanup_high_watermark"),
    ]
    for counter in Self.summaryCounters {
      values[counter.value] = try metaValueUnlocked(counter.meta)
    }
    values["activeJob"] = try querySummaryJobsUnlocked(
      whereClause: "state = 'uploading' AND local_deleted_at IS NULL",
      orderBy: "revision DESC",
      limit: 1
    ).first ?? querySummaryJobsUnlocked(
      whereClause: "state = 'pending' AND local_deleted_at IS NULL",
      orderBy: "revision DESC",
      limit: 1
    ).first
    var problemJob: [String: Any]?
    for failureKind in Self.dominantFailurePriority where problemJob == nil {
      problemJob = try querySummaryJobsUnlocked(
        whereClause: "state = 'failed' AND failure_kind = ?",
        orderBy: "revision DESC",
        limit: 1,
        arguments: [failureKind]
      ).first
    }
    problemJob = try problemJob ?? querySummaryJobsUnlocked(
      whereClause: "state = 'failed'",
      orderBy: "revision DESC",
      limit: 1
    ).first ?? querySummaryJobsUnlocked(
      whereClause: "state = 'paused'",
      orderBy: "revision DESC",
      limit: 1
    ).first
    values["problemJob"] = problemJob
    values["dominantFailureKind"] = problemJob?["state"] as? String == "failed"
      ? problemJob?["failureKind"] as? String
      : nil
    return values
  }

  func cleanupEvents(afterRevision: Int64, limit: Int) throws -> (latest: Int64, hasMore: Bool, events: [[String: Any]]) {
    lock.lock()
    defer { lock.unlock() }
    let latest = try metaValueUnlocked("cleanup_high_watermark")
    let sql = "SELECT revision,event_id,job_id,file_path,file_size_bytes,deleted_at_ms,reason FROM backup_cleanup_events WHERE revision > ? ORDER BY revision LIMIT ?"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "查询清理事件")
    defer { sqlite3_finalize(stmt) }
    try bindInt(stmt, 1, afterRevision)
    try bindInt(stmt, 2, Int64(limit + 1))
    var events: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      events.append(["revision": integer(stmt, 0), "eventId": text(stmt, 1) ?? "", "jobId": text(stmt, 2) ?? "", "filePath": text(stmt, 3) ?? "", "fileSizeBytes": integer(stmt, 4), "deletedAtMs": integer(stmt, 5), "reason": text(stmt, 6) ?? ""])
    }
    let hasMore = events.count > limit
    if hasMore { events.removeLast() }
    return (latest, hasMore, events)
  }

  func acknowledgeCleanupEvents(throughRevision: Int64) throws {
    lock.lock()
    defer { lock.unlock() }
    try writeTransactionUnlocked(operation: "确认清理事件") {
      let sql = "DELETE FROM backup_cleanup_events WHERE revision <= ?"
      var stmt: OpaquePointer?
      try prepare(sql, statement: &stmt, operation: "删除已确认清理事件")
      defer { sqlite3_finalize(stmt) }
      try bindInt(stmt, 1, throughRevision)
      guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError(operation: "删除已确认清理事件", code: sqlite3_errcode(db)) }
      try setMetaValueUnlocked("cleanup_ack_revision", max(throughRevision, try metaValueUnlocked("cleanup_ack_revision")))
    }
  }

  func hasPendingJobsOutsideDestination(_ computerId: String) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let sql = "SELECT EXISTS(SELECT 1 FROM backup_jobs WHERE COALESCE(destination_computer_id, '') != ? AND state != 'completed' LIMIT 1)"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "查询其他备份目标")
    defer { sqlite3_finalize(stmt) }
    try bindText(stmt, 1, computerId)
    return sqlite3_step(stmt) == SQLITE_ROW && integer(stmt, 0) != 0
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
        sessions TEXT,
        revision INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS backup_meta (
        key TEXT PRIMARY KEY,
        int_value INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS backup_cleanup_events (
        revision INTEGER PRIMARY KEY,
        event_id TEXT NOT NULL UNIQUE,
        job_id TEXT NOT NULL,
        generation TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_size_bytes INTEGER NOT NULL,
        deleted_at_ms INTEGER NOT NULL,
        reason TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS backup_cleanup_intents (
        token TEXT PRIMARY KEY,
        job_id TEXT NOT NULL,
        generation TEXT NOT NULL,
        original_path TEXT NOT NULL,
        tombstone_path TEXT NOT NULL UNIQUE,
        expected_bytes INTEGER NOT NULL,
        expected_modified_ms INTEGER NOT NULL,
        expected_device INTEGER NOT NULL,
        expected_inode INTEGER NOT NULL,
        expected_sha256 TEXT,
        reason TEXT NOT NULL,
        completed_state TEXT,
        completed_error_message TEXT,
        allowed_states TEXT NOT NULL,
        phase TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS backup_cleanup_scan (
        singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
        generation TEXT NOT NULL,
        unbacked_days INTEGER NOT NULL,
        backed_days INTEGER NOT NULL,
        after_id TEXT,
        sweep_start_sequence INTEGER NOT NULL,
        evaluation_now_ms INTEGER NOT NULL,
        exhausted INTEGER NOT NULL DEFAULT 0
      );
    """
    try execute(sql, operation: "建表")
    if try !columnExistsUnlocked(table: "backup_jobs", column: "revision") {
      try execute("ALTER TABLE backup_jobs ADD COLUMN revision INTEGER NOT NULL DEFAULT 0", operation: "升级任务修订号")
    }
    try execute("DROP INDEX IF EXISTS idx_backup_jobs_resumable_scan; DROP INDEX IF EXISTS idx_backup_jobs_cleanup; CREATE INDEX IF NOT EXISTS idx_backup_jobs_file_path ON backup_jobs(file_path); CREATE INDEX IF NOT EXISTS idx_backup_jobs_state ON backup_jobs(state); CREATE INDEX IF NOT EXISTS idx_backup_jobs_state_id ON backup_jobs(state, id); CREATE INDEX IF NOT EXISTS idx_backup_jobs_state_local_revision ON backup_jobs(state, local_deleted_at, revision DESC); CREATE INDEX IF NOT EXISTS idx_backup_jobs_failure_revision ON backup_jobs(state, failure_kind, revision DESC); CREATE INDEX IF NOT EXISTS idx_backup_jobs_storage_recovery ON backup_jobs(state, local_deleted_at, COALESCE(file_created_at, '9999-12-31T23:59:59Z'), id); CREATE INDEX IF NOT EXISTS idx_backup_jobs_revision ON backup_jobs(revision); CREATE INDEX IF NOT EXISTS idx_backup_jobs_cleanup_scan ON backup_jobs(id) WHERE local_deleted_at IS NULL AND state NOT IN ('pending', 'uploading');", operation: "创建备份索引")
    try execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_backup_cleanup_intents_active_job ON backup_cleanup_intents(job_id) WHERE phase IN ('claimed','moving','renamed')", operation: "创建清理意图索引")
    try execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_backup_cleanup_intents_active_path ON backup_cleanup_intents(original_path) WHERE phase IN ('claimed','moving','renamed')", operation: "创建清理路径索引")
    for key in ["global_revision", "completed_revision", "cleanup_high_watermark", "cleanup_ack_revision", "cleanup_input_sequence"] {
      try execute("INSERT OR IGNORE INTO backup_meta(key,int_value) VALUES ('\(key)',0)", operation: "初始化备份修订号")
    }
    try ensureSummaryCountersUnlocked()
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
        try writeJobUnlocked(job)
      }
      let expectedIds = Set(legacy.compactMap { $0["id"] as? String })
      guard expectedIds.count == legacy.count,
            !expectedIds.contains("")
      else {
        throw IosBackupStoreError(
          operation: "校验旧任务迁移", code: SQLITE_CORRUPT,
          message: "迁移后的任务数量或 ID 不完整"
        )
      }
      for id in expectedIds where try readJobUnlocked(id) == nil {
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

  private func prepareJobMutationUnlocked(
    jobId: String, filePath: String?
  ) throws -> Bool {
    var cancellation: OpaquePointer?
    try prepare(
      "DELETE FROM backup_cleanup_intents WHERE (job_id = ? OR (? IS NOT NULL AND original_path = ?)) AND phase = 'claimed'",
      statement: &cancellation, operation: "取消未激活清理意图"
    )
    try bindText(cancellation, 1, jobId)
    try bindText(cancellation, 2, filePath)
    try bindText(cancellation, 3, filePath)
    guard sqlite3_step(cancellation) == SQLITE_DONE else {
      sqlite3_finalize(cancellation)
      throw databaseError(operation: "取消未激活清理意图", code: sqlite3_errcode(db))
    }
    sqlite3_finalize(cancellation)
    var statement: OpaquePointer?
    try prepare(
      "SELECT EXISTS(SELECT 1 FROM backup_cleanup_intents WHERE (job_id = ? OR (? IS NOT NULL AND original_path = ?)) AND phase IN ('moving','renamed') LIMIT 1)",
      statement: &statement, operation: "检查清理意图"
    )
    defer { sqlite3_finalize(statement) }
    try bindText(statement, 1, jobId)
    try bindText(statement, 2, filePath)
    try bindText(statement, 3, filePath)
    return !(sqlite3_step(statement) == SQLITE_ROW && integer(statement, 0) != 0)
  }

  private func insertCleanupIntentUnlocked(_ intent: IosBackupCleanupIntent) throws {
    let sql = "INSERT INTO backup_cleanup_intents(token,job_id,generation,original_path,tombstone_path,expected_bytes,expected_modified_ms,expected_device,expected_inode,expected_sha256,reason,completed_state,completed_error_message,allowed_states,phase,created_at_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    var statement: OpaquePointer?
    try prepare(sql, statement: &statement, operation: "保存清理意图")
    defer { sqlite3_finalize(statement) }
    try bindText(statement, 1, intent.token)
    try bindText(statement, 2, intent.jobId)
    try bindText(statement, 3, intent.generation)
    try bindText(statement, 4, intent.originalPath)
    try bindText(statement, 5, intent.tombstonePath)
    try bindInt(statement, 6, intent.expectedBytes)
    try bindInt(statement, 7, intent.expectedModifiedAtMilliseconds)
    try bindInt(statement, 8, Int64(bitPattern: intent.expectedDevice))
    try bindInt(statement, 9, Int64(bitPattern: intent.expectedInode))
    try bindText(statement, 10, intent.expectedSha256)
    try bindText(statement, 11, intent.reason)
    try bindText(statement, 12, intent.completedState)
    try bindText(statement, 13, intent.completedErrorMessage)
    try bindText(statement, 14, intent.allowedStates.sorted().joined(separator: ","))
    try bindText(statement, 15, intent.phase)
    try bindInt(statement, 16, Int64(Date().timeIntervalSince1970 * 1000))
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw databaseError(operation: "保存清理意图", code: sqlite3_errcode(db))
    }
  }

  private func cleanupIntentUnlocked(token: String) throws -> IosBackupCleanupIntent? {
    var statement: OpaquePointer?
    try prepare(
      "SELECT token,job_id,generation,original_path,tombstone_path,expected_bytes,expected_modified_ms,expected_device,expected_inode,expected_sha256,reason,completed_state,completed_error_message,allowed_states,phase FROM backup_cleanup_intents WHERE token = ? LIMIT 1",
      statement: &statement, operation: "读取清理意图"
    )
    defer { sqlite3_finalize(statement) }
    try bindText(statement, 1, token)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return cleanupIntentFromRow(statement)
  }

  private func cleanupIntentFromRow(_ statement: OpaquePointer?) -> IosBackupCleanupIntent {
    IosBackupCleanupIntent(
      token: text(statement, 0) ?? "", jobId: text(statement, 1) ?? "",
      generation: text(statement, 2) ?? "", originalPath: text(statement, 3) ?? "",
      tombstonePath: text(statement, 4) ?? "", expectedBytes: integer(statement, 5),
      expectedModifiedAtMilliseconds: integer(statement, 6),
      expectedDevice: UInt64(bitPattern: integer(statement, 7)),
      expectedInode: UInt64(bitPattern: integer(statement, 8)),
      expectedSha256: text(statement, 9), reason: text(statement, 10) ?? "",
      completedState: text(statement, 11), completedErrorMessage: text(statement, 12),
      allowedStates: Set((text(statement, 13) ?? "").split(separator: ",").map(String.init)),
      phase: text(statement, 14) ?? ""
    )
  }

  private func deleteCleanupIntentUnlocked(token: String) throws {
    var statement: OpaquePointer?
    try prepare(
      "DELETE FROM backup_cleanup_intents WHERE token = ?",
      statement: &statement, operation: "删除清理意图"
    )
    defer { sqlite3_finalize(statement) }
    try bindText(statement, 1, token)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw databaseError(operation: "删除清理意图", code: sqlite3_errcode(db))
    }
  }

  private func firstJobUnlocked(
    whereClause: String,
    orderBy: String
  ) throws -> [String: Any]? {
    let sql = "SELECT * FROM backup_jobs WHERE \(whereClause) ORDER BY \(orderBy) LIMIT 1"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "读取首个备份任务")
    defer { sqlite3_finalize(stmt) }
    let stepCode = sqlite3_step(stmt)
    if stepCode == SQLITE_DONE { return nil }
    guard stepCode == SQLITE_ROW else {
      throw databaseError(operation: "读取首个备份任务", code: stepCode)
    }
    return try jobFromRow(stmt)
  }

  private var summaryJobSelect: String {
    """
      SELECT revision,id,file_path,state,uploaded_bytes,total_bytes,last_modified,
        content_sha256,error_message,failure_kind,file_created_at,backup_completed_at,
        scheduled_cleanup_at,local_deleted_at,waiting_cleanup,remote_record_ids,
        destination_computer_id,cleanup_reason FROM backup_jobs
    """
  }

  private func querySummaryJobsUnlocked(
    whereClause: String,
    orderBy: String,
    limit: Int,
    arguments: [String] = []
  ) throws -> [[String: Any]] {
    let sql = "\(summaryJobSelect) WHERE \(whereClause) ORDER BY \(orderBy) LIMIT \(limit)"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "查询备份摘要任务")
    defer { sqlite3_finalize(stmt) }
    for (index, argument) in arguments.enumerated() {
      try bindText(stmt, Int32(index + 1), argument, operation: "绑定摘要任务条件")
    }
    var jobs: [[String: Any]] = []
    while true {
      let code = sqlite3_step(stmt)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else {
        throw databaseError(operation: "查询备份摘要任务", code: code)
      }
      jobs.append(summaryJobFromRow(stmt))
    }
    return jobs
  }

  private func writeJobUnlocked(_ rawJob: [String: Any]) throws {
    let previous = try (rawJob["id"] as? String).flatMap(readJobUnlocked)
    let revision = try nextRevisionUnlocked()
    let job = Self.migratedJob(rawJob)
    try upsertUnlocked(job, revision: revision)
    if cleanupInputChanged(previous: previous, current: job) {
      try setMetaValueUnlocked(
        "cleanup_input_sequence", try metaValueUnlocked("cleanup_input_sequence") + 1
      )
    }
    try adjustSummaryCountersUnlocked(previous: previous, current: job)
    if previous?["state"] as? String == "completed" || job["state"] as? String == "completed" {
      try setMetaValueUnlocked("completed_revision", revision)
    }
    if previous?["localDeletedAt"] == nil, let deletedAt = job["localDeletedAt"] as? String {
      try insertCleanupEventUnlocked(job: job, deletedAt: deletedAt, revision: revision)
      try setMetaValueUnlocked("cleanup_high_watermark", revision)
    }
  }

  private func cleanupInputChanged(
    previous: [String: Any]?, current: [String: Any]
  ) -> Bool {
    guard let previous else { return true }
    for key in [
      "generation", "filePath", "state", "fileCreatedAt", "backupCompletedAt",
      "localDeletedAt", "contentSha256", "verificationVersion", "remoteRecordId",
      "sessions", "totalBytes", "lastModified",
    ] {
      let old = previous[key]
      let new = current[key]
      if old == nil && new == nil { continue }
      guard let oldObject = old as? NSObject, let newObject = new as? NSObject,
            oldObject.isEqual(newObject)
      else { return true }
    }
    return false
  }

  private func upsertUnlocked(_ rawJob: [String: Any], revision: Int64) throws {
    let job = Self.migratedJob(rawJob)
    let sql = """
      INSERT INTO backup_jobs (
        id, generation, file_path, file_name, destination_computer_id, state,
        uploaded_bytes, total_bytes, last_modified, file_created_at,
        backup_completed_at, scheduled_cleanup_at, local_deleted_at,
        waiting_cleanup, remote_record_ids, content_sha256, verification_version,
        verification_receipt, last_attested_at, cleanup_reason, error_message,
        failure_kind, sessions, revision
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        generation=excluded.generation, file_path=excluded.file_path,
        file_name=excluded.file_name, destination_computer_id=excluded.destination_computer_id,
        state=excluded.state, uploaded_bytes=excluded.uploaded_bytes,
        total_bytes=excluded.total_bytes, last_modified=excluded.last_modified,
        file_created_at=excluded.file_created_at, backup_completed_at=excluded.backup_completed_at,
        scheduled_cleanup_at=excluded.scheduled_cleanup_at, local_deleted_at=excluded.local_deleted_at,
        waiting_cleanup=excluded.waiting_cleanup, remote_record_ids=excluded.remote_record_ids,
        content_sha256=excluded.content_sha256, verification_version=excluded.verification_version,
        verification_receipt=excluded.verification_receipt, last_attested_at=excluded.last_attested_at,
        cleanup_reason=excluded.cleanup_reason, error_message=excluded.error_message,
        failure_kind=excluded.failure_kind, sessions=excluded.sessions, revision=excluded.revision
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
    try bindInt(stmt, 24, revision)
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
    job["revision"] = integer(stmt, 23)
    return job
  }

  private func summaryJobFromRow(_ stmt: OpaquePointer?) -> [String: Any] {
    var job: [String: Any] = [:]
    job["revision"] = integer(stmt, 0)
    job["id"] = text(stmt, 1) ?? ""
    job["filePath"] = text(stmt, 2) ?? ""
    job["state"] = text(stmt, 3) ?? ""
    job["uploadedBytes"] = integer(stmt, 4)
    job["totalBytes"] = integer(stmt, 5)
    job["lastModified"] = integer(stmt, 6)
    job["contentSha256"] = text(stmt, 7)
    job["errorMessage"] = text(stmt, 8)
    job["failureKind"] = text(stmt, 9)
    job["fileCreatedAt"] = text(stmt, 10)
    job["backupCompletedAt"] = text(stmt, 11)
    job["scheduledCleanupAt"] = text(stmt, 12)
    job["localDeletedAt"] = text(stmt, 13)
    job["waitingCleanup"] = integer(stmt, 14) != 0
    job["remoteRecordId"] = Self.recordId(text(stmt, 15))
    job["destinationComputerId"] = text(stmt, 16) ?? ""
    job["cleanupReason"] = text(stmt, 17)
    return job
  }

  private func writeTransactionUnlocked(
    operation: String,
    _ body: () throws -> Void
  ) throws {
    try execute("BEGIN IMMEDIATE", operation: "开始\(operation)")
    do {
      try body()
      try execute("COMMIT", operation: "提交\(operation)")
    } catch {
      try? execute("ROLLBACK", operation: "回滚\(operation)")
      throw error
    }
  }

  private func nextRevisionUnlocked() throws -> Int64 {
    let next = try metaValueUnlocked("global_revision") + 1
    try setMetaValueUnlocked("global_revision", next)
    return next
  }

  private typealias CleanupCheckpoint = (
    generation: String, unbackedDays: Int, backedDays: Int, afterId: String?,
    sweepStartSequence: Int64, evaluationNowMilliseconds: Int64, exhausted: Bool
  )

  private func cleanupCheckpointUnlocked() throws -> CleanupCheckpoint? {
    var statement: OpaquePointer?
    try prepare(
      "SELECT generation,unbacked_days,backed_days,after_id,sweep_start_sequence,evaluation_now_ms,exhausted FROM backup_cleanup_scan WHERE singleton_id = 1",
      statement: &statement, operation: "读取清理分片游标"
    )
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return (
      text(statement, 0) ?? "", Int(integer(statement, 1)),
      Int(integer(statement, 2)), text(statement, 3), integer(statement, 4),
      integer(statement, 5), integer(statement, 6) != 0
    )
  }

  private func newCleanupCheckpointUnlocked(
    unbackedDays: Int, backedDays: Int
  ) throws -> CleanupCheckpoint {
    (
      UUID().uuidString, unbackedDays, backedDays, nil,
      try metaValueUnlocked("cleanup_input_sequence"),
      Int64(Date().timeIntervalSince1970 * 1000), false
    )
  }

  private func writeCleanupCheckpointUnlocked(_ value: CleanupCheckpoint) throws {
    var statement: OpaquePointer?
    try prepare(
      "INSERT INTO backup_cleanup_scan(singleton_id,generation,unbacked_days,backed_days,after_id,sweep_start_sequence,evaluation_now_ms,exhausted) VALUES (1,?,?,?,?,?,?,?) ON CONFLICT(singleton_id) DO UPDATE SET generation=excluded.generation,unbacked_days=excluded.unbacked_days,backed_days=excluded.backed_days,after_id=excluded.after_id,sweep_start_sequence=excluded.sweep_start_sequence,evaluation_now_ms=excluded.evaluation_now_ms,exhausted=excluded.exhausted",
      statement: &statement, operation: "保存清理分片游标"
    )
    defer { sqlite3_finalize(statement) }
    try bindText(statement, 1, value.generation)
    try bindInt(statement, 2, Int64(value.unbackedDays))
    try bindInt(statement, 3, Int64(value.backedDays))
    try bindText(statement, 4, value.afterId)
    try bindInt(statement, 5, value.sweepStartSequence)
    try bindInt(statement, 6, value.evaluationNowMilliseconds)
    try bindInt(statement, 7, value.exhausted ? 1 : 0)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw databaseError(operation: "保存清理分片游标", code: sqlite3_errcode(db))
    }
  }

  private func metaValueUnlocked(_ key: String) throws -> Int64 {
    let sql = "SELECT int_value FROM backup_meta WHERE key = ? LIMIT 1"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "读取备份修订号")
    defer { sqlite3_finalize(stmt) }
    try bindText(stmt, 1, key)
    return sqlite3_step(stmt) == SQLITE_ROW ? integer(stmt, 0) : 0
  }

  private func setMetaValueUnlocked(_ key: String, _ value: Int64) throws {
    let sql = "INSERT INTO backup_meta(key,int_value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET int_value=excluded.int_value"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "保存备份修订号")
    defer { sqlite3_finalize(stmt) }
    try bindText(stmt, 1, key)
    try bindInt(stmt, 2, value)
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw databaseError(operation: "保存备份修订号", code: sqlite3_errcode(db))
    }
  }

  private func ensureSummaryCountersUnlocked() throws {
    if try metaValueUnlocked("summary_counters_initialized") == 1 { return }
    let sql = """
      SELECT COUNT(*),
        SUM(CASE WHEN state = 'pending' THEN 1 ELSE 0 END),
        SUM(CASE WHEN state = 'uploading' THEN 1 ELSE 0 END),
        SUM(CASE WHEN state = 'paused' THEN 1 ELSE 0 END),
        SUM(CASE WHEN state = 'completed' THEN 1 ELSE 0 END),
        SUM(CASE WHEN state = 'failed' THEN 1 ELSE 0 END),
        SUM(CASE WHEN waiting_cleanup != 0 THEN 1 ELSE 0 END),
        SUM(CASE WHEN local_deleted_at IS NOT NULL THEN 1 ELSE 0 END),
        SUM(CASE WHEN state != 'completed' THEN uploaded_bytes ELSE 0 END),
        SUM(CASE WHEN state != 'completed' THEN total_bytes ELSE 0 END)
      FROM backup_jobs
    """
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "播种备份摘要计数")
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else {
      throw databaseError(operation: "播种备份摘要计数", code: sqlite3_errcode(db))
    }
    for (index, counter) in Self.summaryCounters.enumerated() {
      try setMetaValueUnlocked(counter.meta, integer(stmt, Int32(index)))
    }
    try setMetaValueUnlocked("summary_counters_initialized", 1)
  }

  private func adjustSummaryCountersUnlocked(
    previous: [String: Any]?,
    current: [String: Any]?
  ) throws {
    let before = summaryMetrics(previous)
    let after = summaryMetrics(current)
    for (index, counter) in Self.summaryCounters.enumerated() {
      let delta = after[index] - before[index]
      if delta == 0 { continue }
      let updated = try metaValueUnlocked(counter.meta) + delta
      guard updated >= 0 else {
        throw IosBackupStoreError(
          operation: "更新摘要计数", code: SQLITE_CORRUPT,
          message: "摘要计数不能为负数：\(counter.meta)"
        )
      }
      try setMetaValueUnlocked(counter.meta, updated)
    }
  }

  private func summaryMetrics(_ job: [String: Any]?) -> [Int64] {
    guard let job else { return Array(repeating: 0, count: Self.summaryCounters.count) }
    let state = job["state"] as? String ?? ""
    return [
      1,
      state == "pending" ? 1 : 0,
      state == "uploading" ? 1 : 0,
      state == "paused" ? 1 : 0,
      state == "completed" ? 1 : 0,
      state == "failed" ? 1 : 0,
      (job["waitingCleanup"] as? Bool) == true ? 1 : 0,
      job["localDeletedAt"] as? String != nil ? 1 : 0,
      state == "completed" ? 0 : (job["uploadedBytes"] as? NSNumber)?.int64Value ?? 0,
      state == "completed" ? 0 : (job["totalBytes"] as? NSNumber)?.int64Value ?? 0,
    ]
  }

  private func insertCleanupEventUnlocked(
    job: [String: Any],
    deletedAt: String,
    revision: Int64
  ) throws {
    guard let jobId = job["id"] as? String,
          let generation = job["generation"] as? String,
          let filePath = job["filePath"] as? String,
          let deletedDate = Self.isoFormatter.date(from: deletedAt)
    else { return }
    let deletedAtMs = Int64(deletedDate.timeIntervalSince1970 * 1000)
    let eventId = "\(jobId):\(generation):\(deletedAtMs)"
    let sql = "INSERT OR IGNORE INTO backup_cleanup_events(revision,event_id,job_id,generation,file_path,file_size_bytes,deleted_at_ms,reason) VALUES (?,?,?,?,?,?,?,?)"
    var stmt: OpaquePointer?
    try prepare(sql, statement: &stmt, operation: "保存清理事件")
    defer { sqlite3_finalize(stmt) }
    try bindInt(stmt, 1, revision)
    try bindText(stmt, 2, eventId)
    try bindText(stmt, 3, jobId)
    try bindText(stmt, 4, generation)
    try bindText(stmt, 5, filePath)
    try bindInt(stmt, 6, (job["totalBytes"] as? NSNumber)?.int64Value ?? 0)
    try bindInt(stmt, 7, deletedAtMs)
    try bindText(stmt, 8, job["cleanupReason"] as? String ?? "本地录像已清理")
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw databaseError(operation: "保存清理事件", code: sqlite3_errcode(db))
    }
  }

  private func columnExistsUnlocked(table: String, column: String) throws -> Bool {
    var stmt: OpaquePointer?
    try prepare("PRAGMA table_info(\(table))", statement: &stmt, operation: "检查备份表字段")
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW {
      if text(stmt, 1) == column { return true }
    }
    return false
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
