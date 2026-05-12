// ABOUTME: Pure SQL access for the projects table. No business logic.
// ABOUTME: Methods are throws + synchronous; callers run them in Task.detached if needed.

import Foundation
import GRDB

public struct ProjectRepository: Sendable {
    let store: Store

    public init(store: Store) { self.store = store }

    public func insert(_ project: Project) throws {
        try store.write { db in try project.insert(db) }
    }

    public func update(_ project: Project) throws {
        try store.write { db in try project.update(db) }
    }

    public func archive(id: String, at: Int64) throws {
        try store.write { db in
            try db.execute(sql: "UPDATE projects SET archived_at = ? WHERE id = ?", arguments: [at, id])
        }
    }

    public func unarchive(id: String) throws {
        try store.write { db in
            try db.execute(sql: "UPDATE projects SET archived_at = NULL WHERE id = ?", arguments: [id])
        }
    }

    public func findById(_ id: String) throws -> Project? {
        try store.read { db in try Project.fetchOne(db, key: id) }
    }

    public func listActive() throws -> [Project] {
        try store.read { db in
            try Project.filter(sql: "archived_at IS NULL")
                .order(sql: "created_at ASC")
                .fetchAll(db)
        }
    }

    public func listAll() throws -> [Project] {
        try store.read { db in try Project.order(sql: "created_at ASC").fetchAll(db) }
    }
}
