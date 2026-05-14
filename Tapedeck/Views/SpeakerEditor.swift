// ABOUTME: Speaker rename panel above the transcript editor in DetailPane.
// ABOUTME: Renders one row per [label] found in the transcript text.

import SwiftUI
import TapedeckCore

struct SpeakerEditor: View {
    let sourceId: String
    let projectId: String?
    let transcript: String
    let onApply: (_ old: String, _ new: String) async -> Void

    private var labels: [String] { parseLabels(transcript) }

    var body: some View {
        if labels.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speakers").font(.caption).foregroundStyle(.secondary)
                ForEach(labels, id: \.self) { label in
                    HStack {
                        Text("[\(label)]").font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
        }
    }
}
