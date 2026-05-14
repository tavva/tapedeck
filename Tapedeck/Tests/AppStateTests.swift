// ABOUTME: Verifies AppState exposes an injectable initialiser for tests.
// ABOUTME: Production AppState() keeps default behaviour; this seam swaps deps in-process.

import XCTest
import TapedeckCore
@testable import Tapedeck

@MainActor
final class AppStateTests: XCTestCase {
    func testInit_acceptsInjectedDependencies() throws {
        let store = try Store.openInMemory()
        let state = AppState(layout: .standard,
                             store: store,
                             tokenReader: { true },
                             coordinator: FakeRunner(status: 0),
                             lockProbe: { false },
                             polling: false,
                             transientDuration: .milliseconds(10))
        XCTAssertEqual(state.recordings.count, 0)
    }

    func testActivity_prefersHelperStageOverBusy() async throws {
        let store = try Store.openInMemory()
        try writeHelperStage(.transcribing, store: store, now: { 1 })
        let state = AppState(layout: .standard, store: store,
                             tokenReader: { true },
                             coordinator: FakeRunner(status: 0),
                             lockProbe: { false },
                             polling: false,
                             transientDuration: .milliseconds(10))
        try await state.refresh()
        XCTAssertEqual(state.helperStage, .transcribing)
        XCTAssertEqual(state.activity, .transcribePending)
    }

    func testActivity_fallsBackToBusy_whenStageIdle() async throws {
        let store = try Store.openInMemory()
        try clearHelperStage(store: store, now: { 1 })
        let state = AppState(layout: .standard, store: store,
                             tokenReader: { true },
                             coordinator: FakeRunner(status: 0),
                             lockProbe: { false },
                             polling: false,
                             transientDuration: .milliseconds(10))
        try await state.refresh()
        state.busy = .sync
        XCTAssertEqual(state.activity, .sync)
    }

    func testProgress_readsDoneAndTotal() async throws {
        let store = try Store.openInMemory()
        try writeHelperStage(.transcribing, store: store, now: { 1 })
        try writeHelperProgress(done: 3, total: 7, store: store)
        let state = AppState(layout: .standard, store: store,
                             tokenReader: { true },
                             coordinator: FakeRunner(status: 0),
                             lockProbe: { false },
                             polling: false,
                             transientDuration: .milliseconds(10))
        try await state.refresh()
        XCTAssertEqual(state.stageDone, 3)
        XCTAssertEqual(state.stageTotal, 7)
    }

    func testHelperBusyCatch_setsAndClearsTransientMessage() async throws {
        let store = try Store.openInMemory()
        let runner = ThrowingHelperBusyRunner(kind: .transcribePending)
        let state = AppState(layout: .standard, store: store,
                             tokenReader: { true },
                             coordinator: runner,
                             lockProbe: { false },
                             polling: false,
                             transientDuration: .milliseconds(20))
        await state.transcribePending(reason: "test")
        XCTAssertNotNil(state.transientMessage)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(state.transientMessage)
    }
}

final class FakeRunner: OperationRunner, @unchecked Sendable {
    // OperationRunner is a nonisolated `Sendable` protocol; fakes must NOT be
    // @MainActor-isolated or they will fail Swift 6 protocol witness checks.
    let status: Int32
    init(status: Int32) { self.status = status }
    func run(_ kind: SyncCoordinator.Kind, reason: String) async throws -> Int32 {
        status
    }
}

final class ThrowingHelperBusyRunner: OperationRunner, @unchecked Sendable {
    let kind: SyncCoordinator.Kind
    init(kind: SyncCoordinator.Kind) { self.kind = kind }
    func run(_ k: SyncCoordinator.Kind, reason: String) async throws -> Int32 {
        throw SyncCoordinator.CoordinatorError.helperBusy(kind)
    }
}
