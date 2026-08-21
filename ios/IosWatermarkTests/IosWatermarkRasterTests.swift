import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore
import UIKit
import XCTest

final class IosWatermarkRasterTests: XCTestCase {
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
