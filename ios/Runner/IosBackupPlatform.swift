import CryptoKit
import Darwin
import Foundation
import Network
import UIKit

/// Process-local work signal shared by camera and maintenance services.
/// Owners are independent so releasing an older camera instance cannot clear
/// the active state published by a newer instance.
final class IosRecordingActivityState: @unchecked Sendable {
  static let shared = IosRecordingActivityState()

  private let lock = NSLock()
  private var activeOwners: Set<UUID> = []

  func setActive(_ active: Bool, owner: UUID) {
    lock.lock()
    if active {
      activeOwners.insert(owner)
    } else {
      activeOwners.remove(owner)
    }
    lock.unlock()
  }

  var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !activeOwners.isEmpty
  }
}

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

struct BackupSourceError: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum IosBackupRecordingPath {
  static func resolve(
    storedPath: String,
    documentsDirectory: URL? = nil
  ) throws -> URL {
    let stored = URL(fileURLWithPath: storedPath).standardizedFileURL
    if FileManager.default.fileExists(atPath: stored.path) { return stored }
    let documents = try resolvedDocumentsDirectory(documentsDirectory)
    let relative = try recordingsRelativeComponents(stored)
    let recordingsRoot = documents.appendingPathComponent(
      "recordings", isDirectory: true
    ).standardizedFileURL
    let candidate = relative.reduce(recordingsRoot) {
      $0.appendingPathComponent($1, isDirectory: false)
    }.standardizedFileURL
    guard isContained(candidate, by: recordingsRoot) else {
      throw BackupSourceError(message: "备份录像路径超出录像目录")
    }
    return candidate
  }

  static func stableIdentity(
    storedPath: String,
    documentsDirectory: URL? = nil
  ) -> String {
    let stored = URL(fileURLWithPath: storedPath).standardizedFileURL
    guard let relative = try? recordingsRelativeComponents(stored) else {
      return stored.path
    }
    return (["Documents", "recordings"] + relative).joined(separator: "/")
  }

  private static func resolvedDocumentsDirectory(_ override: URL?) throws -> URL {
    if let override { return override.standardizedFileURL }
    guard let documents = FileManager.default.urls(
      for: .documentDirectory, in: .userDomainMask
    ).first else {
      throw BackupSourceError(message: "无法获取录像文件位置")
    }
    return documents.standardizedFileURL
  }

  private static func recordingsRelativeComponents(_ url: URL) throws -> [String] {
    let components = url.pathComponents
    guard let documentsIndex = components.lastIndex(of: "Documents"),
          documentsIndex + 2 < components.count,
          components[documentsIndex + 1] == "recordings"
    else {
      throw BackupSourceError(message: "无法获取录像文件位置")
    }
    let relative = Array(components[(documentsIndex + 2)...])
    guard !relative.isEmpty,
          relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw BackupSourceError(message: "备份录像路径无效")
    }
    return relative
  }

  private static func isContained(_ candidate: URL, by directory: URL) -> Bool {
    let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
    return path.hasPrefix(root + "/")
  }
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

private struct IosBackupOpenFileIdentity: Equatable {
  let device: UInt64
  let inode: UInt64
  let byteCount: Int64
  let modifiedAtMilliseconds: Int64
}

private final class IosBackupCleanupFileProof {
  let identity: IosBackupOpenFileIdentity
  let sha256: String
  private let descriptor: Int32

  init(url: URL, onOpenedBeforeHash: (() -> Void)? = nil) throws {
    descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw BackupSourceError(message: "无法安全打开待清理录像")
    }
    do {
      let before = try Self.identity(descriptor: descriptor)
      guard before.byteCount > 0 else {
        throw BackupSourceError(message: "待清理录像为空")
      }
      onOpenedBeforeHash?()
      var hasher = SHA256()
      var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
      while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { break }
        guard count > 0 else {
          throw BackupSourceError(message: "读取待清理录像失败")
        }
        hasher.update(data: Data(buffer[0..<count]))
      }
      let after = try Self.identity(descriptor: descriptor)
      guard before == after else {
        throw BackupSourceError(message: "待清理录像在校验期间发生变化")
      }
      identity = before
      sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  deinit { Darwin.close(descriptor) }

  func pathStillReferencesOpenedFile(_ path: String) -> Bool {
    guard let current = try? Self.identity(path: path) else { return false }
    return current == identity
  }

  static func identity(path: String) throws -> IosBackupOpenFileIdentity {
    var value = stat()
    guard lstat(path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
      throw BackupSourceError(message: "待清理录像路径已变化")
    }
    return identity(value)
  }

  private static func identity(descriptor: Int32) throws -> IosBackupOpenFileIdentity {
    var value = stat()
    guard fstat(descriptor, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
      throw BackupSourceError(message: "无法确认待清理录像身份")
    }
    return identity(value)
  }

  private static func identity(_ value: stat) -> IosBackupOpenFileIdentity {
    IosBackupOpenFileIdentity(
      device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
      byteCount: Int64(value.st_size),
      modifiedAtMilliseconds: Int64(value.st_mtimespec.tv_sec) * 1000
        + Int64(value.st_mtimespec.tv_nsec) / 1_000_000
    )
  }
}

/// 用 FileHandle 保持上传内存有界，并在每次读块前确认源文件没有被替换。
final class IosBackupFileReader {
  let snapshot: IosBackupFileSnapshot
  private let url: URL
  private let handle: FileHandle

  init(url: URL, handleOverride: FileHandle? = nil) throws {
    self.url = url
    snapshot = try IosBackupFileSnapshot.read(from: url)
    if let handleOverride {
      handle = handleOverride
      return
    }
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw BackupSourceError(message: "无法打开录像文件")
    }
  }

  deinit { try? handle.close() }

  func sha256(bufferSize: Int = 1024 * 1024) throws -> String {
    try assertUnchanged()
    do {
      try handle.seek(toOffset: 0)
    } catch {
      throw BackupSourceError(message: "无法读取录像文件")
    }
    var hasher = SHA256()
    var consumed: Int64 = 0
    while consumed < snapshot.byteCount {
      try Task.checkCancellation()
      let requested = min(Int64(bufferSize), snapshot.byteCount - consumed)
      let data: Data?
      do {
        data = try handle.read(upToCount: Int(requested))
      } catch {
        throw BackupSourceError(message: "无法读取录像文件")
      }
      guard let data, !data.isEmpty else {
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
    do {
      try handle.seek(toOffset: UInt64(offset))
    } catch {
      throw BackupSourceError(message: "无法读取录像文件")
    }
    let data: Data?
    do {
      data = try handle.read(upToCount: Int(expected))
    } catch {
      throw BackupSourceError(message: "无法读取录像文件")
    }
    guard let data,
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

enum IosBackupUploadFailureHandlingResult: Equatable {
  case persisted
  case staleGeneration
  case persistenceFailed
}

private actor IosBackupUploadStartGate {
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

private actor IosBackupMaintenanceGate {
  private var occupied = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var nextWaiterIndex = 0

  func acquire() async {
    if !occupied {
      occupied = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    guard nextWaiterIndex < waiters.count else {
      occupied = false
      waiters.removeAll(keepingCapacity: true)
      nextWaiterIndex = 0
      return
    }
    let continuation = waiters[nextWaiterIndex]
    nextWaiterIndex += 1
    if nextWaiterIndex == waiters.count {
      waiters.removeAll(keepingCapacity: true)
      nextWaiterIndex = 0
    }
    continuation.resume()
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
  private let availableStorageBytesOverride: (() -> Int64)?
  private let storageAttestationOverride:
    (([String: Any], String, Int64) async -> String?)?
  private let uploadFailureUpdateOverride: ((String, String) throws -> Bool)?
  private let uploadPersistenceFailureReporter: ((String, String, Error) -> Void)?
  private let uploadOperationOverride:
    (([String: Any], IosBackupUploadIdentity) async -> Void)?
  private let storageReclaimOperationOverride:
    (() async throws -> [String?: Any?])?
  private let cleanupOperationOverride: (() async throws -> Void)?
  private let cleanupConfigurationOverride: (() -> Bool)?
  private let cleanupRetryDelaysNanoseconds: [UInt64]
  private let recordingActivityState: IosRecordingActivityState
  private let cleanupWorkPauseNanoseconds: UInt64
  private let cleanupSliceIntervalNanoseconds: UInt64
  private let afterCleanupRunnerDecisionForTesting: (() -> Void)?
  private let beforeCleanupRetrySleepForTesting: ((Int, UInt64) -> Void)?
  private let beforeCleanupFileProofForTesting: (([String: Any]) -> Void)?
  private let beforeCleanupCandidateForTesting: (([String: Any]) -> Void)?
  private let beforeCleanupIntentClaimForTesting: (([String: Any]) -> Void)?
  private let beforeCleanupRenameForTesting: ((IosBackupCleanupIntent) throws -> Void)?
  private let afterCleanupRenameForTesting: ((IosBackupCleanupIntent) throws -> Void)?
  private let afterCleanupCommitForTesting: ((IosBackupCleanupIntent) throws -> Void)?
  private let networkMonitor = NWPathMonitor()
  private let networkQueue = DispatchQueue(label: "ios.backup.network")
  private var lastLanReachable = false
  private let uploadsLock = NSLock()
  private var activeUploads: [String: ActiveUpload] = [:]
  private var uploadDispatcherTask: Task<Void, Never>?
  private var uploadDispatchRequested = false
  private let hostLifecycleLock = NSLock()
  private var hostForeground: Bool
  private let beforeUploadDispatcherFinalizationForTesting: (() -> Void)?
  private let maintenanceGate = IosBackupMaintenanceGate()
  private let cleanupLock = NSLock()
  private let cleanupPolicyLock = NSLock()
  private let hostResolver = IosLanBackupHostResolver()
  private var cleanupRunning = false
  private var cleanupRequested = false
  private var cleanupSliceHasMore = false
  private var cleanupRetryAttempt = 0
  private var cleanupRunnerToken: UInt64 = 0
  private var cleanupRunnerTask: Task<Void, Never>?
  private var cleanupDeferredByBackground = false
  private var lastCleanupAt = Date.distantPast
  private let emitLock = NSLock()
  private var summaryEventInFlight = false
  private var summaryEventPending = false
  private var summaryProgressWorkItem: DispatchWorkItem?
  private var lastSummaryEventRequestedAt = Date.distantPast
  private let summaryQueue = DispatchQueue(
    label: "ios.backup.summary",
    qos: .utility
  )
  private let uploadFailureLock = NSLock()
  private var uploadFailureOverrides: [String: (String, BackupTransferError)] = [:]
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
  private static let cleanupRetryDelaysNanoseconds: [UInt64] = [
    1, 2, 4, 8, 16,
  ].map { $0 * 1_000_000_000 }
  private static let cleanupWorkPauseNanoseconds: UInt64 = 250_000_000
  private static let cleanupSliceIntervalNanoseconds: UInt64 = 100_000_000
  private static let summaryProgressThrottle: TimeInterval = 1
  private static let isoFormatter = ISO8601DateFormatter()

  private enum AttestationResult {
    case confirmed(receiptSignature: String)
    case missing
    case unauthorized
    case notReady
    case unreachable
  }

  private enum AtomicCleanupResult {
    case deleted(bytes: Int64)
    case reconciledMissing
    case stale
    case busy
    case failed
  }

  private enum CleanupRunnerDecision {
    case retry(UInt64)
    case continueAfter(UInt64)
    case finished(exhausted: Bool)
  }

  init(
    eventApi: BackupNativeEventApiProtocol,
    defaults: UserDefaults = .standard,
    credentialStore: IosBackupCredentialStore? = nil,
    jobStore: Result<IosBackupJobStore, Error>? = nil,
    recordingsRoot: URL? = nil,
    availableStorageBytesOverride: (() -> Int64)? = nil,
    storageAttestationOverride:
      (([String: Any], String, Int64) async -> String?)? = nil,
    uploadFailureUpdateOverride: ((String, String) throws -> Bool)? = nil,
    uploadPersistenceFailureReporter:
      ((String, String, Error) -> Void)? = nil,
    uploadOperationOverride:
      (([String: Any], IosBackupUploadIdentity) async -> Void)? = nil,
    storageReclaimOperationOverride:
      (() async throws -> [String?: Any?])? = nil,
    cleanupOperationOverride: (() async throws -> Void)? = nil,
    cleanupConfigurationOverride: (() -> Bool)? = nil,
    cleanupRetryDelaysNanoseconds: [UInt64]? = nil,
    recordingActivityState: IosRecordingActivityState = .shared,
    cleanupWorkPauseNanoseconds: UInt64? = nil,
    cleanupSliceIntervalNanoseconds: UInt64? = nil,
    hostForeground: Bool = true,
    beforeUploadDispatcherFinalizationForTesting: (() -> Void)? = nil,
    afterCleanupRunnerDecisionForTesting: (() -> Void)? = nil,
    beforeCleanupRetrySleepForTesting: ((Int, UInt64) -> Void)? = nil,
    beforeCleanupCandidateForTesting: (([String: Any]) -> Void)? = nil,
    beforeCleanupFileProofForTesting: (([String: Any]) -> Void)? = nil,
    beforeCleanupIntentClaimForTesting: (([String: Any]) -> Void)? = nil,
    beforeCleanupRenameForTesting: ((IosBackupCleanupIntent) throws -> Void)? = nil,
    afterCleanupRenameForTesting: ((IosBackupCleanupIntent) throws -> Void)? = nil,
    afterCleanupCommitForTesting: ((IosBackupCleanupIntent) throws -> Void)? = nil
  ) {
    self.eventApi = eventApi
    self.defaults = defaults
    self.credentialStore =
      credentialStore ?? IosBackupCredentialStore(defaults: defaults)
    self.jobStore = jobStore ?? Result { try IosBackupJobStore() }
    self.recordingsRoot = recordingsRoot
    self.availableStorageBytesOverride = availableStorageBytesOverride
    self.storageAttestationOverride = storageAttestationOverride
    self.uploadFailureUpdateOverride = uploadFailureUpdateOverride
    self.uploadPersistenceFailureReporter = uploadPersistenceFailureReporter
    self.uploadOperationOverride = uploadOperationOverride
    self.storageReclaimOperationOverride = storageReclaimOperationOverride
    self.cleanupOperationOverride = cleanupOperationOverride
    self.cleanupConfigurationOverride = cleanupConfigurationOverride
    self.cleanupRetryDelaysNanoseconds =
      cleanupRetryDelaysNanoseconds ?? Self.cleanupRetryDelaysNanoseconds
    self.recordingActivityState = recordingActivityState
    self.cleanupWorkPauseNanoseconds =
      cleanupWorkPauseNanoseconds ?? Self.cleanupWorkPauseNanoseconds
    self.cleanupSliceIntervalNanoseconds =
      cleanupSliceIntervalNanoseconds ?? Self.cleanupSliceIntervalNanoseconds
    self.hostForeground = hostForeground
    self.beforeUploadDispatcherFinalizationForTesting =
      beforeUploadDispatcherFinalizationForTesting
    self.afterCleanupRunnerDecisionForTesting =
      afterCleanupRunnerDecisionForTesting
    self.beforeCleanupRetrySleepForTesting = beforeCleanupRetrySleepForTesting
    self.beforeCleanupCandidateForTesting = beforeCleanupCandidateForTesting
    self.beforeCleanupFileProofForTesting = beforeCleanupFileProofForTesting
    self.beforeCleanupIntentClaimForTesting = beforeCleanupIntentClaimForTesting
    self.beforeCleanupRenameForTesting = beforeCleanupRenameForTesting
    self.afterCleanupRenameForTesting = afterCleanupRenameForTesting
    self.afterCleanupCommitForTesting = afterCleanupCommitForTesting
    networkMonitor.pathUpdateHandler = { [weak self] path in
      self?.lastLanReachable =
        path.status == .satisfied && !path.usesInterfaceType(.cellular)
    }
    networkMonitor.start(queue: networkQueue)
  }

  deinit {
    networkMonitor.cancel()
    cleanupLock.lock()
    cleanupRunnerToken &+= 1
    let cleanupTask = cleanupRunnerTask
    cleanupRunnerTask = nil
    cleanupRunning = false
    cleanupLock.unlock()
    cleanupTask?.cancel()
    uploadsLock.lock()
    uploadDispatcherTask?.cancel()
    for upload in activeUploads.values { upload.task.cancel() }
    uploadsLock.unlock()
  }

  func summary(completion: @escaping (Result<BackupSummaryDto, Error>) -> Void) {
    summaryQueue.async {
      self.triggerCleanupIfDue()
      completion(Result { try self.currentSummary() })
    }
  }

  func initialize(
    request: [String?: Any?],
    completion: @escaping (Result<BackupSummaryDto, Error>) -> Void
  ) {
    do {
      try saveRetentionDays(
        unbacked: (request["unbackedRetentionDays"] as? Int) ?? -1,
        backed: (request["backedRetentionDays"] as? Int) ?? -1,
        returnUnbacked: (request["returnUnbackedRetentionDays"] as? Int) ?? 3,
        returnBacked: (request["returnBackedRetentionDays"] as? Int) ?? 1
      )
      triggerCleanup()
      try applyAutoEnabled(request["autoEnabled"] as? Bool ?? false)
      completion(.success(try currentSummary()))
    } catch {
      completion(.failure(error))
    }
  }

  func setAutoEnabled(
    enabled: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    completion(Result { try applyAutoEnabled(enabled) })
  }

  private func applyAutoEnabled(_ enabled: Bool) throws {
    defaults.set(enabled, forKey: "ios_backup_auto_enabled")
    if !enabled {
      let tasks = withUploadsLock { () -> [Task<Void, Never>] in
        uploadDispatcherTask?.cancel()
        uploadDispatcherTask = nil
        uploadDispatchRequested = false
        let tasks = activeUploads.values.map(\.task)
        activeUploads.removeAll()
        return tasks
      }
      tasks.forEach { $0.cancel() }
    }
    _ = try jobStore.get().setUploadsEnabled(enabled)
    if enabled, hasConfiguredBackupHost() { requestUploadDispatch() }
    emitSummary()
  }

  func jobsForPaths(
    paths: [String],
    completion: @escaping (Result<BackupJobsByPathsDto, Error>) -> Void
  ) {
    guard paths.count <= 100 else {
      completion(.failure(pigeonError("每次最多查询 100 个录像路径", code: "backup_paths_limit")))
      return
    }
    var seen = Set<String>()
    let unique = paths.filter { seen.insert($0).inserted }
    completion(Result {
      let result = try jobStore.get().jobsForPaths(unique)
      var jobs = result.jobs
      var found = Set(jobs.compactMap { $0["filePath"] as? String })
      for path in unique where !found.contains(path) {
        let identity = IosBackupRecordingPath.stableIdentity(storedPath: path)
        guard identity.hasPrefix("Documents/recordings/"),
              var legacy = try jobStore.get().latestJob(
                filePathSuffix: "/\(identity)"
              )
        else { continue }
        legacy["filePath"] = path
        jobs.append(legacy)
        found.insert(path)
      }
      return BackupJobsByPathsDto(
        revision: result.revision,
        jobs: jobs.map(jobDto),
        missingPaths: unique.filter { !found.contains($0) }
      )
    })
  }

  func cleanupEvents(
    afterRevision: Int64,
    limit: Int64,
    completion: @escaping (Result<BackupCleanupPageDto, Error>) -> Void
  ) {
    guard afterRevision >= 0 else {
      completion(.failure(pigeonError("清理事件游标不能为负数", code: "backup_cleanup_cursor")))
      return
    }
    guard (1...100).contains(limit) else {
      completion(.failure(pigeonError("清理事件分页大小必须为 1 到 100", code: "backup_cleanup_limit")))
      return
    }
    completion(Result {
      let page = try jobStore.get().cleanupEvents(
        afterRevision: afterRevision,
        limit: Int(limit)
      )
      let events = page.events.map {
        BackupCleanupEventDto(
          revision: int64($0["revision"]),
          eventId: $0["eventId"] as? String ?? "",
          jobId: $0["jobId"] as? String ?? "",
          filePath: $0["filePath"] as? String ?? "",
          fileSizeBytes: int64($0["fileSizeBytes"]),
          deletedAtMs: int64($0["deletedAtMs"]),
          reason: $0["reason"] as? String ?? ""
        )
      }
      return BackupCleanupPageDto(
        latestRevision: page.latest,
        nextAfterRevision: events.last?.revision ?? afterRevision,
        hasMore: page.hasMore,
        events: events
      )
    })
  }

  func acknowledgeCleanupEvents(
    throughRevision: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard throughRevision >= 0 else {
      completion(.failure(pigeonError("清理事件确认游标不能为负数", code: "backup_cleanup_cursor")))
      return
    }
    completion(Result { try jobStore.get().acknowledgeCleanupEvents(throughRevision: throughRevision) })
  }

  func hasPendingJobsOutsideDestination(
    computerId: String,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    completion(Result { try jobStore.get().hasPendingJobsOutsideDestination(computerId) })
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
      stored.removeValue(forKey: "recoverIncompatibleFailuresOnly")
      defaults.set(stored, forKey: keys.connection)
      defaults.set(connection["deviceName"] as? String, forKey: keys.deviceName)
      if connection["recoverIncompatibleFailuresOnly"] as? Bool == true,
         let computerId = connection["computerId"] as? String {
        _ = try jobStore.get().recoverIncompatibleFailures(
          destinationComputerId: computerId
        )
      }
      triggerCleanup()
      requestUploadDispatch()
      emitSummary()
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func disconnect(completion: @escaping (Result<Void, Error>) -> Void) {
    do {
      try credentialStore.delete()
      defaults.removeObject(forKey: keys.connection)
      emitSummary()
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func enqueueJob(
    request: [String?: Any?],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    enqueueJobs(requests: [request], completion: completion)
  }

  func enqueueJobs(
    requests: [[String?: Any?]],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard requests.count <= 100 else {
      completion(.failure(pigeonError("单次最多入队 100 个备份任务", code: "backup_batch_too_large")))
      return
    }
    var jobs: [[String: Any]] = []
    var uploadJobs: [[String: Any]] = []
    do {
      for request in requests {
        guard let prepared = try prepareEnqueuedJob(request) else { continue }
        jobs.append(prepared.job)
        if prepared.startUpload && prepared.job["state"] as? String != "completed" {
          uploadJobs.append(prepared.job)
        }
      }
      try jobStore.get().upsert(jobs)
      uploadJobs.forEach(startUpload)
      emitSummary()
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  private func prepareEnqueuedJob(
    _ request: [String?: Any?]
  ) throws -> (job: [String: Any], startUpload: Bool)? {
    let path = request["filePath"] as? String ?? ""
    guard !path.isEmpty else {
      throw pigeonError("缺少录像路径", code: "backup_file_path_missing")
    }
    let resolvedUrl = try IosBackupRecordingPath.resolve(storedPath: path)
    guard FileManager.default.fileExists(atPath: resolvedUrl.path) else { return nil }
    let resolvedPath = resolvedUrl.path
    let id = request["id"] as? String ?? stableId(
      IosBackupRecordingPath.stableIdentity(storedPath: path)
    )
    let autoEnabled = defaults.bool(forKey: "ios_backup_auto_enabled")
    let startUploadRequested = request["startUpload"] as? Bool != false &&
      autoEnabled
    let forceRestart = request["forceRestart"] as? Bool == true
      let attributes = try FileManager.default.attributesOfItem(atPath: resolvedPath)
      let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
      guard fileSize > 0 else { return nil }
      let lastModified = Int64(
        ((attributes[.modificationDate] as? Date) ?? .distantPast)
          .timeIntervalSince1970 * 1000
      )
      let requested = normalized(request)
      let destination = requested["destinationComputerId"] as? String ??
        defaults.dictionary(forKey: keys.connection)?["computerId"] as? String ?? ""
      let existing = try jobStore.get().readJob(id: id)
      let requestedSessionId = ((requested["sessions"] as? [Any])?.first as? [String: Any])?["id"] as? String
      let existingSessionId = ((existing?["sessions"] as? [Any])?.first as? [String: Any])?["id"] as? String
      let sameSource = existing != nil &&
        requestedSessionId != nil && requestedSessionId == existingSessionId &&
        int64(existing?["totalBytes"]) == fileSize &&
        int64(existing?["lastModified"]) == lastModified &&
        (existing?["destinationComputerId"] as? String ?? "") == destination
      var job: [String: Any]
      if sameSource, var preserved = existing {
        preserved["filePath"] = resolvedPath
        if let sessions = requested["sessions"] { preserved["sessions"] = sessions }
        let completedWithEvidence = preserved["state"] as? String == "completed" &&
          !(preserved["contentSha256"] as? String ?? "").isEmpty
        if forceRestart && !completedWithEvidence {
          preserved["generation"] = UUID().uuidString
          preserved["state"] = "pending"
          preserved["uploadedBytes"] = 0
          for key in ["backupCompletedAt", "contentSha256", "remoteRecordId", "errorMessage", "failureKind"] {
            preserved.removeValue(forKey: key)
          }
        } else if startUploadRequested && ["paused", "failed"].contains(preserved["state"] as? String ?? "") {
          preserved["state"] = "pending"
          preserved.removeValue(forKey: "errorMessage")
          preserved.removeValue(forKey: "failureKind")
        }
        job = preserved
      } else {
        job = requested
        job["filePath"] = resolvedPath
        job["id"] = id
        job["generation"] = UUID().uuidString
        job["state"] = autoEnabled ? "pending" : "paused"
        job["uploadedBytes"] = 0
        job["totalBytes"] = fileSize
        job["lastModified"] = lastModified
        job["destinationComputerId"] = destination
        job.removeValue(forKey: "errorMessage")
        job.removeValue(forKey: "failureKind")
      }
      return (job, startUploadRequested)
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
      if let job = try readJobById(jobId) {
        startUpload(job)
      }
      emitSummary()
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
      emitSummary()
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func updateRetentionSchedule(
    request: [String?: Any?],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      try saveRetentionDays(
        unbacked: (request["unbackedRetentionDays"] as? Int) ?? -1,
        backed: (request["backedRetentionDays"] as? Int) ?? -1,
        returnUnbacked: (request["returnUnbackedRetentionDays"] as? Int) ?? 3,
        returnBacked: (request["returnBackedRetentionDays"] as? Int) ?? 1
      )
      triggerCleanup()
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func reclaimStorageIfNeeded(
    completion: @escaping (Result<[String?: Any?], Error>) -> Void
  ) {
    Task {
      do {
        completion(.success(try await performStorageReclaim()))
      } catch {
        // broad-catch: 将清理策略、文件或 SQLite 错误完整传回 Pigeon 调用方。
        completion(.failure(error))
      }
    }
  }

  func availableRecordingStorageBytes(
    completion: @escaping (Result<Int64?, Error>) -> Void
  ) {
    completion(.success(availableStorageBytesOrNil()))
  }

  private func performStorageReclaim() async throws -> [String?: Any?] {
    try await withMaintenanceSlot {
      if let storageReclaimOperationOverride {
        return try await storageReclaimOperationOverride()
      }
      return try await performStorageReclaimUncoordinated()
    }
  }

  private func performStorageReclaimUncoordinated() async throws -> [String?: Any?] {
    let recovery = try recoverCleanupIntentsSlice()
    if recovery.processedAny {
      triggerCleanup()
      let available = availableStorageBytes()
      return [
        "availableBytes": available, "availableBytesBefore": available,
        "freedBytes": Int64(0), "deletedCount": 0,
        "warning": available < 3 * 1024 * 1024 * 1024,
        "insufficient": available < 2 * 1024 * 1024 * 1024,
      ]
    }
    let minimumBytes: Int64 = 2 * 1024 * 1024 * 1024
    let targetBytes: Int64 = 3 * 1024 * 1024 * 1024
    let before = availableStorageBytes()
    var current = before
    var deletedCount = 0
    var freedBytes: Int64 = 0
    var jobsChanged = false
    if current < minimumBytes {
      let recordingsRoot = recordingsDirectory().path + "/"
      var afterCreatedAtKey: String?
      var afterId: String?
      var page: (jobs: [[String: Any]], nextCreatedAtKey: String?, nextId: String?)
      repeat {
        page = try jobStore.get().storageRecoveryJobsPage(
          afterCreatedAtKey: afterCreatedAtKey,
          afterId: afterId,
          minimumVerificationVersion: Self.verificationVersion
        )
        for job in page.jobs where current < targetBytes {
        guard
          job["state"] as? String == "completed",
          IosBackupCleanupGate.hasVerifiedRetentionEvidence(
            job,
            minimumVersion: Self.verificationVersion
          ),
          let expectedSha256 = job["contentSha256"] as? String,
          let totalBytes = job["totalBytes"] as? Int64,
          let lastAttested = job["lastAttestedAt"] as? String,
          let attestedDate = Self.isoFormatter.date(from: lastAttested),
          Date().timeIntervalSince(attestedDate) <= Self.storageAttestationFreshness,
          let path = job["filePath"] as? String,
          path.hasPrefix(recordingsRoot)
        else {
          continue
        }
        if !FileManager.default.fileExists(atPath: path) {
          switch try performAtomicCleanup(
            job: job, allowedStates: ["completed"],
            reason: "存储空间不足提前清理"
          ) {
          case .reconciledMissing:
            jobsChanged = true
          case .deleted(let bytes):
            deletedCount += 1
            freedBytes += bytes
            jobsChanged = true
          case .stale, .busy, .failed:
            break
          }
          continue
        }
        let attestation = await storageAttestation(
          job,
          contentSha256: expectedSha256,
          totalBytes: totalBytes
        )
        guard let receiptSignature = attestation else {
          let message = "暂时无法向电脑确认备份，已保留本地录像"
          if job["errorMessage"] as? String != message,
             let id = job["id"] as? String,
             let generation = job["generation"] as? String {
            jobsChanged = try jobStore.get().updateJob(
              id: id, expectedGeneration: generation
            ) { $0["errorMessage"] = message } || jobsChanged
          }
          continue
        }

        guard
          var currentJob = try readJobById(job["id"] as? String ?? ""),
          (currentJob["generation"] as? String) == (job["generation"] as? String),
          currentJob["state"] as? String == "completed",
          currentJob["localDeletedAt"] as? String == nil,
          IosBackupCleanupGate.hasVerifiedRetentionEvidence(
            currentJob,
            minimumVersion: Self.verificationVersion
          ),
          currentJob["contentSha256"] as? String == expectedSha256
        else { continue }

        guard let generation = currentJob["generation"] as? String,
              try jobStore.get().updateJob(
                id: currentJob["id"] as? String ?? "",
                expectedGeneration: generation,
                mutate: { stored in
                stored["verificationReceipt"] = receiptSignature
                stored["lastAttestedAt"] = Self.isoFormatter.string(from: Date())
              }),
              let refreshed = try readJobById(currentJob["id"] as? String ?? "")
        else { continue }
        currentJob = refreshed
        switch try performAtomicCleanup(
          job: currentJob, allowedStates: ["completed"],
          reason: "存储空间不足提前清理"
        ) {
        case .deleted(let bytes):
          deletedCount += 1
          freedBytes += bytes
          jobsChanged = true
          current = availableStorageBytes()
        case .reconciledMissing:
          jobsChanged = true
        case .stale:
          let message = "录像文件已被替换，已取消空间清理"
          if currentJob["errorMessage"] as? String != message {
            jobsChanged = try jobStore.get().updateJob(
              id: currentJob["id"] as? String ?? "",
              expectedGeneration: generation
            ) { $0["errorMessage"] = message } || jobsChanged
          }
          continue
        case .busy:
          continue
        case .failed:
          let message = "空间清理失败，已保留本机录像"
          if currentJob["errorMessage"] as? String != message {
            jobsChanged = try jobStore.get().updateJob(
              id: currentJob["id"] as? String ?? "",
              expectedGeneration: generation
            ) { $0["errorMessage"] = message } || jobsChanged
          }
          continue
        }
        }
        afterCreatedAtKey = page.nextCreatedAtKey
        afterId = page.nextId
      } while current < targetBytes && page.jobs.count == 100
    }
    if jobsChanged {
      emitSummary()
    }
    return [
      "availableBytes": current,
      "availableBytesBefore": before,
      "freedBytes": freedBytes,
      "deletedCount": deletedCount,
      "warning": current < targetBytes,
      "insufficient": current < minimumBytes,
    ]
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
    availableStorageBytesOrNil() ?? 0
  }

  private func availableStorageBytesOrNil() -> Int64? {
    if let availableStorageBytesOverride { return availableStorageBytesOverride() }
    let values = try? FileManager.default.attributesOfFileSystem(
      forPath: recordingsDirectory().path
    )
    return (values?[.systemFreeSize] as? NSNumber)?.int64Value
  }

  private func storageAttestation(
    _ job: [String: Any],
    contentSha256: String,
    totalBytes: Int64
  ) async -> String? {
    if let storageAttestationOverride {
      return await storageAttestationOverride(job, contentSha256, totalBytes)
    }
    guard case .confirmed(let receiptSignature) = await attestBackedJob(
      job,
      contentSha256: contentSha256,
      totalBytes: totalBytes
    ) else { return nil }
    return receiptSignature
  }

  /// Recovers at most one bounded page. New cleanup candidates must wait until
  /// every recoverable intent has crossed recovery or been explicitly resolved.
  private func recoverCleanupIntentsSlice() throws -> (
    processedAny: Bool, hasMore: Bool
  ) {
    let intents = try jobStore.get().cleanupIntents(
      limit: 100, recoverableOnly: true
    )
    guard !intents.isEmpty else { return (false, false) }
    var unresolved = false
    for intent in intents {
      if recordingActivityState.isActive {
        return (true, true)
      }
      unresolved = !(try resumeCleanupIntent(intent)) || unresolved
    }
    var hasMore = false
    if intents.count == 100 {
      hasMore = !(try jobStore.get().cleanupIntents(
        afterToken: intents.last?.token, limit: 1, recoverableOnly: true
      )).isEmpty
    }
    if unresolved {
      throw BackupSourceError(
        message: "仍有清理意图等待文件系统恢复"
      )
    }
    return (true, hasMore)
  }

  @discardableResult
  private func resumeCleanupIntent(_ originalIntent: IosBackupCleanupIntent) throws -> Bool {
    var intent = originalIntent
    let originalExists = FileManager.default.fileExists(atPath: intent.originalPath)
    let tombstoneExists = FileManager.default.fileExists(atPath: intent.tombstonePath)
    // 原路径重新出现意味着可能已有新录像占用。无论 tombstone 是否为旧目标，
    // 都不能继续提交或删除任一路径，留待显式冲突处理。
    if intent.phase != "committed" && originalExists && tombstoneExists {
      _ = try jobStore.get().updateCleanupIntentPhase(
        token: intent.token, from: intent.phase, to: "conflict"
      )
      return true
    }

    if intent.phase == "claimed" {
      guard let activated = try jobStore.get().activateCleanupIntent(
        token: intent.token
      ) else {
        try jobStore.get().abandonCleanupIntent(token: intent.token)
        return true
      }
      intent = activated
    }

    if intent.phase == "moving" {
      if tombstoneExists {
        guard cleanupPathMatchesIntent(intent.tombstonePath, intent: intent) else {
          return false
        }
        _ = try jobStore.get().updateCleanupIntentPhase(
          token: intent.token, from: "moving", to: "renamed"
        )
        intent = replacingPhase(intent, "renamed")
      } else if !originalExists {
        _ = try jobStore.get().updateCleanupIntentPhase(
          token: intent.token, from: "moving", to: "renamed"
        )
        intent = replacingPhase(intent, "renamed")
      } else {
        guard cleanupPathMatchesIntent(intent.originalPath, intent: intent) else {
          _ = try jobStore.get().updateCleanupIntentPhase(
            token: intent.token, from: "moving", to: "conflict"
          )
          return true
        }
        guard Darwin.rename(intent.originalPath, intent.tombstonePath) == 0 else {
          return false
        }
        _ = try jobStore.get().updateCleanupIntentPhase(
          token: intent.token, from: "moving", to: "renamed"
        )
        intent = replacingPhase(intent, "renamed")
      }
    }

    if intent.phase == "renamed" {
      if FileManager.default.fileExists(atPath: intent.originalPath) {
        _ = try jobStore.get().updateCleanupIntentPhase(
          token: intent.token, from: "renamed", to: "conflict"
        )
        return true
      }
      guard try jobStore.get().commitCleanupIntent(token: intent.token) else {
        return false
      }
      intent = replacingPhase(intent, "committed")
    }

    guard intent.phase == "committed" else { return false }
    if FileManager.default.fileExists(atPath: intent.tombstonePath) {
      guard cleanupPathMatchesIntent(intent.tombstonePath, intent: intent) else {
        return false
      }
      guard unlink(intent.tombstonePath) == 0 || errno == ENOENT else { return false }
    }
    try jobStore.get().finishCleanupIntent(token: intent.token)
    return true
  }

  private func replacingPhase(
    _ intent: IosBackupCleanupIntent, _ phase: String
  ) -> IosBackupCleanupIntent {
    IosBackupCleanupIntent(
      token: intent.token, jobId: intent.jobId, generation: intent.generation,
      originalPath: intent.originalPath, tombstonePath: intent.tombstonePath,
      expectedBytes: intent.expectedBytes,
      expectedModifiedAtMilliseconds: intent.expectedModifiedAtMilliseconds,
      expectedDevice: intent.expectedDevice, expectedInode: intent.expectedInode,
      expectedSha256: intent.expectedSha256, reason: intent.reason,
      completedState: intent.completedState,
      completedErrorMessage: intent.completedErrorMessage,
      allowedStates: intent.allowedStates, phase: phase
    )
  }

  private func cleanupPathMatchesIntent(
    _ path: String, intent: IosBackupCleanupIntent
  ) -> Bool {
    guard let proof = try? IosBackupCleanupFileProof(
      url: URL(fileURLWithPath: path)
    ) else {
      return false
    }
    return proof.identity.device == intent.expectedDevice
      && proof.identity.inode == intent.expectedInode
      && proof.identity.byteCount == intent.expectedBytes
      && proof.identity.modifiedAtMilliseconds == intent.expectedModifiedAtMilliseconds
      && (intent.expectedSha256?.isEmpty != false
        || proof.sha256 == intent.expectedSha256)
  }

  private func performAtomicCleanup(
    job: [String: Any], allowedStates: Set<String>, reason: String,
    completedState: String? = nil, completedErrorMessage: String? = nil,
    expectedCleanupGeneration: String? = nil
  ) throws -> AtomicCleanupResult {
    guard let id = job["id"] as? String,
          let generation = job["generation"] as? String,
          let path = job["filePath"] as? String
    else { return .failed }
    let file = URL(fileURLWithPath: path)
    let tombstone = file.deletingLastPathComponent().appendingPathComponent(
      ".\(file.lastPathComponent).packingproof-cleanup-\(UUID().uuidString)"
    )
    let proof: IosBackupCleanupFileProof?
    if FileManager.default.fileExists(atPath: path) {
      do {
        proof = try IosBackupCleanupFileProof(
          url: file,
          onOpenedBeforeHash: { [weak self] in
            self?.beforeCleanupFileProofForTesting?(job)
          }
        )
      } catch {
        // broad-catch: 无法取得可靠文件证明时拒绝清理本地录像
        return .failed
      }
      guard let proof,
            proof.identity.byteCount == int64(job["totalBytes"]),
            proof.identity.modifiedAtMilliseconds == int64(job["lastModified"]),
            (job["contentSha256"] as? String).map({ $0.isEmpty || $0 == proof.sha256 }) ?? true
      else { return .stale }
    } else {
      proof = nil
    }

    beforeCleanupIntentClaimForTesting?(job)
    if let proof, !proof.pathStillReferencesOpenedFile(path) { return .stale }
    let claimResult: (intent: IosBackupCleanupIntent?, failure: AtomicCleanupResult?) = try {
      cleanupPolicyLock.lock()
      defer { cleanupPolicyLock.unlock() }
      let intent = try jobStore.get().beginCleanupIntent(
        jobId: id, expectedGeneration: generation, allowedStates: allowedStates,
        originalPath: path, tombstonePath: tombstone.path,
        expectedBytes: proof?.identity.byteCount ?? int64(job["totalBytes"]),
        expectedModifiedAtMilliseconds: proof?.identity.modifiedAtMilliseconds
          ?? int64(job["lastModified"]),
        expectedDevice: proof?.identity.device ?? 0,
        expectedInode: proof?.identity.inode ?? 0,
        expectedSha256: proof?.sha256 ?? job["contentSha256"] as? String,
        reason: reason, completedState: completedState,
        completedErrorMessage: completedErrorMessage,
        expectedCleanupGeneration: expectedCleanupGeneration
      )
      guard let intent else { return (nil, .busy) }
      guard let movingIntent = try jobStore.get().activateCleanupIntent(
        token: intent.token
      ) else {
        try jobStore.get().abandonCleanupIntent(token: intent.token)
        return (nil, .busy)
      }
      try beforeCleanupRenameForTesting?(movingIntent)

      if let proof {
        guard proof.pathStillReferencesOpenedFile(path),
              !FileManager.default.fileExists(atPath: tombstone.path)
        else {
          _ = try jobStore.get().updateCleanupIntentPhase(
            token: movingIntent.token, from: "moving", to: "conflict"
          )
          return (nil, .stale)
        }
        guard Darwin.rename(path, tombstone.path) == 0 else {
          return (nil, .failed)
        }
        guard proof.pathStillReferencesOpenedFile(tombstone.path) else {
          if !FileManager.default.fileExists(atPath: path) {
            _ = Darwin.rename(tombstone.path, path)
          }
          return (nil, .failed)
        }
      }
      _ = try jobStore.get().updateCleanupIntentPhase(
        token: movingIntent.token, from: "moving", to: "renamed"
      )
      return (movingIntent, nil)
    }()
    if let failure = claimResult.failure { return failure }
    guard let movingIntent = claimResult.intent else { return .failed }
    try afterCleanupRenameForTesting?(movingIntent)
    guard !FileManager.default.fileExists(atPath: path) else { return .failed }
    guard try jobStore.get().commitCleanupIntent(token: movingIntent.token) else {
      return .busy
    }
    try afterCleanupCommitForTesting?(replacingPhase(movingIntent, "committed"))
    if proof != nil {
      guard unlink(tombstone.path) == 0 || errno == ENOENT else { return .failed }
    }
    try jobStore.get().finishCleanupIntent(token: movingIntent.token)
    return proof == nil ? .reconciledMissing : .deleted(bytes: proof!.identity.byteCount)
  }

  func getNetworkDiagnostics(
    completion: @escaping (Result<[String?: Any?]?, Error>) -> Void
  ) {
    completion(.success(["wifiConnected": lastLanReachable]))
  }

  private func currentSummary() throws -> BackupSummaryDto {
    let values = try jobStore.get().summaryValues()
    let connection = defaults.dictionary(forKey: keys.connection)
    var problemJob = values["problemJob"] as? [String: Any]
    uploadFailureLock.lock()
    let override = uploadFailureOverrides.first
    uploadFailureLock.unlock()
    if let (jobId, _) = override,
       let stored = try jobStore.get().readJob(id: jobId) {
      problemJob = jobsApplyingFailureOverrides([stored]).first
    }
    return BackupSummaryDto(
      schemaVersion: 1,
      revision: int64(values["revision"]),
      completedRevision: int64(values["completedRevision"]),
      cleanupHighWatermark: int64(values["cleanupHighWatermark"]),
      deviceId: deviceId(),
      deviceName: deviceName(),
      baseUrl: connection?["baseUrl"] as? String,
      computerId: connection?["computerId"] as? String,
      computerName: connection?["computerName"] as? String,
      lastConnectedAtMs: epochMilliseconds(connection?["lastConnectedAt"]),
      preferredHostId: nil,
      preferredHostName: nil,
      totalCount: int64(values["totalCount"]),
      pendingCount: int64(values["pendingCount"]),
      uploadingCount: int64(values["uploadingCount"]),
      pausedCount: int64(values["pausedCount"]),
      completedCount: int64(values["completedCount"]),
      failedCount: int64(values["failedCount"]),
      waitingCleanupCount: int64(values["waitingCleanupCount"]),
      localDeletedCount: int64(values["localDeletedCount"]),
      unfinishedUploadedBytes: int64(values["unfinishedUploadedBytes"]),
      unfinishedTotalBytes: int64(values["unfinishedTotalBytes"]),
      dominantFailureKind: values["dominantFailureKind"] as? String,
      activeJob: (values["activeJob"] as? [String: Any]).map(jobDto),
      problemJob: problemJob.map(jobDto)
    )
  }

  private func jobDto(_ job: [String: Any]) -> BackupJobDto {
    BackupJobDto(
      revision: int64(job["revision"]),
      id: job["id"] as? String ?? "",
      filePath: job["filePath"] as? String ?? "",
      state: job["state"] as? String ?? "",
      uploadedBytes: int64(job["uploadedBytes"]),
      totalBytes: int64(job["totalBytes"]),
      lastModifiedMs: optionalInt64(job["lastModified"]),
      contentSha256: job["contentSha256"] as? String,
      errorMessage: job["errorMessage"] as? String,
      failureKind: job["failureKind"] as? String,
      fileCreatedAtMs: epochMilliseconds(job["fileCreatedAt"]),
      backupCompletedAtMs: epochMilliseconds(job["backupCompletedAt"]),
      scheduledCleanupAtMs: epochMilliseconds(job["scheduledCleanupAt"]),
      localDeletedAtMs: epochMilliseconds(job["localDeletedAt"]),
      waitingCleanup: job["waitingCleanup"] as? Bool ?? false,
      remoteRecordId: optionalInt64(job["remoteRecordId"]).flatMap { $0 > 0 ? $0 : nil },
      destinationComputerId: job["destinationComputerId"] as? String ?? "",
      cleanupReason: job["cleanupReason"] as? String
    )
  }

  private func int64(_ value: Any?) -> Int64 {
    optionalInt64(value) ?? 0
  }

  private func optionalInt64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    return nil
  }

  private func epochMilliseconds(_ value: Any?) -> Int64? {
    guard let text = value as? String,
          let date = Self.isoFormatter.date(from: text)
    else { return nil }
    return Int64(date.timeIntervalSince1970 * 1000)
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

  private func saveRetentionDays(
    unbacked: Int, backed: Int, returnUnbacked: Int, returnBacked: Int
  ) throws {
    cleanupPolicyLock.lock()
    defer { cleanupPolicyLock.unlock() }
    let previous = defaults.dictionary(forKey: keys.retention)
    let returnChanged = (previous?["returnUnbackedRetentionDays"] as? Int ?? 3) != returnUnbacked
      || (previous?["returnBackedRetentionDays"] as? Int ?? 1) != returnBacked
    try jobStore.get().activateCleanupPolicy(
      unbackedRetentionDays: unbacked, backedRetentionDays: backed,
      forceReset: returnChanged
    )
    defaults.set(
      ["unbackedRetentionDays": unbacked, "backedRetentionDays": backed,
       "returnUnbackedRetentionDays": returnUnbacked,
       "returnBackedRetentionDays": returnBacked],
      forKey: keys.retention
    )
    guard unbackedRetentionDays() == unbacked, backedRetentionDays() == backed else {
      throw BackupSourceError(
        message: "本地保留策略写入后读取不一致"
      )
    }
  }

  private func unbackedRetentionDays() -> Int {
    let values = defaults.dictionary(forKey: keys.retention)
    return (values?["unbackedRetentionDays"] as? Int) ?? 30
  }

  private func backedRetentionDays() -> Int {
    let values = defaults.dictionary(forKey: keys.retention)
    return (values?["backedRetentionDays"] as? Int) ?? 7
  }

  private func returnUnbackedRetentionDays() -> Int {
    let values = defaults.dictionary(forKey: keys.retention)
    return (values?["returnUnbackedRetentionDays"] as? Int) ?? 3
  }

  private func returnBackedRetentionDays() -> Int {
    let values = defaults.dictionary(forKey: keys.retention)
    return (values?["returnBackedRetentionDays"] as? Int) ?? 1
  }

  private func jobsApplyingFailureOverrides(
    _ stored: [[String: Any]]
  ) -> [[String: Any]] {
    uploadFailureLock.lock()
    let overrides = uploadFailureOverrides
    uploadFailureLock.unlock()
    return stored.map { job in
      guard
        let id = job["id"] as? String,
        let generation = job["generation"] as? String,
        let (overrideGeneration, failure) = overrides[id],
        overrideGeneration == generation
      else { return job }
      var visible = job
      visible["state"] = "paused"
      visible["errorMessage"] =
        "\(failure.message)；任务状态写入失败，已保留内存告警"
      visible["failureKind"] = failure.failureKind
      visible["statusCode"] = failure.statusCode
      visible["errorCode"] = failure.errorCode
      return visible
    }
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

  @discardableResult
  func handleUploadFailure(
    jobId: String,
    expectedGeneration: String,
    error: Error
  ) -> IosBackupUploadFailureHandlingResult {
    let failure = Self.backupFailureInfo(error)
    do {
      let updated: Bool
      if let uploadFailureUpdateOverride {
        updated = try uploadFailureUpdateOverride(jobId, expectedGeneration)
      } else {
        updated = try updateUploadJob(
          jobId,
          expectedGeneration: expectedGeneration,
          mutate: { current in
            current["state"] = "paused"
            current["errorMessage"] = failure.message
            current["failureKind"] = failure.failureKind
            current["statusCode"] = failure.statusCode
            current["errorCode"] = failure.errorCode
          }
        )
      }
      uploadFailureLock.lock()
      uploadFailureOverrides.removeValue(forKey: jobId)
      uploadFailureLock.unlock()
      guard updated else { return .staleGeneration }
      emitSummary()
      return .persisted
    } catch {
      uploadFailureLock.lock()
      uploadFailureOverrides[jobId] = (expectedGeneration, failure)
      uploadFailureLock.unlock()
      if let uploadPersistenceFailureReporter {
        uploadPersistenceFailureReporter(jobId, expectedGeneration, error)
      } else {
        NSLog(
          "iOS backup state persistence failed for job %@ generation %@: %@",
          jobId,
          expectedGeneration,
          error.localizedDescription
        )
      }
      emitSummary()
      return .persistenceFailed
    }
  }

  private func emitSummary() {
    summaryQueue.async { [weak self] in
      guard let self else { return }
      self.summaryProgressWorkItem?.cancel()
      self.summaryProgressWorkItem = nil
      self.lastSummaryEventRequestedAt = Date()
      self.sendSummaryIfPossible()
    }
  }

  private func emitProgressSummary() {
    summaryQueue.async { [weak self] in
      guard let self, self.summaryProgressWorkItem == nil else { return }
      let delay = max(
        0,
        Self.summaryProgressThrottle
          - Date().timeIntervalSince(self.lastSummaryEventRequestedAt)
      )
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.summaryProgressWorkItem = nil
        self.lastSummaryEventRequestedAt = Date()
        self.sendSummaryIfPossible()
      }
      self.summaryProgressWorkItem = work
      self.summaryQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }
  }

  func emitProgressSummaryForTesting() {
    emitProgressSummary()
  }

  private func sendSummaryIfPossible() {
    emitLock.lock()
    if summaryEventInFlight {
      summaryEventPending = true
      emitLock.unlock()
      return
    }
    summaryEventInFlight = true
    emitLock.unlock()
    guard let summary = try? currentSummary() else {
      emitLock.lock()
      summaryEventInFlight = false
      emitLock.unlock()
      return
    }
    eventApi.summaryChanged(summary: summary) { [weak self] _ in
      guard let self else { return }
      self.summaryQueue.async {
        self.emitLock.lock()
        self.summaryEventInFlight = false
        let shouldSend = self.summaryEventPending
        self.summaryEventPending = false
        self.emitLock.unlock()
        if shouldSend { self.sendSummaryIfPossible() }
      }
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

  private func startUpload(_: [String: Any]) {
    requestUploadDispatch()
  }

  func onHostForeground() {
    hostLifecycleLock.lock()
    hostForeground = true
    hostLifecycleLock.unlock()
    requestUploadDispatch()
    let deferred = withCleanupLock { () -> Bool in
      let pending = cleanupDeferredByBackground
      cleanupDeferredByBackground = false
      return pending
    }
    if deferred { triggerCleanup() }
  }

  func onHostBackground() {
    hostLifecycleLock.lock()
    hostForeground = false
    hostLifecycleLock.unlock()
  }

  private func isHostForeground() -> Bool {
    hostLifecycleLock.lock()
    defer { hostLifecycleLock.unlock() }
    return hostForeground
  }

  private func withUploadsLock<T>(_ body: () -> T) -> T {
    uploadsLock.lock()
    defer { uploadsLock.unlock() }
    return body()
  }

  private func requestUploadDispatch() {
    guard defaults.bool(forKey: "ios_backup_auto_enabled"),
          isHostForeground() else { return }
    uploadsLock.lock()
    uploadDispatchRequested = true
    guard uploadDispatcherTask == nil else {
      uploadsLock.unlock()
      return
    }
    uploadDispatcherTask = Task.detached { [weak self] in
      await self?.runUploadDispatcher()
    }
    uploadsLock.unlock()
  }

  private func finishUploadDispatcher() {
    beforeUploadDispatcherFinalizationForTesting?()
    uploadsLock.lock()
    uploadDispatcherTask = nil
    let shouldRestart = uploadDispatchRequested
    uploadsLock.unlock()
    if shouldRestart {
      requestUploadDispatch()
    }
  }

  private func runUploadDispatcher() async {
    guard isHostForeground() else {
      finishUploadDispatcher()
      return
    }
    do {
      let recovery = try await withMaintenanceSlot {
        try recoverCleanupIntentsSlice()
      }
      if recovery.processedAny {
        finishUploadDispatcher()
        if recovery.hasMore {
          triggerCleanup()
        } else {
          requestUploadDispatch()
        }
        return
      }
    } catch {
      NSLog("PackingProof cleanup recovery failed before upload: %@", error.localizedDescription)
      finishUploadDispatcher()
      triggerCleanup()
      return
    }
    while !Task.isCancelled && isHostForeground() {
      guard defaults.bool(forKey: "ios_backup_auto_enabled") else { break }
      withUploadsLock { uploadDispatchRequested = false }

      do {
        while !Task.isCancelled,
              isHostForeground(),
              defaults.bool(forKey: "ios_backup_auto_enabled"),
              let job = try jobStore.get().claimNextUploadJob() {
          guard let jobId = job["id"] as? String,
                let generation = job["generation"] as? String,
                !generation.isEmpty
          else { continue }
          guard isHostForeground() else {
            _ = try jobStore.get().updateJob(
              id: jobId,
              expectedGeneration: generation
            ) { current in
              current["state"] = "pending"
            }
            emitSummary()
            break
          }
          let identity = IosBackupUploadIdentity(
            generation: generation,
            token: UUID()
          )
          let startGate = IosBackupUploadStartGate()
          let task = Task.detached { [weak self] in
            await startGate.wait()
            guard let self, !Task.isCancelled else { return }
            if let uploadOperationOverride = self.uploadOperationOverride {
              await uploadOperationOverride(job, identity)
            } else {
              await self.upload(job: job, identity: identity)
            }
          }
          withUploadsLock {
            activeUploads[jobId]?.task.cancel()
            activeUploads[jobId] = ActiveUpload(identity: identity, task: task)
          }
          let current = try jobStore.get().readJob(id: jobId)
          guard current?["generation"] as? String == generation,
                current?["state"] as? String == "uploading"
          else {
            task.cancel()
            finishActiveUpload(jobId: jobId, identity: identity)
            await startGate.open()
            await task.value
            continue
          }
          await startGate.open()
          await task.value
          finishActiveUpload(jobId: jobId, identity: identity)
          if let current = try jobStore.get().readJob(id: jobId),
             current["generation"] as? String == generation,
             current["state"] as? String == "uploading" {
            // 上传状态无法落盘时保留 SQLite 原状，停止本轮 dispatcher，
            // 避免同一任务在数据库故障期间形成无间隔重试循环。
            break
          }
        }
      } catch {
        NSLog(
          "PackingProof backup dispatcher failed: %@",
          error.localizedDescription
        )
      }

      let shouldContinue = withUploadsLock { () -> Bool in
        if uploadDispatchRequested { return true }
        uploadDispatcherTask = nil
        return false
      }
      if shouldContinue {
        continue
      }
      return
    }

    finishUploadDispatcher()
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

  func requestUploadDispatchForTesting() {
    requestUploadDispatch()
  }

  func uploadTaskCountsForTesting() -> (dispatcher: Int, active: Int) {
    withUploadsLock {
      (uploadDispatcherTask == nil ? 0 : 1, activeUploads.count)
    }
  }

  func waitForUploadDispatcherForTesting() async {
    let task = withUploadsLock { uploadDispatcherTask }
    await task?.value
    await drainSummaryQueue()
  }

  func finishUploadDispatcherForTesting() {
    withUploadsLock {
      uploadDispatcherTask = Task {}
    }
    finishUploadDispatcher()
  }

  private func upload(
    job: [String: Any],
    identity: IosBackupUploadIdentity
  ) async {
    guard let jobId = job["id"] as? String else { return }
    defer { finishActiveUpload(jobId: jobId, identity: identity) }

    do {
      guard
        let connection = defaults.dictionary(forKey: keys.connection),
        let storedBaseUrl = connection["baseUrl"] as? String
      else {
        throw pigeonError("未找到备份连接", code: "credential_missing")
      }
      guard let path = job["filePath"] as? String, !path.isEmpty else {
        throw BackupSourceError(message: "备份任务缺少录像文件路径")
      }
      let resolvedUrl = try IosBackupRecordingPath.resolve(storedPath: path)
      if resolvedUrl.path != path {
        let updated = try updateUploadJob(
          jobId, expectedGeneration: identity.generation
        ) { current in
          current["filePath"] = resolvedUrl.path
        }
        guard updated else { throw CancellationError() }
      }
      var baseUrl = storedBaseUrl
      guard let accessKey = try credentialStore.load() else {
        throw pigeonError("未找到备份访问密钥", code: "credential_missing")
      }
      guard
        let rawSessions = job["sessions"] as? [Any],
        rawSessions.count == 1,
        let completionSession = Self.backupCompletionSession(rawSessions[0])
      else {
        throw pigeonError(
          "备份任务必须且只能包含一条录像记录",
          code: "backup_session_invalid"
        )
      }
      let reader = try IosBackupFileReader(url: resolvedUrl)
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
            emitProgressSummary()
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
          throw pigeonError("电脑返回的上传进度无效")
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
        emitProgressSummary()
      }

      try Task.checkCancellation()
      try reader.assertUnchanged()
      let completePath = "/api/mobile-backup/uploads/\(uploadIdEncoded)/complete"
      var completeBody: [String: Any] = [
        "fileSha256": fileSha256,
        "sourceDeviceId": deviceId(),
        "sourceDeviceName": deviceName(),
        "sessions": [completionSession],
      ]
      if connection["supportsUploadVideoCodec"] as? Bool == true,
         let sourceSession = rawSessions[0] as? [String: Any],
         let videoCodec = Self.normalizedVideoCodec(sourceSession["videoCodec"]) {
        completeBody["videoCodec"] = videoCodec
      }
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
      emitSummary()
      triggerCleanup()
    } catch {
      handleUploadFailure(
        jobId: jobId,
        expectedGeneration: identity.generation,
        error: error
      )
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
    emitSummary()
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

  static func backupCompletionSession(_ value: Any) -> [String: Any]? {
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

  static func normalizedVideoCodec(_ value: Any?) -> String? {
    switch (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "h264", "avc": return "h264"
    case "h265", "hevc": return "h265"
    case "av1": return "av1"
    default: return nil
    }
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
        failureKind: backupFailureKind(statusCode: 0, errorCode: pigeon.code)
      )
    }
    if let source = error as? BackupSourceError {
      return BackupTransferError(
        statusCode: 0,
        errorCode: "backup_source_unavailable",
        message: source.message,
        failureKind: "storage_unavailable"
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
    case "credential_missing", "enrollment_required", "device_token_invalid":
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
    try jobStore.get().readJob(id: id)
  }

  private func dueAt(
    _ job: [String: Any], unbackedDays: Int, backedDays: Int,
    returnUnbackedDays: Int? = nil, returnBackedDays: Int? = nil
  ) -> Date? {
    let state = job["state"] as? String ?? ""
    let completedAt = job["backupCompletedAt"] as? String
    // 旧版本“已完成但缺 backupCompletedAt”的录像按 legacy 保留，不参与清理。
    if state == "completed" && completedAt == nil {
      return nil
    }
    let days: Int
    let base: String?
    let isReturn = isReturnGoods(job)
    if let completedAt {
      days = isReturn ? (returnBackedDays ?? self.returnBackedRetentionDays()) : backedDays
      base = completedAt
    } else {
      days = isReturn ? (returnUnbackedDays ?? self.returnUnbackedRetentionDays()) : unbackedDays
      base = job["fileCreatedAt"] as? String
    }
    guard days >= 0, let base, let baseDate = Self.isoFormatter.date(from: base) else {
      return nil
    }
    return baseDate.addingTimeInterval(Double(days) * 24 * 60 * 60)
  }

  private func isReturnGoods(_ job: [String: Any]) -> Bool {
    if let mode = job["mode"] as? String {
      return mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "return"
    }
    guard let sessions = job["sessions"] as? [Any],
          let session = sessions.first as? [String: Any],
          let mode = session["mode"] as? String else { return false }
    return mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "return"
  }

  private func isConfirmationFresh(_ lastAttestedAt: String?, now: Date) -> Bool {
    guard let lastAttestedAt,
          let attested = Self.isoFormatter.date(from: lastAttestedAt) else {
      return false
    }
    return now.timeIntervalSince(attested) <= Self.retentionConfirmationGrace
  }

  private func withMaintenanceSlot<T>(
    _ operation: () async throws -> T
  ) async throws -> T {
    await maintenanceGate.acquire()
    do {
      try Task.checkCancellation()
      let result = try await operation()
      await maintenanceGate.release()
      return result
    } catch {
      await maintenanceGate.release()
      throw error
    }
  }

  private func withCleanupLock<T>(_ operation: () -> T) -> T {
    cleanupLock.lock()
    defer { cleanupLock.unlock() }
    return operation()
  }

  private func triggerCleanup() {
    guard cleanupMaintenanceNeeded() else {
      withCleanupLock { lastCleanupAt = Date() }
      return
    }
    // 后台进程不做清理扫描：远端确认要联网，上传本身也只在前台跑，
    // 后台继续轮询只会持续占用 CPU，被 iOS 以资源超限杀掉。
    guard isHostForeground() else {
      withCleanupLock { cleanupDeferredByBackground = true }
      return
    }
    withCleanupLock {
      guard cleanupRunnerTask == nil else {
        cleanupRequested = true
        return
      }
      startCleanupRunnerUnlocked()
    }
  }

  private func hasConfiguredBackupHost() -> Bool {
    if let cleanupConfigurationOverride {
      return cleanupConfigurationOverride()
    }
    guard let connection = defaults.dictionary(forKey: keys.connection),
          let baseUrl = connection["baseUrl"] as? String,
          let components = URLComponents(string: baseUrl),
          ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
          !(components.host ?? "").isEmpty,
          !(connection["computerId"] as? String ?? "").isEmpty,
          let accessKey = try? credentialStore.load(),
          !accessKey.isEmpty else {
      return false
    }
    return true
  }

  private func cleanupMaintenanceNeeded() -> Bool {
    if hasConfiguredBackupHost() { return true }
    guard case .success(let store) = jobStore else { return false }
    return ((try? store.cleanupIntents(limit: 1, recoverableOnly: true))?.isEmpty == false)
  }

  /// Must be called with cleanupLock held.
  private func startCleanupRunnerUnlocked() {
    cleanupRunnerToken &+= 1
    let token = cleanupRunnerToken
    cleanupRunning = true
    cleanupRequested = false
    lastCleanupAt = Date()
    let activityState = recordingActivityState
    let workPause = cleanupWorkPauseNanoseconds
    cleanupRunnerTask = Task.detached(priority: .utility) { [weak self] in
      while !Task.isCancelled {
        guard let foreground = self?.isHostForeground() else { return }
        guard foreground else {
          self?.deferCleanupForBackground(token: token)
          return
        }
        while activityState.isActive {
          do {
            try await Task.sleep(nanoseconds: workPause)
          } catch {
            // broad-catch: 睡眠只会因任务取消失败，结束当前清理 runner
            self?.finishCleanupRunner(token: token)
            return
          }
          guard self?.cleanupRunnerIsCurrent(token: token) == true else { return }
        }
        let failed = await { [weak self] () async -> Bool? in
          guard let self else { return nil }
          self.withCleanupLock { self.cleanupSliceHasMore = false }
          do {
            try await self.performCleanup()
            return false
          } catch {
            NSLog("PackingProof cleanup slice failed: %@", error.localizedDescription)
            return true
          }
        }()
        guard let failed,
              let decision = self?.cleanupRunnerDecision(token: token, failed: failed)
        else { return }
        self?.afterCleanupRunnerDecisionForTesting?()
        switch decision {
        case .retry(let delay):
          let attempt = self?.withCleanupLock { self?.cleanupRetryAttempt ?? 0 } ?? 0
          self?.beforeCleanupRetrySleepForTesting?(attempt, delay)
          do {
            try await Task.sleep(nanoseconds: delay)
          } catch {
            // broad-catch: 重试等待取消后结束当前清理 runner
            self?.finishCleanupRunner(token: token)
            return
          }
          guard self?.cleanupRunnerIsCurrent(token: token) == true else { return }
        case .continueAfter(let delay):
          do {
            try await Task.sleep(nanoseconds: delay)
          } catch {
            self?.finishCleanupRunner(token: token)
            return
          }
          guard self?.cleanupRunnerIsCurrent(token: token) == true else { return }
        case .finished(let exhausted):
          if exhausted {
            NSLog("PackingProof cleanup retry limit reached; waiting for next trigger")
          }
          return
        }
      }
      self?.finishCleanupRunner(token: token)
    }
  }

  private func cleanupRunnerDecision(
    token: UInt64, failed: Bool
  ) -> CleanupRunnerDecision? {
    withCleanupLock {
      guard cleanupRunnerToken == token, cleanupRunnerTask != nil else { return nil }
      if failed {
        let attempt = cleanupRetryAttempt
        guard attempt < cleanupRetryDelaysNanoseconds.count else {
          cleanupRetryAttempt = 0
          if cleanupRequested {
            cleanupRequested = false
            return .continueAfter(cleanupSliceIntervalNanoseconds)
          }
          finalizeCleanupRunnerUnlocked(token: token)
          return .finished(exhausted: true)
        }
        cleanupRetryAttempt = attempt + 1
        return .retry(cleanupRetryDelaysNanoseconds[attempt])
      }
      cleanupRetryAttempt = 0
      if cleanupSliceHasMore {
        cleanupRequested = false
        return .continueAfter(cleanupSliceIntervalNanoseconds)
      }
      if cleanupRequested {
        cleanupRequested = false
        return .continueAfter(cleanupSliceIntervalNanoseconds)
      }
      finalizeCleanupRunnerUnlocked(token: token)
      return .finished(exhausted: false)
    }
  }

  private func cleanupRunnerIsCurrent(token: UInt64) -> Bool {
    withCleanupLock { cleanupRunnerToken == token && cleanupRunnerTask != nil }
  }

  /// Must be called with cleanupLock held.
  private func finalizeCleanupRunnerUnlocked(token: UInt64) {
    guard cleanupRunnerToken == token else { return }
    cleanupRunnerToken &+= 1
    cleanupRunnerTask = nil
    cleanupRunning = false
  }

  /// 进入后台时结束当前 runner，并记下回到前台要补跑的清理。
  private func deferCleanupForBackground(token: UInt64) {
    withCleanupLock {
      guard cleanupRunnerToken == token, cleanupRunnerTask != nil else { return }
      cleanupDeferredByBackground = true
      finalizeCleanupRunnerUnlocked(token: token)
    }
  }

  private func finishCleanupRunner(token: UInt64) {
    withCleanupLock {
      finalizeCleanupRunnerUnlocked(token: token)
    }
  }

  private func triggerCleanupIfDue() {
    let due = withCleanupLock {
      Date().timeIntervalSince(lastCleanupAt) >= Self.cleanupThrottle
    }
    if due {
      triggerCleanup()
    }
  }

  func performCleanup() async throws {
    do {
      try await withMaintenanceSlot {
        if let cleanupOperationOverride {
          try await cleanupOperationOverride()
        } else {
          try await performCleanupUncoordinated()
        }
      }
    } catch {
      await drainSummaryQueue()
      throw error
    }
    await drainSummaryQueue()
  }

  private func drainSummaryQueue() async {
    await withCheckedContinuation { continuation in
      summaryQueue.async {
        self.flushPendingSummaryOnQueue()
        continuation.resume()
      }
    }
  }

  func drainSummaryQueueForTesting() {
    summaryQueue.sync { flushPendingSummaryOnQueue() }
    // A synchronous fake event callback queues its completion bookkeeping
    // behind the current block, so use a second barrier before fixture teardown.
    summaryQueue.sync { }
  }

  private func flushPendingSummaryOnQueue() {
    let hadPendingProgress = summaryProgressWorkItem != nil
    summaryProgressWorkItem?.cancel()
    summaryProgressWorkItem = nil
    if hadPendingProgress {
      lastSummaryEventRequestedAt = Date()
      sendSummaryIfPossible()
    }
  }

  func triggerCleanupForTesting() {
    triggerCleanup()
  }

  private func performCleanupUncoordinated() async throws {
    if recordingActivityState.isActive {
      withCleanupLock { cleanupSliceHasMore = true }
      return
    }
    let configured = hasConfiguredBackupHost()
    let recovery = try recoverCleanupIntentsSlice()
    if recovery.processedAny {
      withCleanupLock {
        cleanupSliceHasMore = recovery.hasMore || configured
      }
      if configured && !recovery.hasMore { requestUploadDispatch() }
      return
    }
    guard configured else {
      withCleanupLock { cleanupSliceHasMore = false }
      return
    }
    let root = recordingsDirectory().path + "/"
    let unbackedDays = unbackedRetentionDays()
    let backedDays = backedRetentionDays()
    let slice = try jobStore.get().cleanupCandidateJobsSlice(
      unbackedRetentionDays: unbackedDays,
      backedRetentionDays: backedDays
    )
    let now = slice.evaluationNow
    func persistCleanupStatus(
      id: String, generation: String, proposed: [String: Any]
    ) throws -> Bool {
      guard let current = try readJobById(id) else { return false }
      let keys = [
        "waitingCleanup", "errorMessage", "lastAttestedAt",
        "verificationReceipt",
      ]
      let differs = keys.contains { key in
        let old = current[key]
        let new = proposed[key]
        if old == nil && new == nil { return false }
        guard let oldObject = old as? NSObject, let newObject = new as? NSObject else {
          return true
        }
        return !oldObject.isEqual(newObject)
      }
      guard differs else { return false }
      return try jobStore.get().updateJob(
        id: id, expectedGeneration: generation,
        expectedCleanupGeneration: slice.generation
      ) { stored in
        for key in keys {
          if let value = proposed[key] {
            stored[key] = value
          } else {
            stored.removeValue(forKey: key)
          }
        }
      }
    }
    var changed = false
    for job in jobsApplyingFailureOverrides(slice.jobs) {
      if recordingActivityState.isActive {
        // Do not advance the persistent cursor past unprocessed jobs. Jobs
        // already completed in this slice are safe to evaluate again because
        // generation checks and cleanup intents make the operations idempotent.
        withCleanupLock { cleanupSliceHasMore = true }
        if changed { emitProgressSummary() }
        return
      }
      beforeCleanupCandidateForTesting?(job)
      guard try jobStore.get().isCleanupGenerationCurrent(slice.generation) else {
        break
      }
      guard
        let id = job["id"] as? String,
        let path = job["filePath"] as? String,
        path.hasPrefix(root)
      else { continue }
      if job["localDeletedAt"] as? String != nil { continue }
      let state = job["state"] as? String ?? ""
      if state == "pending" || state == "uploading" { continue }
      guard let due = dueAt(
        job, unbackedDays: slice.unbackedRetentionDays,
        backedDays: slice.backedRetentionDays
      ), now >= due else { continue }

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
          if let generation = job["generation"] as? String {
            changed = try persistCleanupStatus(
              id: id, generation: generation, proposed: baseJob
            ) || changed
          }
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
          changed = try persistCleanupStatus(
            id: id, generation: job["generation"] as? String ?? "",
            proposed: baseJob
          ) || changed
          continue
        case .unauthorized:
          baseJob["waitingCleanup"] = false
          baseJob["errorMessage"] = "需要重新扫码授权"
          changed = try persistCleanupStatus(
            id: id, generation: job["generation"] as? String ?? "",
            proposed: baseJob
          ) || changed
          continue
        case .notReady:
          baseJob["waitingCleanup"] = true
          baseJob["errorMessage"] = "电脑端尚未完成校验"
          changed = try persistCleanupStatus(
            id: id, generation: job["generation"] as? String ?? "",
            proposed: baseJob
          ) || changed
          continue
        case .unreachable:
          baseJob["waitingCleanup"] = true
          baseJob["errorMessage"] = "暂时无法向电脑确认备份，已保留本地录像"
          changed = try persistCleanupStatus(
            id: id, generation: job["generation"] as? String ?? "",
            proposed: baseJob
          ) || changed
          continue
        }
      }

      guard let generation = baseJob["generation"] as? String,
            let currentState = baseJob["state"] as? String
      else { continue }
      if completedAt != nil {
        changed = try persistCleanupStatus(
          id: id, generation: generation, proposed: baseJob
        ) || changed
        guard let refreshed = try readJobById(id),
              refreshed["generation"] as? String == generation,
              try jobStore.get().isCleanupGenerationCurrent(slice.generation)
        else { continue }
        baseJob = refreshed
      }
      let reason = completedAt == nil
        ? "未备份录像保留策略清理" : "已备份录像保留策略清理"
      switch try performAtomicCleanup(
        job: baseJob, allowedStates: [currentState], reason: reason,
        completedState: completedAt == nil ? "expired" : nil,
        completedErrorMessage: completedAt == nil
          ? "未备份录像已按保留策略清理" : nil,
        expectedCleanupGeneration: slice.generation
      ) {
      case .stale:
        baseJob["waitingCleanup"] = false
        baseJob["errorMessage"] = "录像文件已被替换，已取消本次自动清理"
        changed = try persistCleanupStatus(
          id: id, generation: generation, proposed: baseJob
        ) || changed
        continue
      case .failed:
        baseJob["waitingCleanup"] = true
        changed = try persistCleanupStatus(
          id: id, generation: generation, proposed: baseJob
        ) || changed
        continue
      case .busy:
        continue
      case .deleted(_), .reconciledMissing:
        changed = true
      }
    }

    let hasMore = try jobStore.get().finishCleanupSlice(slice)
    withCleanupLock { cleanupSliceHasMore = hasMore }

    if changed {
      emitProgressSummary()
    }
    if !hasMore {
      // A throttled progress event may still be pending. Force one final
      // snapshot so the UI eventually observes the completed sweep.
      emitSummary()
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

}

/// iOS 后台上传无法依赖 Dart isolate，因此在原生侧按稳定 NodeId 重新定位主机。
final class IosLanBackupHostResolver: @unchecked Sendable {
  private static let minimumHostVersion = "0.0.55"
  private static let backupProtocol = "mobile-backup-v2"
  private static let enrollmentVersion = 2
  private static let authenticationVersion = 3
  private static let maximumConcurrentProbes = 4

  typealias CandidateProvider = @Sendable () -> [String]
  typealias ProbeOperation = @Sendable (String, String) async -> String?

  private let candidateProvider: CandidateProvider
  private let probeOperation: ProbeOperation

  init() {
    candidateProvider = { IosLanBackupHostResolver.subnetCandidates() }
    probeOperation = { baseUrl, nodeId in
      await IosLanBackupHostResolver.probe(baseUrl: baseUrl, nodeId: nodeId)
    }
  }

  init(
    candidateProvider: @escaping CandidateProvider,
    probeOperation: @escaping ProbeOperation
  ) {
    self.candidateProvider = candidateProvider
    self.probeOperation = probeOperation
  }

  func resolve(currentBaseUrl: String, expectedNodeId: String) async -> String? {
    let nodeId = expectedNodeId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !nodeId.isEmpty else { return nil }
    if let current = await probeOperation(currentBaseUrl, nodeId) {
      return current
    }

    var candidates = candidateProvider().makeIterator()
    return await withTaskGroup(of: String?.self, returning: String?.self) { group in
      func addNextCandidate() -> Bool {
        guard let candidate = candidates.next() else { return false }
        group.addTask { [probeOperation] in
          guard !Task.isCancelled else { return nil }
          return await probeOperation(candidate, nodeId)
        }
        return true
      }

      for _ in 0..<Self.maximumConcurrentProbes where addNextCandidate() {}
      while let result = await group.next() {
        if let result {
          group.cancelAll()
          return result
        }
        if Task.isCancelled {
          group.cancelAll()
          return nil
        }
        _ = addNextCandidate()
      }
      return nil
    }
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
