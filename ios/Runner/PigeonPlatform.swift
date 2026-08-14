import AVFoundation
import AVKit
import CoreImage
import CryptoKit
import Flutter
import ImageIO
import Network
import QuartzCore
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

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
    completion(.failure(pigeonError("当前平台不支持提示音量控制")))
  }

  func boost(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.failure(pigeonError("当前平台不支持提升提示音量")))
  }
}

private final class IosBackupHostApi: BackupNativeHostApi {
  private let defaults = UserDefaults.standard
  private let eventApi: BackupNativeEventApi
  private let networkMonitor = NWPathMonitor()
  private let networkQueue = DispatchQueue(label: "ios.backup.network")
  private var lastLanReachable = false
  private let uploadsLock = NSLock()
  private var activeUploads: [String: Task<Void, Never>] = [:]
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
    defaults.set(normalized(request), forKey: keys.retention)
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
          let remoteIds = job["remoteRecordIds"] as? [Any], !remoteIds.isEmpty,
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
          job["cleanupReason"] = "storage_reclaim"
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
      "jobs": jobs(),
    ]
  }

  private func deviceId() -> String {
    if let value = defaults.string(forKey: keys.deviceId) { return value }
    let value = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
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

  private func startUpload(_ job: [String: Any]) {
    guard let jobId = job["id"] as? String else { return }
    uploadsLock.lock()
    activeUploads[jobId]?.cancel()
    let task = Task.detached { [weak self] in
      if let self { await self.upload(job: job) }
    }
    activeUploads[jobId] = task
    uploadsLock.unlock()
  }

  private func upload(job: [String: Any]) async {
    guard
      let connection = defaults.dictionary(forKey: keys.connection),
      let baseUrl = connection["baseUrl"] as? String,
      let accessKey = defaults.string(forKey: keys.accessKey),
      let path = job["filePath"] as? String,
      let jobId = job["id"] as? String
    else {
      return
    }
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
      let create = try await uploadJson(
        baseUrl: baseUrl,
        path: "/api/mobile-backup/uploads",
        body: [
          "fileSha256": fileSha256,
          "totalBytes": data.count,
          "mimeType": "video/mp4",
        ],
        accessKey: accessKey,
        deviceId: deviceId()
      )
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
        let result = try await uploadChunk(
          baseUrl: baseUrl,
          path: "/api/mobile-backup/uploads/\(uploadIdEncoded)/chunks",
          chunk: chunk,
          offset: offset,
          total: data.count,
          accessKey: accessKey,
          deviceId: deviceId()
        )
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
      let complete = try await uploadJson(
        baseUrl: baseUrl,
        path: "/api/mobile-backup/uploads/\(uploadIdEncoded)/complete",
        body: [
          "fileSha256": fileSha256,
          "sourceDeviceId": deviceId(),
          "sourceDeviceName": deviceName(),
          "sessions": job["sessions"] as? [Any] ?? [],
        ],
        accessKey: accessKey,
        deviceId: deviceId()
      )
      guard complete["status"] as? String == "verified" else {
        throw pigeonError("电脑未确认录像校验结果")
      }
      updateJob(jobId) { current in
        current["state"] = "completed"
        current["uploadedBytes"] = data.count
        current["contentSha256"] = fileSha256
        current["remoteRecordIds"] = complete["recordIds"] as? [Any] ?? []
      }
      emitSnapshot()
    } catch {
      updateJob(jobId) { current in
        current["state"] = "paused"
        current["errorMessage"] = error.localizedDescription
      }
      emitSnapshot()
    }
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
      throw pigeonError("电脑备份请求失败")
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
      throw pigeonError("电脑备份分块失败")
    }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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
}
