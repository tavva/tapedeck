// ABOUTME: Left pane — pseudo-rows (All, Unassigned, Archived) plus project list.

import SwiftUI
import TapedeckCore

struct ProjectSidebar: View {
    @Environment(AppState.self) var appState
    @State private var showingNewProject = false
    @State private var editingProject: Project?

    var body: some View {
        @Bindable var bindable = appState
        List(selection: $bindable.selectedProject) {
            Section("Views") {
                Label("All", systemImage: "tray.full").tag("all")
                Label("Unassigned", systemImage: "questionmark.diamond").tag("unassigned")
                Label("Archived", systemImage: "archivebox").tag("archived")
            }
            Section("Projects") {
                ForEach(appState.projects, id: \.id) { project in
                    Label(project.displayName, systemImage: "folder").tag(project.id)
                        .contextMenu {
                            Button("Edit…") { editingProject = project }
                            Button("Open in Finder") { FinderReveal.openProjectFolder(slug: project.id) }
                        }
                }
                Button(action: { showingNewProject = true }) {
                    Label("New project…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingNewProject) {
            ProjectForm(title: "New project", saveLabel: "Create",
                        onCancel: { showingNewProject = false },
                        onSave: { name, description in
                let slug = name.lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .filter { $0.isLetter || $0.isNumber || $0 == "-" }
                // Insert through the recordingRepo's store via direct GRDB call would be ugly;
                // re-use ProjectRepository via a fresh instance.
                let project = Project(id: slug, displayName: name,
                                      description: description,
                                      createdAt: Int64(Date().timeIntervalSince1970 * 1000),
                                      archivedAt: nil)
                try? insertProject(project)
                showingNewProject = false
                Task { try? await appState.refresh() }
            })
        }
        .sheet(item: $editingProject) { project in
            ProjectForm(title: "Edit project", saveLabel: "Save",
                        name: project.displayName, description: project.description,
                        onCancel: { editingProject = nil },
                        onSave: { name, description in
                editingProject = nil
                Task {
                    do {
                        try await appState.updateProject(id: project.id, displayName: name,
                                                         description: description)
                    } catch {
                        NSLog("updateProject \(project.id) failed: \(error)")
                    }
                }
            })
        }
    }

    private func insertProject(_ project: Project) throws {
        let store = try Store.open(at: Layout.standard.dbURL())
        try ProjectRepository(store: store).insert(project)
    }
}

/// Name + description sheet shared by project creation and editing.
private struct ProjectForm: View {
    let title: String
    let saveLabel: String
    @State var name = ""
    @State var description = ""
    let onCancel: () -> Void
    let onSave: (_ name: String, _ description: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Display name", text: $name)
            TextField("Description", text: $description, axis: .vertical)
                .lineLimit(4...12)
            Text("Used to sort recordings into this project. The classifier reads it alongside each transcript, so mention the people, topics and terms that come up in these conversations.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(saveLabel) { onSave(name, description) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }
}
