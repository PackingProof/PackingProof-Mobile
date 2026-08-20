import AVFoundation
import AVKit
import CoreImage
import CryptoKit
import Darwin
import Flutter
import ImageIO
import Network
import QuartzCore
import SQLite3
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

final class PigeonPlatform {
  private static var cameraHost: IosCameraHostApi?

  static func register(with registry: FlutterPluginRegistry) {
    guard
      let registrar = registry.registrar(forPlugin: "PigeonPlatform"),
      let messenger = registrar.messenger() as? FlutterBinaryMessenger
    else {
      return
    }

    MediaProcessingHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: IosMediaProcessingHostApi()
    )
    SystemMediaPresenterHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: IosSystemMediaPresenterHostApi()
    )
    AlertAudioSessionHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: IosAlertAudioSessionHostApi()
    )
    let backupEvents = BackupNativeEventApi(binaryMessenger: messenger)
    BackupNativeHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: IosBackupHostApi(eventApi: backupEvents)
    )
    let cameraHost = IosCameraHostApi(
      eventApi: CameraEventApi(binaryMessenger: messenger),
      textures: registrar.textures()
    )
    self.cameraHost = cameraHost
    CameraHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: cameraHost
    )
    OrderReceiverHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: IosOrderReceiverHostApi(
        eventApi: OrderReceiverEventApi(binaryMessenger: messenger)
      )
    )
  }

  /// App 终止时必须在 Flutter 引擎销毁前同步关闭相机。
  ///
  /// `FlutterViewController` 会在 `UIApplicationWillTerminateNotification` /
  /// `UISceneDidDisconnectNotification` 中销毁引擎；若相机回调仍调用
  /// `textureFrameAvailable`，会触发 use-after-free 崩溃。
  static func shutdownForTermination() {
    cameraHost?.prepareForTermination()
  }
}

private func pigeonError(
  _ message: String,
  code: String = "ios_unavailable"
) -> PigeonError {
  PigeonError(code: code, message: message, details: nil)
}

private struct BackupTransferError: Error {
  let statusCode: Int
  let errorCode: String
  let message: String
  let failureKind: String
}

private final class IosMediaProcessingHostApi: MediaProcessingHostApi {
  private let exportLock = NSLock()
  private var activeExportSessions: [String: AVAssetExportSession] = [:]

  func generateThumbnail(
    request: ThumbnailRequest,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let url = URL(fileURLWithPath: request.path)
      let asset = AVAsset(url: url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      let time = CMTime(seconds: 1, preferredTimescale: 600)
      do {
        let image = try generator.copyCGImage(at: time, actualTime: nil)
        let output = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString + ".jpg")
        guard
          let destination = CGImageDestinationCreateWithURL(
            output as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
          )
        else {
          throw pigeonError("无法创建预览图")
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        completion(.success(output.path))
      } catch {
        completion(.failure(error))
      }
    }
  }

  func applyWatermark(
    request: WatermarkRequest,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let input = URL(fileURLWithPath: request.inputPath)
        let output = URL(fileURLWithPath: request.outputPath)
        try? FileManager.default.removeItem(at: output)
        let asset = AVAsset(url: input)
        let composition = AVMutableComposition()
        guard
          let sourceVideo = asset.tracks(withMediaType: .video).first,
          let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
          )
        else {
          throw pigeonError("无法读取录像视频轨道")
        }
        try compositionVideo.insertTimeRange(
          CMTimeRange(start: .zero, duration: asset.duration),
          of: sourceVideo,
          at: .zero
        )
        compositionVideo.preferredTransform = sourceVideo.preferredTransform

        if let sourceAudio = asset.tracks(withMediaType: .audio).first,
          let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
          )
        {
          try compositionAudio.insertTimeRange(
            CMTimeRange(start: .zero, duration: asset.duration),
            of: sourceAudio,
            at: .zero
          )
        }

        let size = sourceVideo.naturalSize.applying(
          sourceVideo.preferredTransform
        )
        let width = abs(size.width).rounded(.up)
        let height = abs(size.height).rounded(.up)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: width, height: height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
          start: .zero,
          duration: asset.duration
        )
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(
          assetTrack: compositionVideo
        )
        layerInstruction.setTransform(
          sourceVideo.preferredTransform,
          at: .zero
        )
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        let text = CATextLayer()
        let started = Date(timeIntervalSince1970: Double(request.startedAtMs) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        text.string = request.trackingNumber.isEmpty
          ? formatter.string(from: started)
          : "\(formatter.string(from: started)) Order:\(request.trackingNumber)"
        text.fontSize = max(24, min(46, height * 0.03))
        text.foregroundColor = UIColor.white.cgColor
        text.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
        text.alignmentMode = .right
        text.contentsScale = UIScreen.main.scale
        let textSize = text.preferredFrameSize()
        text.frame = CGRect(
          x: width - textSize.width - 18,
          y: height - textSize.height - 18,
          width: textSize.width,
          height: textSize.height
        )
        parentLayer.addSublayer(text)
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
          postProcessingAsVideoLayer: videoLayer,
          in: parentLayer
        )

        guard
          let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
          )
        else {
          throw pigeonError("无法创建水印导出会话")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.exportAsynchronously {
          switch session.status {
          case .completed:
            completion(.success(output.path))
          case .failed:
            completion(.failure(session.error ?? pigeonError("水印视频生成失败")))
          default:
            completion(.failure(pigeonError("水印视频生成失败")))
          }
        }
      } catch {
        completion(.failure(error))
      }
    }
  }

  func exportRange(
    request: ExportRequest,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let input = URL(fileURLWithPath: request.inputPath)
      let output = URL(fileURLWithPath: request.outputPath)
      let asset = AVAsset(url: input)
      guard let session = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetHighestQuality
      ) else {
        completion(.failure(pigeonError("无法创建导出会话")))
        return
      }
      session.outputURL = output
      session.outputFileType = .mp4
      session.timeRange = CMTimeRange(
        start: CMTime(value: Int64(request.startMs), timescale: 1000),
        duration: CMTime(
          value: Int64(request.endMs - request.startMs),
          timescale: 1000
        )
      )
      self.exportLock.lock()
      self.activeExportSessions[request.outputPath] = session
      self.exportLock.unlock()
      session.exportAsynchronously {
        defer {
          self.exportLock.lock()
          self.activeExportSessions.removeValue(forKey: request.outputPath)
          self.exportLock.unlock()
        }
        switch session.status {
        case .completed:
          completion(.success(output.path))
        case .failed:
          completion(.failure(session.error ?? pigeonError("分享视频生成失败")))
        default:
          completion(.failure(pigeonError("分享视频生成失败")))
        }
      }
    }
  }

  func exportProgress(completion: @escaping (Result<Int64, Error>) -> Void) {
    exportLock.lock()
    let progress = activeExportSessions.values.map { $0.progress }.max() ?? 1
    exportLock.unlock()
    completion(.success(Int64((progress * 100).rounded())))
  }
}

private final class IosSystemMediaPresenterHostApi: SystemMediaPresenterHostApi {
  func getVideoTrackMime(
    path: String,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    let asset = AVAsset(url: URL(fileURLWithPath: path))
    let videoTracks = asset.tracks(withMediaType: .video)
    guard let formatDescription = videoTracks.first?.formatDescriptions.first else {
      completion(.success(nil))
      return
    }
    let mediaSubType = CMFormatDescriptionGetMediaSubType(
      formatDescription as! CMFormatDescription
    )
    switch mediaSubType {
    case kCMVideoCodecType_HEVC:
      completion(.success("video/hevc"))
    case kCMVideoCodecType_H264:
      completion(.success("video/avc"))
    default:
      completion(.success(nil))
    }
  }

  func getVideoDecodeSupport(
    completion: @escaping (Result<VideoDecodeSupportDto?, Error>) -> Void
  ) {
    let hasHevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    let hasAvc = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
    completion(
      .success(
        VideoDecodeSupportDto(
          manufacturer: "Apple",
          brand: "Apple",
          model: UIDevice.current.model,
          sdkInt: 0,
          release: UIDevice.current.systemVersion,
          hasHevcDecoder: hasHevc,
          hasAvcDecoder: hasAvc,
          forceSoftwareDecode: false
        )
      )
    )
  }

  func openWithSystemPlayer(
    path: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      completion(.failure(pigeonError("录像文件不存在")))
      return
    }
    DispatchQueue.main.async {
      let player = AVPlayer(url: url)
      let controller = AVPlayerViewController()
      controller.player = player
      if let root = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first?
        .windows
        .first(where: { $0.isKeyWindow })?
        .rootViewController
      {
        root.present(controller, animated: true)
      }
      completion(.success(()))
    }
  }
}

private final class IosAlertAudioSessionHostApi: AlertAudioSessionHostApi {
  func beginSession(completion: @escaping (Result<Void, Error>) -> Void) {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playAndRecord,
        mode: .videoRecording,
        options: [.defaultToSpeaker]
      )
      try AVAudioSession.sharedInstance().setActive(true)
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func endSession(completion: @escaping (Result<Void, Error>) -> Void) {
    do {
      try AVAudioSession.sharedInstance().setActive(false)
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func disable(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.failure(pigeonError("当前平台不支持提示音量控制")))
  }

  func boost(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.failure(pigeonError("当前平台不支持提升提示音量")))
  }
}

/// 备份任务的 SQLite 存储：与 Android 端 `backup_jobs` 表保持同一 schema 与字段语义，
/// 替代旧版把全部任务塞进一个 UserDefaults 数组、每次写入全量重写的方式。
private final class IosBackupJobStore {
  private static let legacyDefaultsKey = "ios_backup_jobs"
  private static let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
  )

  private var db: OpaquePointer?
  private let lock = NSLock()

  init() {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let path = directory.appendingPathComponent("lan_backup.db").path
    sqlite3_open(path, &db)
    createSchema()
    migrateLegacyJobsIfNeeded()
  }

  deinit {
    sqlite3_close(db)
  }

  func allJobs() -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    return queryJobsUnlocked()
  }

  func upsert(_ rawJob: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }
    upsertUnlocked(rawJob)
  }

  func updateJob(id: String, mutate: (inout [String: Any]) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    guard var job = readJobUnlocked(id) else { return }
    mutate(&job)
    upsertUnlocked(job)
  }

  func deleteJob(id: String) {
    lock.lock()
    defer { lock.unlock() }
    deleteUnlocked(id)
  }

  private func createSchema() {
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
    sqlite3_exec(db, sql, nil, nil, nil)
  }

  private func migrateLegacyJobsIfNeeded() {
    lock.lock()
    defer { lock.unlock() }
    guard
      let legacy = UserDefaults.standard.array(
        forKey: Self.legacyDefaultsKey
      ) as? [[String: Any]],
      !legacy.isEmpty
    else { return }
    for job in legacy {
      upsertUnlocked(job)
    }
    UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
  }

  private func readJobUnlocked(_ id: String) -> [String: Any]? {
    let sql = "SELECT * FROM backup_jobs WHERE id = ? LIMIT 1"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      return nil
    }
    bindText(stmt, 1, id)
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return jobFromRow(stmt)
  }

  private func queryJobsUnlocked() -> [[String: Any]] {
    let sql = "SELECT * FROM backup_jobs ORDER BY last_modified DESC"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      return []
    }
    defer { sqlite3_finalize(stmt) }
    var jobs: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      jobs.append(jobFromRow(stmt))
    }
    return jobs
  }

  private func upsertUnlocked(_ rawJob: [String: Any]) {
    let job = IosBackupHostApi.migratedJob(rawJob)
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
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      return
    }
    defer { sqlite3_finalize(stmt) }
    let row = jobRow(job)
    bindText(stmt, 1, row["id"] as? String)
    bindText(stmt, 2, row["generation"] as? String)
    bindText(stmt, 3, row["file_path"] as? String)
    bindText(stmt, 4, row["file_name"] as? String)
    bindText(stmt, 5, row["destination_computer_id"] as? String)
    bindText(stmt, 6, row["state"] as? String)
    bindInt(stmt, 7, (row["uploaded_bytes"] as? NSNumber)?.int64Value ?? 0)
    bindInt(stmt, 8, (row["total_bytes"] as? NSNumber)?.int64Value ?? 0)
    bindInt(stmt, 9, (row["last_modified"] as? NSNumber)?.int64Value ?? 0)
    bindText(stmt, 10, row["file_created_at"] as? String)
    bindText(stmt, 11, row["backup_completed_at"] as? String)
    bindText(stmt, 12, row["scheduled_cleanup_at"] as? String)
    bindText(stmt, 13, row["local_deleted_at"] as? String)
    bindInt(stmt, 14, ((row["waiting_cleanup"] as? Bool) ?? false) ? 1 : 0)
    bindText(stmt, 15, row["remote_record_ids"] as? String)
    bindText(stmt, 16, row["content_sha256"] as? String)
    bindInt(stmt, 17, Int64((row["verification_version"] as? NSNumber)?.intValue ?? 0))
    bindText(stmt, 18, row["verification_receipt"] as? String)
    bindText(stmt, 19, row["last_attested_at"] as? String)
    bindText(stmt, 20, row["cleanup_reason"] as? String)
    bindText(stmt, 21, row["error_message"] as? String)
    bindText(stmt, 22, row["failure_kind"] as? String)
    bindText(stmt, 23, row["sessions"] as? String)
    sqlite3_step(stmt)
  }

  private func deleteUnlocked(_ id: String) {
    let sql = "DELETE FROM backup_jobs WHERE id = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      return
    }
    bindText(stmt, 1, id)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
  }

  private func jobRow(_ job: [String: Any]) -> [String: Any?] {
    [
      "id": job["id"] as? String ?? "",
      "generation": job["generation"] as? String ?? "",
      "file_path": job["filePath"] as? String ?? "",
      "file_name": job["fileName"] as? String,
      "destination_computer_id": job["destinationComputerId"] as? String,
      "state": job["state"] as? String ?? "",
      "uploaded_bytes": (job["uploadedBytes"] as? NSNumber)?.int64Value ?? 0,
      "total_bytes": (job["totalBytes"] as? NSNumber)?.int64Value ?? 0,
      "last_modified": (job["lastModified"] as? NSNumber)?.int64Value ?? 0,
      "file_created_at": job["fileCreatedAt"] as? String,
      "backup_completed_at": job["backupCompletedAt"] as? String,
      "scheduled_cleanup_at": job["scheduledCleanupAt"] as? String,
      "local_deleted_at": job["localDeletedAt"] as? String,
      "waiting_cleanup": (job["waitingCleanup"] as? Bool) ?? false,
      "remote_record_ids": Self.jsonText(job["remoteRecordIds"]),
      "content_sha256": job["contentSha256"] as? String,
      "verification_version": (job["verificationVersion"] as? NSNumber)?.intValue ?? 0,
      "verification_receipt": Self.jsonText(job["verificationReceipt"]),
      "last_attested_at": job["lastAttestedAt"] as? String,
      "cleanup_reason": job["cleanupReason"] as? String,
      "error_message": job["errorMessage"] as? String,
      "failure_kind": job["failureKind"] as? String,
      "sessions": Self.jsonText(job["sessions"]),
    ]
  }

  private func jobFromRow(_ stmt: OpaquePointer?) -> [String: Any] {
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
    job["remoteRecordIds"] = Self.jsonArray(text(stmt, 14))
    job["contentSha256"] = text(stmt, 15)
    job["verificationVersion"] = Int(integer(stmt, 16))
    job["verificationReceipt"] = Self.jsonObject(text(stmt, 17))
    job["lastAttestedAt"] = text(stmt, 18)
    job["cleanupReason"] = text(stmt, 19)
    job["errorMessage"] = text(stmt, 20)
    job["failureKind"] = text(stmt, 21)
    job["sessions"] = Self.jsonArray(text(stmt, 22))
    return job
  }

  private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: value)
  }

  private func integer(_ stmt: OpaquePointer?, _ index: Int32) -> Int64 {
    sqlite3_column_int64(stmt, index)
  }

  private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
    guard let stmt else { return }
    if let value {
      sqlite3_bind_text(stmt, index, value, -1, Self.sqliteTransient)
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }

  private func bindInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64) {
    guard let stmt else { return }
    sqlite3_bind_int64(stmt, index, value)
  }

  private static func jsonText(_ value: Any?) -> String? {
    guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
    return (try? JSONSerialization.data(withJSONObject: value))
      .flatMap { String(data: $0, encoding: .utf8) }
  }

  private static func jsonArray(_ value: String?) -> [Any] {
    guard let value,
          let data = value.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
    else {
      return []
    }
    return array
  }

  private static func jsonObject(_ value: String?) -> [String: Any]? {
    guard let value,
          let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return object
  }
}

private final class IosBackupHostApi: BackupNativeHostApi {
  private let defaults = UserDefaults.standard
  private let jobStore = IosBackupJobStore()
  private let eventApi: BackupNativeEventApi
  private let networkMonitor = NWPathMonitor()
  private let networkQueue = DispatchQueue(label: "ios.backup.network")
  private var lastLanReachable = false
  private let uploadsLock = NSLock()
  private var activeUploads: [String: Task<Void, Never>] = [:]
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
    accessKey: "ios_backup_access_key",
    jobs: "ios_backup_jobs",
    retention: "ios_backup_retention"
  )

  private static let verificationVersion = 3
  private static let retentionConfirmationGrace: TimeInterval = 24 * 60 * 60
  private static let storageAttestationFreshness: TimeInterval = 5 * 60
  private static let cleanupThrottle: TimeInterval = 60
  private static let isoFormatter = ISO8601DateFormatter()

  private enum AttestationResult {
    case confirmed
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

  init(eventApi: BackupNativeEventApi) {
    self.eventApi = eventApi
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
    completion(.success(currentSnapshot()))
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
    completion(.success(currentSnapshot()))
  }

  func loadAccessKey(completion: @escaping (Result<String?, Error>) -> Void) {
    completion(.success(defaults.string(forKey: keys.accessKey)))
  }

  func isWifiConnected(completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.success(lastLanReachable))
  }

  func saveConnection(
    connection: [String?: Any?],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    defaults.set(normalized(connection), forKey: keys.connection)
    defaults.set(connection["accessKey"] as? String, forKey: keys.accessKey)
    defaults.set(connection["deviceName"] as? String, forKey: keys.deviceName)
    emitSnapshot()
    completion(.success(()))
  }

  func disconnect(completion: @escaping (Result<Void, Error>) -> Void) {
    defaults.removeObject(forKey: keys.connection)
    defaults.removeObject(forKey: keys.accessKey)
    emitSnapshot()
    completion(.success(()))
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
    job["state"] = "pending"
    job["uploadedBytes"] = 0
    job["totalBytes"] = fileSize
    job.removeValue(forKey: "errorMessage")
    job.removeValue(forKey: "failureKind")
    upsert(job)
    startUpload(job)
    emitSnapshot()
    completion(.success(()))
  }

  func requeueJob(
    jobId: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    uploadsLock.lock()
    activeUploads[jobId]?.cancel()
    activeUploads.removeValue(forKey: jobId)
    uploadsLock.unlock()
    updateJob(jobId) { job in
      job["state"] = "pending"
      job.removeValue(forKey: "errorMessage")
      job.removeValue(forKey: "failureKind")
    }
    if let job = jobs().first(where: { $0["id"] as? String == jobId }) {
      startUpload(job)
    }
    emitSnapshot()
    completion(.success(()))
  }

  func cancelJob(
    jobId: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    uploadsLock.lock()
    activeUploads[jobId]?.cancel()
    activeUploads.removeValue(forKey: jobId)
    uploadsLock.unlock()
    updateJob(jobId) { job in
      job["state"] = "paused"
    }
    emitSnapshot()
    completion(.success(()))
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
    let minimumBytes: Int64 = 2 * 1024 * 1024 * 1024
    let targetBytes: Int64 = 3 * 1024 * 1024 * 1024
    let before = availableStorageBytes()
    var current = before
    var deletedCount = 0
    var freedBytes: Int64 = 0
    if current < minimumBytes {
      let recordingsRoot = recordingsDirectory().path + "/"
      for var job in jobs() where current < targetBytes {
        guard
          job["state"] as? String == "completed",
          (job["verificationVersion"] as? Int ?? 0) >= Self.verificationVersion,
          let remoteIds = job["remoteRecordIds"] as? [Any], !remoteIds.isEmpty,
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
            upsert(job)
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
          upsert(job)
        } catch {
          job["errorMessage"] = "空间清理失败，已保留本机录像"
          upsert(job)
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
  }

  private func recordingsDirectory() -> URL {
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

  private func currentSnapshot() -> [String?: Any?] {
    [
      "deviceId": deviceId(),
      "deviceName": deviceName(),
      "connection": defaults.dictionary(forKey: keys.connection),
      "jobs": jobs().map(slimJob),
    ]
  }

  /// 快照瘦身：只下发 Dart 实际消费的字段，避免 sessions 等大字段随每次推送跨通道传输。
  private func slimJob(_ job: [String: Any]) -> [String: Any] {
    var slim: [String: Any] = [:]
    for key in [
      "id", "filePath", "state", "uploadedBytes", "totalBytes", "lastModified",
      "contentSha256", "errorMessage", "failureKind", "fileCreatedAt",
      "backupCompletedAt", "scheduledCleanupAt", "localDeletedAt", "waitingCleanup",
      "remoteRecordIds", "destinationComputerId", "cleanupReason",
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
  fileprivate static func migratedJob(_ job: [String: Any]) -> [String: Any] {
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
    return result
  }

  private func jobs() -> [[String: Any]] {
    jobStore.allJobs()
  }

  private func upsert(_ job: [String: Any]) {
    jobStore.upsert(job)
  }

  private func updateJob(_ id: String, mutate: (inout [String: Any]) -> Void) {
    jobStore.updateJob(id: id, mutate: mutate)
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
      self.eventApi.snapshotChanged(snapshot: self.currentSnapshot()) { _ in }
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
    guard let jobId = job["id"] as? String else { return }
    uploadsLock.lock()
    activeUploads[jobId]?.cancel()
    let previous = uploadTail
    let task = Task.detached { [weak self] in
      await previous.value
      guard let self, !Task.isCancelled else { return }
      await self.upload(job: job)
    }
    activeUploads[jobId] = task
    uploadTail = task
    uploadsLock.unlock()
  }

  private func upload(job: [String: Any]) async {
    guard
      let connection = defaults.dictionary(forKey: keys.connection),
      let storedBaseUrl = connection["baseUrl"] as? String,
      let accessKey = defaults.string(forKey: keys.accessKey),
      let path = job["filePath"] as? String,
      let jobId = job["id"] as? String
    else {
      return
    }
    var baseUrl = storedBaseUrl
    defer {
      uploadsLock.lock()
      activeUploads.removeValue(forKey: jobId)
      uploadsLock.unlock()
    }
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else { return }
    let fileSha256 = SHA256.hash(data: data).map {
      String(format: "%02x", $0)
    }.joined()

    do {
      let createBody: [String: Any] = [
        "fileSha256": fileSha256,
        "totalBytes": data.count,
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
      var offset = min(max(rawOffset.intValue, 0), data.count)
      let uploadIdEncoded = uploadId.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed
      ) ?? uploadId
      while offset < data.count {
        try Task.checkCancellation()
        let end = min(offset + chunkSize, data.count)
        let chunk = data.subdata(in: offset..<end)
        let chunkPath = "/api/mobile-backup/uploads/\(uploadIdEncoded)/chunks"
        let result: [String: Any]
        do {
          result = try await uploadChunk(
            baseUrl: baseUrl,
            path: chunkPath,
            chunk: chunk,
            offset: offset,
            total: data.count,
            accessKey: accessKey,
            deviceId: deviceId()
          )
        } catch {
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
            total: data.count,
            accessKey: accessKey,
            deviceId: deviceId()
          )
        }
        guard let next = result["offset"] as? NSNumber else {
          throw pigeonError("电脑返回的上传进度无效")
        }
        offset = next.intValue
        updateJob(jobId) { current in
          current["state"] = "uploading"
          current["uploadedBytes"] = offset
        }
        emitSnapshot()
      }

      try Task.checkCancellation()
      let completePath = "/api/mobile-backup/uploads/\(uploadIdEncoded)/complete"
      let completeBody: [String: Any] = [
        "fileSha256": fileSha256,
        "sourceDeviceId": deviceId(),
        "sourceDeviceName": deviceName(),
        "sessions": Self.backupCompletionSessions(
          job["sessions"] as? [Any] ?? []
        ),
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
      guard complete["status"] as? String == "verified" else {
        throw BackupTransferError(
          statusCode: 0,
          errorCode: "verification_failed",
          message: "电脑未确认录像校验结果",
          failureKind: "verification_failed"
        )
      }
      let verificationVersion =
        (complete["authVersion"] as? NSNumber)?.intValue ?? 0
      let completedAt = Self.isoFormatter.string(from: Date())
      updateJob(jobId) { current in
        current["state"] = "completed"
        current["uploadedBytes"] = data.count
        current["contentSha256"] = fileSha256
        current["remoteRecordIds"] = complete["recordIds"] as? [Any] ?? []
        current["backupCompletedAt"] = completedAt
        current["verificationVersion"] = verificationVersion
        if verificationVersion > 0 {
          current["lastAttestedAt"] = completedAt
        }
      }
      emitSnapshot()
      triggerCleanup()
    } catch {
      let failure = Self.backupFailureInfo(error)
      updateJob(jobId) { current in
        current["state"] = "paused"
        current["errorMessage"] = failure.message
        current["failureKind"] = failure.failureKind
        current["statusCode"] = failure.statusCode
        current["errorCode"] = failure.errorCode
      }
      emitSnapshot()
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
    offset: Int,
    total: Int,
    accessKey: String,
    deviceId: String
  ) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: baseUrl + path)!)
    request.httpMethod = "PUT"
    request.httpBody = chunk
    request.setValue(
      "bytes \(offset)-\(offset + chunk.count - 1)/\(total)",
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

  private static func backupCompletionSessions(_ rawSessions: [Any]) -> [Any] {
    rawSessions.compactMap { value in
      guard let source = value as? [String: Any] else { return nil }
      let mediaEnd = Self.int64Value(source["mediaEndMs"])
      let mediaStart = Self.int64Value(source["mediaStartMs"])
      let startedAt = source["startedAt"] as? String ?? ""
      let endedAt = source["endedAt"] as? String ?? ""

      var duration = mediaEnd - mediaStart
      if duration <= 0 {
        duration = Self.durationBetween(startedAt: startedAt, endedAt: endedAt)
      }
      if duration <= 0 {
        duration = 1
      }

      var completed: [String: Any] = [
        "sessionId": source["id"] as? String ?? "",
        "trackingNumber": source["trackingNumber"] as? String ?? "",
        "startedAt": startedAt,
        "durationMilliseconds": duration,
        "mode": source["mode"] as? String ?? "shipping",
      ]
      if let orderInfo = source["orderInfo"] as? [String: Any] {
        completed["orderInfo"] = orderInfo
      }
      return completed
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

  private static func durationBetween(
    startedAt: String,
    endedAt: String
  ) -> Int64 {
    guard
      let start = Self.parseIso8601(startedAt),
      let end = Self.parseIso8601(endedAt)
    else {
      return 0
    }
    let milliseconds = end.timeIntervalSince(start) * 1000
    return Int64(max(0, milliseconds))
  }

  private static func parseIso8601(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) {
      return date
    }
    let withoutFraction = value.split(separator: ".").first.map(String.init) ?? value
    return formatter.date(from: withoutFraction)
  }

  private static func backupTransferError(
    statusCode: Int,
    data: Data,
    fallbackMessage: String
  ) -> BackupTransferError {
    let text = String(data: data, encoding: .utf8) ?? ""
    var errorCode = ""
    var message = ""
    if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      errorCode = object["errorCode"] as? String ?? ""
      message = object["error"] as? String ?? ""
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
      failureKind: failureKind
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

  private func secretData(_ value: String) -> Data {
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

  // MARK: - 保留策略清理

  private func readJobById(_ id: String) -> [String: Any]? {
    jobs().first(where: { $0["id"] as? String == id })
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
      await self.performCleanup()
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

  private func performCleanup() async {
    let root = recordingsDirectory().path + "/"
    let now = Date()
    var changed = false

    for job in jobs() {
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
      var unconfirmedCleanup = false
      var baseJob = job

      if completedAt != nil {
        let contentSha256 = job["contentSha256"] as? String
        let version = job["verificationVersion"] as? Int ?? 0
        let recordIds = job["remoteRecordIds"] as? [Any]
        let sessions = job["sessions"] as? [Any]
        let totalBytes = job["totalBytes"] as? Int64 ?? -1
        let hasEvidence =
          version >= Self.verificationVersion &&
          contentSha256?.count == 64 &&
          totalBytes > 0 &&
          !(recordIds?.isEmpty ?? true) &&
          !(sessions?.isEmpty ?? true)

        if !hasEvidence {
          baseJob["waitingCleanup"] = false
          baseJob["errorMessage"] = "备份记录缺少安全校验信息，需重新备份后才能自动清理"
          upsert(baseJob)
          changed = true
          continue
        }

        let attestation: AttestationResult
        if isConfirmationFresh(job["lastAttestedAt"] as? String, now: now) {
          attestation = .confirmed
        } else {
          attestation = await attestBackedJob(
            job,
            contentSha256: contentSha256 ?? "",
            totalBytes: totalBytes
          )
        }

        // 远端确认期间任务可能被重新上传，重新读取并校验代次后再落地。
        guard
          let current = readJobById(id),
          (current["generation"] as? String) == (job["generation"] as? String),
          (current["backupCompletedAt"] as? String) == completedAt,
          current["localDeletedAt"] as? String == nil
        else { continue }
        baseJob = current

        switch attestation {
        case .confirmed:
          baseJob["lastAttestedAt"] = Self.isoFormatter.string(from: now)
        case .missing:
          baseJob["waitingCleanup"] = false
          baseJob["errorMessage"] = "远端缺失，待重新备份"
          upsert(baseJob)
          changed = true
          continue
        case .unauthorized:
          baseJob["waitingCleanup"] = false
          baseJob["errorMessage"] = "需要重新扫码授权"
          upsert(baseJob)
          changed = true
          continue
        case .notReady:
          baseJob["waitingCleanup"] = true
          baseJob["errorMessage"] = "电脑端尚未完成校验"
          upsert(baseJob)
          changed = true
          continue
        case .unreachable:
          unconfirmedCleanup = true
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
        upsert(baseJob)
        changed = true
        continue
      case .failed:
        baseJob["waitingCleanup"] = true
        upsert(baseJob)
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
      } else if unconfirmedCleanup {
        baseJob["cleanupReason"] = "已备份未确认清理（电脑离线）"
      } else {
        baseJob["cleanupReason"] = "已备份录像保留策略清理"
      }
      upsert(baseJob)
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
      let accessKey = defaults.string(forKey: keys.accessKey),
      let recordIds = job["remoteRecordIds"] as? [Any],
      let recordId = recordIds.first as? NSNumber,
      let sessions = job["sessions"] as? [Any],
      let session = sessions.first as? [String: Any],
      let sessionId = session["id"] as? String
    else {
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
        return verifyAttestationReceipt(
          json,
          accessKey: accessKey,
          deviceId: deviceId,
          computerId: computerId,
          sessionId: sessionId,
          fileSha256: fileSha256,
          fileSizeBytes: fileSizeBytes,
          recordId: recordId
        ) ? .confirmed : .notReady
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
    guard (response["authVersion"] as? Int) == Self.verificationVersion else {
      return false
    }
    let verifiedAt = response["verifiedAtUnixSeconds"] as? Int64 ?? 0
    let now = Int64(Date().timeIntervalSince1970)
    guard abs(now - verifiedAt) <= 300 else { return false }
    guard
      let hostNodeId = response["hostNodeId"] as? String,
      let sourceDeviceId = response["sourceDeviceId"] as? String,
      let sourceSessionId = response["sourceSessionId"] as? String,
      let responseSha256 = response["fileSha256"] as? String,
      let responseFileSize = response["fileSizeBytes"] as? Int64,
      let responseRecordId = response["recordId"] as? Int64,
      let receiptSignature = response["receiptSignature"] as? String
    else { return false }
    guard
      hostNodeId.lowercased() == computerId.lowercased(),
      sourceDeviceId.lowercased() == deviceId.lowercased(),
      sourceSessionId == sessionId,
      responseSha256.lowercased() == fileSha256.lowercased(),
      responseFileSize == fileSizeBytes,
      responseRecordId == recordId
    else { return false }
    let canonical = [
      "packingproof-verified-receipt-v3",
      hostNodeId.trimmingCharacters(in: .whitespaces).lowercased(),
      sourceDeviceId.trimmingCharacters(in: .whitespaces).lowercased(),
      sourceSessionId.trimmingCharacters(in: .whitespaces),
      fileSha256.trimmingCharacters(in: .whitespaces).lowercased(),
      String(fileSizeBytes),
      String(recordId),
      String(verifiedAt),
    ].joined(separator: "\n")
    let expected = hmacHex(key: secretData(accessKey), message: canonical)
    return constantTimeEquals(expected, receiptSignature)
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

/// iOS 连续相机原生实现：
/// 保持一个 `AVCaptureSession` 常开，用 `AVAssetWriter` 按单号轮换输出文件，
/// 不重启预览，达到接近 Android 连续录像的体验。
private final class IosCameraHostApi:
  NSObject,
  CameraHostApi,
  FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate,
  AVCaptureMetadataOutputObjectsDelegate
{
  private let eventApi: CameraEventApi
  private let textures: FlutterTextureRegistry
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "packingproof.camera.session")
  private let metadataQueue = DispatchQueue(label: "packingproof.camera.metadata")
  private let bufferLock = NSLock()
  private let stateLock = NSLock()

  private var textureId: Int64 = -1
  private var latestPixelBuffer: CVPixelBuffer?
  private var videoDeviceInput: AVCaptureDeviceInput?
  private var audioDeviceInput: AVCaptureDeviceInput?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var audioOutput: AVCaptureAudioDataOutput?
  private var metadataOutput: AVCaptureMetadataOutput?

  private var recordingSpecName = "hd1080p30"
  private var preferredVideoCodec = "hevc"
  private var recordAudio = true
  private var pairingScanEnabled = false
  private var workScanEnabled = false
  private var previewActive = true
  private var disposed = false
  private var recoveryRuntimeError = false
  private var runtimeErrorObserver: NSObjectProtocol?

  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var currentPath: String?
  private var currentSegmentId = ""
  private var currentStartedAtMs: Int64 = 0
  private var currentSegmentSerial: Int64 = 0
  private var writerSessionStarted = false
  private var sessionId = UUID().uuidString
  private var recordingAudioActive = false
  private var currentAudioSampleCount: Int64 = 0
  private var currentAudioAppendFailedCount: Int64 = 0
  private var currentAudioLastError: String?
  private var splitPending = false
  private var lastAudioSampleCount: Int64 = 0
  private var lastAudioAppendFailedCount: Int64 = 0
  private var lastAudioLastError: String?
  private var lastCompletedSegmentSerial: Int64 = -1
  private var lastSegmentWriterStatus: String?
  private var lastSegmentWriterError: String?
  private var lastSegmentAudioTrackCheckSucceeded: Bool?
  private var lastSegmentAudioTrackCount: Int64?
  private var lastSegmentAudioTrackPresent: Bool?
  private var lastSegmentAudioTrackInspectionError: String?

  /// 固定 sessionPreset .hd1920x1080，竖屏预览与录像输出 1080x1920。
  private var portraitSize: (width: Int, height: Int) { (1080, 1920) }

  init(eventApi: CameraEventApi, textures: FlutterTextureRegistry) {
    self.eventApi = eventApi
    self.textures = textures
    super.init()
    updateTextureId(textures.register(self))
    runtimeErrorObserver = NotificationCenter.default.addObserver(
      forName: .AVCaptureSessionRuntimeError,
      object: session,
      queue: .main
    ) { [weak self] _ in
      self?.recoveryRuntimeError = true
    }
    configureSession()
  }

  deinit {
    markDisposed()
    clearOutputDelegates()
    let session = self.session
    sessionQueue.async {
      if session.isRunning {
        session.stopRunning()
      }
    }
    if let observer = runtimeErrorObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    runtimeErrorObserver = nil
    // 不在此处触碰 textures：引擎销毁阶段调用 FlutterTextureRegistry 会 SIGSEGV。
  }

  // MARK: - CameraHostApi

  func initialize(
    request: CameraInitializeRequest,
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    preferredVideoCodec = request.videoCodec
    recordingSpecName = request.recordingSpec
    sessionQueue.async { [weak self] in
      guard let self else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      self.configureRecordingAudioSession()
      do {
        try self.addAudioInputIfNeeded()
      } catch {
        completion(.failure(error))
        return
      }
      if self.isDisposed {
        self.recoverCamera { recovered in
          if recovered {
            self.markNotDisposed()
            self.finishInitialize(completion)
          } else {
            completion(.failure(pigeonError("摄像头恢复失败")))
          }
        }
      } else {
        if !self.session.isRunning {
          self.session.startRunning()
        }
        self.finishInitialize(completion)
      }
    }
  }

  func ensurePermissions(
    recordAudio: Bool,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    self.recordAudio = recordAudio
    requestVideoAndAudioPermissions(recordAudio: recordAudio) { granted in
      completion(.success(granted))
    }
  }

  func startWork(
    path: String,
    recordAudio: Bool,
    completion: @escaping (Result<CameraRecordingStartDto, Error>) -> Void
  ) {
    self.recordAudio = recordAudio
    sessionQueue.async { [weak self] in
      guard let self, !self.isDisposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      do {
        try self.ensureRunningForWork()
        try self.startWriter(path: path)
        let startedAt = self.currentStartedAtMs
        self.eventApi.segmentStarted(
          event: CameraSegmentStartedDto(
            sessionId: self.sessionId,
            segmentId: self.currentSegmentId,
            startedAtMs: startedAt
          ),
          completion: { _ in }
        )
        completion(.success(CameraRecordingStartDto(
          path: path,
          startedAtMs: startedAt
        )))
      } catch {
        completion(.failure(error))
      }
    }
  }

  func split(
    nextPath: String,
    completion: @escaping (Result<CameraRecordingSplitDto, Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self, !self.isDisposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      guard !self.splitPending else {
        completion(.failure(pigeonError("上一段录像正在保存")))
        return
      }
      guard self.currentPath != nil else {
        completion(.failure(pigeonError("当前没有正在录制的视频")))
        return
      }
      self.splitPending = true
      let completedPath = self.currentPath ?? ""
      let completedStartedAt = self.currentStartedAtMs
      let boundaryAt = Int64(Date().timeIntervalSince1970 * 1000)
      self.finishCurrentWriter { [weak self] in
        guard let self else {
          completion(.failure(pigeonError("摄像头已经关闭")))
          return
        }
        self.sessionQueue.async {
          do {
            try self.startWriter(path: nextPath)
            self.splitPending = false
            completion(.success(CameraRecordingSplitDto(
              completedPath: completedPath,
              nextPath: nextPath,
              completedStartedAtMs: completedStartedAt,
              boundaryAtMs: boundaryAt
            )))
          } catch {
            self.splitPending = false
            self.eventApi.nativeError(
              message: "切换录像文件失败：\(error.localizedDescription)",
              completion: { _ in }
            )
            completion(.failure(error))
          }
        }
      }
    }
  }

  func stopWork(
    completion: @escaping (Result<CameraRecordingStopDto, Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self, !self.isDisposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      if self.splitPending {
        completion(.failure(pigeonError("请等待当前分段保存完成")))
        return
      }
      let path = self.currentPath ?? ""
      let startedAt = self.currentStartedAtMs
      let endedAt = Int64(Date().timeIntervalSince1970 * 1000)
      self.finishCurrentWriter {
        completion(.success(CameraRecordingStopDto(
          path: path,
          startedAtMs: startedAt,
          endedAtMs: endedAt
        )))
      }
    }
  }

  func getDiagnostics(
    completion: @escaping (Result<[String?: Any?]?, Error>) -> Void
  ) {
    let device = videoDeviceInput?.device
    let size = portraitSize
    let usesHevc = preferredVideoCodec.lowercased() == "hevc"
    let scanState = metadataQueue.sync { (pairingScanEnabled, workScanEnabled) }
    let audioSession = AVAudioSession.sharedInstance()
    let audioOptions = audioSession.categoryOptions
    let audioOptionNames = Self.audioSessionCategoryOptionNames(audioOptions)
    let lastSegment = lastSegmentDiagnosticsSnapshot()
    completion(.success([
      "device": [
        "manufacturer": "Apple",
        "model": UIDevice.current.model,
        "sdkInt": 0,
        "release": UIDevice.current.systemVersion,
      ],
      "camera": [
        "initialized": true,
        "sessionRunning": session.isRunning,
        "previewActive": previewActive,
        "disposed": isDisposed,
        "workScanEnabled": scanState.1,
        "pairingScanEnabled": scanState.0,
        "metadataOutputAttached": metadataOutput != nil,
        "videoOutputAttached": videoOutput != nil,
        "audioOutputAttached": audioOutput != nil,
        "recordingAudioActive": recordingAudioActive,
        "currentAudioSampleCount": currentAudioSampleCount,
        "currentAudioAppendFailedCount": currentAudioAppendFailedCount,
        "currentAudioLastError": currentAudioLastError,
        "lastAudioSampleCount": lastAudioSampleCount,
        "lastAudioAppendFailedCount": lastAudioAppendFailedCount,
        "lastAudioLastError": lastAudioLastError,
        "audioSessionCategory": audioSession.category.rawValue,
        "audioSessionMode": audioSession.mode.rawValue,
        "audioSessionCategoryOptions": audioOptionNames,
        "audioSessionCategoryOptionsRawValue": Int64(audioOptions.rawValue),
        "lastSegmentWriterStatus": lastSegment.writerStatus,
        "lastSegmentWriterError": lastSegment.writerError,
        "lastSegmentAudioTrackCheckSucceeded": lastSegment.trackCheckSucceeded,
        "lastSegmentAudioTrackCount": lastSegment.trackCount,
        "lastSegmentAudioTrackPresent": lastSegment.trackPresent,
        "lastSegmentAudioTrackInspectionError": lastSegment.trackInspectionError,
        "cameraPipelineVersion": 1,
        "recordingSpec": recordingSpecName,
        "cameraId": device?.uniqueID ?? "",
        "videoWidth": size.width,
        "videoHeight": size.height,
        "analysisWidth": size.width,
        "analysisHeight": size.height,
        "videoMime": usesHevc ? "video/hevc" : "video/avc",
      ],
    ]))
  }

  private static func audioSessionCategoryOptionNames(
    _ options: AVAudioSession.CategoryOptions
  ) -> [String] {
    var names: [String] = []
    if options.contains(.mixWithOthers) {
      names.append("mixWithOthers")
    }
    if options.contains(.duckOthers) {
      names.append("duckOthers")
    }
    if options.contains(.interruptSpokenAudioAndMixWithOthers) {
      names.append("interruptSpokenAudioAndMixWithOthers")
    }
    if options.contains(.allowBluetooth) {
      names.append("allowBluetooth")
    }
    if options.contains(.allowBluetoothA2DP) {
      names.append("allowBluetoothA2DP")
    }
    if options.contains(.allowAirPlay) {
      names.append("allowAirPlay")
    }
    if options.contains(.defaultToSpeaker) {
      names.append("defaultToSpeaker")
    }
    if options.contains(.overrideMutedMicrophoneInterruption) {
      names.append("overrideMutedMicrophoneInterruption")
    }
    return names
  }

  private func lastSegmentDiagnosticsSnapshot() -> (
    writerStatus: String?,
    writerError: String?,
    trackCheckSucceeded: Bool?,
    trackCount: Int64?,
    trackPresent: Bool?,
    trackInspectionError: String?
  ) {
    stateLock.lock()
    defer { stateLock.unlock() }
    return (
      lastSegmentWriterStatus,
      lastSegmentWriterError,
      lastSegmentAudioTrackCheckSucceeded,
      lastSegmentAudioTrackCount,
      lastSegmentAudioTrackPresent,
      lastSegmentAudioTrackInspectionError
    )
  }

  func setPairingScanEnabled(
    enabled: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    metadataQueue.async { [weak self] in
      guard let self else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      self.pairingScanEnabled = enabled
      completion(.success(()))
    }
  }

  func setWorkScanEnabled(
    enabled: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    metadataQueue.async { [weak self] in
      guard let self else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      self.workScanEnabled = enabled
      completion(.success(()))
    }
  }

  func setPreviewActive(
    active: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self, !self.isDisposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      guard self.currentPath == nil else {
        completion(.failure(pigeonError(
          "录像期间不能暂停摄像头",
          code: "camera_busy"
        )))
        return
      }
      self.previewActive = active
      if active {
        self.configureOutputDelegates()
        if !self.session.isRunning {
          self.session.startRunning()
        }
        guard self.session.isRunning else {
          completion(.failure(pigeonError(
            "摄像头恢复失败",
            code: "preview_resume_failed"
          )))
          return
        }
      } else if self.session.isRunning {
        self.session.stopRunning()
      }
      completion(.success(()))
    }
  }

  func setTorchEnabled(
    enabled: Bool,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self, let device = self.videoDeviceInput?.device, device.hasTorch else {
        completion(.success(false))
        return
      }
      do {
        try device.lockForConfiguration()
        device.torchMode = enabled ? .on : .off
        device.unlockForConfiguration()
        completion(.success(true))
      } catch {
        completion(.success(false))
      }
    }
  }

  func switchCamera(
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    let targetPosition: AVCaptureDevice.Position =
      videoDeviceInput?.device.position == .back ? .front : .back
    switchToPosition(targetPosition, completion: completion)
  }

  func listCameras(
    completion: @escaping (Result<[CameraLensDto], Error>) -> Void
  ) {
    completion(.success(backCameraLenses()))
  }

  func switchToCamera(
    cameraId: String,
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    guard let device = AVCaptureDevice(uniqueID: cameraId) else {
      completion(.failure(pigeonError("找不到指定的摄像头")))
      return
    }
    replaceVideoDevice(device, completion: completion)
  }

  func probeSequence(
    sequence: String,
    budgetMs: Int64,
    completion: @escaping (Result<[String?: Any?]?, Error>) -> Void
  ) {
    // iOS 首版先返回空探针，由 Dart 策略保留为 unverified，
    // 不阻塞真实预览与录像；后续再补齐 AVFoundation 能力探测。
    completion(.success(nil))
  }

  func setCapabilityMode(mode: String) throws {
    // 当前 iOS 实现不切换 Android 那种三档能力模式。
  }

  func dispose(completion: @escaping (Result<Void, Error>) -> Void) {
    markDisposed()
    // 先移除采样回调，避免 App 终止时 AVCaptureSession 再回调到已释放的
    // self，触发 use-after-free（SIGSEGV）。
    clearOutputDelegates()
    sessionQueue.async { [weak self] in
      guard let self else {
        completion(.success(()))
        return
      }
      self.finishCurrentWriter {}
      if self.session.isRunning {
        self.session.stopRunning()
      }
      let textureId = self.currentTextureId
      if textureId >= 0 {
        self.textures.unregisterTexture(textureId)
        self.updateTextureId(-1)
      }
      completion(.success(()))
    }
  }

  /// 终止前同步停止相机并解除纹理注册，保证之后 Flutter 引擎可安全销毁。
  func prepareForTermination() {
    markDisposed()
    clearOutputDelegates()
    if let observer = runtimeErrorObserver {
      NotificationCenter.default.removeObserver(observer)
      runtimeErrorObserver = nil
    }
    sessionQueue.sync { [weak self] in
      guard let self else { return }
      self.finishCurrentWriter(false) {}
      if self.session.isRunning {
        self.session.stopRunning()
      }
      let textureId = self.currentTextureId
      if textureId >= 0 {
        self.textures.unregisterTexture(textureId)
        self.updateTextureId(-1)
      }
    }
    metadataQueue.sync {}
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    guard let latestPixelBuffer else { return nil }
    return Unmanaged.passRetained(latestPixelBuffer)
  }

  // MARK: - AVCapture delegates

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !isDisposed else { return }
    if output === videoOutput {
      guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        return
      }
      bufferLock.lock()
      latestPixelBuffer = pixelBuffer
      bufferLock.unlock()
      let textureId = currentTextureId
      if textureId >= 0 && !isDisposed {
        textures.textureFrameAvailable(textureId)
      }
      appendVideo(sampleBuffer, pixelBuffer: pixelBuffer)
    } else if output === audioOutput {
      appendAudio(sampleBuffer)
    }
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard !isDisposed else { return }
    guard pairingScanEnabled || workScanEnabled else { return }
    let detectedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    var candidates: [BarcodeCandidateDto] = []
    for object in metadataObjects {
      guard let machineReadable = object as? AVMetadataMachineReadableCodeObject,
            let value = machineReadable.stringValue else {
        continue
      }
      let bounds = machineReadable.bounds
      let area = Int64(max(1, Int(bounds.width * bounds.height * 1_000_000)))
      candidates.append(BarcodeCandidateDto(
        value: value,
        area: area,
        format: metadataTypeName(machineReadable.type),
        detectedAtMs: detectedAtMs
      ))
    }
    if !candidates.isEmpty {
      eventApi.barcodeBatch(candidates: candidates, completion: { _ in })
    }
  }

  // MARK: - Session configuration

  private func configureSession() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.session.beginConfiguration()
      self.session.sessionPreset = .hd1920x1080

      if let videoDevice = Self.defaultVideoDevice(position: .back) {
        do {
          let input = try AVCaptureDeviceInput(device: videoDevice)
          if self.session.canAddInput(input) {
            self.session.addInput(input)
            self.videoDeviceInput = input
          }
        } catch {
          self.eventApi.nativeError(
            message: "打开摄像头失败：\(error.localizedDescription)",
            completion: { _ in }
          )
        }
      }

      let videoOutput = AVCaptureVideoDataOutput()
      // 保持系统缺省的丢弃迟到帧语义，避免视频帧在串行 sessionQueue 上堆积，
      // 进而把 metadata 回调（扫码）长时间排挤掉，导致「偶尔能扫上、大部分扫不上」。
      videoOutput.alwaysDiscardsLateVideoFrames = true
      videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      if self.session.canAddOutput(videoOutput) {
        self.session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video) {
          connection.videoOrientation = .portrait
          connection.isVideoMirrored = false
        }
        self.videoOutput = videoOutput
      }

      let audioOutput = AVCaptureAudioDataOutput()
      if self.session.canAddOutput(audioOutput) {
        self.session.addOutput(audioOutput)
        self.audioOutput = audioOutput
      }

      let metadataOutput = AVCaptureMetadataOutput()
      if self.session.canAddOutput(metadataOutput) {
        self.session.addOutput(metadataOutput)
        let availableTypes = metadataOutput.availableMetadataObjectTypes
        metadataOutput.metadataObjectTypes = Self.supportedMetadataTypes.filter {
          availableTypes.contains($0)
        }
        self.metadataOutput = metadataOutput
      }

      self.session.commitConfiguration()
      self.configureOutputDelegates()
    }
  }

  /// 幂等地重挂 video/audio/metadata 的 delegate：只覆盖 delegate 与 queue，
  /// 不创建新 output、不创建新 queue、不改变 output 数量。
  private func configureOutputDelegates() {
    videoOutput?.setSampleBufferDelegate(self, queue: sessionQueue)
    audioOutput?.setSampleBufferDelegate(self, queue: sessionQueue)
    // 扫码回调走独立队列，避免与视频帧写入 / AVAssetWriter 在 sessionQueue 上排队。
    metadataOutput?.setMetadataObjectsDelegate(self, queue: metadataQueue)
  }

  /// 摘除全部 delegate，避免已释放对象再收到回调。
  private func clearOutputDelegates() {
    videoOutput?.setSampleBufferDelegate(nil, queue: nil)
    audioOutput?.setSampleBufferDelegate(nil, queue: nil)
    metadataOutput?.setMetadataObjectsDelegate(nil, queue: nil)
  }

  /// 录像期音频会话：同时支持录音与播放提示音，避免被 .playback 降级。
  private func configureRecordingAudioSession() {
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .videoRecording,
      options: [.defaultToSpeaker]
    )
    try? AVAudioSession.sharedInstance().setActive(true)
  }

  /// 工作开始前只负责让会话可运行，不重注册纹理、不处理 dispose 恢复。
  private func ensureRunningForWork() throws {
    if recordAudio {
      configureRecordingAudioSession()
    }
    try addAudioInputIfNeeded()
    configureOutputDelegates()
    try restoreMetadataOutputForWork()
    guard outputsAreValidForWork() else {
      throw pigeonError(
        "摄像头输出状态异常",
        code: "camera_outputs_invalid"
      )
    }
    if !session.isRunning {
      session.startRunning()
    }
    guard session.isRunning else {
      throw pigeonError(
        "摄像头会话未运行",
        code: "camera_session_not_running"
      )
    }
  }

  /// 恢复扫码输出配置。`AVCaptureOutput.connections` 本身只包含该 output
  /// 的 connection，因此从其中取出的首个 connection 即为当前 metadata output
  /// 的有效 connection；这里不遍历 session 中其他 output 的 connection。
  private func restoreMetadataOutputForWork() throws {
    guard let metadataOutput else {
      throw pigeonError(
        "摄像头输出状态异常",
        code: "camera_outputs_invalid"
      )
    }
    let availableTypes = metadataOutput.availableMetadataObjectTypes
    let configuredTypes = Self.supportedMetadataTypes.filter {
      availableTypes.contains($0)
    }
    guard !configuredTypes.isEmpty else {
      throw pigeonError(
        "当前设备不支持扫码类型",
        code: "metadata_types_unavailable"
      )
    }
    metadataOutput.metadataObjectTypes = configuredTypes
    guard !metadataOutput.metadataObjectTypes.isEmpty else {
      throw pigeonError(
        "扫码输出配置失败",
        code: "metadata_types_unavailable"
      )
    }
    guard let connection = metadataOutput.connections.first else {
      throw pigeonError(
        "扫码输出连接不可用",
        code: "metadata_connection_unavailable"
      )
    }
    connection.isEnabled = true
  }

  /// 校验三个 output 均仍挂载在当前 session 上。
  private func outputsAreValid() -> Bool {
    let outputs = session.outputs
    let videoValid = videoOutput.map { outputs.contains($0) } ?? false
    let audioValid = audioOutput.map { outputs.contains($0) } ?? false
    let metadataValid = metadataOutput.map { outputs.contains($0) } ?? false
    return videoValid && audioValid && metadataValid
  }

  private func outputsAreValidForWork() -> Bool {
    let outputs = session.outputs
    let videoValid = videoOutput.map { outputs.contains($0) } ?? false
    let metadataValid = metadataOutput.map { outputs.contains($0) } ?? false
    let audioValid = !recordAudio || (audioOutput.map { outputs.contains($0) } ?? false)
    return videoValid && metadataValid && audioValid
  }

  private func addAudioInputIfNeeded() throws {
    guard recordAudio else { return }
    if let audioDeviceInput, session.inputs.contains(audioDeviceInput) {
      return
    }
    let wasRunning = session.isRunning
    if wasRunning {
      session.stopRunning()
    }
    guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
      throw pigeonError("未找到麦克风输入", code: "audio_input_missing")
    }
    do {
      let input = try AVCaptureDeviceInput(device: audioDevice)
      guard session.canAddInput(input) else {
        throw pigeonError("无法添加麦克风输入", code: "audio_input_missing")
      }
      session.addInput(input)
      audioDeviceInput = input
    } catch {
      if wasRunning {
        session.startRunning()
      }
      throw error
    }
  }

  /// 恢复已 dispose 的相机：校验 outputs → 重注册纹理 → 重挂 delegate →
  /// 重启 session，并在短时间内有界确认运行状态。
  private func recoverCamera(completion: @escaping (Bool) -> Void) {
    recoveryRuntimeError = false
    guard outputsAreValid() else {
      completion(false)
      return
    }
    if currentTextureId < 0 {
      let newId = textures.register(self)
      guard newId >= 0 else {
        completion(false)
        return
      }
      updateTextureId(newId)
    }
    configureOutputDelegates()
    if !session.isRunning {
      session.startRunning()
    }
    sessionQueue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
      guard let self else {
        completion(false)
        return
      }
      if self.session.isRunning && !self.recoveryRuntimeError {
        completion(true)
      } else {
        self.rollbackRecovery()
        completion(false)
      }
    }
  }

  /// 恢复失败时回滚纹理与 delegate，保持 disposed 状态干净。
  private func rollbackRecovery() {
    clearOutputDelegates()
    let textureId = currentTextureId
    if textureId >= 0 {
      textures.unregisterTexture(textureId)
      updateTextureId(-1)
    }
  }

  /// 初始化完成：发 sessionStarted 事件并返回初始化结果。
  private func finishInitialize(
    _ completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    eventApi.sessionStarted(
      event: CameraSessionStartedDto(
        sessionId: sessionId,
        startedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
      ),
      completion: { _ in }
    )
    completion(.success(initializationDto()))
  }

  private func replaceVideoDevice(
    _ device: AVCaptureDevice,
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self, !self.isDisposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      do {
        let input = try AVCaptureDeviceInput(device: device)
        self.session.beginConfiguration()
        if let oldInput = self.videoDeviceInput {
          self.session.removeInput(oldInput)
        }
        guard self.session.canAddInput(input) else {
          self.session.commitConfiguration()
          completion(.failure(pigeonError("无法切换到该摄像头")))
          return
        }
        self.session.addInput(input)
        self.videoDeviceInput = input
        self.session.commitConfiguration()
        if let connection = self.videoOutput?.connection(with: .video) {
          // 切换镜头后重新固定竖屏方向，前置镜头同时开启镜像，
          // 避免切换后预览被拉伸或未镜像。
          connection.videoOrientation = .portrait
          connection.isVideoMirrored = device.position == .front
        }
        completion(.success(self.initializationDto()))
      } catch {
        completion(.failure(error))
      }
    }
  }

  private func switchToPosition(
    _ position: AVCaptureDevice.Position,
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    guard let device = Self.defaultVideoDevice(position: position) else {
      completion(.failure(pigeonError("找不到可切换的摄像头")))
      return
    }
    replaceVideoDevice(device, completion: completion)
  }

  private func initializationDto() -> CameraInitializationDto {
    let device = videoDeviceInput?.device
    let size = portraitSize
    let usesHevc = preferredVideoCodec.lowercased() == "hevc"
    return CameraInitializationDto(
      textureId: currentTextureId,
      previewWidth: Int64(size.width),
      previewHeight: Int64(size.height),
      sensorOrientation: 0,
      fps: 30,
      videoMime: usesHevc ? "video/hevc" : "video/avc",
      codecFallbackReason: nil,
      flashAvailable: device?.hasTorch == true,
      lensDirection: device?.position == .front ? "front" : "back",
      canSwitchCamera: Self.hasFrontCamera && Self.hasBackCamera,
      cameraId: device?.uniqueID,
      zoomRatio: Double(device?.videoZoomFactor ?? 1)
    )
  }

  // MARK: - Recording

  private func startWriter(path: String) throws {
    if recordAudio {
      configureRecordingAudioSession()
    }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let codec: AVVideoCodecType =
      preferredVideoCodec.lowercased() == "hevc" ? .hevc : .h264
    let size = portraitSize
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: size.width,
      AVVideoHeightKey: size.height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 8_000_000,
        AVVideoExpectedSourceFrameRateKey: 30,
      ],
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: size.width,
        kCVPixelBufferHeightKey as String: size.height,
      ]
    )

    var audioInput: AVAssetWriterInput?
    if recordAudio {
      guard audioOutput != nil else {
        throw pigeonError(
          "未找到麦克风输入",
          code: "audio_input_missing"
        )
      }
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 96_000,
      ]
      audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
      audioInput?.expectsMediaDataInRealTime = true
    }

    if writer.canAdd(videoInput) {
      writer.add(videoInput)
    } else {
      throw pigeonError("无法创建录像视频轨道")
    }
    if let audioInput {
      guard writer.canAdd(audioInput) else {
        throw pigeonError(
          "无法创建录像声音轨道",
          code: "audio_track_creation_failed"
        )
      }
      writer.add(audioInput)
    }

    guard writer.startWriting() else {
      throw writer.error ?? pigeonError("开始录像失败")
    }
    self.writer = writer
    self.videoInput = videoInput
    self.audioInput = audioInput
    self.pixelBufferAdaptor = adaptor
    self.currentPath = path
    self.currentSegmentId = UUID().uuidString
    self.currentStartedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    self.currentSegmentSerial += 1
    self.writerSessionStarted = false
    self.recordingAudioActive = recordAudio && audioInput != nil
    self.currentAudioSampleCount = 0
    self.currentAudioAppendFailedCount = 0
    self.currentAudioLastError = nil
  }

  private func appendVideo(_ sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer) {
    guard let writer, let videoInput, writer.status == .writing else { return }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if !writerSessionStarted {
      writer.startSession(atSourceTime: timestamp)
      writerSessionStarted = true
    }
    if videoInput.isReadyForMoreMediaData {
      pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: timestamp)
    }
  }

  private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    guard let writer, let audioInput, writer.status == .writing,
          writerSessionStarted, audioInput.isReadyForMoreMediaData else {
      return
    }
    currentAudioSampleCount += 1
    if !audioInput.append(sampleBuffer) {
      currentAudioAppendFailedCount += 1
      if currentAudioLastError == nil {
        currentAudioLastError =
          writer.error?.localizedDescription ?? "声音样本写入失败"
      }
    }
  }

  private func finishCurrentWriter(
    _ sendEvents: Bool = true,
    timeout: TimeInterval = 5,
    completion: @escaping () -> Void
  ) {
    guard let writer else {
      completion()
      return
    }
    let completedPath = currentPath
    let completedStartedAt = currentStartedAtMs
    let completedSegmentId = currentSegmentId
    let completedSegmentSerial = currentSegmentSerial
    let endedAt = Int64(Date().timeIntervalSince1970 * 1000)
    videoInput?.markAsFinished()
    audioInput?.markAsFinished()
    self.writer = nil
    self.videoInput = nil
    self.audioInput = nil
    self.pixelBufferAdaptor = nil
    self.currentPath = nil
    writerSessionStarted = false
    lastAudioSampleCount = currentAudioSampleCount
    lastAudioAppendFailedCount = currentAudioAppendFailedCount
    lastAudioLastError = currentAudioLastError
    currentAudioSampleCount = 0
    currentAudioAppendFailedCount = 0
    currentAudioLastError = nil
    recordingAudioActive = false

    let finishLock = NSLock()
    var didFinish = false
    let timeoutItem = DispatchWorkItem { [weak self] in
      finishLock.lock()
      guard !didFinish else {
        finishLock.unlock()
        return
      }
      didFinish = true
      finishLock.unlock()
      writer.cancelWriting()
      self?.recordLastSegmentResult(
        serial: completedSegmentSerial,
        writerStatus: "cancelled",
        writerError: "录像写入超时",
        path: nil,
        inspectionError: "录像写入超时"
      )
      if sendEvents, let completedPath {
        self?.eventApi.segmentFailed(
          event: CameraSegmentFailedDto(
            sessionId: self?.sessionId ?? "",
            segmentId: completedSegmentId,
            reason: "录像写入超时"
          ),
          completion: { _ in }
        )
      }
      completion()
    }
    sessionQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

    writer.finishWriting { [weak self] in
      finishLock.lock()
      guard !didFinish else {
        finishLock.unlock()
        return
      }
      didFinish = true
      finishLock.unlock()
      timeoutItem.cancel()
      let writerStatus = writer.status
      let writerError = writer.error?.localizedDescription
      self?.recordLastSegmentResult(
        serial: completedSegmentSerial,
        writerStatus: Self.writerStatusName(writerStatus),
        writerError: writerError,
        path: writerStatus == .completed ? completedPath : nil,
        inspectionError: writerStatus == .completed
          ? nil
          : writerError ?? "录像文件写入失败"
      )
      if sendEvents {
        guard let self else {
          completion()
          return
        }
        if writer.status == .completed, let completedPath, !completedSegmentId.isEmpty {
          self.eventApi.segmentCompleted(
            event: CameraSegmentCompletedDto(
              sessionId: self.sessionId,
              segmentId: completedSegmentId,
              path: completedPath,
              startedAtMs: completedStartedAt,
              endedAtMs: endedAt
            ),
            completion: { _ in }
          )
        } else if let completedPath {
          self.eventApi.segmentFailed(
            event: CameraSegmentFailedDto(
              sessionId: self.sessionId,
              segmentId: completedSegmentId,
              reason: writer.error?.localizedDescription ?? "录像文件写入失败"
            ),
            completion: { _ in }
          )
        }
      }
      completion()
    }
  }

  private static func writerStatusName(_ status: AVAssetWriter.Status) -> String {
    switch status {
    case .unknown:
      return "unknown"
    case .writing:
      return "writing"
    case .completed:
      return "completed"
    case .failed:
      return "failed"
    case .cancelled:
      return "cancelled"
    @unknown default:
      return "unknown"
    }
  }

  private func recordLastSegmentResult(
    serial: Int64,
    writerStatus: String,
    writerError: String?,
    path: String?,
    inspectionError: String?
  ) {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard serial >= lastCompletedSegmentSerial else {
      return
    }
    lastCompletedSegmentSerial = serial
    lastSegmentWriterStatus = writerStatus
    lastSegmentWriterError = writerError

    guard let path, !path.isEmpty else {
      lastSegmentAudioTrackCheckSucceeded = false
      lastSegmentAudioTrackCount = nil
      lastSegmentAudioTrackPresent = nil
      lastSegmentAudioTrackInspectionError = inspectionError
      return
    }

    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let audioTracks = asset.tracks(withMediaType: .audio)
    lastSegmentAudioTrackCheckSucceeded = true
    lastSegmentAudioTrackCount = Int64(audioTracks.count)
    lastSegmentAudioTrackPresent = !audioTracks.isEmpty
    lastSegmentAudioTrackInspectionError = nil
  }

  private var isDisposed: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return disposed
  }

  private func markDisposed() {
    stateLock.lock()
    disposed = true
    stateLock.unlock()
  }

  private func markNotDisposed() {
    stateLock.lock()
    disposed = false
    stateLock.unlock()
  }

  private var currentTextureId: Int64 {
    stateLock.lock()
    defer { stateLock.unlock() }
    return textureId
  }

  private func updateTextureId(_ newValue: Int64) {
    stateLock.lock()
    textureId = newValue
    stateLock.unlock()
  }

  // MARK: - Helpers

  private func requestVideoAndAudioPermissions(
    recordAudio: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    AVCaptureDevice.requestAccess(for: .video) { videoGranted in
      guard videoGranted else {
        completion(false)
        return
      }
      guard recordAudio else {
        completion(true)
        return
      }
      AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
        completion(audioGranted)
      }
    }
  }

  private func backCameraLenses() -> [CameraLensDto] {
    Self.backDevices.map { device in
      CameraLensDto(
        cameraId: device.uniqueID,
        focalLength: 0,
        zoomRatio: Self.zoomRatio(for: device),
        isMain: device.deviceType == .builtInWideAngleCamera
      )
    }
  }

  private func metadataTypeName(_ type: AVMetadataObject.ObjectType) -> String {
    switch type {
    case .ean13: return "ean13"
    case .ean8: return "ean8"
    case .code128: return "code128"
    case .qr: return "qr"
    default: return type.rawValue
    }
  }

  private static let supportedMetadataTypes: [AVMetadataObject.ObjectType] = [
    .ean13,
    .ean8,
    .code128,
    .code39,
    .code93,
    .qr,
    .pdf417,
    .upce,
  ]

  private static let backDevices: [AVCaptureDevice] = {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [
        .builtInWideAngleCamera,
        .builtInUltraWideCamera,
        .builtInTelephotoCamera,
      ],
      mediaType: .video,
      position: .back
    ).devices
  }()

  private static let frontDevices: [AVCaptureDevice] = {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera],
      mediaType: .video,
      position: .front
    ).devices
  }()

  private static var hasBackCamera: Bool { !backDevices.isEmpty }
  private static var hasFrontCamera: Bool { !frontDevices.isEmpty }

  private static func defaultVideoDevice(
    position: AVCaptureDevice.Position
  ) -> AVCaptureDevice? {
    if position == .front {
      return frontDevices.first
    }
    // 显式优先主摄（广角）：DiscoverySession 的设备顺序没有文档保证，
    // 若把超广角排到首位，初始化或翻转回后置会落在 0.5x，导致条码过小扫不上。
    return backDevices.first(where: {
      $0.deviceType == .builtInWideAngleCamera
    }) ?? backDevices.first
  }

  private static func zoomRatio(for device: AVCaptureDevice) -> Double {
    switch device.deviceType {
    case .builtInUltraWideCamera: return 0.5
    case .builtInTelephotoCamera: return 2.0
    default: return 1.0
    }
  }

}

/// iOS 前台订单接收：用本地 TCP 监听 5280，解析桌面端推送的
/// `POST /api/orderinfo` JSON 数组。仅支持 App 前台运行；退到后台
/// 后系统可能挂起监听，后续再单独评估后台方案。
private final class IosOrderReceiverHostApi: OrderReceiverHostApi {
  private let eventApi: OrderReceiverEventApi
  private let queue = DispatchQueue(label: "packingproof.order.receiver")
  private let networkQueue = DispatchQueue(label: "packingproof.order.network")
  private let networkMonitor = NWPathMonitor()
  private let storeLock = NSLock()
  private var ordersByTrackingNumber: [String: OrderInfoDto] = [:]
  private var serverSocket: Int32 = -1
  private var running = false
  private var backgroundDelivery = false
  private var lastError = ""
  private var activeWifiInterfaceNames = Set<String>()

  init(eventApi: OrderReceiverEventApi) {
    self.eventApi = eventApi
    networkMonitor.pathUpdateHandler = { [weak self] path in
      let names = path.availableInterfaces
        .filter { $0.type == .wifi }
        .map(\.name)
      self?.activeWifiInterfaceNames = Set(names)
    }
    networkMonitor.start(queue: networkQueue)
  }

  deinit {
    networkMonitor.cancel()
    if running {
      try? stopReceiver()
    }
  }

  func startReceiver(backgroundDelivery: Bool) throws -> OrderReceiverStatusDto {
    self.backgroundDelivery = backgroundDelivery
    if running {
      return status()
    }

    let socketHandle = socket(AF_INET, SOCK_STREAM, 0)
    guard socketHandle >= 0 else {
      lastError = "创建订单接收服务失败"
      throw pigeonError(lastError)
    }

    var reuse: Int32 = 1
    setsockopt(
      socketHandle,
      SOL_SOCKET,
      SO_REUSEADDR,
      &reuse,
      socklen_t(MemoryLayout<Int32>.size)
    )

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = INADDR_ANY

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
        bind(socketHandle, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      close(socketHandle)
      lastError = "订单接收端口 5280 已被占用"
      throw pigeonError(lastError, code: "order_receiver_port_in_use")
    }

    guard listen(socketHandle, 8) == 0 else {
      close(socketHandle)
      lastError = "订单接收服务监听失败"
      throw pigeonError(lastError, code: "order_receiver_bind_failed")
    }

    serverSocket = socketHandle
    running = true
    let preferredAddress = preferredPrivateIPv4()
    lastError = preferredAddress == nil ? "无法确定可用局域网地址" : ""
    queue.async { [weak self] in
      self?.acceptLoop()
    }
    return status()
  }

  func getReceiverStatus() throws -> OrderReceiverStatusDto {
    return status()
  }

  func lookup(trackingNumber: String) throws -> OrderInfoDto? {
    let key = trackingNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !key.isEmpty else { return nil }
    storeLock.lock()
    defer { storeLock.unlock() }
    return ordersByTrackingNumber[key]
  }

  func updateBackgroundDelivery(enabled: Bool) throws {
    backgroundDelivery = enabled
  }

  func stopReceiver() throws {
    guard running else { return }
    running = false
    let socketHandle = serverSocket
    serverSocket = -1
    if socketHandle >= 0 {
      close(socketHandle)
    }
  }

  // MARK: - HTTP server

  private var port: Int { 5280 }

  private func status() -> OrderReceiverStatusDto {
    let address = preferredPrivateIPv4() ?? ""
    return OrderReceiverStatusDto(
      running: running,
      ipAddress: address,
      url: running && !address.isEmpty ? "http://\(address):\(port)" : "",
      port: Int64(port),
      errorMessage: lastError
    )
  }

  private func preferredPrivateIPv4() -> String? {
    let names = networkQueue.sync { activeWifiInterfaceNames }
    return Self.currentPrivateIPv4(preferredInterfaceNames: names)
  }

  private func acceptLoop() {
    while running {
      var clientAddress = sockaddr_in()
      var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      let client = withUnsafeMutablePointer(to: &clientAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
          accept(serverSocket, socketPointer, &clientLength)
        }
      }
      guard client >= 0 else {
        if running {
          let code = errno
          lastError = "接收电脑连接失败 errno=\(code) \(String(cString: strerror(code)))"
        }
        Thread.sleep(forTimeInterval: 0.1)
        continue
      }
      handle(client)
      close(client)
    }
  }

  private func handle(_ client: Int32) {
    do {
      let request = try readRequest(client)
      try route(client, request)
    } catch {
      lastError = error.localizedDescription
      writeJSON(client, status: 400, body: ["ok": false, "error": error.localizedDescription])
    }
  }

  private func route(_ client: Int32, _ request: HTTPRequest) throws {
    if request.method == "OPTIONS" {
      writeJSON(client, status: 200, body: ["ok": true])
      return
    }

    let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
    if request.method == "GET" && path == "/api/storage" {
      writeJSON(client, status: 200, body: [
        "ok": true,
        "service": "packingproof-mobile",
        "port": port,
      ])
      return
    }

    if request.method == "POST" && path == "/api/orderinfo" {
      let items = try parseOrderInfoArray(request.body)
      storeLock.lock()
      for item in items where !item.isTest {
        ordersByTrackingNumber[item.trackingNumber.uppercased()] = item
      }
      storeLock.unlock()
      if !items.isEmpty {
        let eventApi = eventApi
        DispatchQueue.main.async {
          eventApi.orderInfoReceived(items: items) { _ in }
        }
      }
      let storedCount = items.filter { !$0.isTest }.count
      writeJSON(client, status: 200, body: [
        "ok": true,
        "count": storedCount,
        "testCount": items.count - storedCount,
      ])
      return
    }

    writeJSON(client, status: 404, body: ["ok": false, "error": "接口不存在"])
  }

  private func parseOrderInfoArray(_ data: Data) throws -> [OrderInfoDto] {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let array = object as? [[String: Any]] else {
      throw pigeonError("订单 JSON 格式无效")
    }
    guard !array.isEmpty else {
      throw pigeonError("空数据")
    }
    guard array.count <= 200 else {
      throw pigeonError("单次最多推送 200 条订单")
    }

    let now = Int64(Date().timeIntervalSince1970 * 1000)
    return try array.map { item in
      OrderInfoDto(
        trackingNumber: try text(item, "trackingNumber", maxLength: 128)
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .uppercased(),
        orderId: try text(item, "orderId", maxLength: 128),
        buyerMessage: try text(item, "buyerMessage", maxLength: 2000),
        sellerMemo: try text(item, "sellerMemo", maxLength: 2000),
        productInfo: try text(item, "productInfo", maxLength: 4000),
        hasRefund: item["hasRefund"] as? Bool ?? false,
        isPrintedRefund: item["isPrintedRefund"] as? Bool ?? false,
        refundStatus: try text(item, "refundStatus", maxLength: 256),
        refundProductInfo: try text(item, "refundProductInfo", maxLength: 4000),
        pushTimeMs: now,
        isTest: item["isTest"] as? Bool ?? false
      )
    }
  }

  private func text(_ item: [String: Any], _ key: String, maxLength: Int) throws -> String {
    let value = (item[key] as? String) ?? ""
    guard value.count <= maxLength else {
      throw pigeonError("\(key) 过长，最多允许 \(maxLength) 个字符")
    }
    return value
  }

  private func readRequest(_ client: Int32) throws -> HTTPRequest {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = recv(client, &buffer, buffer.count, 0)
      if count <= 0 {
        break
      }
      data.append(contentsOf: buffer[0..<count])
      if data.range(of: Data("\r\n\r\n".utf8)) != nil {
        break
      }
      if data.count > 1024 * 1024 {
        throw pigeonError("请求内容过大")
      }
    }

    let headerSeparator = Data("\r\n\r\n".utf8)
    guard let range = data.range(of: headerSeparator) else {
      throw pigeonError("订单请求无效")
    }
    let headerData = data.subdata(in: data.startIndex..<range.lowerBound)
    var bodyData = data.subdata(in: range.upperBound..<data.endIndex)
    guard let headerText = String(data: headerData, encoding: .utf8) else {
      throw pigeonError("订单请求无效")
    }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      throw pigeonError("订单请求无效")
    }
    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count >= 2 else {
      throw pigeonError("订单请求无效")
    }

    let method = String(requestParts[0]).uppercased()
    let path = String(requestParts[1])
    let contentLength = lines
      .first(where: { $0.lowercased().hasPrefix("content-length:") })
      .map { Int($0.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)) ?? 0 }
      ?? 0

    guard contentLength >= 0 && contentLength <= 1024 * 1024 else {
      throw pigeonError("请求内容过大，最大允许 1024 KB")
    }

    while bodyData.count < contentLength {
      let remaining = contentLength - bodyData.count
      var chunk = [UInt8](repeating: 0, count: min(8192, remaining))
      let count = recv(client, &chunk, chunk.count, 0)
      if count <= 0 {
        break
      }
      bodyData.append(contentsOf: chunk[0..<count])
    }

    guard bodyData.count == contentLength else {
      throw pigeonError("订单数据接收不完整，请重试")
    }

    return HTTPRequest(method: method, path: path, body: bodyData)
  }

  private func writeJSON(_ client: Int32, status: Int, body: [String: Any]) {
    let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    let reason = Self.reason(for: status)
    var header = "HTTP/1.1 \(status) \(reason)\r\n"
    header += "Content-Type: application/json; charset=utf-8\r\n"
    header += "Content-Length: \(bodyData.count)\r\n"
    header += "Access-Control-Allow-Origin: *\r\n"
    header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
    header += "Access-Control-Allow-Headers: Content-Type\r\n"
    header += "Connection: close\r\n\r\n"
    var response = Data(header.utf8)
    response.append(bodyData)
    response.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      _ = send(client, base, response.count, 0)
    }
  }

  private static func reason(for status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    default: return "OK"
    }
  }

  private static func currentPrivateIPv4(
    preferredInterfaceNames: Set<String> = []
  ) -> String? {
    var interfacePointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfacePointer) == 0 else { return nil }
    defer { freeifaddrs(interfacePointer) }

    struct Candidate {
      let interfaceName: String
      let address: String
      let score: Int
    }

    var candidates: [Candidate] = []
    var cursor = interfacePointer
    while let interface = cursor {
      defer { cursor = interface.pointee.ifa_next }
      let flags = Int32(interface.pointee.ifa_flags)
      guard (flags & IFF_UP) != 0,
            (flags & IFF_LOOPBACK) == 0,
            let address = interface.pointee.ifa_addr,
            address.pointee.sa_family == UInt8(AF_INET) else {
        continue
      }

      let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socketAddress in
        String(cString: inet_ntoa(socketAddress.pointee.sin_addr))
      }
      guard isPrivateIPv4(ip) else { continue }
      let name = String(cString: interface.pointee.ifa_name)
      candidates.append(Candidate(
        interfaceName: name,
        address: ip,
        score: interfaceScore(
          name: name,
          address: ip,
          preferredInterfaceNames: preferredInterfaceNames
        )
      ))
    }

    return candidates
      .sorted {
        if $0.score != $1.score { return $0.score < $1.score }
        return $0.interfaceName < $1.interfaceName
      }
      .first?
      .address
  }

  private static func interfaceScore(
    name: String,
    address: String,
    preferredInterfaceNames: Set<String>
  ) -> Int {
    if isLinkLocalIPv4(address) { return 200 }
    if preferredInterfaceNames.contains(name) { return 0 }
    if name == "en0" { return 1 }
    if name.hasPrefix("en") { return 2 }
    if name.hasPrefix("bridge") { return 3 }
    if isExcludedInterfaceName(name) { return 100 }
    return 50
  }

  private static func isLinkLocalIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".").compactMap { Int($0) }
    return parts.count == 4 && parts[0] == 169 && parts[1] == 254
  }

  private static func isExcludedInterfaceName(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower.hasPrefix("utun")
      || lower.hasPrefix("ipsec")
      || lower.hasPrefix("ppp")
      || lower.hasPrefix("tap")
      || lower.hasPrefix("tun")
      || lower.hasPrefix("pdp_ip")
      || lower == "awdl0"
      || lower == "llw0"
      || lower.hasPrefix("anpi")
  }

  private static func isPrivateIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
      return false
    }
    return parts[0] == 10
      || (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31)
      || (parts[0] == 192 && parts[1] == 168)
      || (parts[0] == 169 && parts[1] == 254)
  }

  private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
  }
}
