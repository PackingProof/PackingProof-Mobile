import AVFoundation
import AVKit
import CoreImage
import CryptoKit
import Darwin
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
    CameraHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: IosCameraHostApi(
        eventApi: CameraEventApi(binaryMessenger: messenger),
        textures: registrar.textures()
      )
    )
    OrderReceiverHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: IosOrderReceiverHostApi(
        eventApi: OrderReceiverEventApi(binaryMessenger: messenger)
      )
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
    if let savedName = defaults.string(forKey: keys.deviceName)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !savedName.isEmpty {
      return savedName
    }
    return "本机"
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
  private let bufferLock = NSLock()

  private var textureId: Int64 = -1
  private var latestPixelBuffer: CVPixelBuffer?
  private var videoDeviceInput: AVCaptureDeviceInput?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var audioOutput: AVCaptureAudioDataOutput?
  private var metadataOutput: AVCaptureMetadataOutput?

  private var recordingSpecName = "hd1080p30"
  private var preferredVideoCodec = "hevc"
  private var recordAudio = true
  private var pairingScanEnabled = false
  private var workScanEnabled = false
  private var disposed = false

  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var currentPath: String?
  private var currentSegmentId = ""
  private var currentStartedAtMs: Int64 = 0
  private var writerSessionStarted = false
  private var sessionId = UUID().uuidString

  init(eventApi: CameraEventApi, textures: FlutterTextureRegistry) {
    self.eventApi = eventApi
    self.textures = textures
    super.init()
    textureId = textures.register(self)
    configureSession()
  }

  deinit {
    if textureId >= 0 {
      textures.unregisterTexture(textureId)
    }
  }

  // MARK: - CameraHostApi

  func initialize(
    request: CameraInitializeRequest,
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    preferredVideoCodec = request.videoCodec
    recordingSpecName = request.recordingSpec
    sessionQueue.async { [weak self] in
      guard let self, !self.disposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      if !self.session.isRunning {
        self.session.startRunning()
      }
      self.eventApi.sessionStarted(
        event: CameraSessionStartedDto(
          sessionId: self.sessionId,
          startedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ),
        completion: { _ in }
      )
      completion(.success(self.initializationDto()))
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
      guard let self, !self.disposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      do {
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
      guard let self, !self.disposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      let completedPath = self.currentPath ?? ""
      let completedStartedAt = self.currentStartedAtMs
      let boundaryAt = Int64(Date().timeIntervalSince1970 * 1000)
      self.finishCurrentWriter { [weak self] in
        guard let self else { return }
        self.sessionQueue.async {
          do {
            try self.startWriter(path: nextPath)
          } catch {
            self.eventApi.nativeError(
              message: "切换录像文件失败：\(error.localizedDescription)",
              completion: { _ in }
            )
          }
        }
      }
      completion(.success(CameraRecordingSplitDto(
        completedPath: completedPath,
        nextPath: nextPath,
        completedStartedAtMs: completedStartedAt,
        boundaryAtMs: boundaryAt
      )))
    }
  }

  func stopWork(
    completion: @escaping (Result<CameraRecordingStopDto, Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self, !self.disposed else {
        completion(.failure(pigeonError("摄像头已经关闭")))
        return
      }
      let path = self.currentPath ?? ""
      let startedAt = self.currentStartedAtMs
      let endedAt = Int64(Date().timeIntervalSince1970 * 1000)
      self.finishCurrentWriter {}
      completion(.success(CameraRecordingStopDto(
        path: path,
        startedAtMs: startedAt,
        endedAtMs: endedAt
      )))
    }
  }

  func getDiagnostics(
    completion: @escaping (Result<[String?: Any?]?, Error>) -> Void
  ) {
    completion(.success([
      "initialized": true,
      "sessionRunning": session.isRunning,
      "cameraPipelineVersion": 1,
      "recordingSpec": recordingSpecName,
    ]))
  }

  func setPairingScanEnabled(
    enabled: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    pairingScanEnabled = enabled
    completion(.success(()))
  }

  func setWorkScanEnabled(
    enabled: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    workScanEnabled = enabled
    completion(.success(()))
  }

  func setPreviewActive(
    active: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    completion(.success(()))
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
    disposed = true
    sessionQueue.async { [weak self] in
      guard let self else {
        completion(.success(()))
        return
      }
      self.finishCurrentWriter {}
      if self.session.isRunning {
        self.session.stopRunning()
      }
      self.textures.unregisterTexture(self.textureId)
      self.textureId = -1
      completion(.success(()))
    }
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
    if output === videoOutput {
      guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        return
      }
      bufferLock.lock()
      latestPixelBuffer = pixelBuffer
      bufferLock.unlock()
      textures.textureFrameAvailable(textureId)
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
    guard pairingScanEnabled || workScanEnabled else { return }
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
        format: metadataTypeName(machineReadable.type)
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
      videoOutput.alwaysDiscardsLateVideoFrames = false
      videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      if self.session.canAddOutput(videoOutput) {
        self.session.addOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
        self.videoOutput = videoOutput
      }

      let audioOutput = AVCaptureAudioDataOutput()
      if self.session.canAddOutput(audioOutput) {
        self.session.addOutput(audioOutput)
        audioOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
        self.audioOutput = audioOutput
      }

      let metadataOutput = AVCaptureMetadataOutput()
      if self.session.canAddOutput(metadataOutput) {
        self.session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: self.sessionQueue)
        let availableTypes = metadataOutput.availableMetadataObjectTypes
        metadataOutput.metadataObjectTypes = Self.supportedMetadataTypes.filter {
          availableTypes.contains($0)
        }
        self.metadataOutput = metadataOutput
      }

      self.session.commitConfiguration()
    }
  }

  private func replaceVideoDevice(
    _ device: AVCaptureDevice,
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self, !self.disposed else {
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
    let dimensions = Self.dimensions(for: device)
    let usesHevc = preferredVideoCodec.lowercased() == "hevc"
    return CameraInitializationDto(
      textureId: textureId,
      previewWidth: Int64(dimensions.width),
      previewHeight: Int64(dimensions.height),
      sensorOrientation: 90,
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
    finishCurrentWriter {}
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let codec: AVVideoCodecType =
      preferredVideoCodec.lowercased() == "hevc" ? .hevc : .h264
    let dimensions = Self.dimensions(for: videoDeviceInput?.device)
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: dimensions.width,
      AVVideoHeightKey: dimensions.height,
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
        kCVPixelBufferWidthKey as String: dimensions.width,
        kCVPixelBufferHeightKey as String: dimensions.height,
      ]
    )

    var audioInput: AVAssetWriterInput?
    if recordAudio {
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
    if let audioInput, writer.canAdd(audioInput) {
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
    self.writerSessionStarted = false
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
    audioInput.append(sampleBuffer)
  }

  private func finishCurrentWriter(completion: @escaping () -> Void) {
    guard let writer else {
      completion()
      return
    }
    let completedPath = currentPath
    let completedStartedAt = currentStartedAtMs
    let completedSegmentId = currentSegmentId
    let endedAt = Int64(Date().timeIntervalSince1970 * 1000)
    videoInput?.markAsFinished()
    audioInput?.markAsFinished()
    self.writer = nil
    self.videoInput = nil
    self.audioInput = nil
    self.pixelBufferAdaptor = nil
    self.currentPath = nil
    writerSessionStarted = false
    writer.finishWriting { [weak self] in
      guard let self else { return }
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
      completion()
    }
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
    position == .front ? frontDevices.first : backDevices.first
  }

  private static func zoomRatio(for device: AVCaptureDevice) -> Double {
    switch device.deviceType {
    case .builtInUltraWideCamera: return 0.5
    case .builtInTelephotoCamera: return 2.0
    default: return 1.0
    }
  }

  private static func dimensions(
    for device: AVCaptureDevice?
  ) -> CMVideoDimensions {
    guard let formatDescription = device?.activeFormat.formatDescription else {
      return CMVideoDimensions(width: 1920, height: 1080)
    }
    return CMVideoFormatDescriptionGetDimensions(formatDescription)
  }
}

/// iOS 前台订单接收：用本地 TCP 监听 5280，解析桌面端推送的
/// `POST /api/orderinfo` JSON 数组。仅支持 App 前台运行；退到后台
/// 后系统可能挂起监听，后续再单独评估后台方案。
private final class IosOrderReceiverHostApi: OrderReceiverHostApi {
  private let eventApi: OrderReceiverEventApi
  private let queue = DispatchQueue(label: "packingproof.order.receiver")
  private let storeLock = NSLock()
  private var ordersByTrackingNumber: [String: OrderInfoDto] = [:]
  private var serverSocket: Int32 = -1
  private var running = false
  private var backgroundDelivery = false
  private var lastError = ""

  init(eventApi: OrderReceiverEventApi) {
    self.eventApi = eventApi
  }

  deinit {
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
      throw pigeonError(lastError)
    }

    guard listen(socketHandle, 8) == 0 else {
      close(socketHandle)
      lastError = "订单接收服务监听失败"
      throw pigeonError(lastError)
    }

    serverSocket = socketHandle
    running = true
    lastError = ""
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
    let address = Self.currentPrivateIPv4() ?? ""
    return OrderReceiverStatusDto(
      running: running,
      ipAddress: address,
      url: running && !address.isEmpty ? "http://\(address):\(port)" : "",
      port: Int64(port),
      errorMessage: lastError
    )
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
          lastError = "接收电脑连接失败"
        }
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
        eventApi.orderInfoReceived(items: items) { _ in }
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

  private static func currentPrivateIPv4() -> String? {
    var interfacePointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfacePointer) == 0 else { return nil }
    defer { freeifaddrs(interfacePointer) }

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
      if isPrivateIPv4(ip) {
        return ip
      }
    }
    return nil
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
