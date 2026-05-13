// ABOUTME: Persistent player bar along the bottom of the main window. Reads state
// ABOUTME: from AppState.playback and routes button/slider events back to it.

import SwiftUI

struct PlayerBar: View {
    @Environment(AppState.self) var appState

    var body: some View {
        if let rec = appState.playback.currentRecording {
            HStack(spacing: 12) {
                Button {
                    appState.playback.togglePlayPause()
                } label: {
                    Image(systemName: appState.playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)

                Text(rec.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)

                Text(formatTime(appState.playback.currentTime))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { appState.playback.currentTime },
                        set: { appState.playback.seek(to: $0) }
                    ),
                    in: 0...max(appState.playback.duration, 0.01)
                )

                Text(formatTime(appState.playback.duration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(height: 44)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
