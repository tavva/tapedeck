// ABOUTME: Speaker rename panel above the transcript editor in DetailPane.
// ABOUTME: Renders one row per [label] found in the transcript text.

import SwiftUI
import TapedeckCore

struct SpeakerEditor: View {
    @Environment(AppState.self) private var appState
    let sourceId: String
    let projectId: String?
    let transcript: String
    let onApply: (_ old: String, _ new: String) async -> Void

    @State private var editText: [String: String] = [:]
    @State private var known: [KnownSpeaker] = []
    @State private var pendingMerge: PendingMerge? = nil

    private struct PendingMerge: Equatable {
        let oldLabel: String
        let newLabel: String
    }

    private var labels: [String] { parseLabels(transcript) }

    var body: some View {
        if labels.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speakers").font(.caption).foregroundStyle(.secondary)
                ForEach(labels, id: \.self) { label in
                    row(for: label)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
            // Reload when the recording changes, when its project changes,
            // or when the parsed-label set changes (after a rename).
            .task(id: ReloadKey(sourceId: sourceId, projectId: projectId,
                                 labels: labels)) {
                reload()
            }
            .alert("Merge speakers?",
                   isPresented: Binding(
                       get: { pendingMerge != nil },
                       set: { if !$0 { pendingMerge = nil } })) {
                Button("Cancel", role: .cancel) { pendingMerge = nil }
                Button("Merge", role: .destructive) {
                    if let m = pendingMerge {
                        Task { await onApply(m.oldLabel, m.newLabel) }
                    }
                    pendingMerge = nil
                }
            } message: {
                if let m = pendingMerge {
                    Text("\"[\(m.newLabel)]\" already exists in this transcript. " +
                         "Merging cannot be undone without re-transcribing.")
                }
            }
        }
    }

    private struct ReloadKey: Equatable {
        let sourceId: String
        let projectId: String?
        let labels: [String]
    }

    @ViewBuilder
    private func row(for label: String) -> some View {
        let typed = editText[label] ?? label
        let validationError = validate((editText[label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let candidateChanged = typed.trimmingCharacters(in: .whitespacesAndNewlines) != label
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("[\(label)]")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 110, alignment: .leading)
                Text("→").foregroundStyle(.secondary)
                TextField("name", text: binding(for: label))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { Task { await applyRename(label: label) } }
                Button("Apply") {
                    Task { await applyRename(label: label) }
                }
                .disabled(!candidateChanged || validationError != nil)
                Menu("▼") {
                    let filtered = filteredKnown(matching: typed)
                    let inProject = filtered.filter(\.inCurrentProject)
                    let others = filtered.filter { !$0.inCurrentProject }
                    if !inProject.isEmpty {
                        Section("This project") {
                            ForEach(inProject, id: \.name) { s in
                                Button(s.name) { editText[label] = s.name }
                            }
                        }
                    }
                    if !others.isEmpty {
                        Section(inProject.isEmpty ? "All speakers" : "Other") {
                            ForEach(others, id: \.name) { s in
                                Button(s.name) { editText[label] = s.name }
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Text(known.isEmpty ? "No saved speakers yet"
                                           : "No matches").disabled(true)
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }
            // Live error: only surface once the user has typed something that
            // diverges from the original label and is invalid.
            if candidateChanged, let err = validationError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(.leading, 118)
            }
        }
    }

    /// Returns the validation error for a candidate name, or nil if valid.
    /// Used both to gate the Apply button and to render the inline error.
    private func validate(_ name: String) -> String? {
        if name.isEmpty { return "Name cannot be empty" }
        if name.contains("[") || name.contains("]") || name.contains("\n") {
            return "Name cannot contain [, ], or newlines"
        }
        return nil
    }

    private func applyRename(label: String) async {
        let candidate = (editText[label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate != label else { return }
        guard validate(candidate) == nil else { return }
        if labels.contains(candidate) {
            pendingMerge = PendingMerge(oldLabel: label, newLabel: candidate)
            return
        }
        await onApply(label, candidate)
        // editText is cleared by DetailPane re-reading the transcript, which
        // changes the parsed `labels` set and re-renders this view.
    }

    private func binding(for label: String) -> Binding<String> {
        Binding(
            get: { editText[label] ?? label },
            set: { editText[label] = $0 }
        )
    }

    /// Case-insensitive prefix match. When the field still holds the original
    /// `[speaker N]` label (untouched), return the full list so the user sees
    /// every option in their first interaction.
    private func filteredKnown(matching typed: String) -> [KnownSpeaker] {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || labels.contains(trimmed) { return known }
        let lower = trimmed.lowercased()
        return known.filter { $0.name.lowercased().hasPrefix(lower) }
    }

    func reload() {
        known = (try? appState.speakers.knownSpeakers(for: projectId)) ?? []
    }
}
