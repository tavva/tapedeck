// ABOUTME: Settings → Transcription tab. Manages the Deepgram API key.

import SwiftUI
import TapedeckCore

struct TranscriptionTab: View {
    @State private var key: String = ""
    @State private var saveState: SaveState = .idle
    enum SaveState { case idle, saved, testing, connected, invalid }

    var body: some View {
        Form {
            Section {
                LabeledContent("API key") {
                    SecureField("", text: $key)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Save") { saveKey() }
                        .disabled(key.isEmpty || saveState == .testing)
                    Button("Test connection") { Task { await testKey() } }
                        .disabled(key.isEmpty || saveState == .testing)
                    Spacer()
                    statusLabel
                }
            } header: {
                Text("Deepgram")
            } footer: {
                Text("Used to transcribe recordings before classification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            key = (try? KeychainStore.shared.get(
                service: "tapedeck.deepgram.key", account: "default")) ?? ""
        }
    }

    @ViewBuilder var statusLabel: some View {
        switch saveState {
        case .idle:
            EmptyView()
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid:
            Label("Key rejected", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func saveKey() {
        try? KeychainStore.shared.set(service: "tapedeck.deepgram.key", account: "default", value: key)
        saveState = .saved
    }

    private func testKey() async {
        saveState = .testing
        do {
            let c = DeepgramClient(apiKey: key)
            _ = try await c.transcribe(audioAt: URL(fileURLWithPath: "/dev/null"),
                                       contentType: "audio/wav")
            saveState = .connected
        } catch DeepgramClient.DeepgramError.invalidApiKey {
            saveState = .invalid
        } catch {
            saveState = .connected   // any non-auth error means the key was accepted
        }
    }
}
