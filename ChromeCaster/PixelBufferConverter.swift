//
//  PixelBufferConverter.swift
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

enum PixelBufferConverter {
    /// Default until `configureStreamDimensions` runs (e.g. before `SCStream` starts).
    private static let defaultStreamWidth = 960
    private static let defaultStreamHeight = 540

    /// Target frame rate (must match `SCStreamConfiguration.minimumFrameInterval` and FFmpeg `-framerate`).
    static let streamFPS = 30

    /// FFmpeg `-pix_fmt` for `rawvideo` stdin (packed NV12 @ output width×height).
    static let ffmpegRawVideoPixFmt = "nv12"

    private static let dimLock = NSLock()
    private static var _streamWidth = defaultStreamWidth
    private static var _streamHeight = defaultStreamHeight

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// Reused NV12 buffer sized to the current stream dimensions (serial video ingress queue).
    private static var streamSizedNV12Buffer: CVPixelBuffer?

    /// Width/height FFmpeg and the scaler target; set before `SCStream` starts (`configureStreamDimensions`).
    static var streamWidth: Int {
        dimLock.lock()
        defer { dimLock.unlock() }
        return _streamWidth
    }

    static var streamHeight: Int {
        dimLock.lock()
        defer { dimLock.unlock() }
        return _streamHeight
    }

    /// Aligns capture, Core Image output, and FFmpeg `-video_size`. Must run on the same thread order as today: before `SCStream.startCapture` and before `ffmpeg` spawn.
    static func configureStreamDimensions(width: Int, height: Int) {
        let w = makeEven(clamp(width, min: 640, max: 7680))
        let h = makeEven(clamp(height, min: 360, max: 4320))
        dimLock.lock()
        _streamWidth = w
        _streamHeight = h
        streamSizedNV12Buffer = nil
        dimLock.unlock()
        print("[PixelBufferConverter] Stream output \(w)x\(h)")
    }

    private static func clamp(_ v: Int, min: Int, max: Int) -> Int {
        Swift.min(Swift.max(v, min), max)
    }

    private static func makeEven(_ v: Int) -> Int {
        Swift.max(2, (v / 2) * 2)
    }

    /// Packed frame for FFmpeg `rawvideo` (`nv12`), always exactly the configured output size.
    static func pixelBufferToFFmpegRawVideo(from pixelBuffer: CVPixelBuffer) -> Data? {
        dimLock.lock()
        let outW = _streamWidth
        let outH = _streamHeight
        dimLock.unlock()

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            break
        default:
            print("[PixelBufferConverter] Expected NV12 from ScreenCaptureKit, got format \(format).")
            return nil
        }

        guard width > 0, height > 0 else {
            print("[PixelBufferConverter] Ignoring empty buffer \(width)x\(height).")
            return nil
        }

        guard let normalized = renderStretchedToStreamNV12(
            source: pixelBuffer,
            sourceWidth: width,
            sourceHeight: height,
            outputWidth: outW,
            outputHeight: outH
        ) else {
            print("[PixelBufferConverter] renderStretchedToStreamNV12 failed for \(width)x\(height) → \(outW)x\(outH).")
            return nil
        }

        CVPixelBufferLockBaseAddress(normalized, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(normalized, .readOnly) }
        return packNV12(pixelBuffer: normalized, width: outW, height: outH)
    }

    // MARK: - Stretch to stream size

    private static func ensureStreamOutputBuffer(outputWidth: Int, outputHeight: Int) -> CVPixelBuffer? {
        dimLock.lock()
        defer { dimLock.unlock() }

        if let b = streamSizedNV12Buffer,
           CVPixelBufferGetWidth(b) == outputWidth,
           CVPixelBufferGetHeight(b) == outputHeight
        {
            return b
        }

        streamSizedNV12Buffer = nil
        var buf: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            outputWidth,
            outputHeight,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs as CFDictionary,
            &buf
        )
        guard status == kCVReturnSuccess, let out = buf else {
            print("[PixelBufferConverter] CVPixelBufferCreate failed: \(status)")
            return nil
        }
        streamSizedNV12Buffer = out
        return out
    }

    private static func renderStretchedToStreamNV12(
        source: CVPixelBuffer,
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> CVPixelBuffer? {
        guard let dst = ensureStreamOutputBuffer(outputWidth: outputWidth, outputHeight: outputHeight) else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        let input = CIImage(cvPixelBuffer: source)
        let scaleX = CGFloat(outputWidth) / CGFloat(sourceWidth)
        let scaleY = CGFloat(outputHeight) / CGFloat(sourceHeight)
        let resized = input.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let streamRect = CGRect(x: 0, y: 0, width: CGFloat(outputWidth), height: CGFloat(outputHeight))
        let cropped = resized.cropped(to: streamRect)

        let cs = CGColorSpaceCreateDeviceRGB()
        ciContext.render(cropped, to: dst, bounds: streamRect, colorSpace: cs)
        return dst
    }

    // MARK: - NV12 → packed bytes for FFmpeg rawvideo

    private static func packNV12(pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> Data? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return nil }

        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let ySize = width * height
        let uvRows = height / 2
        var data = Data(count: ySize + width * uvRows)

        data.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress else { return }
            let yOut = dst.assumingMemoryBound(to: UInt8.self)
            let uvOut = yOut.advanced(by: ySize)
            let ySrc = yBase.assumingMemoryBound(to: UInt8.self)
            let uvSrc = uvBase.assumingMemoryBound(to: UInt8.self)
            for row in 0 ..< height {
                memcpy(yOut.advanced(by: row * width), ySrc.advanced(by: row * yStride), width)
            }
            for row in 0 ..< uvRows {
                memcpy(uvOut.advanced(by: row * width), uvSrc.advanced(by: row * uvStride), width)
            }
        }
        return data
    }
}
