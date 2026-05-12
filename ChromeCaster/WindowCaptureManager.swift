//
//  WindowCaptureManager.swift
//  ChromeCaster
//

import CoreMedia
import ScreenCaptureKit

/// Not `@MainActor`: screen samples must not hop to the main thread every frame.
final class WindowCaptureManager: NSObject {
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?

    private var emitCapture: ((CMSampleBuffer, SCStreamOutputType) -> Void)?

    func attach(ffmpeg: FFmpegStreamer) {
        emitCapture = { [weak ffmpeg] buffer, outputType in
            guard let ffmpeg else { return }
            switch outputType {
            case .screen:
                ffmpeg.processVideo(sampleBuffer: buffer)
            case .audio:
                ffmpeg.processAudio(sampleBuffer: buffer)
            default:
                break
            }
        }
    }

    /// Run **before** starting ffmpeg so Screen Recording TCC runs first and we don’t spawn a child with a broken stdin pipe.
    func preflightChromeWindowAvailable() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let chromeWindows = content.windows.filter { window in
            window.owningApplication?.applicationName == "Google Chrome"
        }
        guard chromeWindows.first != nil else {
            print("[WindowCaptureManager] No Google Chrome window found.")
            throw CaptureError.chromeWindowNotFound
        }
    }

    private func applyBaseStreamConfiguration(_ configuration: SCStreamConfiguration) {
        configuration.width = PixelBufferConverter.streamWidth
        configuration.height = PixelBufferConverter.streamHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(PixelBufferConverter.streamFPS))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = false
        if #available(macOS 13.0, *) {
            configuration.capturesAudio = false
            // >1 avoids SCK dropping bursts when the handler returns quickly; stdin coalescing keeps latency bounded.
            configuration.queueDepth = 2
        }
    }

    /// Starts capture. Returns whether an **audio** output was attached (requires macOS 13+ and system permission).
    /// - Parameter videoEnabled: When `false`, only tab audio is captured (Chrome window must still exist for the filter).
    func start(videoEnabled: Bool = true) async throws -> Bool {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let chromeWindows = content.windows.filter { window in
            window.owningApplication?.applicationName == "Google Chrome"
        }

        guard let window = chromeWindows.first else {
            print("[WindowCaptureManager] No Google Chrome window found.")
            throw CaptureError.chromeWindowNotFound
        }

        print("[WindowCaptureManager] Capturing window id=\(window.windowID) title=\(window.title ?? "(untitled)") videoEnabled=\(videoEnabled)")

        // Fixed 960×540: SCK + FFmpeg stay light so encoding stays ≥ realtime (lower end-to-end latency).
        PixelBufferConverter.configureStreamDimensions(width: 960, height: 540)
        print("[WindowCaptureManager] SCStream / encoder video size 960x540")

        let filter = SCContentFilter(desktopIndependentWindow: window)

        guard let emit = emitCapture else {
            print("[WindowCaptureManager] attach(ffmpeg:) was not called before start.")
            throw CaptureError.notConfigured
        }

        let output = CaptureStreamOutput(emit: emit)
        let sampleQueue = DispatchQueue(label: "dev.sandeepsingh.chromecaster.sck", qos: .userInteractive)

        var stream: SCStream
        var audioAttached = false

        if !videoEnabled {
            guard #available(macOS 13.0, *) else {
                throw CaptureError.audioOnlyRequiresNewerOS
            }
            let cfgAudioOnly = SCStreamConfiguration()
            applyBaseStreamConfiguration(cfgAudioOnly)
            cfgAudioOnly.capturesAudio = true
            stream = SCStream(filter: filter, configuration: cfgAudioOnly, delegate: self)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            audioAttached = true
        } else if #available(macOS 13.0, *) {
            let cfgWithAudio = SCStreamConfiguration()
            applyBaseStreamConfiguration(cfgWithAudio)
            cfgWithAudio.capturesAudio = true

            stream = SCStream(filter: filter, configuration: cfgWithAudio, delegate: self)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            do {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
                audioAttached = true
            } catch {
                print("[WindowCaptureManager] Tab/system audio unavailable (video only): \(error.localizedDescription)")
                let cfgVideoOnly = SCStreamConfiguration()
                applyBaseStreamConfiguration(cfgVideoOnly)
                stream = SCStream(filter: filter, configuration: cfgVideoOnly, delegate: self)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            }
        } else {
            let cfgVideoOnly = SCStreamConfiguration()
            applyBaseStreamConfiguration(cfgVideoOnly)
            stream = SCStream(filter: filter, configuration: cfgVideoOnly, delegate: self)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        }

        try await stream.startCapture()

        self.streamOutput = output
        self.stream = stream
        return audioAttached
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            print("[WindowCaptureManager] stopCapture error: \(error.localizedDescription)")
        }
        self.stream = nil
        streamOutput = nil
    }

    enum CaptureError: LocalizedError {
        case chromeWindowNotFound
        case notConfigured
        case audioOnlyRequiresNewerOS

        var errorDescription: String? {
            switch self {
            case .chromeWindowNotFound:
                "No on-screen Google Chrome window was found. Open Chrome, then allow ChromeCaster under System Settings → Privacy & Security → Screen Recording."
            case .notConfigured:
                "Internal error: capture pipeline was not wired. Restart the app."
            case .audioOnlyRequiresNewerOS:
                "Audio-only streaming requires macOS 13 or later (ScreenCaptureKit tab audio)."
            }
        }
    }
}

// MARK: - SCStreamDelegate

extension WindowCaptureManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[WindowCaptureManager] Stream stopped with error: \(error.localizedDescription)")
    }
}

// MARK: - Output

private final class CaptureStreamOutput: NSObject, SCStreamOutput {
    private let emit: (CMSampleBuffer, SCStreamOutputType) -> Void
    /// Debug: SCK only delivers further video samples after this handler returns; keep it fast.
    private var screenFrameCounter = 0

    init(emit: @escaping (CMSampleBuffer, SCStreamOutputType) -> Void) {
        self.emit = emit
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            screenFrameCounter += 1
            print("[Capture] frame \(screenFrameCounter)")
            emit(sampleBuffer, outputType)
        case .audio:
            emit(sampleBuffer, outputType)
        default:
            break
        }
    }
}
