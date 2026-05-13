// ABOUTME: Covers idempotent upsert, error rows, and classify-state transitions.
// ABOUTME: Each test gets a fresh in-memory store.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("RecordingRepository")
struct RecordingRepositoryTests {
    private func setup() throws -> (Store, RecordingRepository) {
        let store = try Store.openInMemory()
        return (store, RecordingRepository(store: store))
    }

    @Test func upsertIsIdempotentOnSourceId() throws {
        let (_, repo) = try setup()
        let r1 = Recording(sourceId: "abc", filename: "Meeting 1", startedAt: 1000,
                           durationMs: 60_000, filesize: 1_024, audioExtension: nil,
                           lastSeenAt: 1)
        try repo.upsertFromRemote(r1)
        try repo.upsertFromRemote(r1)
        #expect(try repo.count() == 1)
    }

    @Test func findReturnsNilForUnknownSourceId() throws {
        let (_, repo) = try setup()
        #expect(try repo.find(sourceId: "missing") == nil)
    }

    @Test func findReturnsRecordingForKnownSourceId() throws {
        let (_, repo) = try setup()
        let r = Recording(sourceId: "abc", filename: "Meeting", startedAt: 1000,
                          durationMs: 60_000, filesize: 1_024, audioExtension: "opus",
                          lastSeenAt: 1)
        try repo.upsertFromRemote(r)
        let found = try repo.find(sourceId: "abc")
        #expect(found?.sourceId == "abc")
        #expect(found?.filename == "Meeting")
        #expect(found?.audioExtension == "opus")
    }

    @Test func recordErrorThenClearOnSuccess() throws {
        let (_, repo) = try setup()
        let r = Recording(sourceId: "abc", filename: "x", startedAt: 1, durationMs: 1,
                          filesize: 1, audioExtension: nil, lastSeenAt: 1)
        try repo.upsertFromRemote(r)
        try repo.recordError(sourceId: "abc", stage: .transcribe, at: 10, message: "boom")

        #expect(try repo.error(sourceId: "abc", stage: .transcribe)?.attempt == 1)
        try repo.recordError(sourceId: "abc", stage: .transcribe, at: 20, message: "boom again")
        #expect(try repo.error(sourceId: "abc", stage: .transcribe)?.attempt == 2)

        try repo.clearError(sourceId: "abc", stage: .transcribe)
        #expect(try repo.error(sourceId: "abc", stage: .transcribe) == nil)
    }
}
