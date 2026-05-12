// ABOUTME: Spawns TapedeckSyncHelper as a child process. One concurrent run at a time.
// ABOUTME: Resolves via terminationHandler so the main actor never blocks on waitUntilExit.

import Foundation

actor SyncCoordinator {
    static let shared = SyncCoordinator()
    private var inflight: Task<Int32, Error>?

    /// Spawns the helper if not already running; returns its termination status (0 on success).
    @discardableResult
    func runOnce(reason: String) async throws -> Int32 {
        if let existing = inflight { return try await existing.value }
        let task = Task { try await self.spawn(reason: reason) }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    private func spawn(reason: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let proc = Process()
            proc.executableURL = Bundle.main.bundleURL
                .appending(path: "Contents/MacOS/TapedeckSyncHelper")
            proc.environment = ProcessInfo.processInfo.environment
                .merging(["TAPEDECK_SYNC_REASON": reason]) { _, new in new }
            proc.terminationHandler = { p in
                cont.resume(returning: p.terminationStatus)
            }
            do { try proc.run() }
            catch { cont.resume(throwing: error) }
        }
    }
}
