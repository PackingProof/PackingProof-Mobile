import CoreGraphics
import QuartzCore
import UIKit
import XCTest

final class IosWatermarkRasterTests: XCTestCase {
  func testNativeRasterKeepsChangingWatermarkUncroppedInAllOrientations()
    throws
  {
    let sourceSize = CGSize(width: 540, height: 960)
    let fixtures: [(name: String, transform: CGAffineTransform, expected: CGSize)] = [
      ("portrait", .identity, sourceSize),
      (
        "landscape-left",
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 960, ty: 0),
        CGSize(width: 960, height: 540)
      ),
      (
        "landscape-right",
        CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 540),
        CGSize(width: 960, height: 540)
      ),
    ]
    let timeline = IosWatermarkTimeline(
      startedAtMs: 1_767_268_800_000,
      trackingNumber: "TRACK-001",
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    for fixture in fixtures {
      let fontSize = max(35, min(61, fixture.expected.height * 0.032))
      let firstText = IosWatermarkStyle.attributedText(
        timeline.text(at: 0),
        fontSize: fontSize
      )
      let layout = IosWatermarkLayout.make(
        naturalSize: sourceSize,
        preferredTransform: fixture.transform,
        textSize: measuredSize(of: firstText)
      )
      XCTAssertEqual(layout.renderSize, fixture.expected, fixture.name)

      let firstPixels = try render(
        text: firstText,
        layout: layout,
        fixture: fixture.name
      )
      let secondPixels = try render(
        text: IosWatermarkStyle.attributedText(
          timeline.text(at: 1.25),
          fontSize: fontSize
        ),
        layout: layout,
        fixture: fixture.name
      )
      let firstWatermark = try XCTUnwrap(
        firstPixels.watermarkBounds(),
        "\(fixture.name) 首帧没有渲染水印像素"
      )
      let secondWatermark = try XCTUnwrap(
        secondPixels.watermarkBounds(),
        "\(fixture.name) 第二个时间点没有渲染水印像素"
      )
      assertWatermarkIsUncropped(
        firstWatermark,
        imageSize: fixture.expected,
        fixture: fixture.name
      )
      assertWatermarkIsUncropped(
        secondWatermark,
        imageSize: fixture.expected,
        fixture: fixture.name
      )
      XCTAssertGreaterThan(
        firstPixels.changedWatermarkPixels(comparedWith: secondPixels),
        20,
        "\(fixture.name) 水印在不同时刻没有产生可见变化"
      )
    }
  }

  private func measuredSize(of text: NSAttributedString) -> CGSize {
    let bounds = text.boundingRect(
      with: CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      ),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return CGSize(
      width: bounds.width.rounded(.up) + 12,
      height: bounds.height.rounded(.up) + 12
    )
  }

  private func render(
    text: NSAttributedString,
    layout: IosWatermarkLayout,
    fixture: String
  ) throws -> PixelSnapshot {
    let width = Int(layout.renderSize.width)
    let height = Int(layout.renderSize.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let context = CGContext(
          data: bytes.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else {
        return false
      }
      let parent = CALayer()
      parent.frame = CGRect(x: 0, y: 0, width: width, height: height)
      parent.backgroundColor = CGColor(
        red: 32 / 255,
        green: 96 / 255,
        blue: 160 / 255,
        alpha: 1
      )
      parent.addSublayer(
        IosWatermarkStyle.textLayer(
          text: text,
          frame: layout.textFrame,
          contentsScale: 1
        )
      )
      parent.render(in: context)
      return true
    }
    guard rendered else {
      throw WatermarkRasterTestError.cannotRender(fixture)
    }
    return PixelSnapshot(width: width, height: height, rgba: pixels)
  }

  private func assertWatermarkIsUncropped(
    _ watermark: PixelSnapshot.WatermarkBounds,
    imageSize: CGSize,
    fixture: String
  ) {
    XCTAssertGreaterThan(watermark.brightPixels, 40, fixture)
    XCTAssertGreaterThan(watermark.darkPixels, 40, fixture)
    XCTAssertGreaterThanOrEqual(watermark.bounds.minX, 8, fixture)
    XCTAssertGreaterThanOrEqual(watermark.bounds.minY, 8, fixture)
    XCTAssertLessThanOrEqual(watermark.bounds.maxX, imageSize.width - 8, fixture)
    XCTAssertLessThanOrEqual(watermark.bounds.maxY, imageSize.height - 8, fixture)
  }
}

private struct PixelSnapshot {
  struct WatermarkBounds {
    let bounds: CGRect
    let brightPixels: Int
    let darkPixels: Int
  }

  let width: Int
  let height: Int
  let rgba: [UInt8]

  func watermarkBounds() -> WatermarkBounds? {
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    var brightPixels = 0
    var darkPixels = 0
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        let bright = isBright(at: offset)
        let dark = isDark(at: offset)
        guard bright || dark else { continue }
        brightPixels += bright ? 1 : 0
        darkPixels += dark ? 1 : 0
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return WatermarkBounds(
      bounds: CGRect(
        x: CGFloat(minX),
        y: CGFloat(minY),
        width: CGFloat(maxX - minX + 1),
        height: CGFloat(maxY - minY + 1)
      ),
      brightPixels: brightPixels,
      darkPixels: darkPixels
    )
  }

  func changedWatermarkPixels(comparedWith other: PixelSnapshot) -> Int {
    guard width == other.width, height == other.height else { return 0 }
    var changed = 0
    for offset in stride(from: 0, to: rgba.count, by: 4) {
      let currentIsWatermark = isBright(at: offset) || isDark(at: offset)
      let otherIsWatermark = other.isBright(at: offset) || other.isDark(at: offset)
      guard currentIsWatermark || otherIsWatermark else { continue }
      let largestDifference = max(
        abs(Int(rgba[offset]) - Int(other.rgba[offset])),
        max(
          abs(Int(rgba[offset + 1]) - Int(other.rgba[offset + 1])),
          abs(Int(rgba[offset + 2]) - Int(other.rgba[offset + 2]))
        )
      )
      if largestDifference >= 60 { changed += 1 }
    }
    return changed
  }

  private func isBright(at offset: Int) -> Bool {
    rgba[offset] >= 210 && rgba[offset + 1] >= 210 && rgba[offset + 2] >= 210
  }

  private func isDark(at offset: Int) -> Bool {
    rgba[offset] <= 45 && rgba[offset + 1] <= 45 && rgba[offset + 2] <= 45
  }
}

private enum WatermarkRasterTestError: Error {
  case cannotRender(String)
}
