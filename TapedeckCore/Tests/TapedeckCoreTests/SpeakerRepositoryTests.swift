// ABOUTME: Exercises SpeakerRepository: usage upsert, ranking, reconcile.
// ABOUTME: Uses Store.openInMemory() and seeds recordings via RecordingRepository.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("SpeakerRepository")
struct SpeakerRepositoryTests {
    @Test func canConstructRepository() throws {
        let store = try Store.openInMemory()
        _ = SpeakerRepository(store: store)
    }

    @Test func syncUsage_replacesAllRowsForSource() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "S1")

        try repo.syncUsage(sourceId: "S1", labels: ["Alice", "Bob"])
        try repo.syncUsage(sourceId: "S1", labels: ["Alice", "Carol"])

        let names = try fetchNames(store: store, sourceId: "S1")
        #expect(names == ["Alice", "Carol"])
    }

    @Test func syncUsage_filtersOutDefaultLabels() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "S1")

        try repo.syncUsage(sourceId: "S1", labels: ["speaker 0", "Ben", "speaker 12"])

        let names = try fetchNames(store: store, sourceId: "S1")
        #expect(names == ["Ben"])
    }

    @Test func clearUsage_removesAllRowsForSource() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "S1")
        try insertRecording(store: store, sourceId: "S2")
        try repo.syncUsage(sourceId: "S1", labels: ["Alice"])
        try repo.syncUsage(sourceId: "S2", labels: ["Bob"])

        try repo.clearUsage(sourceId: "S1")

        #expect(try fetchNames(store: store, sourceId: "S1") == [])
        #expect(try fetchNames(store: store, sourceId: "S2") == ["Bob"])
    }

    @Test func knownSpeakers_ranksProjectFirstThenFrequency() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "A", projectId: "P1")
        try insertRecording(store: store, sourceId: "B", projectId: "P2")
        try insertRecording(store: store, sourceId: "C", projectId: "P2")
        try insertRecording(store: store, sourceId: "D", projectId: "P2")

        try repo.syncUsage(sourceId: "A", labels: ["Alice"])
        try repo.syncUsage(sourceId: "B", labels: ["Bob"])
        try repo.syncUsage(sourceId: "C", labels: ["Bob"])
        try repo.syncUsage(sourceId: "D", labels: ["Bob", "Carol"])

        let speakers = try repo.knownSpeakers(for: "P1")
        #expect(speakers == [
            .init(name: "Alice", inCurrentProject: true),
            .init(name: "Bob",   inCurrentProject: false),
            .init(name: "Carol", inCurrentProject: false),
        ])
    }

    @Test func knownSpeakers_followsCurrentProjectAfterReassignment() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        let recordings = RecordingRepository(store: store)
        try insertRecording(store: store, sourceId: "S1", projectId: "P1")
        try insertProject(store: store, projectId: "P2")
        try repo.syncUsage(sourceId: "S1", labels: ["Ben"])

        try recordings.setClassification(
            sourceId: "S1", projectId: "P2",
            confidence: 1.0, reasoning: "manual", by: "user", at: 0,
            linkState: .linked)

        let inP1 = try repo.knownSpeakers(for: "P1")
        let inP2 = try repo.knownSpeakers(for: "P2")
        #expect(inP1 == [.init(name: "Ben", inCurrentProject: false)])
        #expect(inP2 == [.init(name: "Ben", inCurrentProject: true)])
    }

    @Test func knownSpeakers_excludesDefaultLabelsOnly() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "S1")

        // syncUsage will drop "speaker 0" but keep "speaker coach"
        try repo.syncUsage(sourceId: "S1", labels: ["speaker 0", "speaker coach", "Ben"])

        let names = try repo.knownSpeakers(for: nil).map(\.name)
        #expect(Set(names) == ["speaker coach", "Ben"])
    }

    @Test func reconcileAll_populatesPoolFromUnopenedTranscripts() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "A", projectId: "P1")
        try insertRecording(store: store, sourceId: "B", projectId: "P1")

        try repo.reconcileAll(from: [
            (sourceId: "A", text: "[speaker 0] hi\n\n[Alice] hello"),
            (sourceId: "B", text: "[Bob] hey"),
        ])

        let names = try repo.knownSpeakers(for: "P1").map(\.name)
        #expect(Set(names) == ["Alice", "Bob"])
    }

    @Test func reconcileAll_replacesPriorRowsForListedSources() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "A")
        try repo.syncUsage(sourceId: "A", labels: ["Stale"])

        try repo.reconcileAll(from: [
            (sourceId: "A", text: "[Fresh] hi"),
        ])

        #expect(try fetchNames(store: store, sourceId: "A") == ["Fresh"])
    }
}

private func insertProject(store: Store, projectId: String) throws {
    try store.write { db in
        try db.execute(sql: """
            INSERT OR IGNORE INTO projects(id, display_name, description, created_at)
            VALUES (?, ?, '', 0)
        """, arguments: [projectId, projectId])
    }
}

private func insertRecording(store: Store, sourceId: String, projectId: String? = nil) throws {
    if let pid = projectId {
        try insertProject(store: store, projectId: pid)
    }
    try store.write { db in
        try db.execute(sql: """
            INSERT INTO recordings(source_id, filename, started_at, duration_ms,
                                   filesize, project_link_state, last_seen_at, project_id)
            VALUES (?, 'test.ogg', 0, 0, 0, 'none', 0, ?)
        """, arguments: [sourceId, projectId])
    }
}

private func fetchNames(store: Store, sourceId: String) throws -> [String] {
    try store.read { db in
        try String.fetchAll(db, sql: """
            SELECT name FROM speaker_usage WHERE source_id = ? ORDER BY name
        """, arguments: [sourceId])
    }
}
