// ABOUTME: Opens recordings and project folders in Finder via NSWorkspace.

import AppKit
import TapedeckCore

enum FinderReveal {
    /// Reveals a recording in Finder: highlights its transcript/audio file, or
    /// opens the enclosing (project or dated audio) folder if nothing is on disk.
    static func reveal(_ rec: Recording) {
        switch Layout.standard.revealTarget(for: rec) {
        case .file(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .folder(let url):
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens a project's folder in Finder, creating it first if it doesn't exist
    /// yet (a project with no classified recordings has no folder on disk).
    static func openProjectFolder(slug: String) {
        let dir = Layout.standard.projectDir(slug: slug)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
