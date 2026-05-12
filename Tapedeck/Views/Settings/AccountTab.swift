// ABOUTME: Settings → Account tab. Sign-in status + LaunchAgent toggle.

import SwiftUI
import TapedeckCore

struct AccountTab: View {
    @Environment(AppState.self) var appState
    @State private var openTokenWindow = false

    var body: some View {
        Form {
            Section("Plaud") {
                switch appState.tokenStatus {
                case "ok":
                    Label("Signed in", systemImage: "checkmark.seal")
                    Button("Sign out") { try? signOut() }
                case "expired":
                    Label("Session expired — re-sign in", systemImage: "exclamationmark.triangle")
                    Button("Re-sign in via web…") { openTokenWindow = true }
                default:    // "missing"
                    Label("Not signed in", systemImage: "key")
                    Button("Sign in via web…") { openTokenWindow = true }
                }
            }
            Section("Background sync") {
                Toggle("Enable LaunchAgent", isOn: Binding(
                    get: { FileManager.default.fileExists(atPath: LaunchAgent.plistURL.path) },
                    set: { on in if on { LaunchAgent.installIfNeeded() } else { LaunchAgent.uninstall() } }
                ))
            }
        }
        .sheet(isPresented: $openTokenWindow) { TokenWindow() }
    }

    private func signOut() throws {
        try KeychainStore.shared.delete(service: "tapedeck.source.jwt", account: "default")
        try appState.clearTokenStatus()
        Task { try? await appState.refresh() }
        AppStateNotifier.post(changedKey: "token_status")
    }
}
