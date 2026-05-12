//
//  ContentView.swift
//  ChromeCaster
//

import SwiftUI

struct ContentView: View {
    @StateObject private var session = SessionManager()

    var body: some View {
        MainView(session: session)
            .frame(minWidth: 420, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
