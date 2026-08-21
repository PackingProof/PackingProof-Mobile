import CryptoKit
import Darwin
import Foundation
import Network

private struct BackupTransferError: Error {
  let statusCode: Int
  let errorCode: String
  let message: String
  let failureKind: String
  let expectedOffset: Int64?

  init(
    statusCode: Int,
    errorCode: String,
    message: String,
    failureKind: String,
    expectedOffset: Int64? = nil
  ) {
    self.statusCode = statusCode
    self.errorCode = errorCode
    self.message = message
    self.failureKind = failureKind
    self.expectedOffset = expectedOffset
  }
}

private struct BackupSourceError: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

struct IosBackupFileSnapshot: Equatable {
  let byteCount: Int64
  let modifiedAtMilliseconds: Int64

  static func read(from url: URL) throws -> IosBackupFileSnapshot {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
      throw BackupSourceError(message: "无法读取录像文件信息")
    }
    guard let size = attributes[.size] as? NSNumber,
          let modified = attributes[.modificationDate] as? Date,
          size.int64Value > 0
    else {
      throw BackupSourceError(message: "录像文件不存在或为空")
    }
    return IosBackupFileSnapshot(
      byteCount: size.int64Value,
      modifiedAtMilliseconds: Int64(modified.timeIntervalSince1970 * 1000)
    )
  }
}

/// 用 FileHandle 保持上传内存有界，并在每次读块前确认源文件没有被替换。
final class IosBackupFileReader {
  let snapshot: IosBackupFileSnapshot
  private let url: URL
  private let handle: FileHandle

  init(url: URL) throws {
    self.url = url
    snapshot = try IosBackupFileSnapshot.read(from: url)
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw BackupSourceError(message: "无法打开录像文件")
    }
  }

  deinit { try? handle.close() }

  func sha256(bufferSize: Int = 1024 * 1024) throws -> String {
    try assertUnchanged()
    try handle.seek(toOffset: 0)
    var hasher = SHA256()
    var consumed: Int64 = 0
    while consumed < snapshot.byteCount {
      try Task.checkCancellation()
      let requested = min(Int64(bufferSize), snapshot.byteCount - consumed)
      guard let data = try handle.read(upToCount: Int(requested)), !data.isEmpty else {
        throw BackupSourceError(message: "录像文件读取不完整")
      }
      consumed += Int64(data.count)
      hasher.update(data: data)
    }
    try assertUnchanged()
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func read(offset: Int64, count: Int) throws -> Data {
    try assertUnchanged()
    guard offset >= 0, offset < snapshot.byteCount else {
      throw BackupSourceError(message: "录像上传偏移无效")
    }
    let expected = min(Int64(count), snapshot.byteCount - offset)
    try handle.seek(toOffset: UInt64(offset))
    guard let data = try handle.read(upToCount: Int(expected)),
          data.count == Int(expected)
    else {
      throw BackupSourceError(message: "录像文件读取不完整")
    }
    try assertUnchanged()
    return data
  }

  func assertUnchanged() throws {
    guard try IosBackupFileSnapshot.read(from: url) == snapshot else {
      throw BackupSourceError(message: "录像文件已被替换，已停止备份")
    }
  }
}

/// 电脑完成回执的本地信任边界。只有所有绑定字段和 HMAC 都通过，
/// 才允许把任务标记为 completed/可清理。
enum IosBackupReceiptVerifier {
  static let version = 3
  static let freshness: TimeInterval = 5 * 60

  static func verify(
    _ response: [String: Any],
    accessKey: String,
    hostNodeId: String,
    sourceDeviceId: String,
    sourceSessionId: String,
    fileSha256: String,
    fileSizeBytes: Int64,
    recordId: Int64,
    now: Date = Date()
  ) -> Bool {
    guard response["status"] as? String == "verified",
          int(response["authVersion"]) == version,
          let verifiedAt = int64(response["verifiedAtUnixSeconds"]),
          abs(Int64(now.timeIntervalSince1970) - verifiedAt) <= Int64(freshness),
          let responseHost = response["hostNodeId"] as? String,
          let responseDevice = response["sourceDeviceId"] as? String,
          let responseSession = response["sourceSessionId"] as? String,
          let responseSha = response["fileSha256"] as? String,
          let responseSize = int64(response["fileSizeBytes"]),
          let responseRecord = int64(response["recordId"]),
          response["recordIds"] == nil,
          let signature = response["receiptSignature"] as? String,
          responseHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
            hostNodeId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          responseDevice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
            sourceDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          responseSession == sourceSessionId,
          responseSha.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
            fileSha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          responseSize == fileSizeBytes,
          responseRecord == recordId
    else {
      return false
    }

    let canonical = [
      "packingproof-verified-receipt-v3",
      responseHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      responseDevice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      responseSession.trimmingCharacters(in: .whitespacesAndNewlines),
      fileSha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      String(fileSizeBytes),
      String(recordId),
      String(verifiedAt),
    ].joined(separator: "\n")
    let key = SymmetricKey(data: IosBackupHostApi.secretDataValue(accessKey))
    let expected = HMAC<SHA256>.authenticationCode(
      for: Data(canonical.utf8), using: key
    ).map { String(format: "%02x", $0) }.joined()
    return constantTimeEquals(expected, signature)
  }

  private static func int(_ value: Any?) -> Int? {
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? Int { return value }
    return nil
  }

  private static func int64(_ value: Any?) -> Int64? {
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    return nil
  }

  private static func constantTimeEquals(_ left: String, _ right: String) -> Bool {
    let a = Array(left.lowercased().utf8)
    let b = Array(right.lowercased().utf8)
    guard a.count == b.count else { return false }
    var result: UInt8 = 0
    for index in 0..<a.count { result |= a[index] ^ b[index] }
    return result == 0
  }
}

enum IosBackupCleanupGate {
  static func hasSingleSession(_ job: [String: Any]) -> Bool {
    (job["sessions"] as? [Any])?.count == 1
  }

  static func hasVerifiedRetentionEvidence(
    _ job: [String: Any],
    minimumVersion: Int
  ) -> Bool {
    let contentSha256 = job["contentSha256"] as? String
    let version = job["verificationVersion"] as? Int ?? 0
    let recordId = job["remoteRecordId"] as? NSNumber
    let totalBytes = job["totalBytes"] as? Int64 ?? -1
    let receipt = job["verificationReceipt"] as? String
    return version >= minimumVersion &&
      contentSha256?.count == 64 &&
      totalBytes > 0 &&
      (recordId?.int64Value ?? 0) > 0 &&
      !(receipt?.isEmpty ?? true) &&
      hasSingleSession(job)
  }
}

struct IosBackupUploadIdentity: Equatable {
  let generation: String
  let token: UUID
}

enum IosBackupActiveUploadGate {
  static func shouldRemove(
    active: IosBackupUploadIdentity?,
    finished: IosBackupUploadIdentity
  ) -> Bool {
    active == finished
  }
}

final class IosBackupHostApi: BackupNativeHostApi {
  private struct ActiveUpload {
    let identity: IosBackupUploadIdentity
    let task: Task<Void, Never>
  }

  private let defaults: UserDefaults
  private let credentialStore: IosBackupCredentialStore
  private let jobStore: Result<IosBackupJobStore, Error>
  private let eventApi: BackupNativeEventApiProtocol
  private let recordingsRoot: URL?
  private let networkMonitor = NWPathMonitor()
  private let networkQueue = DispatchQueue(label: "ios.backup.network")
  private var lastLanReachable = false
  private let uploadsLock = NSLock()
  private var activeUploads: [String: ActiveUpload] = [:]
  private var uploadTail: Task<Void, Never> = Task { }
  private let cleanupLock = NSLock()
  private let hostResolver = IosLanBackupHostResolver()
  private var cleanupRunning = false
  private var lastCleanupAt = Date.distantPast
  private let emitLock = NSLock()
  private var emitScheduled = false
  private let keys = (
    deviceId: "ios_backup_device_id",
    deviceName: "ios_backup_device_name",
    connection: "ios_backup_connection",
    jobs: "ios_backup_jobs",
    retention: "ios_backup_retention"
  )

  private static let verificationVersion = 3
  private static let retentionConfirmationGrace: TimeInterval = 24 * 60 * 60
  private static let storageAttestationFreshness: TimeInterval = 5 * 60
  private static let cleanupThrottle: TimeInterval = 60
  private static let isoFormatter = ISO8601DateFormatter()

  private enum AttestationResult {
    case confirmed(receiptSignature: String)
    case missing
    case unauthorized
    case notReady
    case unreachable
  }

  private enum FileCleanupResult {
    case deleted
    case missing
    case stale
    case failed
  }

  init(
    eventApi: BackupNativeEventApiProtocol,
    defaults: UserDefaults = .standard,
    credentialStore: IosBackupCredentialStore? = nil,
    jobStore: Result<IosBackupJobStore, Error>? = nil,
    recordingsRoot: URL? = nil
  ) {
    self.eventApi = eventApi
    self.defaults = defaults
    self.credentialStore =
      credentialStore ?? IosBackupCredentialStore(defaults: defaults)
    self.jobStore = jobStore ?? Result { try IosBackupJobStore() }
    self.recordingsRoot = recordingsRoot
    networkMonitor.pathUpdateHandler = { [weak self] path in
      self?.lastLanReachable =
        path.status == .satisfied && !path.usesInterfaceType(.cellular)
    }
    networkMonitor.start(queue: networkQueue)
  }

  deinit {
    networkMonitor.cancel()
  }

  func snapshot(completion: @escaping (Result<[String?: Any?]?, Error>) -> Void) {
    triggerCleanupIfDue()
    completion(Result { try currentSnapshot() })
  }

  func initialize(
    request: [String?: Any?],
    completion: @escaping (Result<[String?: Any?]?, Error>) -> Void
  ) {
    saveRetentionDays(
      unbacked: (request["unbackedRetentionDays"] as? Int) ?? -1,
      backed: (request["backedRetentionDays"] as? Int) ?? -1
    )
    triggerCleanup()
    completion(Result { try currentSnapshot() })
  }

  func loadAccessKey(completion: @escaping (Result<String?, Error>) -> Void) {
    completion(Result { try credentialStore.load() })
  }

  func isWifiConnected(completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.success(lastLanReachable))
  }

  func saveConnection(
    connection: [String?: Any?],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      guard let accessKey = connection["accessKey"] as? String else {
        throw pigeonError("备份连接缺少访问密钥", code: "credential_missing")
      }
      try credentialStore.save(accessKey)
      var stored = normalized(connection)
      stored.removeValue(forKey: "accessKey")
      defaults.set(stored, forKey: keys.connection)
      defaults.set(connection["deviceName"] as? String, forKey: keys.deviceName)
      emitSnapshot()
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func disconnect(completion: @escaping (Result<Void, Error>) -> Void) {
    do {
      try credentialStore.delete()
      defaults.removeObject(forKey: keys.connection)
      emitSnapshot()
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func enqueueJob(
    request: [String?: Any?],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    var job = normalized(request)
    let path = request["filePath"] as? String ?? ""
    let id = request["id"] as? String ?? stableId(path)
    let fileSize = (try? FileManager.default.attributesOfItem(
      atPath: path
    )[.size] as? Int64) ?? 0
    job["id"] = id
    job["generation"] = UUID().uuidString
    job["state"] = "pending"
    job["uploadedBytes"] = 0
    job["totalBytes"] = fileSize
    job.removeValue(forKey: "errorMessage")
    job.removeValue(forKey: "failureKind")
    do {
      try upsert(job)
      startUpload(job)
      emitSnapshot()
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func requeueJob(
    jobId: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      try updateJob(jobId, mutate: { job in
        job["generation"] = UUID().uuidString
        job["state"] = "pending"
        job.removeValue(forKey: "errorMessage")
        job.removeValue(forKey: "failureKind")
      })
      cancelActiveUpload(jobId: jobId)
      if let job = try jobs().first(where: { $0["id"] as? String == jobId }) {
        startUpload(job)
      }
      emitSnapshot()
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func cancelJob(
    jobId: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      try updateJob(jobId, mutate: { job in
        job["generation"] = UUID().uuidString
        job["state"] = "paused"
      })
      cancelActiveUpload(jobId: jobId)
      emitSnapshot()
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func updateRetentionSchedule(
    request: [String?: Any?],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    saveRetentionDays(
      unbacked: (request["unbackedRetentionDays"] as? Int) ?? -1,
      backed: (request["backedRetentionDays"] as? Int) ?? -1
    )
    triggerCleanup()
    completion(.success(()))
  }

  func reclaimStorageIfNeeded(
    completion: @escaping (Result<[String?: Any?], Error>) -> Void
  ) {
    do {
      let minimumBytes: Int64 = 2 * 1024 * 1024 * 1024
      let targetBytes: Int64 = 3 * 1024 * 1024 * 1024
      let before = availableStorageBytes()
      var current = before
      var deletedCount = 0
      var freedBytes: Int64 = 0
      if current < minimumBytes {
        let recordingsRoot = recordingsDirectory().path + "/"
        for var job in try jobs() where current < targetBytes {
          guard
            job["state"] as? String == "completed",
            (job["verificationVersion"] as? Int ?? 0) >= Self.verificationVersion,
            let remoteId = job["remoteRecordId"] as? NSNumber,
            remoteId.int64Value > 0,
            let receipt = job["verificationReceipt"] as? String,
            !receipt.isEmpty,
            IosBackupCleanupGate.hasSingleSession(job),
            let lastAttested = job["lastAttestedAt"] as? String,
            let attestedDate = Self.isoFormatter.date(from: lastAttested),
            Date().timeIntervalSince(attestedDate) <= Self.storageAttestationFreshness,
            let path = job["filePath"] as? String,
            path.hasPrefix(recordingsRoot)
          else {
            continue
          }
          let file = URL(fileURLWithPath: path)
          guard FileManager.default.fileExists(atPath: path) else { continue }
          if let expected = job["contentSha256"] as? String, !expected.isEmpty {
            if sha256(file: file) != expected {
              job["errorMessage"] = "录像文件已被替换，已取消空间清理"
              try upsert(job)
              continue
            }
          }
          let size = Int64(
            (try? FileManager.default.attributesOfItem(
              atPath: path
            )[.size] as? Int64) ?? 0
          )
          do {
            try FileManager.default.removeItem(at: file)
            deletedCount += 1
            freedBytes += size
            job["localDeletedAt"] = ISO8601DateFormatter().string(from: Date())
            job["cleanupReason"] = "存储空间不足提前清理"
            try upsert(job)
          } catch {
            job["errorMessage"] = "空间清理失败，已保留本机录像"
            try upsert(job)
          }
          current = availableStorageBytes()
        }
      }
      emitSnapshot()
      completion(
        .success(
          [
            "availableBytes": current,
            "availableBytesBefore": before,
            "freedBytes": freedBytes,
            "deletedCount": deletedCount,
            "warning": current < targetBytes,
            "insufficient": current < minimumBytes,
          ]
        )
      )
    } catch {
      completion(.failure(error))
    }
  }

  private func recordingsDirectory() -> URL {
    if let recordingsRoot { return recordingsRoot }
    let root = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return root.appendingPathComponent("recordings", isDirectory: true)
  }

  private func availableStorageBytes() -> Int64 {
    let values = try? FileManager.default.attributesOfFileSystem(
      forPath: recordingsDirectory().path
    )
    return (values?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
  }

  private func sha256(file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = handle.readData(ofLength: 1024 * 1024)
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func getNetworkDiagnostics(
    completion: @escaping (Result<[String?: Any?]?, Error>) -> Void
  ) {
    completion(.success(["wifiConnected": lastLanReachable]))
  }

  private func currentSnapshot() throws -> [String?: Any?] {
    _ = try credentialStore.load()
    return [
      "deviceId": deviceId(),
      "deviceName": deviceName(),
      "connection": defaults.dictionary(forKey: keys.connection),
      "jobs": try jobs().map(slimJob),
    ]
  }

  /// 快照瘦身：只下发 Dart 实际消费的字段，避免 sessions 等大字段随每次推送跨通道传输。
  private func slimJob(_ job: [String: Any]) -> [String: Any] {
    var slim: [String: Any] = [:]
    for key in [
      "id", "filePath", "state", "uploadedBytes", "totalBytes", "lastModified",
      "contentSha256", "errorMessage", "failureKind", "fileCreatedAt",
      "backupCompletedAt", "scheduledCleanupAt", "localDeletedAt", "waitingCleanup",
      "remoteRecordId", "destinationComputerId", "cleanupReason",
    ] {
      slim[key] = job[key]
    }
    return slim
  }

  private func deviceId() -> String {
    if let value = defaults.string(forKey: keys.deviceId) { return value }
    let value = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    defaults.set(value, forKey: keys.deviceId)
    return value
  }

  private func deviceName() -> String {
    if let savedName = defaults.string(forKey: keys.deviceName)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !savedName.isEmpty {
      return savedName
    }
    return "本机"
  }

  private func saveRetentionDays(unbacked: Int, backed: Int) {
    defaults.set(
      ["unbackedRetentionDays": unbacked, "backedRetentionDays": backed],
      forKey: keys.retention
    )
  }

  private func unbackedRetentionDays() -> Int {
    let values = defaults.dictionary(forKey: keys.retention)
    return (values?["unbackedRetentionDays"] as? Int) ?? 30
  }

  private func backedRetentionDays() -> Int {
    let values = defaults.dictionary(forKey: keys.retention)
    return (values?["backedRetentionDays"] as? Int) ?? 7
  }

  /// 旧版本任务字段补齐：fileCreatedAt 用文件 lastModified（与 Android 一致），
  /// 其余用文件元数据或默认值回填，避免旧任务被误判为未备份/可清理。
  static func migratedJob(_ job: [String: Any]) -> [String: Any] {
    var result = job
    let path = job["filePath"] as? String ?? ""
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let modified = attributes?[.modificationDate] as? Date
    let size = (attributes?[.size] as? NSNumber)?.int64Value

    if result["fileCreatedAt"] == nil, let modified {
      result["fileCreatedAt"] = Self.isoFormatter.string(from: modified)
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

  private func jobs() throws -> [[String: Any]] {
    try jobStore.get().allJobs()
  }

  private func upsert(_ job: [String: Any]) throws {
    try jobStore.get().upsert(job)
  }

  private func updateJob(
    _ id: String,
    mutate: (inout [String: Any]) -> Void
  ) throws {
    guard try jobStore.get().updateJob(id: id, mutate: mutate) else {
      throw pigeonError("备份任务不存在", code: "backup_job_missing")
    }
  }

  @discardableResult
  func updateUploadJob(
    _ id: String,
    expectedGeneration: String,
    mutate: (inout [String: Any]) -> Void
  ) throws -> Bool {
    try jobStore.get().updateJob(
      id: id,
      expectedGeneration: expectedGeneration,
      mutate: mutate
    )
  }

  private func emitSnapshot() {
    emitLock.lock()
    let alreadyScheduled = emitScheduled
    emitScheduled = true
    emitLock.unlock()
    if alreadyScheduled {
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self else { return }
      self.emitLock.lock()
      self.emitScheduled = false
      self.emitLock.unlock()
      guard let snapshot = try? self.currentSnapshot() else { return }
      self.eventApi.snapshotChanged(snapshot: snapshot) { _ in }
    }
  }

  private func stableId(_ path: String) -> String {
    var hash: UInt64 = 1469598103934665603
    for byte in path.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1099511628211
    }
    return String(format: "%016llx", hash)
  }

  private func normalized(_ value: [String?: Any?]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, item) in value {
      guard let key = key, let item = item, !(item is NSNull) else { continue }
      result[key] = item
    }
    return result
  }

  private func startUpload(_ job: [String: Any]) {
    guard let jobId = job["id"] as? String,
          let generation = job["generation"] as? String,
          !generation.isEmpty
    else { return }
    let identity = IosBackupUploadIdentity(
      generation: generation,
      token: UUID()
    )
    uploadsLock.lock()
    activeUploads[jobId]?.task.cancel()
    let previous = uploadTail
    let task = Task.detached { [weak self] in
      await previous.value
      guard let self, !Task.isCancelled else { return }
      await self.upload(job: job, identity: identity)
    }
    activeUploads[jobId] = ActiveUpload(identity: identity, task: task)
    uploadTail = task
    uploadsLock.unlock()
  }

  private func cancelActiveUpload(jobId: String) {
    uploadsLock.lock()
    activeUploads.removeValue(forKey: jobId)?.task.cancel()
    uploadsLock.unlock()
  }

  private func finishActiveUpload(
    jobId: String,
    identity: IosBackupUploadIdentity
  ) {
    uploadsLock.lock()
    if IosBackupActiveUploadGate.shouldRemove(
      active: activeUploads[jobId]?.identity,
      finished: identity
    ) {
      activeUploads.removeValue(forKey: jobId)
    }
    uploadsLock.unlock()
  }

  private func upload(
    job: [String: Any],
    identity: IosBackupUploadIdentity
  ) async {
    guard let jobId = job["id"] as? String else { return }
    defer { finishActiveUpload(jobId: jobId, identity: identity) }
    guard
      let connection = defaults.dictionary(forKey: keys.connection),
      let storedBaseUrl = connection["baseUrl"] as? String,
      let path = job["filePath"] as? String
    else {
      return
    }
    var baseUrl = storedBaseUrl
    let url = URL(fileURLWithPath: path)

    do {
      guard let accessKey = try credentialStore.load() else {
        throw pigeonError("未找到备份访问密钥", code: "credential_missing")
      }
      guard
        let rawSessions = job["sessions"] as? [Any],
        rawSessions.count == 1,
        let completionSession = Self.backupCompletionSession(rawSessions[0])
      else {
        throw BackupSourceError(message: "备份任务必须且只能包含一条录像记录")
      }
      let reader = try IosBackupFileReader(url: url)
      let totalBytes = reader.snapshot.byteCount
      let fileSha256 = try reader.sha256()
      let createBody: [String: Any] = [
        "fileSha256": fileSha256,
        "totalBytes": totalBytes,
        "mimeType": "video/mp4",
      ]
      let create: [String: Any]
      do {
        create = try await uploadJson(
          baseUrl: baseUrl,
          path: "/api/mobile-backup/uploads",
          body: createBody,
          accessKey: accessKey,
          deviceId: deviceId()
        )
      } catch {
        guard let recovered = await recoverBaseUrl(
          failedBaseUrl: baseUrl,
          connection: connection
        ) else { throw error }
        baseUrl = recovered
        create = try await uploadJson(
          baseUrl: baseUrl,
          path: "/api/mobile-backup/uploads",
          body: createBody,
          accessKey: accessKey,
          deviceId: deviceId()
        )
      }
      guard
        let uploadId = create["uploadId"] as? String,
        let rawOffset = create["offset"] as? NSNumber,
        let rawChunkSize = create["chunkSize"] as? NSNumber
      else {
        throw pigeonError("电脑返回的上传会话无效")
      }
      let chunkSize = min(
        max(rawChunkSize.intValue, 256 * 1024),
        8 * 1024 * 1024
      )
      var offset = min(max(rawOffset.int64Value, 0), totalBytes)
      let uploadIdEncoded = uploadId.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed
      ) ?? uploadId
      var offsetResyncAttempts = 0
      while offset < totalBytes {
        try Task.checkCancellation()
        let chunk = try reader.read(offset: offset, count: chunkSize)
        let chunkPath = "/api/mobile-backup/uploads/\(uploadIdEncoded)/chunks"
        let result: [String: Any]
        do {
          result = try await uploadChunk(
            baseUrl: baseUrl,
            path: chunkPath,
            chunk: chunk,
            offset: offset,
            total: totalBytes,
            accessKey: accessKey,
            deviceId: deviceId()
          )
        } catch {
          if let transfer = error as? BackupTransferError,
             transfer.statusCode == 409,
             transfer.errorCode == "offset_mismatch",
             let expected = transfer.expectedOffset,
             expected >= 0, expected <= totalBytes {
            offsetResyncAttempts += 1
            guard offsetResyncAttempts <= 3 else { throw transfer }
            offset = expected
            guard try updateUploadJob(
              jobId,
              expectedGeneration: identity.generation,
              mutate: { current in
                current["state"] = "uploading"
                current["uploadedBytes"] = offset
              }
            ) else { return }
            emitSnapshot()
            continue
          }
          guard let recovered = await recoverBaseUrl(
            failedBaseUrl: baseUrl,
            connection: connection
          ) else { throw error }
          baseUrl = recovered
          result = try await uploadChunk(
            baseUrl: baseUrl,
            path: chunkPath,
            chunk: chunk,
            offset: offset,
            total: totalBytes,
            accessKey: accessKey,
            deviceId: deviceId()
          )
        }
        guard let next = result["offset"] as? NSNumber else {
          throw pigeonError("电脑返回的上传进度无效")
        }
        let nextOffset = next.int64Value
        guard nextOffset > offset, nextOffset <= totalBytes else {
          throw BackupSourceError(message: "电脑返回的上传进度无效")
        }
        offsetResyncAttempts = 0
        offset = nextOffset
        guard try updateUploadJob(
          jobId,
          expectedGeneration: identity.generation,
          mutate: { current in
            current["state"] = "uploading"
            current["uploadedBytes"] = offset
          }
        ) else { return }
        emitSnapshot()
      }

      try Task.checkCancellation()
      try reader.assertUnchanged()
      let completePath = "/api/mobile-backup/uploads/\(uploadIdEncoded)/complete"
      let completeBody: [String: Any] = [
        "fileSha256": fileSha256,
        "sourceDeviceId": deviceId(),
        "sourceDeviceName": deviceName(),
        "sessions": [completionSession],
      ]
      let complete: [String: Any]
      do {
        complete = try await uploadJson(
          baseUrl: baseUrl,
          path: completePath,
          body: completeBody,
          accessKey: accessKey,
          deviceId: deviceId()
        )
      } catch {
        guard let recovered = await recoverBaseUrl(
          failedBaseUrl: baseUrl,
          connection: connection
        ) else { throw error }
        baseUrl = recovered
        complete = try await uploadJson(
          baseUrl: baseUrl,
          path: completePath,
          body: completeBody,
          accessKey: accessKey,
          deviceId: deviceId()
        )
      }
      guard
        let sessions = job["sessions"] as? [Any],
        sessions.count == 1,
        let session = sessions.first as? [String: Any],
        let sessionId = session["id"] as? String,
        let recordId = (complete["recordId"] as? NSNumber)?.int64Value,
        recordId > 0,
        let computerId = connection["computerId"] as? String,
        IosBackupReceiptVerifier.verify(
          complete,
          accessKey: accessKey,
          hostNodeId: computerId,
          sourceDeviceId: deviceId(),
          sourceSessionId: sessionId,
          fileSha256: fileSha256,
          fileSizeBytes: totalBytes,
          recordId: recordId
        )
      else {
        throw BackupTransferError(
          statusCode: 0,
          errorCode: "verification_failed",
          message: "电脑未确认录像校验结果",
          failureKind: "verification_failed"
        )
      }
      let completedAt = Self.isoFormatter.string(from: Date())
      guard try updateUploadJob(
        jobId,
        expectedGeneration: identity.generation,
        mutate: { current in
          current["state"] = "completed"
          current["uploadedBytes"] = totalBytes
          current["contentSha256"] = fileSha256
          current["remoteRecordId"] = recordId
          current["backupCompletedAt"] = completedAt
          current["verificationVersion"] = IosBackupReceiptVerifier.version
          current["verificationReceipt"] = complete["receiptSignature"] as? String
          current["lastAttestedAt"] = completedAt
        }
      ) else { return }
      emitSnapshot()
      triggerCleanup()
    } catch {
      let failure = Self.backupFailureInfo(error)
      let updated = try? updateUploadJob(
        jobId,
        expectedGeneration: identity.generation,
        mutate: { current in
          current["state"] = "paused"
          current["errorMessage"] = failure.message
          current["failureKind"] = failure.failureKind
          current["statusCode"] = failure.statusCode
          current["errorCode"] = failure.errorCode
        }
      )
      if updated == true {
        emitSnapshot()
      }
    }
  }

  private func recoverBaseUrl(
    failedBaseUrl: String,
    connection: [String: Any]
  ) async -> String? {
    guard
      let computerId = connection["computerId"] as? String,
      !computerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let resolved = await hostResolver.resolve(
        currentBaseUrl: failedBaseUrl,
        expectedNodeId: computerId
      ),
      resolved.trimmingCharacters(in: CharacterSet(charactersIn: "/")) !=
        failedBaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    else { return nil }

    var updated = connection
    updated["baseUrl"] = resolved
    updated["lastConnectedAt"] = Self.isoFormatter.string(from: Date())
    defaults.set(updated, forKey: keys.connection)
    emitSnapshot()
    return resolved
  }

  private func uploadJson(
    baseUrl: String,
    path: String,
    body: [String: Any],
    accessKey: String,
    deviceId: String
  ) async throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: body)
    var request = URLRequest(url: URL(string: baseUrl + path)!)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applySignature(
      to: &request,
      method: "POST",
      path: path,
      body: data,
      accessKey: accessKey,
      deviceId: deviceId
    )
    let (responseData, response) = try await URLSession.shared.data(
      for: request
    )
    guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode
    else {
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw Self.backupTransferError(
        statusCode: statusCode,
        data: responseData,
        fallbackMessage: "电脑备份请求失败"
      )
    }
    return (try JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
  }

  private func uploadChunk(
    baseUrl: String,
    path: String,
    chunk: Data,
    offset: Int64,
    total: Int64,
    accessKey: String,
    deviceId: String
  ) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: baseUrl + path)!)
    request.httpMethod = "PUT"
    request.httpBody = chunk
    request.setValue(
      "bytes \(offset)-\(offset + Int64(chunk.count) - 1)/\(total)",
      forHTTPHeaderField: "Content-Range"
    )
    request.setValue(
      SHA256.hash(data: chunk).map { String(format: "%02x", $0) }.joined(),
      forHTTPHeaderField: "X-Chunk-SHA256"
    )
    applySignature(
      to: &request,
      method: "PUT",
      path: path,
      body: chunk,
      accessKey: accessKey,
      deviceId: deviceId
    )
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode
    else {
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw Self.backupTransferError(
        statusCode: statusCode,
        data: data,
        fallbackMessage: "电脑备份分块失败"
      )
    }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private static func backupCompletionSession(_ value: Any) -> [String: Any]? {
    guard
      let source = value as? [String: Any],
      let id = source["id"] as? String,
      !id.isEmpty,
      let startedAt = source["startedAt"] as? String,
      let endedAt = source["endedAt"] as? String
    else { return nil }
    return [
      "id": id,
      "trackingNumber": source["trackingNumber"] as? String ?? "",
      "startedAt": startedAt,
      "endedAt": endedAt,
      "mediaStartMs": int64Value(source["mediaStartMs"]),
      "mediaEndMs": int64Value(source["mediaEndMs"]),
      "mode": source["mode"] as? String ?? "shipping",
      "markers": source["markers"] as? [Any] ?? [],
    ]
  }

  private static func int64Value(_ value: Any?) -> Int64 {
    if let number = value as? NSNumber {
      return number.int64Value
    }
    if let number = value as? Int64 {
      return number
    }
    if let number = value as? Int {
      return Int64(number)
    }
    return 0
  }

  private static func backupTransferError(
    statusCode: Int,
    data: Data,
    fallbackMessage: String
  ) -> BackupTransferError {
    let text = String(data: data, encoding: .utf8) ?? ""
    var errorCode = ""
    var message = ""
    var expectedOffset: Int64?
    if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      errorCode = object["errorCode"] as? String ?? ""
      message = object["error"] as? String ?? ""
      expectedOffset = (object["expectedOffset"] as? NSNumber)?.int64Value
    }
    if message.isEmpty {
      message = text.isEmpty ? fallbackMessage : text
    }
    let failureKind = Self.backupFailureKind(
      statusCode: statusCode,
      errorCode: errorCode
    )
    return BackupTransferError(
      statusCode: statusCode,
      errorCode: errorCode,
      message: message,
      failureKind: failureKind,
      expectedOffset: expectedOffset
    )
  }

  private static func backupFailureInfo(_ error: Error) -> BackupTransferError {
    if let transfer = error as? BackupTransferError {
      return transfer
    }
    if let pigeon = error as? PigeonError {
      return BackupTransferError(
        statusCode: 0,
        errorCode: pigeon.code,
        message: pigeon.message ?? pigeon.localizedDescription,
        failureKind: "unknown"
      )
    }
    if let source = error as? BackupSourceError {
      return BackupTransferError(
        statusCode: 0,
        errorCode: "backup_source_unavailable",
        message: source.message,
        failureKind: "unknown"
      )
    }
    if error is CancellationError {
      return BackupTransferError(
        statusCode: 0,
        errorCode: "backup_cancelled",
        message: "备份已暂停",
        failureKind: "offline_or_timeout"
      )
    }
    return BackupTransferError(
      statusCode: 0,
      errorCode: "backup_transfer_failed",
      message: error.localizedDescription,
      failureKind: "offline_or_timeout"
    )
  }

  private static func backupFailureKind(
    statusCode: Int,
    errorCode: String
  ) -> String {
    switch errorCode {
    case "enrollment_required", "device_token_invalid":
      return "credential_invalid"
    case "backup_protocol_upgrade_required":
      return "incompatible_version"
    case "offset_mismatch":
      return "temporary_service"
    case "sha256_mismatch":
      return "verification_failed"
    case "upload_not_found":
      return "upload_expired"
    case "invalid_session_id":
      return "unknown"
    default:
      break
    }
    switch statusCode {
    case 401, 403:
      return "credential_invalid"
    case 426:
      return "incompatible_version"
    case 409, 429:
      return "temporary_service"
    case 422:
      return "verification_failed"
    case 500...599:
      return "temporary_service"
    default:
      return "unknown"
    }
  }

  private func applySignature(
    to request: inout URLRequest,
    method: String,
    path: String,
    body: Data,
    accessKey: String,
    deviceId: String
  ) {
    let timestamp = Int(Date().timeIntervalSince1970)
    let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    let contentHash = SHA256.hash(data: body).map {
      String(format: "%02x", $0)
    }.joined()
    let canonical = "\(method.uppercased())\n\(path)\n\(timestamp)\n\(nonce)\n\(contentHash)\n\(deviceId.lowercased())"
    let key = SymmetricKey(data: secretData(accessKey))
    let signature = HMAC<SHA256>.authenticationCode(
      for: Data(canonical.utf8),
      using: key
    ).map { String(format: "%02x", $0) }.joined()
    request.setValue("3", forHTTPHeaderField: "X-EPM-Auth-Version")
    request.setValue("\(timestamp)", forHTTPHeaderField: "X-EPM-Timestamp")
    request.setValue(nonce, forHTTPHeaderField: "X-EPM-Nonce")
    request.setValue(contentHash, forHTTPHeaderField: "X-EPM-Content-SHA256")
    request.setValue(signature, forHTTPHeaderField: "X-EPM-Signature")
    request.setValue(deviceId, forHTTPHeaderField: "X-EPM-Device-Id")
    request.setValue("mobile", forHTTPHeaderField: "X-EPM-Device-Kind")
  }

  fileprivate static func secretDataValue(_ value: String) -> Data {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.count >= 32, normalized.count.isMultiple(of: 2) {
      var bytes: [UInt8] = []
      var index = normalized.startIndex
      while index < normalized.endIndex {
        let next = normalized.index(index, offsetBy: 2)
        if let byte = UInt8(normalized[index..<next], radix: 16) {
          bytes.append(byte)
        } else {
          return Data(normalized.utf8)
        }
        index = next
      }
      return Data(bytes)
    }
    return Data(normalized.utf8)
  }

  private func secretData(_ value: String) -> Data {
    Self.secretDataValue(value)
  }

  // MARK: - 保留策略清理

  private func readJobById(_ id: String) throws -> [String: Any]? {
    try jobs().first(where: { $0["id"] as? String == id })
  }

  private func dueAt(_ job: [String: Any]) -> Date? {
    let state = job["state"] as? String ?? ""
    let completedAt = job["backupCompletedAt"] as? String
    // 旧版本“已完成但缺 backupCompletedAt”的录像按 legacy 保留，不参与清理。
    if state == "completed" && completedAt == nil {
      return nil
    }
    let days: Int
    let base: String?
    if let completedAt {
      days = backedRetentionDays()
      base = completedAt
    } else {
      days = unbackedRetentionDays()
      base = job["fileCreatedAt"] as? String
    }
    guard days >= 0, let base, let baseDate = Self.isoFormatter.date(from: base) else {
      return nil
    }
    return baseDate.addingTimeInterval(Double(days) * 24 * 60 * 60)
  }

  private func isConfirmationFresh(_ lastAttestedAt: String?, now: Date) -> Bool {
    guard let lastAttestedAt,
          let attested = Self.isoFormatter.date(from: lastAttestedAt) else {
      return false
    }
    return now.timeIntervalSince(attested) <= Self.retentionConfirmationGrace
  }

  private func triggerCleanup() {
    cleanupLock.lock()
    guard !cleanupRunning else {
      cleanupLock.unlock()
      return
    }
    cleanupRunning = true
    lastCleanupAt = Date()
    cleanupLock.unlock()

    Task.detached { [weak self] in
      guard let self else { return }
      try? await self.performCleanup()
      self.cleanupLock.lock()
      self.cleanupRunning = false
      self.cleanupLock.unlock()
    }
  }

  private func triggerCleanupIfDue() {
    cleanupLock.lock()
    let due = Date().timeIntervalSince(lastCleanupAt) >= Self.cleanupThrottle
    cleanupLock.unlock()
    if due {
      triggerCleanup()
    }
  }

  func performCleanup() async throws {
    let root = recordingsDirectory().path + "/"
    let now = Date()
    var changed = false

    for job in try jobs() {
      guard
        let id = job["id"] as? String,
        let path = job["filePath"] as? String,
        path.hasPrefix(root)
      else { continue }
      if job["localDeletedAt"] as? String != nil { continue }
      let state = job["state"] as? String ?? ""
      if state == "pending" || state == "uploading" { continue }
      guard let due = dueAt(job), now >= due else { continue }

      let completedAt = job["backupCompletedAt"] as? String
      var baseJob = job

      if completedAt != nil {
        let contentSha256 = job["contentSha256"] as? String
        let totalBytes = job["totalBytes"] as? Int64 ?? -1
        let hasEvidence = IosBackupCleanupGate.hasVerifiedRetentionEvidence(
          job,
          minimumVersion: Self.verificationVersion
        )

        if !hasEvidence {
          baseJob["waitingCleanup"] = true
          baseJob["errorMessage"] = "备份记录缺少安全校验信息，需重新备份后才能自动清理"
          try upsert(baseJob)
          changed = true
          continue
        }

        let attestation: AttestationResult
        let storedReceipt = job["verificationReceipt"] as? String
        if !(storedReceipt?.isEmpty ?? true),
           isConfirmationFresh(job["lastAttestedAt"] as? String, now: now) {
          attestation = .confirmed(receiptSignature: storedReceipt ?? "")
        } else {
          attestation = await attestBackedJob(
            job,
            contentSha256: contentSha256 ?? "",
            totalBytes: totalBytes
          )
        }

        // 远端确认期间任务可能被重新上传，重新读取并校验代次后再落地。
        guard
          let current = try readJobById(id),
          (current["generation"] as? String) == (job["generation"] as? String),
          (current["backupCompletedAt"] as? String) == completedAt,
          current["localDeletedAt"] as? String == nil
        else { continue }
        baseJob = current

        switch attestation {
        case .confirmed(let receiptSignature):
          baseJob["lastAttestedAt"] = Self.isoFormatter.string(from: now)
          baseJob["verificationReceipt"] = receiptSignature
        case .missing:
          baseJob["waitingCleanup"] = false
          baseJob["errorMessage"] = "远端缺失，待重新备份"
          try upsert(baseJob)
          changed = true
          continue
        case .unauthorized:
          baseJob["waitingCleanup"] = false
          baseJob["errorMessage"] = "需要重新扫码授权"
          try upsert(baseJob)
          changed = true
          continue
        case .notReady:
          baseJob["waitingCleanup"] = true
          baseJob["errorMessage"] = "电脑端尚未完成校验"
          try upsert(baseJob)
          changed = true
          continue
        case .unreachable:
          baseJob["waitingCleanup"] = true
          baseJob["errorMessage"] = "暂时无法向电脑确认备份，已保留本地录像"
          try upsert(baseJob)
          changed = true
          continue
        }
      }

      let file = URL(fileURLWithPath: path)
      switch deleteExpected(
        file: file,
        expectedBytes: baseJob["totalBytes"] as? Int64 ?? -1,
        expectedLastModified: baseJob["lastModified"] as? Int64 ?? -1,
        expectedSha256: baseJob["contentSha256"] as? String
      ) {
      case .stale:
        baseJob["waitingCleanup"] = false
        baseJob["errorMessage"] = "录像文件已被替换，已取消本次自动清理"
        try upsert(baseJob)
        changed = true
        continue
      case .failed:
        baseJob["waitingCleanup"] = true
        try upsert(baseJob)
        changed = true
        continue
      case .deleted, .missing:
        break
      }

      baseJob["localDeletedAt"] = Self.isoFormatter.string(from: now)
      baseJob["scheduledCleanupAt"] = nil
      baseJob["waitingCleanup"] = false
      if completedAt == nil {
        baseJob["cleanupReason"] = "未备份录像保留策略清理"
        baseJob["state"] = "expired"
        baseJob["errorMessage"] = "未备份录像已按保留策略清理"
      } else {
        baseJob["cleanupReason"] = "已备份录像保留策略清理"
      }
      try upsert(baseJob)
      changed = true
    }

    if changed {
      emitSnapshot()
    }
  }

  private func attestBackedJob(
    _ job: [String: Any],
    contentSha256: String,
    totalBytes: Int64
  ) async -> AttestationResult {
    guard
      let connection = defaults.dictionary(forKey: keys.connection),
      let baseUrl = connection["baseUrl"] as? String,
      let recordId = job["remoteRecordId"] as? NSNumber,
      let sessions = job["sessions"] as? [Any],
      IosBackupCleanupGate.hasSingleSession(job),
      let session = sessions.first as? [String: Any],
      let sessionId = session["id"] as? String
    else {
      return .unreachable
    }
    let accessKey: String
    do {
      guard let stored = try credentialStore.load() else { return .unreachable }
      accessKey = stored
    } catch {
      return .unreachable
    }
    return await attestRemoteRecord(
      baseUrl: baseUrl,
      recordId: recordId.int64Value,
      accessKey: accessKey,
      deviceId: deviceId(),
      sessionId: sessionId,
      fileSha256: contentSha256,
      fileSizeBytes: totalBytes,
      computerId: connection["computerId"] as? String ?? ""
    )
  }

  private func attestRemoteRecord(
    baseUrl: String,
    recordId: Int64,
    accessKey: String,
    deviceId: String,
    sessionId: String,
    fileSha256: String,
    fileSizeBytes: Int64,
    computerId: String
  ) async -> AttestationResult {
    let path = "/api/mobile-backup/records/\(recordId)/attestation"
    guard let url = URL(string: baseUrl + path) else { return .unreachable }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    applySignature(
      to: &request,
      method: "GET",
      path: path,
      body: Data(),
      accessKey: accessKey,
      deviceId: deviceId
    )
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return .unreachable }
      switch http.statusCode {
      case 200:
        let json =
          (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard json["status"] as? String == "verified" else { return .notReady }
        let verified = verifyAttestationReceipt(
          json,
          accessKey: accessKey,
          deviceId: deviceId,
          computerId: computerId,
          sessionId: sessionId,
          fileSha256: fileSha256,
          fileSizeBytes: fileSizeBytes,
          recordId: recordId
        )
        guard verified,
              let signature = json["receiptSignature"] as? String,
              !signature.isEmpty
        else { return .notReady }
        return .confirmed(receiptSignature: signature)
      case 404:
        return .missing
      case 403:
        return .unauthorized
      case 409:
        return .notReady
      default:
        return .unreachable
      }
    } catch {
      return .unreachable
    }
  }

  private func verifyAttestationReceipt(
    _ response: [String: Any],
    accessKey: String,
    deviceId: String,
    computerId: String,
    sessionId: String,
    fileSha256: String,
    fileSizeBytes: Int64,
    recordId: Int64
  ) -> Bool {
    IosBackupReceiptVerifier.verify(
      response,
      accessKey: accessKey,
      hostNodeId: computerId,
      sourceDeviceId: deviceId,
      sourceSessionId: sessionId,
      fileSha256: fileSha256,
      fileSizeBytes: fileSizeBytes,
      recordId: recordId
    )
  }

  private func hmacHex(key: Data, message: String) -> String {
    let symmetricKey = SymmetricKey(data: key)
    let code = HMAC<SHA256>.authenticationCode(
      for: Data(message.utf8),
      using: symmetricKey
    )
    return code.map { String(format: "%02x", $0) }.joined()
  }

  private func constantTimeEquals(_ left: String, _ right: String) -> Bool {
    let a = Array(left.lowercased().utf8)
    let b = Array(right.lowercased().utf8)
    guard a.count == b.count else { return false }
    var result: UInt8 = 0
    for index in 0..<a.count {
      result |= a[index] ^ b[index]
    }
    return result == 0
  }

  private func deleteExpected(
    file: URL,
    expectedBytes: Int64,
    expectedLastModified: Int64,
    expectedSha256: String?
  ) -> FileCleanupResult {
    guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    let modified = attributes?[.modificationDate] as? Date
    let modifiedMs = modified.map { Int64($0.timeIntervalSince1970 * 1000) } ?? -1
    if expectedBytes > 0 && size != expectedBytes { return .stale }
    if expectedLastModified > 0 && modifiedMs != expectedLastModified {
      return .stale
    }
    if let expectedSha256, !expectedSha256.isEmpty, sha256(file: file) != expectedSha256 {
      return .stale
    }
    do {
      try FileManager.default.removeItem(at: file)
      return .deleted
    } catch {
      return .failed
    }
  }
}

/// iOS 后台上传无法依赖 Dart isolate，因此在原生侧按稳定 NodeId 重新定位主机。
final class IosLanBackupHostResolver: @unchecked Sendable {
  private static let minimumHostVersion = "0.0.32"
  private static let backupProtocol = "mobile-backup-v2"
  private static let enrollmentVersion = 2
  private static let authenticationVersion = 3

  func resolve(currentBaseUrl: String, expectedNodeId: String) async -> String? {
    let nodeId = expectedNodeId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !nodeId.isEmpty else { return nil }
    if let current = await Self.probe(baseUrl: currentBaseUrl, nodeId: nodeId) {
      return current
    }

    for batch in Self.subnetCandidates().chunks(ofCount: 32) {
      let match = await withTaskGroup(of: String?.self, returning: String?.self) { group in
        for candidate in batch {
          group.addTask {
            await Self.probe(baseUrl: candidate, nodeId: nodeId)
          }
        }
        for await result in group {
          if let result {
            group.cancelAll()
            return result
          }
        }
        return nil
      }
      if let match {
        return match
      }
    }
    return nil
  }

  private static func probe(baseUrl: String, nodeId: String) async -> String? {
    guard let url = URL(string: baseUrl + "/api/node-info") else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 0.9)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard
        (response as? HTTPURLResponse)?.statusCode == 200,
        let node = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        node["protocol"] as? String == "packingproof",
        (node["protocolVersion"] as? NSNumber)?.intValue == 1,
        (node["nodeId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == nodeId,
        let capabilities = node["capabilities"] as? [String],
        capabilities.contains(where: { $0.caseInsensitiveCompare("host") == .orderedSame }),
        capabilities.contains(where: { $0.caseInsensitiveCompare("mobile-backup") == .orderedSame }),
        compatible(node["backupCompatibility"] as? [String: Any]),
        var components = URLComponents(string: baseUrl)
      else { return nil }
      let advertisedPort = (node["httpPort"] as? NSNumber)?.intValue ?? components.port ?? 5280
      components.port = (1...65535).contains(advertisedPort) ? advertisedPort : 5280
      components.path = ""
      components.query = nil
      components.fragment = nil
      return components.url?.absoluteString.trimmingCharacters(
        in: CharacterSet(charactersIn: "/")
      )
    } catch {
      return nil
    }
  }

  private static func compatible(_ value: [String: Any]?) -> Bool {
    guard let value else { return false }
    let appVersion = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? ""
    let appBuild = Int(Bundle.main.object(
      forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "") ?? 0
    return compareLanBackupVersions(
      value["hostVersion"] as? String ?? "",
      minimumHostVersion
    ) >= 0 &&
      value["protocol"] as? String == backupProtocol &&
      (value["enrollmentVersion"] as? NSNumber)?.intValue == enrollmentVersion &&
      (value["authVersion"] as? NSNumber)?.intValue == authenticationVersion &&
      compareLanBackupVersions(
        appVersion,
        value["minimumMobileVersion"] as? String ?? ""
      ) >= 0 &&
      appBuild >= ((value["minimumMobileBuildNumber"] as? NSNumber)?.intValue ?? Int.max)
  }

  private static func subnetCandidates() -> [String] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
    defer { freeifaddrs(pointer) }
    var addresses = Set<String>()
    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = current {
      defer { current = interface.pointee.ifa_next }
      guard
        let address = interface.pointee.ifa_addr,
        address.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }
      let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        String(cString: inet_ntoa($0.pointee.sin_addr))
      }
      if isPrivateIpv4(value) { addresses.insert(value) }
    }
    var candidates: [String] = []
    for address in addresses {
      let parts = address.split(separator: ".")
      guard parts.count == 4, let localHost = Int(parts[3]) else { continue }
      let prefix = parts.prefix(3).joined(separator: ".")
      for host in scanOrder(localHost: localHost) {
        let candidate = "\(prefix).\(host)"
        if !addresses.contains(candidate) {
          candidates.append("http://\(candidate):5280")
        }
      }
    }
    return candidates
  }
}

func compareLanBackupVersions(_ left: String, _ right: String) -> Int {
  func parse(_ value: String) -> [Int]? {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.first == "v" || normalized.first == "V" {
      normalized.removeFirst()
    }
    normalized = normalized.split(whereSeparator: { $0 == "+" || $0 == "-" }).first.map(String.init) ?? ""
    let values = normalized.split(separator: ".").compactMap { Int($0) }
    return values.count == normalized.split(separator: ".").count ? values : nil
  }
  guard let lhs = parse(left) else { return -1 }
  guard let rhs = parse(right) else { return 1 }
  for index in 0..<max(lhs.count, rhs.count) {
    let comparison = (index < lhs.count ? lhs[index] : 0) -
      (index < rhs.count ? rhs[index] : 0)
    if comparison != 0 { return comparison < 0 ? -1 : 1 }
  }
  return 0
}

private func isPrivateIpv4(_ value: String) -> Bool {
  let parts = value.split(separator: ".").compactMap { Int($0) }
  guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
    return false
  }
  return parts[0] == 10 ||
    (parts[0] == 172 && (16...31).contains(parts[1])) ||
    (parts[0] == 192 && parts[1] == 168)
}

private func scanOrder(localHost: Int) -> [Int] {
  var result: [Int] = []
  for low in 1...127 {
    let high = 255 - low
    if low != localHost { result.append(low) }
    if high != localHost { result.append(high) }
  }
  return result
}

private extension Array {
  func chunks(ofCount count: Int) -> [[Element]] {
    stride(from: 0, to: self.count, by: count).map {
      Array(self[$0..<Swift.min($0 + count, self.count)])
    }
  }
}
