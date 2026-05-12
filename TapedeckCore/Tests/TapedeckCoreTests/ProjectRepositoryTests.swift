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

        try repo.insert(.init(id: "kitchen-reno", displayName: "Kitchen Reno",
                              description: "Cabinets, flooring and appliances", createdAt: 1, archivedAt: nil))
        try repo.insert(.init(id: "marketing", displayName: "Marketing",
                              description: "Campaign planning", createdAt: 2, archivedAt: nil))

        let active = try repo.listActive()
        #expect(active.map(\.id) == ["kitchen-reno", "marketing"])
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
