import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import _MediaGenerationKit

/// Encodes a sequence of generated frames into an mp4 container using
/// `AVAssetWriter`. v0 supports H.264 and HEVC; webm/gif/frame_sequence are
/// deferred (see `VideoFormatAPI`). Bitrate formulas match
/// `DrawThingsCLI.swift:1907` upstream:
/// - H.264: `max(9.5 Mbps, width × height × 5 bits)`
/// - HEVC:  `max(7.5 Mbps, width × height × 4 bits)`
///
/// The writer must target a file URL, so we write to a temporary file, slurp
/// the bytes back, then unlink. Callers receive the encoded `Data` and base64
/// it for the JSON response.
enum VideoEncoder {
  static func encode(
    frames: [MediaGenerationPipeline.Result],
    fps: Int,
    format: VideoFormatAPI
  ) async throws -> Data {
    guard !frames.isEmpty else {
      throw EngineError.noImageProduced
    }
    let firstWidth = frames[0].width
    let firstHeight = frames[0].height
    let codec: AVVideoCodecType = (format == .mp4Hevc) ? .hevc : .h264
    let bitrate = bitrateForCodec(codec: codec, width: firstWidth, height: firstHeight)

    let scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dht-video-\(UUID().uuidString)", isDirectory: true)
    let tempURL = scratchDir.appendingPathComponent("output.mp4")
    let cleanup = { try? FileManager.default.removeItem(at: scratchDir) }
    do {
      try FileManager.default.createDirectory(
        at: scratchDir, withIntermediateDirectories: true)
    } catch {
      throw VideoEncodingError.writerInitFailed(
        "could not create scratch dir: \(error)")
    }

    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(url: tempURL, fileType: .mp4)
    } catch {
      cleanup()
      throw VideoEncodingError.writerInitFailed("\(error)")
    }

    let outputSettings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: firstWidth,
      AVVideoHeightKey: firstHeight,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate
      ],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = false

    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: firstWidth,
      kCVPixelBufferHeightKey as String: firstHeight,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input, sourcePixelBufferAttributes: attrs)

    guard writer.canAdd(input) else {
      cleanup()
      throw VideoEncodingError.writerInitFailed("writer cannot add video input")
    }
    writer.add(input)

    guard writer.startWriting() else {
      let err = writer.error
      cleanup()
      throw VideoEncodingError.writerInitFailed(
        "startWriting failed: \(err.map { "\($0)" } ?? "no underlying error")")
    }
    writer.startSession(atSourceTime: .zero)

    let timescale = Int32(max(fps, 1))
    do {
      for (i, frame) in frames.enumerated() {
        guard frame.width == firstWidth, frame.height == firstHeight else {
          throw VideoEncodingError.inconsistentFrameSize(
            index: i, expected: "\(firstWidth)×\(firstHeight)",
            got: "\(frame.width)×\(frame.height)")
        }
        let pixelBuffer = try makePixelBuffer(
          from: frame, width: firstWidth, height: firstHeight, scratchDir: scratchDir)
        // The writer flow controls via isReadyForMoreMediaData; spin (Task-yield)
        // until it accepts the next frame so we don't drop on bursts.
        while !input.isReadyForMoreMediaData {
          try await Task.sleep(nanoseconds: 5_000_000)  // 5ms
          try Task.checkCancellation()
        }
        let presentationTime = CMTime(value: CMTimeValue(i), timescale: timescale)
        if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
          let err = writer.error
          throw VideoEncodingError.appendFailed(
            index: i, detail: err.map { "\($0)" } ?? "adaptor.append returned false")
        }
      }
    } catch {
      writer.cancelWriting()
      cleanup()
      throw error
    }

    input.markAsFinished()
    await writer.finishWriting()

    if writer.status != .completed {
      let err = writer.error
      cleanup()
      throw VideoEncodingError.finalizationFailed(
        "writer status \(writer.status.rawValue): \(err.map { "\($0)" } ?? "unknown")")
    }

    let data: Data
    do {
      data = try Data(contentsOf: tempURL)
    } catch {
      cleanup()
      throw VideoEncodingError.finalizationFailed("read-back failed: \(error)")
    }
    cleanup()
    return data
  }

  /// Converts one `Result` (NHWC float tensor) into a `CVPixelBuffer` by way
  /// of PNG → CGImage → CGContext draw. The SDK's `MediaGenerationImageCodec`
  /// is `internal`, so we round-trip through `result.write(to:type:)` on a
  /// temp file to get PNG bytes. The temp file is created in a per-encode
  /// scratch directory the caller manages (passed in as `scratchDir`) and
  /// deleted right after the buffer is built.
  private static func makePixelBuffer(
    from frame: MediaGenerationPipeline.Result,
    width: Int,
    height: Int,
    scratchDir: URL
  ) throws -> CVPixelBuffer {
    let frameURL = scratchDir.appendingPathComponent("\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: frameURL) }
    do {
      try frame.write(to: frameURL, type: .png)
    } catch {
      throw VideoEncodingError.frameEncodeFailed("frame.write(.png) failed: \(error)")
    }
    let pngData: Data
    do {
      pngData = try Data(contentsOf: frameURL)
    } catch {
      throw VideoEncodingError.frameEncodeFailed("read-back of frame PNG failed: \(error)")
    }

    guard
      let source = CGImageSourceCreateWithData(pngData as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw VideoEncodingError.frameEncodeFailed("CGImage create failed")
    }

    let attrs: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      attrs as CFDictionary, &pb)
    guard status == kCVReturnSuccess, let buffer = pb else {
      throw VideoEncodingError.frameEncodeFailed("CVPixelBufferCreate status=\(status)")
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let baseAddress = CVPixelBufferGetBaseAddress(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo: UInt32 =
      CGImageAlphaInfo.premultipliedFirst.rawValue
      | CGBitmapInfo.byteOrder32Little.rawValue

    guard
      let ctx = CGContext(
        data: baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: colorSpace, bitmapInfo: bitmapInfo)
    else {
      throw VideoEncodingError.frameEncodeFailed("CGContext create failed")
    }
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }

  private static func bitrateForCodec(codec: AVVideoCodecType, width: Int, height: Int) -> Int {
    let pixelArea = width * height
    switch codec {
    case .h264:
      return max(9_500_000, pixelArea * 5)
    case .hevc:
      return max(7_500_000, pixelArea * 4)
    default:
      return 9_500_000
    }
  }
}

enum VideoEncodingError: Error {
  case writerInitFailed(String)
  case appendFailed(index: Int, detail: String)
  case finalizationFailed(String)
  case frameEncodeFailed(String)
  case inconsistentFrameSize(index: Int, expected: String, got: String)
}
