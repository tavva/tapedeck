// ABOUTME: WKWebView-based capture of the Plaud session JWT from web.plaud.ai localStorage.
// ABOUTME: Polls localStorage every 1s; after 90s reveals a manual paste field.

import SwiftUI
import WebKit
import TapedeckCore

struct TokenWindow: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) var dismiss
    @State private var showPaste = false
    @State private var pasted = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("Sign in to Plaud")
                .font(.headline)
            PlaudWebView { token in
                save(token)
            }
            .frame(minWidth: 600, minHeight: 500)
            .onAppear {
                Task { try? await Task.sleep(nanoseconds: 90_000_000_000); showPaste = true }
            }
            if showPaste {
                VStack(alignment: .leading) {
                    Text("Or paste the JWT manually:").font(.caption)
                    TextField("eyJhbGciOi…", text: $pasted)
                        .textFieldStyle(.roundedBorder)
                    Button("Save pasted token") {
                        save(pasted)
                    }
                    .disabled(pasted.isEmpty)
                }
                .padding(.horizontal)
            }
        }
        .padding()
    }

    private func save(_ raw: String) {
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let token = unquoted.hasPrefix("bearer ")
            ? String(unquoted.dropFirst("bearer ".count)) : unquoted
        try? KeychainStore.shared.set(
            service: "tapedeck.source.jwt", account: "default", value: token)
        try? appState.clearTokenStatus()
        AppStateNotifier.post(changedKey: "token_status")
        Task { try? await appState.refresh(); dismiss() }
    }
}

private struct PlaudWebView: NSViewRepresentable {
    let onCapture: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://web.plaud.ai/")!))
        context.coordinator.startPolling(view)
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCapture: (String) -> Void
        var timer: Timer?
        init(onCapture: @escaping (String) -> Void) { self.onCapture = onCapture }
        func startPolling(_ view: WKWebView) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak view, onCapture] _ in
                guard let view else { return }
                view.evaluateJavaScript("localStorage.getItem('pld_tokenstr')") { value, _ in
                    if let raw = value as? String, !raw.isEmpty, raw != "null" {
                        onCapture(raw)
                    }
                }
            }
        }
    }
}
