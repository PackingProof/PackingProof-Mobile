import Foundation
import QuartzCore
import UIKit

/// 保持固定 1080x1920 竖屏采集缓冲不变，仅用 MP4 轨道元数据表达最终录像方向。
func iosRecordingTransform(for recordingOrientation: String) -> CGAffineTransform {
  switch recordingOrientation {
  case "landscapeLeft":
    return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1920, ty: 0)
  case "landscapeRight":
    return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1080)
  default:
    return .identity
  }
}

struct IosWatermarkTimeline {
  let startedAtMs: Int64
  let trackingNumber: String
  private let formatter: DateFormatter

  init(
    startedAtMs: Int64,
    trackingNumber: String,
    timeZone: TimeZone = .current
  ) {
    self.startedAtMs = startedAtMs
    self.trackingNumber = trackingNumber
    formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
  }

  func text(at compositionSeconds: Double) -> String {
    let elapsedMilliseconds = Int64(max(0, compositionSeconds) * 1_000)
    let date = Date(
      timeIntervalSince1970: Double(startedAtMs + elapsedMilliseconds) / 1_000
    )
    let timestamp = formatter.string(from: date)
    return trackingNumber.isEmpty
      ? timestamp
      : "\(timestamp)\n\(trackingNumber)"
  }

  func keyframeSeconds(duration: Double) -> [Double] {
    guard duration.isFinite, duration > 0 else { return [0] }
    let lastWholeSecond = Int(duration.rounded(.down))
    var seconds = (0...lastWholeSecond).map(Double.init)
    if seconds.last != duration {
      seconds.append(duration)
    }
    return seconds
  }
}

struct IosWatermarkLayout {
  let renderSize: CGSize
  let textFrame: CGRect

  static func make(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform,
    textSize: CGSize,
    topFraction: CGFloat = 0.1
  ) -> IosWatermarkLayout {
    let renderSize = resolvedRenderSize(
      naturalSize: naturalSize,
      preferredTransform: preferredTransform
    )
    let availableWidth = max(1, renderSize.width)
    let availableHeight = max(1, renderSize.height)
    let width = min(textSize.width, availableWidth)
    let height = min(textSize.height, availableHeight)
    return IosWatermarkLayout(
      renderSize: renderSize,
      textFrame: CGRect(
        x: (renderSize.width - width) / 2,
        y: max(
          0,
          renderSize.height - renderSize.height * topFraction - height
        ),
        width: width,
        height: height
      )
    )
  }

  static func resolvedRenderSize(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform
  ) -> CGSize {
    let transformedBounds = CGRect(origin: .zero, size: naturalSize)
      .applying(preferredTransform)
      .standardized
    return CGSize(
      width: transformedBounds.width.rounded(.up),
      height: transformedBounds.height.rounded(.up)
    )
  }
}

struct IosWatermarkStyle {
  /// Core Animation 水印图层使用最终视频像素坐标，禁止跟随设备屏幕倍率二次缩放。
  static let videoContentsScale: CGFloat = 1

  static func attributedText(
    _ value: String,
    fontSize: CGFloat
  ) -> NSAttributedString {
    let paragraphStyle = NSMutableParagraphStyle()
    let lineHeight = fontSize * 1.25
    paragraphStyle.minimumLineHeight = lineHeight
    paragraphStyle.maximumLineHeight = lineHeight
    return NSAttributedString(
      string: value,
      attributes: [
        .font: UIFont.boldSystemFont(ofSize: fontSize),
        .foregroundColor: UIColor.white,
        .strokeColor: UIColor.black,
        .strokeWidth: -10,
        .paragraphStyle: paragraphStyle,
      ]
    )
  }

  static func textLayer(
    text: NSAttributedString,
    frame: CGRect,
    contentsScale: CGFloat = videoContentsScale
  ) -> CATextLayer {
    let layer = CATextLayer()
    layer.string = text
    layer.alignmentMode = .center
    layer.contentsScale = contentsScale
    layer.frame = frame
    return layer
  }
}

enum IosLiveWatermarkError: Error {
  case unsupportedPixelFormat
  case pixelBufferLockFailed(CVReturn)
  case missingBaseAddress
  case rasterizationFailed
}

struct IosLiveWatermarkGeometry {
  static func outputSize(
    sourceWidth: Int,
    sourceHeight: Int,
    orientation: String
  ) -> CGSize {
    if orientation == "landscapeLeft" || orientation == "landscapeRight" {
      return CGSize(width: sourceHeight, height: sourceWidth)
    }
    return CGSize(width: sourceWidth, height: sourceHeight)
  }

  static func sourcePixel(
    outputX: Int,
    outputY: Int,
    sourceWidth: Int,
    sourceHeight: Int,
    orientation: String
  ) -> (x: Int, y: Int) {
    switch orientation {
    case "landscapeLeft":
      return (outputY, sourceHeight - 1 - outputX)
    case "landscapeRight":
      return (sourceWidth - 1 - outputY, outputX)
    default:
      return (outputX, outputY)
    }
  }

  static func outputOrigin(outputSize: CGSize, rasterSize: CGSize) -> CGPoint {
    CGPoint(
      x: max(0, (outputSize.width - rasterSize.width) / 2),
      y: min(
        max(0, outputSize.height * 0.1),
        max(0, outputSize.height - rasterSize.height)
      )
    )
  }
}

private struct IosLiveWatermarkRaster {
  let width: Int
  let height: Int
  let bgra: [UInt8]
}

/// 每秒只排版并栅格化一次水印，其余帧复用同一透明 BGRA 位图。
/// 位图先绘制黑色粗字，再绘制白色填充，白色会盖住描边的内半圈。
final class IosLiveWatermarkRenderer {
  private let formatter: DateFormatter
  private var cachedSecond: Int64?
  private var cachedTrackingNumber = ""
  private var cachedOutputSize = CGSize.zero
  private var cachedRaster: IosLiveWatermarkRaster?

  init(timeZone: TimeZone = .current) {
    formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
  }

  func apply(
    to pixelBuffer: CVPixelBuffer,
    orientation: String,
    trackingNumber: String,
    date: Date = Date()
  ) throws {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
      throw IosLiveWatermarkError.unsupportedPixelFormat
    }
    let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
    let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
    let outputSize = IosLiveWatermarkGeometry.outputSize(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      orientation: orientation
    )
    let second = Int64(date.timeIntervalSince1970.rounded(.down))
    if cachedSecond != second ||
      cachedTrackingNumber != trackingNumber ||
      cachedOutputSize != outputSize
    {
      cachedRaster = try makeRaster(
        text: watermarkText(date: date, trackingNumber: trackingNumber),
        outputSize: outputSize
      )
      cachedSecond = second
      cachedTrackingNumber = trackingNumber
      cachedOutputSize = outputSize
    }
    guard let raster = cachedRaster else {
      throw IosLiveWatermarkError.rasterizationFailed
    }
    try blend(
      raster,
      into: pixelBuffer,
      outputSize: outputSize,
      orientation: orientation
    )
  }

  func reset() {
    cachedSecond = nil
    cachedTrackingNumber = ""
    cachedOutputSize = .zero
    cachedRaster = nil
  }

  private func watermarkText(date: Date, trackingNumber: String) -> String {
    let timestamp = formatter.string(from: date)
    return trackingNumber.isEmpty ? timestamp : "\(timestamp)\n\(trackingNumber)"
  }

  private func makeRaster(
    text: String,
    outputSize: CGSize
  ) throws -> IosLiveWatermarkRaster {
    let fontSize = max(35, min(61, outputSize.height * 0.032))
    let font = UIFont.boldSystemFont(ofSize: fontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.minimumLineHeight = fontSize * 1.25
    paragraph.maximumLineHeight = fontSize * 1.25
    let measurement = NSAttributedString(
      string: text,
      attributes: [.font: font, .paragraphStyle: paragraph]
    ).boundingRect(
      with: CGSize(
        width: max(1, outputSize.width),
        height: CGFloat.greatestFiniteMagnitude
      ),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    let strokeWidth = fontSize * 0.1
    let padding = ceil(strokeWidth + 3)
    let width = max(1, Int(ceil(measurement.width + padding * 2)))
    let height = max(1, Int(ceil(measurement.height + padding * 2)))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(
      size: CGSize(width: width, height: height),
      format: format
    )
    let image = renderer.image { _ in
      let rect = CGRect(
        x: padding,
        y: padding,
        width: CGFloat(width) - padding * 2,
        height: CGFloat(height) - padding * 2
      )
      let outline = NSAttributedString(
        string: text,
        attributes: [
          .font: font,
          .foregroundColor: UIColor.black,
          .strokeColor: UIColor.black,
          .strokeWidth: -10,
          .paragraphStyle: paragraph,
        ]
      )
      outline.draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
      let fill = NSAttributedString(
        string: text,
        attributes: [
          .font: font,
          .foregroundColor: UIColor.white,
          .paragraphStyle: paragraph,
        ]
      )
      fill.draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
    }
    guard let cgImage = image.cgImage else {
      throw IosLiveWatermarkError.rasterizationFailed
    }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(
        data: bytes.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
          CGImageAlphaInfo.premultipliedFirst.rawValue
      ) else {
        return false
      }
      context.translateBy(x: 0, y: CGFloat(height))
      context.scaleBy(x: 1, y: -1)
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else {
      throw IosLiveWatermarkError.rasterizationFailed
    }
    return IosLiveWatermarkRaster(width: width, height: height, bgra: pixels)
  }

  private func blend(
    _ raster: IosLiveWatermarkRaster,
    into pixelBuffer: CVPixelBuffer,
    outputSize: CGSize,
    orientation: String
  ) throws {
    let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
    let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
    let outputWidth = Int(outputSize.width)
    let outputHeight = Int(outputSize.height)
    let origin = IosLiveWatermarkGeometry.outputOrigin(
      outputSize: outputSize,
      rasterSize: CGSize(width: raster.width, height: raster.height)
    )
    let originX = Int(origin.x.rounded(.down))
    let originY = Int(origin.y.rounded(.down))
    let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockResult == kCVReturnSuccess else {
      throw IosLiveWatermarkError.pixelBufferLockFailed(lockResult)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw IosLiveWatermarkError.missingBaseAddress
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let destination = baseAddress.assumingMemoryBound(to: UInt8.self)
    raster.bgra.withUnsafeBytes { sourceBytes in
      guard let source = sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return
      }
      for rasterY in 0..<raster.height {
        let outputY = originY + rasterY
        guard outputY >= 0, outputY < outputHeight else { continue }
        for rasterX in 0..<raster.width {
          let outputX = originX + rasterX
          guard outputX >= 0, outputX < outputWidth else { continue }
          let sourceOffset = (rasterY * raster.width + rasterX) * 4
          let alpha = Int(source[sourceOffset + 3])
          if alpha == 0 { continue }
          let mapped = IosLiveWatermarkGeometry.sourcePixel(
            outputX: outputX,
            outputY: outputY,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            orientation: orientation
          )
          guard mapped.x >= 0, mapped.x < sourceWidth,
                mapped.y >= 0, mapped.y < sourceHeight else {
            continue
          }
          let destinationOffset = mapped.y * bytesPerRow + mapped.x * 4
          let inverseAlpha = 255 - alpha
          for channel in 0..<3 {
            let blended = Int(source[sourceOffset + channel]) +
              (Int(destination[destinationOffset + channel]) * inverseAlpha + 127) / 255
            destination[destinationOffset + channel] = UInt8(min(255, blended))
          }
          destination[destinationOffset + 3] = 255
        }
      }
    }
  }
}
