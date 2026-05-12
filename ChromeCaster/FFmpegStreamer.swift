//
//  FFmpegStreamer.swift
//  ChromeCaster
//

import CoreMedia
import Darwin
import Foundation

extension Notification.Name {
    /// Posted on the main queue when the ffmpeg child exits on its own (crash, error, or remote close).
    static let ffmpegProcessDidExitUnexpectedly = Notification.Name("dev.sandeepeven.ChromeCaster.ffmpegProcessDidExitUnexpectedly")
}

struct StreamLaunchConfiguration: Sendable {
    /// Port where **MediaMTX** listens; ffmpeg publishes to `rtsp://127.0.0.1:<port>/live`.
    var mediaMtxRTSPPort: Int
    var includeAudio: Bool
    var audioOnly: Bool
    /// Linear gain applied to PCM before the FIFO (0…1).
    var audioGain: Float
    /// Prefer `libfdk_aac` when not App Sandbox (ignored when sandboxed).
    var preferLibFDKAAC: Bool
}

/// Spawns `ffmpeg`: rawvideo stdin (+ optional tab-audio FIFO) → H.264/AAC → **RTSP** to local MediaMTX. Play on the TV with `rtsp://<Mac-LAN-IP>:<port>/live` in VLC.
final class FFmpegStreamer: @unchecked Sendable {
    private let writeQueue = DispatchQueue(label: "dev.sandeepsingh.chromecaster.ffmpeg.stdin", qos: .userInteractive)
    /// Heavy NV12 conversion must not run on ScreenCaptureKit’s sample queue (especially with a shallow `queueDepth`).
    private let videoIngressQueue = DispatchQueue(label: "dev.sandeepsingh.chromecaster.video-ingress", qos: .userInteractive)

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stderrReader: DispatchSourceRead?

    /// ScreenCaptureKit tab audio → FFmpeg second input (named FIFO of packed f32le stereo PCM).
    private var audioFifoPath: String?
    private var audioFifoWriter: FileHandle?
    private let audioFifoQueue = DispatchQueue(label: "dev.sandeepsingh.chromecaster.audio-fifo", qos: .userInteractive)
    private var includeAudioInMux = false
    private var audioOnlyMode = false

    private let audioGainLock = NSLock()
    private var audioGain: Float = 1

    /// Latest packed NV12 frame for ffmpeg stdin; new frames **replace** the previous undrained packet (no counter that can strand at max pending).
    private let videoStdinMailboxLock = NSLock()
    private var latestVideoStdinPacket: Data?

    /// Coalesce SCK video: `latestVideoSample` holds only the newest frame; each ingress job drains until empty (no `pumpRunning` flag — that raced and could strand frames).
    private let videoCoalesceLock = NSLock()
    private var latestVideoSample: CMSampleBuffer?

    private(set) var isRunning = false

    /// `true` when the process is running under macOS App Sandbox (no `libfdk_aac` / non‑Apple codecs).
    private static var runsUnderAppSandbox: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    func setAudioGain(_ value: Float) {
        audioGainLock.lock()
        audioGain = max(0, min(1, value))
        audioGainLock.unlock()
    }

    func start(config: StreamLaunchConfiguration) throws {
        guard !isRunning else { return }

        defer {
            if !isRunning, audioFifoPath != nil {
                tearDownAudioFifo()
            }
        }

        if config.audioOnly, !config.includeAudio {
            throw StreamerError.audioOnlyRequiresTabAudio
        }

        guard (1 ... 65_535).contains(config.mediaMtxRTSPPort) else {
            throw StreamerError.invalidPort
        }

        guard let ffmpegURL = Self.resolveFFmpegExecutable() else {
            throw StreamerError.ffmpegNotFound
        }

        var fifoPathForAudio: String?
        if config.includeAudio {
            let fifoURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("chromecaster-audio-\(UUID().uuidString).fifo", isDirectory: false)
            let path = fifoURL.path
            unlink(path)
            if mkfifo(path, 0o600) != 0 {
                throw StreamerError.audioFifoFailed(errno: errno)
            }
            audioFifoPath = path
            fifoPathForAudio = path
        }

        let arguments = Self.buildFFmpegArguments(config: config, fifoPathForAudio: fifoPathForAudio)

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments

        let stderr = Pipe()
        process.standardError = stderr

        let stdin: Pipe?
        if config.audioOnly {
            process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
            stdin = nil
        } else {
            let s = Pipe()
            process.standardInput = s
            stdin = s
        }

        if let nullOut = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null")) {
            process.standardOutput = nullOut
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let reason: String
            switch proc.terminationReason {
            case .exit:
                reason = "exit(\(proc.terminationStatus))"
            case .uncaughtSignal:
                reason = "signal \(proc.terminationStatus) (\(Self.signalName(proc.terminationStatus)))"
            @unknown default:
                reason = "reason \(proc.terminationReason.rawValue) status \(proc.terminationStatus)"
            }
            print("[FFmpegStreamer] ffmpeg terminated: \(reason)")
            self.handleProcessTerminatedExternally()
        }

        self.process = process
        stdinPipe = stdin
        stderrPipe = stderr

        attachStderrLogging(stderr.fileHandleForReading)

        print("[FFmpegStreamer] ffmpeg args:")
        print(arguments.joined(separator: " "))

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            stderrReader?.cancel()
            stderrReader = nil
            self.process = nil
            stdinPipe = nil
            stderrPipe = nil
            throw error
        }

        if config.includeAudio {
            beginOpeningAudioFifoForWriting()
        }

        isRunning = true
        includeAudioInMux = config.includeAudio
        audioOnlyMode = config.audioOnly
        audioGainLock.lock()
        audioGain = max(0, min(1, config.audioGain))
        audioGainLock.unlock()

        print("[FFmpegStreamer] Started ffmpeg at \(ffmpegURL.path)")
        print("[FFmpegStreamer] Publishing RTSP (TCP) to rtsp://127.0.0.1:\(config.mediaMtxRTSPPort)/live — start **MediaMTX** first (see scripts/mediamtx.yml).")

        primeStdin()
    }

    /// Backward-compatible entry: full motion + optional tab audio.
    func start(listenPort: Int, includeAudio: Bool) throws {
        try start(
            config: StreamLaunchConfiguration(
                mediaMtxRTSPPort: listenPort,
                includeAudio: includeAudio,
                audioOnly: false,
                audioGain: 1,
                preferLibFDKAAC: false
            )
        )
    }

    private static func buildFFmpegArguments(config: StreamLaunchConfiguration, fifoPathForAudio: String?) -> [String] {
        let w = PixelBufferConverter.streamWidth
        let h = PixelBufferConverter.streamHeight
        let fps = PixelBufferConverter.streamFPS
        let videoSize = "\(w)x\(h)"

        // MARK: Global demuxer / mux (video-only can stay aggressive; **do not** tighten these when `fifoPathForAudio != nil` or VLC/Fire TV often lose AAC)
        let muxesTabAudio = fifoPathForAudio != nil
        let globalFFlags = muxesTabAudio ? "nobuffer+flush_packets" : "nobuffer+flush_packets+discardcorrupt"
        let maxInterleaveMs = muxesTabAudio ? "10000" : "0"

        var arguments: [String] = [
            "-hide_banner",
            "-loglevel", "info",
            "-flags", "+low_delay",
            "-fflags", globalFFlags,
            "-avioflags", "direct",
            "-max_delay", "0",
            "-probesize", "32",
            "-analyzeduration", "0",
            "-fpsprobesize", "0",
        ]

        // Tab-audio FIFO (`f32le` → AAC): two branches below (audio-only vs video+audio). **Do not** change their `-f/-ar/-fflags genpts/-async/-map` or `audioEncoderArgs()` without re-testing TV audio.
        if config.audioOnly, let ap = fifoPathForAudio {
            arguments += [
                "-f", "f32le",
                "-ac", "2",
                "-ar", "\(Int(ScreenCaptureAudioPCM.ffmpegSampleRate))",
                "-thread_queue_size", "512",
                "-fflags", "+genpts",
                "-use_wallclock_as_timestamps", "1",
                "-async", "1",
                "-i", ap,
                "-f", "lavfi",
                "-i", "color=c=black:s=\(videoSize):r=\(fps)",
                "-map", "1:v",
                "-map", "0:a",
            ]
            arguments += Self.videoToolboxEncodeArgs()
            arguments += Self.audioEncoderArgs(preferFDK: config.preferLibFDKAAC)
        } else if !config.audioOnly {
            arguments += Self.videoOnlyRawInputArgs(videoSize: videoSize, fps: fps)
            if config.includeAudio, let ap = fifoPathForAudio {
                // Same FIFO discipline as audio-only branch (see comment above `if config.audioOnly`).
                arguments += [
                    "-f", "f32le",
                    "-ac", "2",
                    "-ar", "\(Int(ScreenCaptureAudioPCM.ffmpegSampleRate))",
                    "-thread_queue_size", "512",
                    "-fflags", "+genpts",
                    "-use_wallclock_as_timestamps", "1",
                    "-async", "1",
                    "-i", ap,
                    "-map", "0:v",
                    "-map", "1:a",
                ]
                arguments += Self.videoToolboxEncodeArgs()
                arguments += Self.audioEncoderArgs(preferFDK: config.preferLibFDKAAC)
            } else {
                arguments += ["-map", "0:v"] + Self.videoToolboxEncodeArgs() + ["-an"]
            }
        }

        arguments += [
            "-max_interleave_delta", maxInterleaveMs,
            "-f", "rtsp",
            "-rtsp_transport", "tcp",
            "rtsp://127.0.0.1:\(config.mediaMtxRTSPPort)/live",
        ]

        return arguments
    }

    private static func videoOnlyRawInputArgs(videoSize: String, fps: Int) -> [String] {
        [
            "-thread_queue_size", "256",
            "-f", "rawvideo",
            "-pix_fmt", PixelBufferConverter.ffmpegRawVideoPixFmt,
            "-video_size", videoSize,
            "-framerate", "\(fps)",
            "-use_wallclock_as_timestamps", "1",
            "-i", "pipe:0",
        ]
    }

    private static func videoToolboxEncodeArgs() -> [String] {
        [
            "-c:v", "h264_videotoolbox",
            "-allow_sw", "1",
            "-realtime", "1",
            "-b:v", "2500k",
            "-maxrate", "2500k",
            "-bufsize", "2500k",
            "-g", "10",
            "-keyint_min", "10",
            "-bf", "0",
            "-profile:v", "main",
        ]
    }

    /// **Audio-critical:** `-af aresample…`, codec choice, and bitrate — avoid changing when fixing video latency.
    private static func audioEncoderArgs(preferFDK: Bool) -> [String] {
        let useFDK = preferFDK && !runsUnderAppSandbox
        let asyncResample = ["-af", "aresample=async=1:first_pts=0"]
        if useFDK {
            return asyncResample + ["-c:a", "libfdk_aac", "-b:a", "128k"]
        }
        if preferFDK, runsUnderAppSandbox {
            print("[FFmpegStreamer] libfdk_aac requested but App Sandbox is active — using aac_at.")
        }
        return asyncResample + ["-c:a", "aac_at", "-b:a", "128k"]
    }

    private func beginOpeningAudioFifoForWriting() {
        guard let path = audioFifoPath else { return }
        audioFifoQueue.async { [weak self] in
            guard let self else { return }
            let fd = open(path, O_WRONLY)
            guard fd >= 0 else {
                print("[FFmpegStreamer] Audio FIFO open(O_WRONLY) failed errno=\(errno) \(String(cString: strerror(errno)))")
                return
            }
            self.audioFifoWriter = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            print("[FFmpegStreamer] Audio FIFO writer connected")
        }
    }

    private func tearDownAudioFifo() {
        audioFifoQueue.sync {
            if let w = audioFifoWriter {
                try? w.close()
            }
            audioFifoWriter = nil
        }
        if let p = audioFifoPath {
            unlink(p)
            audioFifoPath = nil
        }
        includeAudioInMux = false
    }

    private static func applyLinearGainF32LE(_ pcm: Data, gain: Float) -> Data {
        if abs(gain - 1) < 0.000_1 { return pcm }
        if gain <= 0 { return Data(count: pcm.count) }
        var out = Data(pcm)
        out.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            let n = raw.count / MemoryLayout<Float>.size
            for i in 0 ..< n {
                let v = base[i] * gain
                base[i] = min(1, max(-1, v))
            }
        }
        return out
    }

    private func primeStdin() {
        guard !audioOnlyMode, stdinPipe != nil else { return }
        usleep(120_000)

        let w = PixelBufferConverter.streamWidth
        let h = PixelBufferConverter.streamHeight
        let frameBytes = w * h * 3 / 2
        let blackFrame = Data(count: frameBytes)

        writeQueue.sync {
            guard let handle = stdinPipe?.fileHandleForWriting else { return }
            let fd = handle.fileDescriptor
            guard fd >= 0 else { return }

            for _ in 0 ..< 6 {
                var wroteFrame = false
                blackFrame.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    let len = raw.count
                    var total = 0
                    while total < len {
                        let n = Darwin.write(fd, base.advanced(by: total), len - total)
                        if n < 0 {
                            let e = errno
                            if e == EINTR { continue }
                            print("[FFmpegStreamer] stdin prime failed errno=\(e) \(String(cString: strerror(e)))")
                            return
                        }
                        if n == 0 {
                            print("[FFmpegStreamer] stdin prime: write returned 0")
                            return
                        }
                        total += n
                    }
                    wroteFrame = true
                }
                if !wroteFrame { break }
            }
        }
    }

    func processVideo(sampleBuffer: CMSampleBuffer) {
        guard !audioOnlyMode, isRunning else { return }
        videoCoalesceLock.lock()
        latestVideoSample = sampleBuffer
        videoCoalesceLock.unlock()

        videoIngressQueue.async { [weak self] in
            guard let self else { return }
            while true {
                let sample: CMSampleBuffer? = {
                    self.videoCoalesceLock.lock()
                    defer { self.videoCoalesceLock.unlock() }
                    let s = self.latestVideoSample
                    self.latestVideoSample = nil
                    return s
                }()
                guard let sample else { return }
                self.processVideoOnIngressQueue(sampleBuffer: sample)
            }
        }
    }

    private func processVideoOnIngressQueue(sampleBuffer: CMSampleBuffer) {
        guard isRunning, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard let frameData = PixelBufferConverter.pixelBufferToFFmpegRawVideo(from: imageBuffer) else {
            print("[FFmpegStreamer] video conversion returned nil (frame dropped before stdin)")
            return
        }

        print("[Capture] sending frame to ffmpeg")
        enqueueFrameData(frameData)
    }

    func processAudio(sampleBuffer: CMSampleBuffer) {
        guard isRunning, includeAudioInMux else { return }
        guard var pcm = ScreenCaptureAudioPCM.f32lePacked48kStereo(from: sampleBuffer), !pcm.isEmpty else { return }
        audioGainLock.lock()
        let g = audioGain
        audioGainLock.unlock()
        pcm = Self.applyLinearGainF32LE(pcm, gain: g)
        audioFifoQueue.async { [weak self] in
            guard let self, self.isRunning, let w = self.audioFifoWriter else { return }
            do {
                try w.write(contentsOf: pcm)
            } catch {
                print("[FFmpegStreamer] Audio FIFO write failed: \(error.localizedDescription)")
            }
        }
    }

    func enqueueFrameData(_ data: Data) {
        print("[FFmpegStreamer] enqueueVideoFrame size=\(data.count)")
        var replacedPriorPacket = false
        videoStdinMailboxLock.lock()
        replacedPriorPacket = latestVideoStdinPacket != nil
        latestVideoStdinPacket = data
        videoStdinMailboxLock.unlock()
        if replacedPriorPacket {
            let expectedNV12 = PixelBufferConverter.streamWidth * PixelBufferConverter.streamHeight * 3 / 2
            print("[FFmpegStreamer] stdin video mailbox: replaced undrained packet (latest wins; NV12 frame ≈ \(expectedNV12) B)")
        }
        writeQueue.async { [weak self] in
            self?.flushCoalescedVideoStdinWrite()
        }
    }

    /// Drains the stdin mailbox on `writeQueue`. **Never** dequeue a packet until stdin is ready — dequeuing then failing `guard` dropped frames and starved FFmpeg after `frame=1`.
    private func flushCoalescedVideoStdinWrite() {
        guard isRunning else { return }
        while isRunning {
            guard let handle = stdinPipe?.fileHandleForWriting else { return }
            let packet: Data? = {
                videoStdinMailboxLock.lock()
                defer { videoStdinMailboxLock.unlock() }
                let p = latestVideoStdinPacket
                latestVideoStdinPacket = nil
                return p
            }()
            guard let packet else { break }
            do {
                try handle.write(contentsOf: packet)
            } catch {
                print("[FFmpegStreamer] stdin write failed: \(error.localizedDescription)")
                videoStdinMailboxLock.lock()
                if latestVideoStdinPacket == nil {
                    latestVideoStdinPacket = packet
                }
                videoStdinMailboxLock.unlock()
                break
            }
        }
    }

    func stop() {
        guard isRunning || process != nil || audioFifoPath != nil else { return }
        isRunning = false

        videoCoalesceLock.lock()
        latestVideoSample = nil
        videoCoalesceLock.unlock()

        videoStdinMailboxLock.lock()
        latestVideoStdinPacket = nil
        videoStdinMailboxLock.unlock()

        process?.terminationHandler = nil

        stderrReader?.cancel()
        stderrReader = nil

        // Close stdin and terminate the child **before** waiting on `audioFifoQueue`: a blocked
        // `write()` to a full FIFO cannot complete until ffmpeg exits or reads more data.
        if let handle = stdinPipe?.fileHandleForWriting {
            try? handle.close()
        }
        stdinPipe = nil

        let procToKill = process
        if let procToKill, procToKill.isRunning {
            procToKill.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                if procToKill.isRunning {
                    procToKill.interrupt()
                }
            }
        }
        process = nil

        tearDownAudioFifo()

        if let stderrPipe {
            try? stderrPipe.fileHandleForReading.close()
        }
        stderrPipe = nil

        audioOnlyMode = false

        print("[FFmpegStreamer] Stopped")
    }

    private func handleProcessTerminatedExternally() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }

            self.isRunning = false

            self.process?.terminationHandler = nil
            self.process = nil

            self.stderrReader?.cancel()
            self.stderrReader = nil

            if let handle = self.stdinPipe?.fileHandleForWriting {
                try? handle.close()
            }
            self.stdinPipe = nil

            self.videoStdinMailboxLock.lock()
            self.latestVideoStdinPacket = nil
            self.videoStdinMailboxLock.unlock()

            self.tearDownAudioFifo()

            if let stderrPipe = self.stderrPipe {
                try? stderrPipe.fileHandleForReading.close()
            }
            self.stderrPipe = nil

            self.audioOnlyMode = false

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .ffmpegProcessDidExitUnexpectedly, object: nil)
            }
        }
    }

    private func attachStderrLogging(_ handle: FileHandle) {
        let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler {
            let data = handle.availableData
            if data.isEmpty {
                source.cancel()
                return
            }
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                print("[ffmpeg] \(line)")
            }
        }
        source.setCancelHandler {
            try? handle.close()
        }
        source.resume()
        stderrReader = source
    }

    private static func signalName(_ status: Int32) -> String {
        if let p = strsignal(status) {
            return String(cString: p)
        }
        return "signal \(status)"
    }

    private static func resolveFFmpegExecutable() -> URL? {
        if let macOSDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundled = macOSDir.appendingPathComponent("ffmpeg", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }

        let bundleCandidates = [
            Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: nil),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ffmpeg"),
        ].compactMap { $0 }

        for url in bundleCandidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }

        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = pathEnv.split(separator: ":").map(String.init)

        for dir in paths {
            let url = URL(fileURLWithPath: String(dir)).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let common = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for path in common {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    enum StreamerError: LocalizedError {
        case invalidPort
        case ffmpegNotFound
        case audioFifoFailed(errno: Int32)
        case audioOnlyRequiresTabAudio

        var errorDescription: String? {
            switch self {
            case .invalidPort:
                "Enter a valid RTSP port for MediaMTX (1–65535), default 8554."
            case .ffmpegNotFound:
                "Could not find `ffmpeg`. Install it (`brew install ffmpeg`), then clean build so the “Embed ffmpeg” step copies it into the app."
            case let .audioFifoFailed(code):
                "Could not create audio pipe (errno \(code))."
            case .audioOnlyRequiresTabAudio:
                "Audio-only streaming needs Chrome tab audio (macOS 13 or later and Screen Recording permission)."
            }
        }
    }
}
