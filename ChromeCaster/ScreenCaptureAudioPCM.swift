//
//  ScreenCaptureAudioPCM.swift
//  ChromeCaster
//
//  Converts ScreenCaptureKit / CoreAudio CMSampleBuffers to packed PCM @48kHz stereo for FFmpeg raw audio.
//

import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

enum ScreenCaptureAudioPCM {
    /// Must match FFmpeg `-ar` for the audio FIFO input.
    static let ffmpegSampleRate: Double = 48_000
    static let ffmpegChannels: UInt32 = 2

    /// Packed little-endian interleaved **Float32** stereo @ 48 kHz (FFmpeg `-f f32le`).
    static func f32lePacked48kStereo(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard CMSampleBufferIsValid(sampleBuffer) else { return nil }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        var asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }

        guard let inFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: ffmpegSampleRate,
            channels: AVAudioChannelCount(ffmpegChannels),
            interleaved: true
        ) else { return nil }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        inBuffer.frameLength = AVAudioFrameCount(frames)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: inBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        let ratio = ffmpegSampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(ceil(Double(frames) * ratio) + 32)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return nil }

        do {
            try converter.convert(to: outBuffer, from: inBuffer)
        } catch {
            print("[ScreenCaptureAudioPCM] AVAudioConverter: \(error.localizedDescription)")
            return nil
        }

        guard outBuffer.frameLength > 0, let chData = outBuffer.floatChannelData else { return nil }

        let outFrames = Int(outBuffer.frameLength)
        let packedByteCount = outFrames * Int(ffmpegChannels) * MemoryLayout<Float>.size

        if outFormat.isInterleaved {
            let bytesPerFrame = Int(outFormat.streamDescription.pointee.mBytesPerFrame)
            guard bytesPerFrame > 0 else { return nil }
            return Data(bytes: chData[0], count: outFrames * bytesPerFrame)
        }

        guard Int(outFormat.channelCount) >= 2 else { return nil }
        let l = chData[0]
        let r = chData[1]
        var packed = Data(count: packedByteCount)
        packed.withUnsafeMutableBytes { raw in
            guard let dst = raw.bindMemory(to: Float.self).baseAddress else { return }
            for i in 0 ..< outFrames {
                dst[i * 2] = l[i]
                dst[i * 2 + 1] = r[i]
            }
        }
        return packed
    }
}
