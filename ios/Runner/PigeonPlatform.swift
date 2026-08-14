import AVFoundation
import AVKit
import Flutter
import ImageIO
import UIKit
import UniformTypeIdentifiers

final class PigeonPlatform {
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
  }
}

private func pigeonError(_ message: String) -> PigeonError {
  PigeonError(code: "ios_unavailable", message: message, details: nil)
}

private final class IosMediaProcessingHostApi: MediaProcessingHostApi {
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
    completion(.failure(pigeonError("iOS 水印移植尚未完成")))
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
      session.exportAsynchronously {
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
    completion(.success(100))
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
    completion(
      .success(
        VideoDecodeSupportDto(
          manufacturer: "Apple",
          brand: "Apple",
          model: UIDevice.current.model,
          sdkInt: 0,
          release: UIDevice.current.systemVersion,
          hasHevcDecoder: true,
          hasAvcDecoder: true,
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
        .playback,
        mode: .spokenAudio,
        options: [.duckOthers]
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
    completion(.success(()))
  }

  func boost(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.success(()))
  }
}

private final class IosBackupHostApi: BackupNativeHostApi {
  private let defaults = UserDefaults.standard
  private let eventApi: BackupNativeEventApi
  private let keys = (
    deviceId: "ios_backup_device_id",
    deviceName: "ios_backup_device_name",
    connection: "ios_backup_connection",
    accessKey: "ios_backup_access_key",
    jobs: "ios_backup_jobs",
    retention: "ios_backup_retention"
  )

  init(eventApi: BackupNativeEventApi) {
    self.eventApi = eventApi
  }

  func snapshot(completion: @escaping (Result<[String?: Any?]?, Error>) -> Void) {
    completion(.success(currentSnapshot()))
  }

  func initialize(
    request: [String?: Any?],
    completion: @escaping (Result<[String?: Any?]?, Error>) -> Void
  ) {
    defaults.set(request["unbackedRetentionDays"], forKey: keys.retention)
    completion(.success(currentSnapshot()))
  }

  func loadAccessKey(completion: @escaping (Result<String?, Error>) -> Void) {
    completion(.success(defaults.string(forKey: keys.accessKey)))
  }

  func isWifiConnected(completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.success(true))
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
    emitSnapshot()
    completion(.success(()))
  }

  func requeueJob(
    jobId: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    updateJob(jobId) { job in
      job["state"] = "pending"
      job.removeValue(forKey: "errorMessage")
      job.removeValue(forKey: "failureKind")
    }
    emitSnapshot()
    completion(.success(()))
  }

  func cancelJob(
    jobId: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
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
    defaults.set(normalized(request), forKey: keys.retention)
    completion(.success(()))
  }

  func reclaimStorageIfNeeded(
    completion: @escaping (Result<[String?: Any?], Error>) -> Void
  ) {
    completion(
      .success(
        [
          "availableBytes": 1 << 62,
          "availableBytesBefore": 1 << 62,
          "freedBytes": 0,
          "deletedCount": 0,
          "warning": false,
          "insufficient": false,
        ]
      )
    )
  }

  func getNetworkDiagnostics(
    completion: @escaping (Result<[String?: Any?]?, Error>) -> Void
  ) {
    completion(.success(["wifiConnected": true]))
  }

  private func currentSnapshot() -> [String?: Any?] {
    [
      "deviceId": deviceId(),
      "deviceName": deviceName(),
      "connection": defaults.dictionary(forKey: keys.connection),
      "jobs": jobs(),
    ]
  }

  private func deviceId() -> String {
    if let value = defaults.string(forKey: keys.deviceId) { return value }
    let value = UUID().uuidString
    defaults.set(value, forKey: keys.deviceId)
    return value
  }

  private func deviceName() -> String {
    defaults.string(forKey: keys.deviceName) ?? "iOS 设备"
  }

  private func jobs() -> [[String: Any]] {
    (defaults.array(forKey: keys.jobs) as? [[String: Any]]) ?? []
  }

  private func upsert(_ job: [String: Any]) {
    let id = job["id"] as? String ?? ""
    var all = jobs().filter { $0["id"] as? String != id }
    all.append(job)
    defaults.set(all, forKey: keys.jobs)
  }

  private func updateJob(_ id: String, mutate: (inout [String: Any]) -> Void) {
    var all = jobs()
    guard let index = all.firstIndex(where: { $0["id"] as? String == id }) else {
      return
    }
    var job = all[index]
    mutate(&job)
    all[index] = job
    defaults.set(all, forKey: keys.jobs)
  }

  private func emitSnapshot() {
    eventApi.snapshotChanged(snapshot: currentSnapshot()) { _ in }
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
      guard let key = key, let item = item else { continue }
      result[key] = item
    }
    return result
  }
}
