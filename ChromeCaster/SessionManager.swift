//
//  SessionManager.swift
//  ChromeCaster
//

import Combine
import Foundation
import SwiftUI

private let preferFDKDefaultsKey = "ChromecasterPreferLibFDKAAC"

@MainActor
final class SessionManager: ObservableObject {
    /// MediaMTX RTSP port (ffmpeg publishes to `127.0.0.1:<port>/live`; VLC on the TV uses `rtsp://<this-Mac’s-LAN-IP>:<port>/live`).
    @Published var listenPort: String = "8554"
    @Published var audioOnly: Bool = false
    /// 0…100, applied to PCM before encoding (adjust while streaming).
    @Published var audioVolumePercent: Double = 100
    /// Uses `libfdk_aac` when not App Sandbox and your `ffmpeg` build includes it; otherwise `aac_at`.
    @Published var preferLibFDKAAC: Bool = false

    @Published private(set) var isStreaming = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var vlcPlaybackURL: String?

    let runsUnderAppSandbox: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private let ffmpeg = FFmpegStreamer()
    private let capture = WindowCaptureManager()

    private var ffmpegExitObserver: NSObjectProtocol?

    init() {
        preferLibFDKAAC = UserDefaults.standard.bool(forKey: preferFDKDefaultsKey)
        capture.attach(ffmpeg: ffmpeg)
        ffmpegExitObserver = NotificationCenter.default.addObserver(
            forName: .ffmpegProcessDidExitUnexpectedly,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleFFmpegExitedUnexpectedly() }
        }
    }

    deinit {
        if let ffmpegExitObserver {
            NotificationCenter.default.removeObserver(ffmpegExitObserver)
        }
    }

    private func handleFFmpegExitedUnexpectedly() async {
        guard isStreaming else { return }
        ffmpeg.stop()
        await capture.stop()
        isStreaming = false
        vlcPlaybackURL = nil
        let msg = "FFmpeg stopped (often: MediaMTX not running, port 8554 in use, or encoder error). Start `./mediamtx` with `scripts/mediamtx.yml`, then check Console for [ffmpeg] lines."
        lastError = msg
        statusMessage = msg
        print("[SessionManager] \(msg)")
    }

    func start() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        vlcPlaybackURL = nil
        statusMessage = "Starting…"

        UserDefaults.standard.set(preferLibFDKAAC, forKey: preferFDKDefaultsKey)

        let trimmedPort = listenPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(trimmedPort) ?? 8554

        do {
            statusMessage = "Checking screen recording & Chrome window…"
            try await capture.preflightChromeWindowAvailable()

            if preferLibFDKAAC, runsUnderAppSandbox {
                statusMessage = "libfdk_aac is disabled in the App Sandbox — using aac_at."
            }

            if audioOnly {
                statusMessage = "Starting tab audio capture…"
            } else {
                statusMessage = "Starting screen capture…"
            }

            let includeAudio: Bool
            do {
                includeAudio = try await capture.start(videoEnabled: !audioOnly)
            } catch {
                throw error
            }

            if audioOnly, !includeAudio {
                throw FFmpegStreamer.StreamerError.audioOnlyRequiresTabAudio
            }

            statusMessage = "Starting encoder…"
            let gain = Float(max(0, min(100, audioVolumePercent)) / 100)
            ffmpeg.setAudioGain(gain)

            let config = StreamLaunchConfiguration(
                mediaMtxRTSPPort: port,
                includeAudio: includeAudio,
                audioOnly: audioOnly,
                audioGain: gain,
                preferLibFDKAAC: preferLibFDKAAC
            )

            do {
                try ffmpeg.start(config: config)
            } catch {
                await capture.stop()
                throw error
            }

            isStreaming = true
            let ip = LANIPAddress.primaryIPv4() ?? "127.0.0.1"
            let url = "rtsp://\(ip):\(port)/live"
            vlcPlaybackURL = url
            if includeAudio {
                statusMessage = "Stream is live — open the RTSP URL in VLC on the TV (MediaMTX must be running on this Mac). Tab audio still plays here unless you mute Chrome; the slider only affects the **stream**."
            } else {
                statusMessage = "Stream is live. In VLC use Open Network Stream with the RTSP URL below (MediaMTX on this Mac, default port \(port))."
            }
            print("[SessionManager] VLC RTSP URL: \(url)")
        } catch {
            let text = error.localizedDescription
            lastError = text
            statusMessage = text
            isStreaming = false
            vlcPlaybackURL = nil
            print("[SessionManager] Start failed: \(text)")
        }

        isBusy = false
    }

    /// Updates PCM gain while streaming (slider).
    func applyLiveAudioGainIfStreaming() {
        guard isStreaming else { return }
        let g = Float(max(0, min(100, audioVolumePercent)) / 100)
        ffmpeg.setAudioGain(g)
    }

    func stop() async {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "Stopping…"

        ffmpeg.stop()
        await capture.stop()

        isStreaming = false
        vlcPlaybackURL = nil
        statusMessage = "Stopped."
        print("[SessionManager] Pipeline stopped.")
        isBusy = false
    }
}
