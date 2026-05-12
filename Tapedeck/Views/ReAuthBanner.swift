// ABOUTME: Top-of-window banner shown when AppState.tokenStatus == "expired".

import SwiftUI
import TapedeckCore

struct ReAuthBanner: View {
    @State private var presentTokenWindow = false

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Plaud session expired — please re-sign in.")
            Spacer()
            Button("Sign in to Plaud") { presentTokenWindow = true }
        }
        .padding(8)
        .background(Color.yellow.opacity(0.3))
        .sheet(isPresented: $presentTokenWindow) { TokenWindow() }
    }
}
