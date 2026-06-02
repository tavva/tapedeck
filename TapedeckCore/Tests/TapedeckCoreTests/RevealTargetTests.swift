// ABOUTME: Verifies which on-disk file or folder Finder should reveal for a recording.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("RevealTarget")
struct RevealTargetTests {
    private func makeLayout() -> Layout {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "tapedeck-reveal-\(UUID())")
        return Layout(userRoot: tmp.appending(path: "user"),
                      supportRoot: tmp.appending(path: "support"),
                      logsRoot: tmp.appending(path: "logs"))
    }

    // 2026-05-11T09:30:00Z
    private let startedAt: Int64 = 1_778_491_800_000

    private func recording(projectId: String?) -> Recording {
        Recording(sourceId: "rec-1", filename: "Meeting", startedAt: startedAt,
                  durationMs: 0, filesize: 0, audioExtension: "ogg",
                  projectId: projectId, lastSeenAt: 0)
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func audioDir(_ layout: Layout) -> URL {
        layout.audioDir(date: Date(timeIntervalSince1970: TimeInterval(startedAt) / 1000))
    }

    @Test func classifiedTranscribedRevealsProjectTranscript() throws {
        let layout = makeLayout()
        let rec = recording(projectId: "engineering")
        let stem = layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let projectTranscript = layout.projectDir(slug: "engineering").appending(path: "\(stem).transcript.txt")
        try write(projectTranscript)

        #expect(layout.revealTarget(for: rec) == .file(projectTranscript))
    }

    @Test func unclassifiedTranscribedRevealsAudioDirTranscript() throws {
        let layout = makeLayout()
        let rec = recording(projectId: nil)
        let stem = layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let transcript = audioDir(layout).appending(path: "\(stem).transcript.txt")
        try write(transcript)

        #expect(layout.revealTarget(for: rec) == .file(transcript))
    }

    @Test func downloadedButNotTranscribedRevealsAudioFile() throws {
        let layout = makeLayout()
        let rec = recording(projectId: nil)
        let stem = layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let audio = audioDir(layout).appending(path: "\(stem).ogg")
        try write(audio)

        #expect(layout.revealTarget(for: rec) == .file(audio))
    }

    @Test func classifiedButProjectDirMissingFallsBackToAudioDir() throws {
        let layout = makeLayout()
        let rec = recording(projectId: "engineering")
        let stem = layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let transcript = audioDir(layout).appending(path: "\(stem).transcript.txt")
        try write(transcript)  // project dir never created

        #expect(layout.revealTarget(for: rec) == .file(transcript))
    }

    @Test func nothingOnDiskOpensDatedAudioFolder() throws {
        let layout = makeLayout()
        let rec = recording(projectId: nil)

        #expect(layout.revealTarget(for: rec) == .folder(audioDir(layout)))
    }
}
