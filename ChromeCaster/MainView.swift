//
//  MainView.swift
//  ChromeCaster
//

import SwiftUI

struct MainView: View {
    @ObservedObject var session: SessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chrome Streamer")
                .font(.largeTitle.weight(.semibold))

            StreamSetupView(
                listenPort: $session.listenPort,
                audioOnly: $session.audioOnly,
                audioVolumePercent: $session.audioVolumePercent,
                preferLibFDKAAC: $session.preferLibFDKAAC,
                encodingOptionsLocked: session.isStreaming,
                runsUnderAppSandbox: session.runsUnderAppSandbox,
                vlcURL: session.vlcPlaybackURL
            )
            .onChange(of: session.audioVolumePercent) { _ in
                session.applyLiveAudioGainIfStreaming()
            }

            HStack(spacing: 12) {
                Button(session.isStreaming ? "Stop" : "Start") {
                    Task {
                        if session.isStreaming {
                            await session.stop()
                        } else {
                            await session.start()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.isBusy)

                if session.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let message = session.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundColor(session.lastError == nil ? .primary : .red)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

#Preview {
    MainView(session: SessionManager())
}
