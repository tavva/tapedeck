// ABOUTME: Sign-in helper. Opens Plaud in the user's default browser; user pastes the copied session JSON here.
// ABOUTME: Manual paste because Plaud's sign-in uses Google Identity Services, which refuses to run in WKWebView.

import SwiftUI
import AppKit
import TapedeckCore

struct TokenWindow: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) var dismiss
    @State private var pasted = ""

    private static let plaudURL = URL(string: "https://web.plaud.ai/")!
    /// Copies the current workspace's tokens (plus its id) from the Plaud web app's storage.
    private static let consoleSnippet =
        "copy(JSON.stringify((w=>({workspaceId:w,...JSON.parse(localStorage['pld_session.tokens'])" +
        ".byWsId[w]}))(JSON.parse(localStorage['pld_session.workspace']).currentId)))"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to Plaud")
                .font(.headline)

            Text("Plaud's sign-in widget doesn't work inside the app. Sign in via your browser and paste your session here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(1) {
                Button("Open Plaud in browser") {
                    NSWorkspace.shared.open(Self.plaudURL)
                }
                .buttonStyle(.borderedProminent)
            }

            step(2) {
                Text("Sign in as usual.")
                    .font(.callout)
            }

            step(3) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open your browser's developer console and run this. It copies your session to the clipboard:")
                        .font(.callout)
                    HStack(spacing: 6) {
                        Text(Self.consoleSnippet)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.consoleSnippet, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            step(4) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste it here:")
                        .font(.callout)
                    TextField(#"{"workspaceId":"ws_…","token":"eyJ…",…}"#, text: $pasted, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    if !trimmedPaste.isEmpty && credentials == nil {
                        Text("That isn't the copied session. Run the snippet again and paste what it copies.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save session") { if let credentials { save(credentials) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(credentials == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func step<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private var trimmedPaste: String {
        pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var credentials: PlaudCredentials? {
        try? PlaudCredentials(json: trimmedPaste)
    }

    private func save(_ credentials: PlaudCredentials) {
        guard let json = try? credentials.json() else { return }
        try? KeychainStore.shared.set(
            service: PlaudCredentials.keychainService, account: "default", value: json)
        try? appState.clearTokenStatus()
        AppStateNotifier.post(changedKey: "token_status")
        Task { try? await appState.refresh(); dismiss() }
    }
}
