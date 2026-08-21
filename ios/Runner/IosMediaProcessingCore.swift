import AVFoundation
import Foundation
import QuartzCore

struct IosWatermarkExportRequest {
  let inputPath: String
  let outputPath: String
  let startedAtMs: Int64
  let trackingNumber: String
}

struct IosMediaProcessingCoreError: Error {
  let message: String
  let code: String?

  init(message: String, code: String? = nil) {
    self.message = message
    self.code = code
  }
}

func iosWatermarkErrorIsInterrupted(_ error: Error?) -> Bool {
  guard let error else { return false }
  var pending: [NSError] = [error as NSError]
  var visited = Set<ObjectIdentifier>()
  while let current = pending.popLast() {
    let identity = ObjectIdentifier(current)
    if !visited.insert(identity).inserted { continue }
    if current.domain == AVFoundationErrorDomain,
      current.code == AVError.Code.operationInterrupted.rawValue
    {
      return true
    }
    if let underlying = current.userInfo[NSUnderlyingErrorKey] as? Error {
      pending.append(underlying as NSError)
    }
  }
  return false
}

final class IosMediaProcessingCore {
  func applyWatermark(
    request: IosWatermarkExportRequest,
    completion: @escaping (Result<URL, Error>) -> Void
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
          throw IosMediaProcessingCoreError(message: "无法读取录像视频轨道")
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

        let renderSize = IosWatermarkLayout.resolvedRenderSize(
          naturalSize: sourceVideo.naturalSize,
          preferredTransform: sourceVideo.preferredTransform
        )
        let fontSize = max(35, min(61, renderSize.height * 0.032))
        let timeline = IosWatermarkTimeline(
          startedAtMs: request.startedAtMs,
          trackingNumber: request.trackingNumber
        )
        let firstText = IosWatermarkStyle.attributedText(
          timeline.text(at: 0),
          fontSize: fontSize
        )
        let textBounds = firstText.boundingRect(
          with: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
          ),
          options: [.usesLineFragmentOrigin, .usesFontLeading],
          context: nil
        )
        let layout = IosWatermarkLayout.make(
          naturalSize: sourceVideo.naturalSize,
          preferredTransform: sourceVideo.preferredTransform,
          textSize: CGSize(
            width: textBounds.width.rounded(.up) + 12,
            height: textBounds.height.rounded(.up) + 12
          )
        )
        let width = layout.renderSize.width
        let height = layout.renderSize.height
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

        let text = IosWatermarkStyle.textLayer(
          text: firstText,
          frame: layout.textFrame
        )
        let duration = asset.duration.seconds.isFinite
          ? max(0, asset.duration.seconds)
          : 0
        let keyframeSeconds = timeline.keyframeSeconds(duration: duration)
        if duration > 0, keyframeSeconds.count > 1 {
          let animation = CAKeyframeAnimation(keyPath: "string")
          animation.values = keyframeSeconds.map {
            IosWatermarkStyle.attributedText(
              timeline.text(at: $0),
              fontSize: fontSize
            )
          }
          animation.keyTimes = keyframeSeconds.map {
            NSNumber(value: min(1, $0 / duration))
          }
          animation.duration = duration
          animation.beginTime = AVCoreAnimationBeginTimeAtZero
          animation.calculationMode = .discrete
          animation.isRemovedOnCompletion = false
          animation.fillMode = .forwards
          text.add(animation, forKey: "watermarkText")
        }
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
          throw IosMediaProcessingCoreError(message: "无法创建水印导出会话")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.exportAsynchronously {
          switch session.status {
          case .completed:
            do {
              let attributes = try FileManager.default.attributesOfItem(
                atPath: output.path
              )
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
              let outputAsset = AVAsset(url: output)
              let duration = outputAsset.duration.seconds
              guard fileSize > 0,
                !outputAsset.tracks(withMediaType: .video).isEmpty,
                duration.isFinite,
                duration > 0
              else {
                throw IosMediaProcessingCoreError(
                  message: "水印成片校验失败，原片已保留"
                )
              }
              completion(.success(output))
            } catch {
              try? FileManager.default.removeItem(at: output)
              completion(.failure(error))
            }
          case .failed:
            completion(
              .failure(
                session.error
                  ?? IosMediaProcessingCoreError(message: "水印视频生成失败")
              )
            )
          case .cancelled:
            completion(
              .failure(
                IosMediaProcessingCoreError(
                  message: "水印导出被系统中断，返回前台后将自动重试",
                  code: "watermark_interrupted"
                )
              )
            )
          default:
            completion(
              .failure(IosMediaProcessingCoreError(message: "水印视频生成失败"))
            )
          }
        }
      } catch {
        completion(.failure(error))
      }
    }
  }
}
