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
