//
//  StreamSetupView.swift
//  ChromeCaster
//

import AppKit
import SwiftUI

struct StreamSetupView: View {
    @Binding var listenPort: String
    @Binding var audioOnly: Bool
    @Binding var audioVolumePercent: Double
    @Binding var preferLibFDKAAC: Bool
    /// When true, lock port / audio-only / encoder toggles (not volume).
    var encodingOptionsLocked: Bool
    let runsUnderAppSandbox: Bool
    let vlcURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stream setup")
                .font(.headline)

            HStack(alignment: .firstTextBaseline) {
                Text("RTSP port")
                    .frame(width: 90, alignment: .leading)
                TextField("8554", text: $listenPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .disabled(encodingOptionsLocked)
                Text(latencyCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Audio only (no video; black video is encoded)", isOn: $audioOnly)
                .disabled(encodingOptionsLocked)

            VStack(alignment: .leading, spacing: 4) {
                Text("Stream audio level (TV)")
                    .font(.subheadline.weight(.medium))
                HStack {
                    Slider(value: $audioVolumePercent, in: 0 ... 100, step: 1)
                    Text("\(Int(audioVolumePercent))%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
                Text("This only scales audio **sent to the stream**. Chrome still plays sound on **this Mac’s speakers** unless you mute the tab, lower site volume, or use headphones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Prefer libfdk_aac (non‑sandbox builds only)", isOn: $preferLibFDKAAC)
                .disabled(runsUnderAppSandbox || encodingOptionsLocked)
            if runsUnderAppSandbox {
                Text("App Sandbox builds always use **aac_at**. Turn this on only for a Developer ID / non‑sandbox ffmpeg that includes libfdk_aac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("If your bundled `ffmpeg` lacks libfdk_aac, startup will fail — switch off and use aac_at.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let vlcURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VLC → Open Network Stream — paste this URL (must start with rtsp://). Optional: append ` :network-caching=100` for lower latency.")
                        .font(.subheadline.weight(.medium))
                    Text(vlcURL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)

                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(vlcURL, forType: .string)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var latencyCaption: String {
        "FFmpeg publishes RTSP (TCP) to **MediaMTX** on this Mac (`127.0.0.1`). Run `./mediamtx` with `scripts/mediamtx.yml` before **Start**. The TV uses your Mac’s **LAN** IP, not localhost."
    }
}

#Preview {
    StreamSetupView(
        listenPort: .constant("8554"),
        audioOnly: .constant(false),
        audioVolumePercent: .constant(100),
        preferLibFDKAAC: .constant(false),
        encodingOptionsLocked: false,
        runsUnderAppSandbox: true,
        vlcURL: "rtsp://192.168.1.10:8554/live"
    )
    .padding()
}
