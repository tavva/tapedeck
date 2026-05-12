// ABOUTME: Centre pane — filtered list of recordings with status pips.

import SwiftUI
import TapedeckCore

struct RecordingList: View {
    @Environment(AppState.self) var appState

    var filtered: [Recording] {
        switch appState.selectedProject {
        case nil, "all":
            return appState.recordings
        case "unassigned":
            return appState.recordings.filter { $0.projectId == nil }
        case "archived":
            return []
        case let slug?:
            return appState.recordings.filter { $0.projectId == slug }
        }
    }

    @State private var selection: String?

    var body: some View {
        List(filtered, id: \.sourceId, selection: $selection) { rec in
            HStack {
                VStack(alignment: .leading) {
                    Text(rec.filename).font(.body)
                    Text(formatTimestamp(rec.startedAt))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPip(state: rec.audioDownloadedAt != nil ? .done : .pending,
                          error: appState.errors[rec.sourceId]?[.download] != nil)
                StatusPip(state: rec.transcribedAt != nil ? .done : .pending,
                          error: appState.errors[rec.sourceId]?[.transcribe] != nil)
                StatusPip(state: rec.classifiedAt != nil ? .done : .pending,
                          error: appState.errors[rec.sourceId]?[.classify] != nil)
                if let pid = rec.projectId {
                    Text(pid).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func formatTimestamp(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: date)
    }
}

private struct StatusPip: View {
    enum State { case done, pending }
    let state: State
    let error: Bool
    var body: some View {
        Circle()
            .fill(error ? .red : (state == .done ? .green : .gray))
            .frame(width: 8, height: 8)
    }
}
