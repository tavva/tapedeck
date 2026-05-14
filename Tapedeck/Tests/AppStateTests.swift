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
