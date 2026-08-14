import AVFoundation
import Flutter

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
    completion(.success(nil))
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
    completion(.failure(pigeonError("iOS 分享剪辑移植尚未完成")))
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
    completion(.success(nil))
  }

  func getVideoDecodeSupport(
    completion: @escaping (Result<VideoDecodeSupportDto?, Error>) -> Void
  ) {
    completion(.success(nil))
  }

  func openWithSystemPlayer(
    path: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    completion(.failure(pigeonError("iOS 系统播放器移植尚未完成")))
  }
}

private final class IosAlertAudioSessionHostApi: AlertAudioSessionHostApi {
  func beginSession(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.success(()))
  }

  func endSession(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.success(()))
  }

  func disable(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.success(()))
  }

  func boost(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.success(()))
  }
}
