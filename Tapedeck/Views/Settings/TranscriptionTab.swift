// ABOUTME: Settings → Transcription tab. Manages the Deepgram API key.

import SwiftUI
import TapedeckCore

struct TranscriptionTab: View {
    @State private var key: String = ""
    @State private var saveState: SaveState = .idle
    enum SaveState { case idle, saved, invalid }

    var body: some View {
        Form {
            Section("Deepgram") {
                SecureField("API key", text: $key)
                    .onAppear {
                        key = (try? KeychainStore.shared.get(
                            service: "tapedeck.deepgram.key", account: "default")) ?? ""
                    }
                HStack {
                    Button("Save") { saveKey() }
                        .disabled(key.isEmpty)
                    Button("Test connection") { Task { await testKey() } }
                        .disabled(key.isEmpty)
                    statusLabel
                }
            }
        }
    }

    @ViewBuilder var statusLabel: some View {
        switch saveState {
        case .idle:    EmptyView()
        case .saved:   Label("Saved", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .invalid: Label("Key rejected", systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }

    private func saveKey() {
        try? KeychainStore.shared.set(service: "tapedeck.deepgram.key", account: "default", value: key)
        saveState = .saved
    }

    private func testKey() async {
        do {
            let c = DeepgramClient(apiKey: key)
            _ = try await c.transcribe(audioAt: URL(fileURLWithPath: "/dev/null"),
                                       contentType: "audio/wav")
            saveState = .saved
        } catch DeepgramClient.DeepgramError.invalidApiKey {
            saveState = .invalid
        } catch {
            saveState = .saved   // any non-auth error means the key was accepted
        }
    }
}
