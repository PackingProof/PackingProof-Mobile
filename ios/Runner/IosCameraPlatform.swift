import AVFoundation
import Flutter
import UIKit

/// iOS 连续相机原生实现：
/// 保持一个 `AVCaptureSession` 常开，用 `AVAssetWriter` 按单号轮换输出文件，
/// 不重启预览，达到接近 Android 连续录像的体验。
final class IosCameraHostApi:
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
  private var recordingOrientationName = "portrait"
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

  private func captureVideoOrientation() -> AVCaptureVideoOrientation {
    switch recordingOrientationName {
    case "landscapeLeft": return .landscapeLeft
    case "landscapeRight": return .landscapeRight
    default: return .portrait
    }
  }

  func initialize(
    request: CameraInitializeRequest,
    completion: @escaping (Result<CameraInitializationDto, Error>) -> Void
  ) {
    preferredVideoCodec = request.videoCodec
    recordingSpecName = request.recordingSpec
    recordingOrientationName = ["landscapeLeft", "landscapeRight"].contains(request.recordingOrientation)
      ? request.recordingOrientation : "portrait"
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
          connection.videoOrientation = captureVideoOrientation()
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
          connection.videoOrientation = captureVideoOrientation()
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
