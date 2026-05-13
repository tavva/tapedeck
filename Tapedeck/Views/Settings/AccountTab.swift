// ABOUTME: Settings → Account tab. Sign-in status + LaunchAgent toggle.

import SwiftUI
import TapedeckCore

struct AccountTab: View {
    @Environment(AppState.self) var appState
    @State private var openTokenWindow = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { statusLabel }
                HStack {
                    Spacer()
                    actionButton
                }
            } header: {
                Text("Plaud")
            } footer: {
                Text("Tapedeck uses your Plaud session token to fetch new recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: launchAgentBinding) {
                    Text("Run Tapedeck Sync in the background")
                    Text("Periodically pulls new recordings even when Tapedeck isn't open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Background sync")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $openTokenWindow) { TokenWindow() }
    }

    @ViewBuilder private var statusLabel: some View {
        switch appState.tokenStatus {
        case "ok":
            Label("Signed in", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case "expired":
            Label("Session expired", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        default:
            Label("Not signed in", systemImage: "key")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch appState.tokenStatus {
        case "ok":
            Button("Sign out", role: .destructive) { try? signOut() }
        case "expired":
            Button("Re-sign in via web…") { openTokenWindow = true }
                .buttonStyle(.borderedProminent)
        default:
            Button("Sign in via web…") { openTokenWindow = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var launchAgentBinding: Binding<Bool> {
        Binding(
            get: { FileManager.default.fileExists(atPath: LaunchAgent.plistURL.path) },
            set: { on in if on { LaunchAgent.installIfNeeded() } else { LaunchAgent.uninstall() } }
        )
    }

    private func signOut() throws {
        try KeychainStore.shared.delete(service: "tapedeck.source.jwt", account: "default")
        try appState.clearTokenStatus()
        Task { try? await appState.refresh() }
        AppStateNotifier.post(changedKey: "token_status")
    }
}
