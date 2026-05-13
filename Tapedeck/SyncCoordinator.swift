// ABOUTME: Spawns TapedeckSyncHelper as a child process. One concurrent operation at a time,
// ABOUTME: scoped by operation Kind so the UI never silently aliases sync vs classify intents.

import Foundation

actor SyncCoordinator {
    static let shared = SyncCoordinator()

    enum Kind: Equatable, Sendable {
        case sync
        case classifyPending
        case classifySource(String)

        var helperArgs: [String] {
            switch self {
            case .sync: return []
            case .classifyPending: return ["--classify-pending"]
            case .classifySource(let id): return ["--classify-source", id]
            }
        }
    }

    enum CoordinatorError: Error, Equatable {
        case otherOperationRunning(Kind)
    }

    typealias Spawner = @Sendable (Kind, String) async throws -> Int32

    private var current: (kind: Kind, task: Task<Int32, Error>)?
    private let spawner: Spawner

    init(spawner: @escaping Spawner = SyncCoordinator.spawnHelper) {
        self.spawner = spawner
    }

    @discardableResult
    func runOnce(reason: String) async throws -> Int32 {
        try await dispatch(.sync, reason: reason)
    }

    @discardableResult
    func classifyPending(reason: String) async throws -> Int32 {
        try await dispatch(.classifyPending, reason: reason)
    }

    @discardableResult
    func classifyOne(sourceId: String, reason: String) async throws -> Int32 {
        try await dispatch(.classifySource(sourceId), reason: reason)
    }

    private func dispatch(_ kind: Kind, reason: String) async throws -> Int32 {
        if let cur = current {
            if cur.kind == kind { return try await cur.task.value }
            throw CoordinatorError.otherOperationRunning(cur.kind)
        }
        let spawner = self.spawner
        let task = Task { try await spawner(kind, reason) }
        current = (kind, task)
        defer { current = nil }
        return try await task.value
    }

    @Sendable
    private static func spawnHelper(kind: Kind, reason: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let proc = Process()
            proc.executableURL = Bundle.main.bundleURL
                .appending(path: "Contents/MacOS/TapedeckSyncHelper")
            proc.arguments = kind.helperArgs
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
