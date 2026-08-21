import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore
import UIKit
import XCTest

final class IosWatermarkRasterTests: XCTestCase {
  func testAttributedTextUsesFixedPreviewLineHeight() throws {
    let fontSize: CGFloat = 40
    let text = IosWatermarkStyle.attributedText(
      "2026/08/21 12:34:56\nTRACK-001",
      fontSize: fontSize
    )
    let attributes = text.attributes(at: 0, effectiveRange: nil)
    let paragraphStyle = try XCTUnwrap(
      attributes[.paragraphStyle] as? NSParagraphStyle
    )
    let font = try XCTUnwrap(attributes[.font] as? UIFont)

    XCTAssertEqual(paragraphStyle.minimumLineHeight, fontSize * 1.25)
    XCTAssertEqual(paragraphStyle.maximumLineHeight, fontSize * 1.25)
    XCTAssertEqual(font.pointSize, fontSize)
    XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    XCTAssertEqual(attributes[.strokeWidth] as? Int, -10)
  }

  func testVideoTextLayerUsesFinalPixelScale() {
    let layer = IosWatermarkStyle.textLayer(
      text: IosWatermarkStyle.attributedText("watermark", fontSize: 35),
      frame: CGRect(x: 0, y: 0, width: 240, height: 60)
    )

    XCTAssertEqual(IosWatermarkStyle.videoContentsScale, 1)
    XCTAssertEqual(layer.contentsScale, 1)
  }

  func testInterruptedClassificationFindsNestedAvFoundationError() {
    let interrupted = NSError(
      domain: AVFoundationErrorDomain,
      code: AVError.Code.operationInterrupted.rawValue
    )
    let wrapper = NSError(
      domain: "PackingProof.WatermarkTests",
      code: 1,
      userInfo: [NSUnderlyingErrorKey: interrupted]
    )

    XCTAssertTrue(iosWatermarkErrorIsInterrupted(wrapper))
    XCTAssertFalse(
      iosWatermarkErrorIsInterrupted(
        NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue)
      )
    )
  }

  func testRecordingTransformKeepsPortraitBuffersAndMapsSemanticDirections() {
    let cases: [(name: String, radians: CGFloat, displayedSize: CGSize)] = [
      ("portrait", 0, CGSize(width: 1080, height: 1920)),
      ("landscapeLeft", .pi / 2, CGSize(width: 1920, height: 1080)),
      ("landscapeRight", -.pi / 2, CGSize(width: 1920, height: 1080)),
    ]

    for fixture in cases {
      let transform = iosRecordingTransform(for: fixture.name)
      let displayedBounds = CGRect(
        origin: .zero,
        size: CGSize(width: 1080, height: 1920)
      ).applying(transform).standardized
      XCTAssertEqual(transform.a, cos(fixture.radians), accuracy: 0.0001)
      XCTAssertEqual(transform.b, sin(fixture.radians), accuracy: 0.0001)
      XCTAssertEqual(transform.c, -sin(fixture.radians), accuracy: 0.0001)
      XCTAssertEqual(transform.d, cos(fixture.radians), accuracy: 0.0001)
      XCTAssertEqual(displayedBounds.origin, .zero, fixture.name)
      XCTAssertEqual(displayedBounds.size, fixture.displayedSize, fixture.name)
      XCTAssertEqual(
        IosWatermarkLayout.resolvedRenderSize(
          naturalSize: CGSize(width: 1080, height: 1920),
          preferredTransform: transform
        ),
        fixture.displayedSize,
        fixture.name
      )
    }
  }

  func testLiveRendererPlacesSamePixelsAtOutputTopCenterInAllOrientations()
    throws
  {
    let sourceWidth = 1080
    let sourceHeight = 1920
    let date = Date(timeIntervalSince1970: 1_776_768_896)
    for orientation in ["portrait", "landscapeLeft", "landscapeRight"] {
      var pixelBuffer: CVPixelBuffer?
      XCTAssertEqual(
        CVPixelBufferCreate(
          kCFAllocatorDefault,
          sourceWidth,
          sourceHeight,
          kCVPixelFormatType_32BGRA,
          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
          &pixelBuffer
        ),
        kCVReturnSuccess
      )
      let buffer = try XCTUnwrap(pixelBuffer)
      fill(buffer, blue: 80, green: 96, red: 112)
      try IosLiveWatermarkRenderer(timeZone: TimeZone(secondsFromGMT: 0)!).apply(
        to: buffer,
        orientation: orientation,
        trackingNumber: "TRACK-001",
        date: date
      )
      let bounds = try XCTUnwrap(
        changedOutputBounds(
          buffer,
          background: (80, 96, 112),
          orientation: orientation
        )
      )
      let output = IosLiveWatermarkGeometry.outputSize(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        orientation: orientation
      )
      XCTAssertEqual(bounds.midX, output.width / 2, accuracy: 2, orientation)
      XCTAssertGreaterThanOrEqual(bounds.minY, output.height * 0.1, orientation)
      XCTAssertLessThan(bounds.minY, output.height * 0.1 + 24, orientation)
      XCTAssertGreaterThan(bounds.brightPixels, 40, orientation)
      XCTAssertGreaterThan(bounds.darkPixels, 40, orientation)
    }
  }

  func testLiveWatermarkRasterOriginIsExactlyTopTenPercentAndCentered() {
    for output in [
      CGSize(width: 1080, height: 1920),
      CGSize(width: 1920, height: 1080),
    ] {
      let raster = CGSize(width: 420, height: 120)
      let origin = IosLiveWatermarkGeometry.outputOrigin(
        outputSize: output,
        rasterSize: raster
      )
      XCTAssertEqual(origin.x + raster.width / 2, output.width / 2)
      XCTAssertEqual(origin.y, output.height * 0.1)
    }
  }

  func testNativeRasterKeepsChangingWatermarkUncroppedInAllOrientations()
    throws
  {
    let sourceSize = CGSize(width: 1080, height: 1920)
    let fixtures: [(name: String, transform: CGAffineTransform, expected: CGSize)] = [
      ("portrait", iosRecordingTransform(for: "portrait"), sourceSize),
      (
        "landscape-left",
        iosRecordingTransform(for: "landscapeLeft"),
        CGSize(width: 1920, height: 1080)
      ),
      (
        "landscape-right",
        iosRecordingTransform(for: "landscapeRight"),
        CGSize(width: 1920, height: 1080)
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
          frame: layout.textFrame
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

  private func fill(
    _ pixelBuffer: CVPixelBuffer,
    blue: UInt8,
    green: UInt8,
    red: UInt8
  ) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(
      to: UInt8.self
    )
    for y in 0..<height {
      for x in 0..<width {
        let offset = y * bytesPerRow + x * 4
        bytes[offset] = blue
        bytes[offset + 1] = green
        bytes[offset + 2] = red
        bytes[offset + 3] = 255
      }
    }
  }

  private func changedOutputBounds(
    _ pixelBuffer: CVPixelBuffer,
    background: (UInt8, UInt8, UInt8),
    orientation: String
  ) -> (midX: CGFloat, minY: CGFloat, brightPixels: Int, darkPixels: Int)? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
    let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(
      to: UInt8.self
    )
    var minX = Int.max
    var maxX = Int.min
    var minY = Int.max
    var brightPixels = 0
    var darkPixels = 0
    for sourceY in 0..<sourceHeight {
      for sourceX in 0..<sourceWidth {
        let offset = sourceY * bytesPerRow + sourceX * 4
        let blue = bytes[offset]
        let green = bytes[offset + 1]
        let red = bytes[offset + 2]
        guard (blue, green, red) != background else { continue }
        let output: (x: Int, y: Int) = switch orientation {
        case "landscapeLeft":
          (sourceHeight - 1 - sourceY, sourceX)
        case "landscapeRight":
          (sourceY, sourceWidth - 1 - sourceX)
        default:
          (sourceX, sourceY)
        }
        minX = min(minX, output.x)
        maxX = max(maxX, output.x)
        minY = min(minY, output.y)
        let luminance = (Int(red) + Int(green) + Int(blue)) / 3
        brightPixels += luminance > 180 ? 1 : 0
        darkPixels += luminance < 45 ? 1 : 0
      }
    }
    guard minX <= maxX else { return nil }
    return (
      midX: CGFloat(minX + maxX) / 2,
      minY: CGFloat(minY),
      brightPixels: brightPixels,
      darkPixels: darkPixels
    )
  }
}

final class IosMediaProcessingCoreTests: XCTestCase {
  func testInvalidInputKeepsFailureMessageAndRemovesStaleOutput() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("watermark-core-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let output = root.appendingPathComponent("output.mp4")
    try Data("stale-output".utf8).write(to: output)
    let completed = expectation(description: "watermark core completed")
    var received: Result<URL, Error>?

    IosMediaProcessingCore().applyWatermark(
      request: IosWatermarkExportRequest(
        inputPath: root.appendingPathComponent("missing.mp4").path,
        outputPath: output.path,
        startedAtMs: 0,
        trackingNumber: ""
      )
    ) { result in
      received = result
      completed.fulfill()
    }

    wait(for: [completed], timeout: 5)
    guard case .failure(let error as IosMediaProcessingCoreError) = received else {
      return XCTFail("无效输入应返回水印 Core 错误")
    }
    XCTAssertEqual(error.message, "无法读取录像视频轨道")
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
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
