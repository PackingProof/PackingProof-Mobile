import Foundation
import QuartzCore
import UIKit

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
      : "\(timestamp)\nOrder:\(trackingNumber)"
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
    margin: CGFloat = 18
  ) -> IosWatermarkLayout {
    let renderSize = resolvedRenderSize(
      naturalSize: naturalSize,
      preferredTransform: preferredTransform
    )
    let availableWidth = max(1, renderSize.width - margin * 2)
    let availableHeight = max(1, renderSize.height - margin * 2)
    return IosWatermarkLayout(
      renderSize: renderSize,
      textFrame: CGRect(
        x: max(margin, renderSize.width - textSize.width - margin),
        y: max(margin, renderSize.height - textSize.height - margin),
        width: min(textSize.width, availableWidth),
        height: min(textSize.height, availableHeight)
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
  static func attributedText(
    _ value: String,
    fontSize: CGFloat
  ) -> NSAttributedString {
    NSAttributedString(
      string: value,
      attributes: [
        .font: UIFont.boldSystemFont(ofSize: fontSize),
        .foregroundColor: UIColor.white,
        .strokeColor: UIColor.black,
        .strokeWidth: -10,
      ]
    )
  }

  static func textLayer(
    text: NSAttributedString,
    frame: CGRect,
    contentsScale: CGFloat
  ) -> CATextLayer {
    let layer = CATextLayer()
    layer.string = text
    layer.alignmentMode = .right
    layer.contentsScale = contentsScale
    layer.frame = frame
    return layer
  }
}
