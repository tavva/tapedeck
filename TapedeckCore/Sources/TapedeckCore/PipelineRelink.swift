// ABOUTME: Relink stage. Updates project-folder symlinks/copies for newly classified rows.

import Foundation

extension Pipeline {
    public func relinkChanged() throws {
        let pending = (try? recordings.recordingsNeedingRelink()) ?? []
        for rec in pending {
            do {
                if let oldSlug = rec.linkedProjectId {
                    try removeProjectLinks(rec: rec, slug: oldSlug)
                }
                if let newSlug = rec.projectId {
                    try writeProjectLinks(rec: rec, slug: newSlug)
                }
                try recordings.markLinked(sourceId: rec.sourceId, linkedProjectId: rec.projectId)
                try recordings.clearError(sourceId: rec.sourceId, stage: .link)
            } catch {
                try? recordings.recordError(sourceId: rec.sourceId, stage: .link,
                                            at: deps.now(), message: "\(error)")
                deps.logger.error("relink_failed", source: rec.sourceId, message: "\(error)")
            }
        }
    }

    private func writeProjectLinks(rec: Recording, slug: String) throws {
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let audioDir = deps.layout.audioDir(date: date)
        let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let projectDir = deps.layout.projectDir(slug: slug)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        func replaceCopy(from src: URL, to dst: URL) throws {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
        }
        try replaceCopy(from: audioDir.appending(path: "\(stem).transcript.txt"),
                        to: projectDir.appending(path: "\(stem).transcript.txt"))
        try replaceCopy(from: audioDir.appending(path: "\(stem).deepgram.json"),
                        to: projectDir.appending(path: "\(stem).deepgram.json"))

        let ext = rec.audioExtension ?? "audio"
        let audio = audioDir.appending(path: "\(stem).\(ext)")
        let link = projectDir.appending(path: "\(stem).\(ext)")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: audio)
    }

    private func removeProjectLinks(rec: Recording, slug: String) throws {
        let projectDir = deps.layout.projectDir(slug: slug)
        let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        for ext in ["transcript.txt", "deepgram.json",
                    rec.audioExtension ?? "audio"] {
            try? FileManager.default.removeItem(at: projectDir.appending(path: "\(stem).\(ext)"))
        }
    }
}
