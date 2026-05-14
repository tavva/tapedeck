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
}

private func insertRecording(store: Store, sourceId: String, projectId: String? = nil) throws {
    if let pid = projectId {
        try store.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO projects(id, display_name, description, created_at)
                VALUES (?, ?, '', 0)
            """, arguments: [pid, pid])
        }
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
