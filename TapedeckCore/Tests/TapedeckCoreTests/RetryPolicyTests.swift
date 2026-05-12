// ABOUTME: Verifies retry counts and sleep schedule for transient vs permanent errors.

import Testing
import Foundation
@testable import TapedeckCore

actor Counter {
    private(set) var calls = 0
    private(set) var sleeps: [UInt64] = []
    func recordCall() { calls += 1 }
    func recordSleep(_ ns: UInt64) { sleeps.append(ns) }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {
    @Test func retriesOnRetryableThenSucceeds() async throws {
        let counter = Counter()
        let result = try await RetryPolicy.run(maxAttempts: 4,
                                                sleep: { ns in await counter.recordSleep(ns) }) {
            await counter.recordCall()
            let n = await counter.calls
            if n < 3 { throw HTTPRetryableError(status: 503, body: "") }
            return 42
        }
        #expect(result == 42)
        #expect(await counter.calls == 3)
        #expect(await counter.sleeps == [1_000_000_000, 2_000_000_000])
    }

    @Test func rethrowsNonRetryableImmediately() async throws {
        let counter = Counter()
        do {
            _ = try await RetryPolicy.run(maxAttempts: 4,
                                           sleep: { ns in await counter.recordSleep(ns) }) {
                await counter.recordCall()
                throw HTTPNonRetryableError(status: 404, body: "missing")
            }
            Issue.record("should have thrown")
        } catch is HTTPNonRetryableError {
            // expected
        }
        #expect(await counter.calls == 1)
        #expect(await counter.sleeps.isEmpty)
    }
}
