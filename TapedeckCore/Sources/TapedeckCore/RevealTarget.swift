// ABOUTME: Resolves which on-disk file or folder Finder should reveal for a recording.

import Foundation

public enum RevealTarget: Equatable, Sendable {
    case file(URL)    // open the enclosing folder and highlight this file
    case folder(URL)  // open this folder's contents
}

extension Layout {
    /// The Finder reveal target for a recording. Classified recordings resolve to
    /// their project folder (the relinked copy); others to the dated audio folder.
    /// Prefers the transcript, then the audio file, then the folder itself.
    public func revealTarget(for rec: Recording, fileManager fm: FileManager = .default) -> RevealTarget {
        let audio = audioDir(date: Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000))
        let folder: URL
        if let slug = rec.projectId, fm.fileExists(atPath: projectDir(slug: slug).path) {
            folder = projectDir(slug: slug)
        } else {
            folder = audio
        }
        let stem = stem(sourceId: rec.sourceId, title: rec.filename)

        let transcript = folder.appending(path: "\(stem).transcript.txt")
        if fm.fileExists(atPath: transcript.path) { return .file(transcript) }

        if let ext = rec.audioExtension {
            let audioFile = folder.appending(path: "\(stem).\(ext)")
            if fm.fileExists(atPath: audioFile.path) { return .file(audioFile) }
        }

        return .folder(folder)
    }
}
