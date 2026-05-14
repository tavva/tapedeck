// ABOUTME: Tests the helper-stage writers that publish helper progress into app_state.

import Testing
import Foundation
import GRDB
@testable import TapedeckCore

@Suite("HelperStatus")
struct HelperStatusTests {
    private func read(_ store: Store, key: String) throws -> String? {
        try store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?",
                                arguments: [key])
        }
    }

    @Test func writeHelperStage_writesStageAndTimestamp() throws {
        let store = try Store.openInMemory()
        try writeHelperStage(.transcribing, store: store, now: { 1700 })
        #expect(try read(store, key: "helper_stage") == "transcribing")
        #expect(try read(store, key: "helper_started_at") == "1700")
    }

    @Test func writeHelperStage_overwritesExisting() throws {
        let store = try Store.openInMemory()
        try writeHelperStage(.syncing, store: store, now: { 100 })
        try writeHelperStage(.classifying, store: store, now: { 200 })
        #expect(try read(store, key: "helper_stage") == "classifying")
        #expect(try read(store, key: "helper_started_at") == "200")
    }

    @Test func writeHelperStage_resetsProgressCounters() throws {
        let store = try Store.openInMemory()
        try writeHelperStage(.transcribing, store: store, now: { 100 })
        try writeHelperProgress(done: 3, total: 7, store: store)
        try writeHelperStage(.classifying, store: store, now: { 200 })
        #expect(try read(store, key: "helper_stage_done") == "0")
        #expect(try read(store, key: "helper_stage_total") == "0")
    }

    @Test func writeHelperProgress_writesDoneAndTotal() throws {
        let store = try Store.openInMemory()
        try writeHelperProgress(done: 3, total: 7, store: store)
        #expect(try read(store, key: "helper_stage_done") == "3")
        #expect(try read(store, key: "helper_stage_total") == "7")
    }

    @Test func clearHelperStage_setsIdleAndZeroesCounters() throws {
        let store = try Store.openInMemory()
        try writeHelperStage(.transcribing, store: store, now: { 100 })
        try writeHelperProgress(done: 2, total: 5, store: store)
        try clearHelperStage(store: store, now: { 999 })
        #expect(try read(store, key: "helper_stage") == "idle")
        #expect(try read(store, key: "helper_stage_done") == "0")
        #expect(try read(store, key: "helper_stage_total") == "0")
    }
}
