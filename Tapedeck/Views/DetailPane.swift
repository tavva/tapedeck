// ABOUTME: Right pane — selected recording details, transcript, classification picker.

import SwiftUI
import TapedeckCore

struct DetailPane: View {
    @Environment(AppState.self) var appState
    @State private var transcriptText: String = ""

    private var selected: Recording? {
        guard let id = appState.selectedSourceId else { return nil }
        return appState.recordings.first { $0.sourceId == id }
    }

    var body: some View {
        Group {
            if let rec = selected {
                detailView(rec)
            } else {
                Text("Select a recording").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func detailView(_ rec: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(rec.filename).font(.title2).bold()
                Text("\(Duration.milliseconds(rec.durationMs).formatted(.units(width: .narrow))) · \(rec.filesize / 1024) KB")
                    .font(.caption).foregroundStyle(.secondary)
                if let confidence = rec.classificationConfidence {
                    let projectId = Binding<String?>(
                        get: { rec.projectId },
                        set: { newValue in
                            Task { try? await appState.overrideProject(sourceId: rec.sourceId, newProjectId: newValue) }
                        }
                    )
                    Picker("Project", selection: projectId) {
                        Text("Unassigned").tag(nil as String?)
                        ForEach(appState.projects, id: \.id) { project in
                            Text(project.displayName).tag(project.id as String?)
                        }
                    }
                    Text(String(format: "Confidence: %.2f", confidence))
                        .font(.caption).foregroundStyle(.secondary)
                    if let reasoning = rec.classificationReasoning {
                        Text(reasoning).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button("▶ Play") {
                        appState.playback.load(rec)
                        appState.playback.togglePlayPause()
                    }
                    .disabled(rec.audioDownloadedAt == nil)
                    Button(rec.transcribedAt == nil ? "Transcribe" : "Retranscribe") {
                        Task { await appState.transcribeOne(sourceId: rec.sourceId,
                                                            reason: "ui_transcribe_one") }
                    }
                    .disabled(appState.activity != nil
                              || rec.audioDownloadedAt == nil)
                    Button(rec.classifiedAt == nil ? "Classify" : "Reclassify") {
                        Task { await appState.classifyOne(sourceId: rec.sourceId,
                                                          reason: "ui_classify_one") }
                    }
                    .disabled(appState.activity != nil
                              || rec.transcribedAt == nil
                              || appState.projects.isEmpty)
                }
                if !transcriptText.isEmpty {
                    SpeakerEditor(
                        sourceId: rec.sourceId,
                        projectId: rec.projectId,
                        transcript: transcriptText,
                        onApply: { old, new in
                            await applyRename(rec: rec, old: old, new: new)
                        }
                    )
                }
                TextEditor(text: .constant(transcriptText))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
            }
            .padding()
        }
        .onAppear { loadTranscript(rec) }
        .onChange(of: rec.sourceId) { _, _ in loadTranscript(rec) }
        .onChange(of: rec.transcribedAt) { _, _ in loadTranscript(rec) }
    }

    private func loadTranscript(_ rec: Recording) {
        let url = transcriptURL(for: rec)
        transcriptText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? appState.speakers.syncUsage(
            sourceId: rec.sourceId,
            labels: parseLabels(transcriptText))
    }

    private func applyRename(rec: Recording, old: String, new: String) async {
        let url = transcriptURL(for: rec)
        guard let current = try? String(contentsOf: url, encoding: .utf8) else { return }
        let updated = renameLabel(current, from: old, to: new)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            // Update speaker_usage immediately on file rewrite — independent
            // of any later relink work that might throw before loadTranscript
            // runs at the end of this block.
            try? appState.speakers.syncUsage(
                sourceId: rec.sourceId,
                labels: parseLabels(updated))

            if rec.linkedProjectId != nil {
                try appState.recordingRepo.markPendingRelink(sourceId: rec.sourceId)
                // Refresh now so the UI reflects the new labels immediately;
                // syncNow will refresh again once the helper finishes relinking.
                try await appState.refresh()
                Task { await appState.syncNow(reason: "speaker_rename") }
            }
            loadTranscript(rec)
        } catch {
            NSLog("SpeakerEditor apply failed: \(error)")
        }
    }

    /// URL of the on-disk transcript file. Derived from `sourceId`, `filename`,
    /// and `startedAt` — all stable identity fields — so it remains correct
    /// even when called via a stale `Recording` value captured into a closure.
    private func transcriptURL(for rec: Recording) -> URL {
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let dir = Layout.standard.audioDir(date: date)
        let stem = Layout.standard.stem(sourceId: rec.sourceId, title: rec.filename)
        return dir.appending(path: "\(stem).transcript.txt")
    }
}
