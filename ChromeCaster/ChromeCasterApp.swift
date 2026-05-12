//
//  ChromeCasterApp.swift
//  ChromeCaster
//

import Darwin
import SwiftUI

@main
struct ChromeCasterApp: App {
    init() {
        // Avoid SIGPIPE (13) terminating the app when ffmpeg closes stdin while we still enqueue frames.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
