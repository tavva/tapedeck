// ABOUTME: Exercises Project CRUD: insert, list active, archive, edit.
// ABOUTME: Uses Store.openInMemory() for isolation.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("ProjectRepository")
struct ProjectRepositoryTests {
    @Test func insertAndListActive() throws {
        let store = try Store.openInMemory()
        let repo = ProjectRepository(store: store)

        try repo.insert(.init(id: "homeschool-mvp", displayName: "Homeschool MVP",
                              description: "Curriculum planning for two kids", createdAt: 1, archivedAt: nil))
        try repo.insert(.init(id: "investors", displayName: "Investors",
                              description: "Fundraising conversations", createdAt: 2, archivedAt: nil))

        let active = try repo.listActive()
        #expect(active.map(\.id) == ["homeschool-mvp", "investors"])
    }

    @Test func archiveHidesProjectFromListActive() throws {
        let store = try Store.openInMemory()
        let repo = ProjectRepository(store: store)
        try repo.insert(.init(id: "p1", displayName: "P1", description: "", createdAt: 1, archivedAt: nil))
        try repo.archive(id: "p1", at: 5)

        #expect(try repo.listActive().isEmpty)
        let archived = try repo.findById("p1")
        #expect(archived?.archivedAt == 5)
    }
}
