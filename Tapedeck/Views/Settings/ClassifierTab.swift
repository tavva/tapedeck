// ABOUTME: Settings → Classifier tab. Gemini key + confidence threshold.

import SwiftUI
import TapedeckCore
import GRDB

struct ClassifierTab: View {
    @State private var key: String = ""
    @State private var threshold: Double = 0.7
    @State private var saveState: SaveState = .idle
    enum SaveState { case idle, saved, invalid }

    var body: some View {
        Form {
            Section("Gemini") {
                SecureField("API key", text: $key)
                    .onAppear {
                        key = (try? KeychainStore.shared.get(
                            service: "tapedeck.gemini.key", account: "default")) ?? ""
                        threshold = readThreshold()
                    }
                HStack {
                    Button("Save") { saveKey() }
                        .disabled(key.isEmpty)
                    Button("Test connection") { Task { await testKey() } }
                        .disabled(key.isEmpty)
                    statusLabel
                }
            }
            Section("Confidence threshold") {
                Slider(value: $threshold, in: 0.5...0.95, step: 0.05) {
                    Text("Threshold: \(threshold, format: .number.precision(.fractionLength(2)))")
                }
                .onChange(of: threshold) { _, newValue in writeThreshold(newValue) }
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
        try? KeychainStore.shared.set(service: "tapedeck.gemini.key", account: "default", value: key)
        saveState = .saved
    }

    private func testKey() async {
        do {
            let c = GeminiClient(apiKey: key)
            _ = try await c.classify(transcript: "x", projects: [])
            saveState = .saved
        } catch GeminiClient.GeminiError.invalidApiKey {
            saveState = .invalid
        } catch {
            saveState = .saved
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
