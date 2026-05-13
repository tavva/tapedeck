// ABOUTME: Right pane — selected recording details, transcript, classification picker.

import SwiftUI
import AVKit
import TapedeckCore

struct DetailPane: View {
    @Environment(AppState.self) var appState
    @State private var player: AVAudioPlayer?
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
                Button("▶ Play") { play(rec) }
                    .disabled(rec.audioDownloadedAt == nil)
                TextEditor(text: .constant(transcriptText))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
            }
            .padding()
        }
        .onAppear { loadTranscript(rec) }
        .onChange(of: rec.sourceId) { _, _ in loadTranscript(rec) }
    }

    private func loadTranscript(_ rec: Recording) {
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let dir = Layout.standard.audioDir(date: date)
        let stem = Layout.standard.stem(sourceId: rec.sourceId, title: rec.filename)
        let url = dir.appending(path: "\(stem).transcript.txt")
        transcriptText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func play(_ rec: Recording) {
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let dir = Layout.standard.audioDir(date: date)
        let stem = Layout.standard.stem(sourceId: rec.sourceId, title: rec.filename)
        let ext = rec.audioExtension ?? "audio"
        let url = dir.appending(path: "\(stem).\(ext)")
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}
