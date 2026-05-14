// ABOUTME: SQL access for speaker_usage. Drives the rename-flow dropdown.
// ABOUTME: Holds no business logic — see SpeakerEditor for the rename flow.

import Foundation
import GRDB

public struct KnownSpeaker: Sendable, Equatable {
    public let name: String
    public let inCurrentProject: Bool

    public init(name: String, inCurrentProject: Bool) {
        self.name = name
        self.inCurrentProject = inCurrentProject
    }
}

public struct SpeakerRepository: Sendable {
    let store: Store

    public init(store: Store) { self.store = store }

    /// Replaces every `speaker_usage` row for `sourceId` with `labels`,
    /// filtering out default `speaker N` entries. Called on transcript load
    /// and after every rename so the DB tracks the file as canonical.
    public func syncUsage(sourceId: String, labels: [String]) throws {
        try store.write { db in
            try syncUsageInTx(db, sourceId: sourceId, labels: labels)
        }
    }

    /// Returns every distinct speaker name (excluding `speaker N` defaults)
    /// ordered by: rows whose recording is in `projectId` first (by their
    /// in-project frequency), then the rest by global frequency, with
    /// alphabetical name as the final tiebreak.
    public func knownSpeakers(for projectId: String?) throws -> [KnownSpeaker] {
        try store.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT u.name AS name,
                       SUM(CASE WHEN r.project_id = ? THEN 1 ELSE 0 END) AS in_project,
                       COUNT(*) AS total
                FROM speaker_usage u
                JOIN recordings r ON r.source_id = u.source_id
                GROUP BY u.name
                ORDER BY in_project DESC, total DESC, u.name ASC
            """, arguments: [projectId])

            return rows.compactMap { row in
                let name: String = row["name"]
                guard !isDefaultLabel(name) else { return nil }
                let inProject: Int = row["in_project"]
                return KnownSpeaker(name: name, inCurrentProject: inProject > 0)
            }
        }
    }

    /// Removes every `speaker_usage` row for `sourceId`. Called when a
    /// transcript is rewritten by re-transcription.
    public func clearUsage(sourceId: String) throws {
        try store.write { db in
            try db.execute(sql: "DELETE FROM speaker_usage WHERE source_id = ?",
                           arguments: [sourceId])
        }
    }

    /// Shared transaction body. `syncUsage` and `reconcileAll` both call this;
    /// the caller is responsible for owning the surrounding `store.write`.
    func syncUsageInTx(_ db: Database, sourceId: String, labels: [String]) throws {
        try db.execute(sql: "DELETE FROM speaker_usage WHERE source_id = ?",
                       arguments: [sourceId])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var inserted = Set<String>()
        for raw in labels {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isDefaultLabel(name) else { continue }
            guard inserted.insert(name).inserted else { continue }
            try db.execute(sql: """
                INSERT INTO speaker_usage(name, source_id, used_at) VALUES (?, ?, ?)
            """, arguments: [name, sourceId, now])
        }
    }
}
