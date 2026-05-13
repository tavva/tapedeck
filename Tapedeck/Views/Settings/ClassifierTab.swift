// ABOUTME: Settings → Classifier tab. Gemini key + confidence threshold.

import SwiftUI
import TapedeckCore
import GRDB

struct ClassifierTab: View {
    @State private var key: String = ""
    @State private var threshold: Double = 0.7
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
                Text("Gemini")
            } footer: {
                Text("Used to classify each transcript into one of your projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    HStack {
                        Slider(value: $threshold, in: 0.5...0.95, step: 0.05)
                        Text(threshold, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                } label: {
                    Text("Confidence")
                }
            } header: {
                Text("Auto-assign threshold")
            } footer: {
                Text("Recordings below this confidence land in Unclassified for review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            key = (try? KeychainStore.shared.get(
                service: "tapedeck.gemini.key", account: "default")) ?? ""
            threshold = readThreshold()
        }
        .onChange(of: threshold) { _, newValue in writeThreshold(newValue) }
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
        try? KeychainStore.shared.set(service: "tapedeck.gemini.key", account: "default", value: key)
        saveState = .saved
    }

    private func testKey() async {
        saveState = .testing
        do {
            let c = GeminiClient(apiKey: key)
            _ = try await c.classify(transcript: "x", projects: [])
            saveState = .connected
        } catch GeminiClient.GeminiError.invalidApiKey {
            saveState = .invalid
        } catch {
            saveState = .connected
        }
    }

    private func readThreshold() -> Double {
        guard let store = try? Store.open(at: Layout.standard.dbURL()) else { return 0.7 }
        let raw: String? = (try? store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'classifier_threshold'")
        }) ?? nil
        return raw.flatMap(Double.init) ?? 0.7
    }

    private func writeThreshold(_ value: Double) {
        guard let store = try? Store.open(at: Layout.standard.dbURL()) else { return }
        try? store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES('classifier_threshold', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [String(value)])
        }
    }
}
