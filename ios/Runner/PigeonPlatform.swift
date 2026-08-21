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

final class PigeonPlatform {
  private static var cameraHost: IosCameraHostApi?
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
    let promptAudioHost = IosPromptAudioHost()
    self.promptAudioHost = promptAudioHost
    let promptAudioChannel = FlutterMethodChannel(
      name: "app.packingproof.mobile/prompt_audio",
      binaryMessenger: messenger
    )
    self.promptAudioChannel = promptAudioChannel
    promptAudioChannel.setMethodCallHandler(promptAudioHost.handle)
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

private final class IosPromptAudioHost: NSObject {
  private var players: [String: AVAudioPlayer] = [:]
  private var completions: [String: FlutterResult] = [:]

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "prepare":
      prepare(call, result: result)
    case "play":
      play(call, result: result)
    case "stop":
      stop()
      result(nil)
    case "dispose":
      dispose()
      result(nil)
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
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .videoRecording,
        options: [.defaultToSpeaker]
      )
      try session.setActive(true)
      player.currentTime = 0
      player.delegate = self
      completions[key] = result
      if !player.play() {
        completions.removeValue(forKey: key)
        result(FlutterError(code: "play_failed", message: "提示音播放失败", details: nil))
      }
    } catch {
      completions.removeValue(forKey: key)
      result(FlutterError(code: "play_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func stop() {
    for player in players.values {
      player.stop()
    }
    for completion in completions.values {
      completion(nil)
    }
    completions.removeAll()
  }

  private func dispose() {
    stop()
    players.removeAll()
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
    completion(nil)
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
