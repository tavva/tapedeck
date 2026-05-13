// ABOUTME: Tests SyncCoordinator's per-kind single-flight gating without spawning the helper.

import XCTest
@testable import Tapedeck

final class SyncCoordinatorTests: XCTestCase {
    func testSameKindCallsShareInflightTask() async throws {
        let calls = CallCounter()
        let coord = SyncCoordinator(spawner: { _, _ in
            await calls.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return 0
        })

        async let a = coord.runOnce(reason: "a")
        async let b = coord.runOnce(reason: "b")
        let (ra, rb) = try await (a, b)
        XCTAssertEqual(ra, 0)
        XCTAssertEqual(rb, 0)
        let total = await calls.value
        XCTAssertEqual(total, 1, "two concurrent runOnce calls should share one helper invocation")
    }

    func testCrossKindCallThrowsOtherOperationRunning() async throws {
        let proceed = Gate()
        let coord = SyncCoordinator(spawner: { kind, _ in
            if kind == .sync { await proceed.wait() }
            return 0
        })

        async let sync = coord.runOnce(reason: "first")
        // Give the sync task a moment to take the gate.
        try await Task.sleep(nanoseconds: 10_000_000)

        do {
            _ = try await coord.classifyPending(reason: "second")
            XCTFail("expected otherOperationRunning")
        } catch SyncCoordinator.CoordinatorError.otherOperationRunning(let kind) {
            XCTAssertEqual(kind, .sync)
        }

        await proceed.open()
        _ = try await sync
    }

    func testNewOperationStartsAfterPreviousCompletes() async throws {
        let calls = CallCounter()
        let coord = SyncCoordinator(spawner: { _, _ in
            await calls.increment()
            return 0
        })
        _ = try await coord.runOnce(reason: "first")
        _ = try await coord.classifyPending(reason: "second")
        let total = await calls.value
        XCTAssertEqual(total, 2)
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Gate {
    private var resumed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if resumed { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func open() {
        resumed = true
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume() }
    }
}
