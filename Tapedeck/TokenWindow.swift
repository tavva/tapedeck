// ABOUTME: Sign-in helper. Opens Plaud in the user's default browser; user pastes the captured JWT here.
// ABOUTME: Manual paste because Plaud's sign-in uses Google Identity Services, which refuses to run in WKWebView.

import SwiftUI
import AppKit
import TapedeckCore

struct TokenWindow: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) var dismiss
    @State private var pasted = ""

    private static let plaudURL = URL(string: "https://web.plaud.ai/")!
    private static let consoleSnippet = "localStorage.getItem('pld_tokenstr')"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to Plaud")
                .font(.headline)

            Text("Plaud's sign-in widget doesn't work inside the app. Sign in via your browser and paste the session token here.")
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
                    Text("Open your browser's developer console and run:")
                        .font(.callout)
                    HStack(spacing: 6) {
                        Text(Self.consoleSnippet)
                            .font(.system(.callout, design: .monospaced))
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
                    Text("Paste the result (the long eyJ… string):")
                        .font(.callout)
                    TextField("eyJhbGciOi…", text: $pasted, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save token") { save(pasted) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private func save(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let token = unquoted.hasPrefix("bearer ")
            ? String(unquoted.dropFirst("bearer ".count)) : unquoted
        try? KeychainStore.shared.set(
            service: "tapedeck.source.jwt", account: "default", value: token)
        try? appState.clearTokenStatus()
        AppStateNotifier.post(changedKey: "token_status")
        Task { try? await appState.refresh(); dismiss() }
    }
}
