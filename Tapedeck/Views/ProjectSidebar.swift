// ABOUTME: Left pane — pseudo-rows (All, Unassigned, Archived) plus project list.

import SwiftUI
import TapedeckCore

struct ProjectSidebar: View {
    @Environment(AppState.self) var appState
    @State private var showingNewProject = false
    @State private var newName = ""
    @State private var newDescription = ""

    var body: some View {
        @Bindable var bindable = appState
        List(selection: $bindable.selectedProject) {
            Section("Views") {
                Label("All", systemImage: "tray.full").tag("all" as String?)
                Label("Unassigned", systemImage: "questionmark.diamond").tag("unassigned" as String?)
                Label("Archived", systemImage: "archivebox").tag("archived" as String?)
            }
            Section {
                ForEach(appState.projects, id: \.id) { project in
                    Label(project.displayName, systemImage: "folder").tag(project.id as String?)
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button(action: { showingNewProject = true }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New project")
                }
            }
        }
        .sheet(isPresented: $showingNewProject) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New project").font(.headline)
                TextField("Display name", text: $newName)
                TextField("Description", text: $newDescription, axis: .vertical)
                HStack {
                    Spacer()
                    Button("Cancel") { showingNewProject = false; newName = ""; newDescription = "" }
                    Button("Create") {
                        let slug = newName.lowercased()
                            .replacingOccurrences(of: " ", with: "-")
                            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
                        // Insert through the recordingRepo's store via direct GRDB call would be ugly;
                        // re-use ProjectRepository via a fresh instance.
                        let project = Project(id: slug, displayName: newName,
                                              description: newDescription,
                                              createdAt: Int64(Date().timeIntervalSince1970 * 1000),
                                              archivedAt: nil)
                        try? insertProject(project)
                        showingNewProject = false
                        newName = ""; newDescription = ""
                        Task { try? await appState.refresh() }
                    }.disabled(newName.isEmpty)
                }
            }
            .padding()
            .frame(minWidth: 360)
        }
    }

    private func insertProject(_ project: Project) throws {
        let store = try Store.open(at: Layout.standard.dbURL())
        try ProjectRepository(store: store).insert(project)
    }
}
