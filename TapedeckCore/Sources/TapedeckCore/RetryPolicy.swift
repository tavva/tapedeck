// ABOUTME: Exponential-backoff retry used by every external HTTP client.
// ABOUTME: Retries on HTTPRetryableError and transient URLError; never on 401/4xx.

import Foundation

public enum RetryPolicy {
    /// 4 attempts total with sleeps 1s, 2s, 4s between failures.
    public static func run<T: Sendable>(
        maxAttempts: Int = 4,
        sleep: @Sendable @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        _ block: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do { return try await block() }
            catch let retryable as HTTPRetryableError {
                if attempt >= maxAttempts - 1 { throw retryable }
            }
            catch let url as URLError where Self.isRetryableURLError(url) {
                if attempt >= maxAttempts - 1 { throw url }
            }
            try await sleep(UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
            attempt += 1
        }
    }

    static func isRetryableURLError(_ e: URLError) -> Bool {
        [.timedOut, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed].contains(e.code)
    }
}
