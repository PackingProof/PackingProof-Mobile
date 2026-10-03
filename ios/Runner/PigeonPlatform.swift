import AVFoundation
import AVKit
import CoreImage
import Darwin
import Flutter
import ImageIO
import Network
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

enum IosVideoCodecCapabilities {
  static let hasHevcDecoder = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
  static let hasAvcDecoder = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
  static let hasHevcEncoder = supportsEncoder(kCMVideoCodecType_HEVC)
  static let hasAvcEncoder = supportsEncoder(kCMVideoCodecType_H264)

  private static func supportsEncoder(_ codecType: CMVideoCodecType) -> Bool {
    VTCopySupportedPropertyDictionaryForEncoder(
      width: 1920,
      height: 1080,
      codecType: codecType,
      encoderSpecification: nil,
      encoderIDOut: nil,
      supportedPropertiesOut: nil
    ) == noErr
  }
}


final class PigeonPlatform {
  private static var cameraHost: IosCameraHostApi?
  private static var backupHost: IosBackupHostApi?
  private static var orderReceiverHost: IosOrderReceiverHostApi?
  private static var promptAudioHost: IosPromptAudioHost?
  private static var promptAudioChannel: FlutterMethodChannel?

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
    let audioSessionCoordinator = IosSharedAudioSessionCoordinator.shared
    AlertAudioSessionHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: IosAlertAudioSessionHostApi(
        audioSessionCoordinator: audioSessionCoordinator
      )
    )
    let backupEvents = BackupNativeEventApi(binaryMessenger: messenger)
    let backupHost = IosBackupHostApi(
      eventApi: backupEvents,
      hostForeground: UIApplication.shared.applicationState != .background
    )
    self.backupHost = backupHost
    BackupNativeHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: backupHost
    )
    let cameraHost = IosCameraHostApi(
      eventApi: CameraEventApi(binaryMessenger: messenger),
      textures: registrar.textures(),
      audioSessionCoordinator: audioSessionCoordinator
    )
    self.cameraHost = cameraHost
    CameraHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: cameraHost
    )
    let orderReceiverHost = IosOrderReceiverHostApi(
      eventApi: OrderReceiverEventApi(binaryMessenger: messenger)
    )
    self.orderReceiverHost = orderReceiverHost
    OrderReceiverHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: orderReceiverHost
    )
    let promptAudioHost = IosPromptAudioHost(
      audioSessionCoordinator: audioSessionCoordinator
    )
    self.promptAudioHost = promptAudioHost
    let promptAudioChannel = FlutterMethodChannel(
      name: "app.packingproof.mobile/prompt_audio",
      binaryMessenger: messenger
    )
    self.promptAudioChannel = promptAudioChannel
    promptAudioChannel.setMethodCallHandler(promptAudioHost.handle)
  }

  /// App 终止时必须在 Flutter 引擎销毁前同步停掉所有还会给 Dart 发消息的宿主。
  ///
  /// `FlutterViewController` 会在 `UIApplicationWillTerminateNotification` /
  /// `UISceneDidDisconnectNotification` 中销毁引擎；若相机回调仍调用
  /// `textureFrameAvailable`，会触发 use-after-free 崩溃；后台队列上迟到的
  /// 备份快照或订单推送则会撞上 `sendOnChannel:` 的
  /// “Sending a message before the FlutterEngine has been run.” 断言被中止
  /// （崩溃点 Bis-OzOmkFmwWGxbAUqzqG）。
  static func shutdownForTermination() {
    cameraHost?.prepareForTermination()
    backupHost?.prepareForTermination()
    orderReceiverHost?.prepareForTermination()
  }

  static func onHostForeground() {
    backupHost?.onHostForeground()
  }

  static func onHostBackground() {
    backupHost?.onHostBackground()
  }
}

private final class IosPromptAudioHost: NSObject {
  private var players: [String: AVAudioPlayer] = [:]
  private var completions: [String: FlutterResult] = [:]
  private var audioSessionKeys = Set<String>()
  private let audioSessionCoordinator: IosSharedAudioSessionCoordinator

  init(
    audioSessionCoordinator: IosSharedAudioSessionCoordinator = .shared
  ) {
    self.audioSessionCoordinator = audioSessionCoordinator
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "prepare":
      prepare(call, result: result)
    case "play":
      play(call, result: result)
    case "stop":
      do {
        try stop()
        result(nil)
      } catch {
        // broad-catch: 原生音频会话错误统一转换为 FlutterError
        result(FlutterError(
          code: "audio_session_release_failed",
          message: error.localizedDescription,
          details: nil
        ))
      }
    case "dispose":
      do {
        try dispose()
        result(nil)
      } catch {
        // broad-catch: 原生音频会话错误统一转换为 FlutterError
        result(FlutterError(
          code: "audio_session_release_failed",
          message: error.localizedDescription,
          details: nil
        ))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func prepare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let key = args["key"] as? String,
      let mimeType = args["mimeType"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "提示音参数无效", details: nil))
      return
    }
    let data: Data
    if let typed = args["bytes"] as? FlutterStandardTypedData {
      data = typed.data
    } else if let values = args["bytes"] as? [UInt8] {
      data = Data(values)
    } else {
      result(FlutterError(code: "bad_bytes", message: "提示音数据无效", details: nil))
      return
    }
    let fileExtension = mimeType.contains("wav") ? "wav" : "mp3"
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
    do {
      try data.write(to: fileURL)
      let player = try AVAudioPlayer(contentsOf: fileURL)
      player.prepareToPlay()
      players[key] = player
      result(nil)
    } catch {
      result(FlutterError(code: "prepare_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func play(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let key = args["key"] as? String,
      let player = players[key]
    else {
      result(FlutterError(code: "not_prepared", message: "提示音尚未准备好", details: nil))
      return
    }
    var addedAudioSessionKey = false
    do {
      if !audioSessionKeys.contains(key) {
        if audioSessionKeys.isEmpty {
          try audioSessionCoordinator.acquire(.prompt)
        }
        audioSessionKeys.insert(key)
        addedAudioSessionKey = true
      }
      player.currentTime = 0
      player.delegate = self
      completions[key] = result
      if !player.play() {
        completions.removeValue(forKey: key)
        try releaseAudioSession(for: key)
        result(FlutterError(code: "play_failed", message: "提示音播放失败", details: nil))
      }
    } catch {
      completions.removeValue(forKey: key)
      if addedAudioSessionKey {
        try? releaseAudioSession(for: key)
      }
      result(FlutterError(code: "play_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func stop() throws {
    for player in players.values {
      player.stop()
    }
    for completion in completions.values {
      completion(nil)
    }
    completions.removeAll()
    try releaseAllAudioSessions()
  }

  private func dispose() throws {
    try stop()
    players.removeAll()
  }

  private func releaseAudioSession(for key: String) throws {
    guard audioSessionKeys.contains(key) else { return }
    if audioSessionKeys.count == 1 {
      try audioSessionCoordinator.release(.prompt)
    }
    audioSessionKeys.remove(key)
  }

  private func releaseAllAudioSessions() throws {
    guard !audioSessionKeys.isEmpty else { return }
    try audioSessionCoordinator.release(.prompt)
    audioSessionKeys.removeAll()
  }
}

extension IosPromptAudioHost: AVAudioPlayerDelegate {
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard
      let entry = players.first(where: { $0.value === player }),
      let completion = completions.removeValue(forKey: entry.key)
    else {
      return
    }
    do {
      try releaseAudioSession(for: entry.key)
      completion(nil)
    } catch {
      // broad-catch: 原生音频会话错误统一转换为 FlutterError
      completion(FlutterError(
        code: "audio_session_release_failed",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }
}

func pigeonError(
  _ message: String,
  code: String = "ios_unavailable"
) -> PigeonError {
  PigeonError(code: code, message: message, details: nil)
}

private final class IosMediaProcessingHostApi: MediaProcessingHostApi {
  private let exportLock = NSLock()
  private var activeExportSessions: [String: AVAssetExportSession] = [:]
  private let core = IosMediaProcessingCore()

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
    let coreRequest = IosWatermarkExportRequest(
      inputPath: request.inputPath,
      outputPath: request.outputPath,
      startedAtMs: request.startedAtMs,
      trackingNumber: request.trackingNumber
    )
    core.applyWatermark(request: coreRequest) { result in
      switch result {
      case .success(let output):
        completion(.success(output.path))
      case .failure(let error as IosMediaProcessingCoreError):
        completion(
          .failure(pigeonError(error.message, code: error.code ?? "ios_unavailable"))
        )
      case .failure(let error) where iosWatermarkErrorIsInterrupted(error):
        completion(
          .failure(
            pigeonError(
              "水印导出被系统中断，返回前台后将自动重试",
              code: "watermark_interrupted"
            )
          )
        )
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func cancelWatermark(
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    core.cancelWatermark()
    completion(.success(()))
  }

  func exportRange(
    request: ExportRequest,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let input = URL(fileURLWithPath: request.inputPath)
      let output = URL(fileURLWithPath: request.outputPath)
      let asset = AVAsset(url: input)
      let policy = iosVideoExportPolicy(passthrough: request.passthrough)
      guard let session = AVAssetExportSession(
        asset: asset,
        presetName: policy.presetName
      ) else {
        completion(.failure(pigeonError("无法创建导出会话")))
        return
      }
      session.outputURL = output
      session.outputFileType = .mp4
      session.shouldOptimizeForNetworkUse = policy.optimizeForNetworkUse
      if policy.appliesRequestedTimeRange {
        session.timeRange = CMTimeRange(
          start: CMTime(value: Int64(request.startMs), timescale: 1000),
          duration: CMTime(
            value: Int64(request.endMs - request.startMs),
            timescale: 1000
          )
        )
      }
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
    let hasHevc = IosVideoCodecCapabilities.hasHevcDecoder
    let hasAvc = IosVideoCodecCapabilities.hasAvcDecoder
    let hasHevcEncoder = IosVideoCodecCapabilities.hasHevcEncoder
    let hasAvcEncoder = IosVideoCodecCapabilities.hasAvcEncoder
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
          hasHevcEncoder: hasHevcEncoder,
          hasAvcEncoder: hasAvcEncoder,
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

final class IosAlertAudioSessionHostApi: AlertAudioSessionHostApi {
  private let audioSessionCoordinator: IosSharedAudioSessionCoordinator
  private var audioSessionHeld = false

  init(
    audioSessionCoordinator: IosSharedAudioSessionCoordinator = .shared
  ) {
    self.audioSessionCoordinator = audioSessionCoordinator
  }

  func beginSession(completion: @escaping (Result<Void, Error>) -> Void) {
    do {
      if !audioSessionHeld {
        try audioSessionCoordinator.acquire(.maxVolume)
        audioSessionHeld = true
      }
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func endSession(completion: @escaping (Result<Void, Error>) -> Void) {
    do {
      if audioSessionHeld {
        try audioSessionCoordinator.release(.maxVolume)
        audioSessionHeld = false
      }
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
