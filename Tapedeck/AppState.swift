// ABOUTME: Observable façade over Store for the UI. Refresh is the single read path.
// ABOUTME: Helper writes are seen via DistributedNotificationCenter + 30s fallback poll.

import Foundation
import GRDB
import Observation
import TapedeckCore

struct StatusCounts: Equatable {
    var total: Int
    var toTranscribe: Int
    var toClassify: Int

    init(recordings: [Recording]) {
        total = recordings.count
        toTranscribe = recordings.reduce(0) { acc, r in
            acc + (r.audioDownloadedAt != nil && r.transcribedAt == nil ? 1 : 0)
        }
        toClassify = recordings.reduce(0) { acc, r in
            acc + (r.transcribedAt != nil && r.classifiedAt == nil ? 1 : 0)
        }
    }
}

@Observable
@MainActor
final class AppState {
    var recordings: [Recording] = []
    var projects: [Project] = []
    var errors: [String: [SyncStage: StageError]] = [:]     // keyed by recording.sourceId
    var tokenStatus: String = "ok"
    var lastSyncAt: Int64? = nil
    var statusCounts: StatusCounts { StatusCounts(recordings: recordings) }
    var selectedProject: String? = "all"
    var selectedSourceId: String? = nil
    var busy: SyncCoordinator.Kind? = nil
    var helperStage: HelperStage = .idle
    var stageDone: Int = 0
    var stageTotal: Int = 0
    var transientMessage: String? = nil

    var activity: SyncCoordinator.Kind? {
        switch helperStage {
        case .syncing:      return .sync
        case .transcribing: return .transcribePending
        case .classifying:  return .classifyPending
        case .idle:         return busy
        }
    }

    struct HelperSnapshot {
        var stage: HelperStage
        var done: Int
        var total: Int
        var lastSyncAt: Int64?
    }

    private let layout: Layout
    private let store: Store
    private let projectRepo: ProjectRepository
    let recordingRepo: RecordingRepository
    private let tokenReader: () -> Bool
    private let coordinator: any OperationRunner
    private let lockProbe: () -> Bool
    private let transientDuration: Duration
    private var timer: Timer?
    let playback = PlaybackController()

    nonisolated static func defaultTokenReader() -> Bool {
        (try? KeychainStore.shared.get(service: "tapedeck.source.jwt", account: "default")) != nil
    }

    nonisolated static func probeLock(at url: URL) -> Bool {
        guard let lock = try? SyncLock(path: url) else { return false }
        return lock.tryAcquire()  // released on return when lock goes out of scope
    }

    init(layout: Layout = .standard,
         store: Store? = nil,
         tokenReader: @escaping () -> Bool = AppState.defaultTokenReader,
         coordinator: any OperationRunner = SyncCoordinator.shared,
         lockProbe: (() -> Bool)? = nil,
         polling: Bool = true,
         transientDuration: Duration = .seconds(4)) {
        self.layout = layout
        self.store = (try? store ?? Store.open(at: layout.dbURL()))!
        self.projectRepo = ProjectRepository(store: self.store)
        self.recordingRepo = RecordingRepository(store: self.store)
        self.tokenReader = tokenReader
        self.coordinator = coordinator
        self.lockProbe = lockProbe ?? { AppState.probeLock(at: layout.lockURL()) }
        self.transientDuration = transientDuration
        clearStaleStageIfNoHelper()
        if polling { startPolling() }
    }

    private func clearStaleStageIfNoHelper() {
        let raw = (try? store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key='helper_stage'")
        }) ?? nil
        let stored = raw.flatMap(HelperStage.init(rawValue:)) ?? .idle
        guard stored != .idle else { return }
        guard lockProbe() else { return }
        try? clearHelperStage(store: store, now: { Int64(Date().timeIntervalSince1970 * 1000) })
        self.helperStage = .idle
        self.stageDone = 0
        self.stageTotal = 0
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in try? await self.refresh() }
        }
    }

    func refresh(changedKey: String? = nil) async throws {
        let projects = try projectRepo.listActive()
        let recordings = try store.read { db in try Self.fetchAllRecordings(db) }
        let errors = try store.read { db in try Self.fetchErrors(db) }
        let storedStatus = try store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'token_status'")
        }
        let hasToken = tokenReader()
        let resolved: String
        switch (hasToken, storedStatus) {
        case (false, _):        resolved = "missing"
        case (true, "expired"): resolved = "expired"
        case (true, _):         resolved = "ok"
        }
        let snapshot: HelperSnapshot = try store.read { db in
            let raw = try String.fetchOne(db,
                sql: "SELECT value FROM app_state WHERE key='helper_stage'")
            let done = try Int.fetchOne(db,
                sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key='helper_stage_done'") ?? 0
            let total = try Int.fetchOne(db,
                sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key='helper_stage_total'") ?? 0
            let lastSync = try Int64.fetchOne(db,
                sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key='last_sync_at'")
            return HelperSnapshot(
                stage: raw.flatMap(HelperStage.init(rawValue:)) ?? .idle,
                done: done, total: total, lastSyncAt: lastSync)
        }
        self.projects = projects
        self.recordings = recordings
        self.errors = errors
        self.tokenStatus = resolved
        self.helperStage = snapshot.stage
        self.stageDone = snapshot.done
        self.stageTotal = snapshot.total
        self.lastSyncAt = snapshot.lastSyncAt
        clearStaleStageIfNoHelper()
    }

    func clearTokenStatus() throws {
        try store.write { db in
            try db.execute(sql: "DELETE FROM app_state WHERE key = 'token_status'")
        }
    }

    static func fetchAllRecordings(_ db: Database) throws -> [Recording] {
        try Row.fetchAll(db, sql: "SELECT * FROM recordings ORDER BY started_at DESC").map { row in
            Recording(
                sourceId: row["source_id"], filename: row["filename"],
                startedAt: row["started_at"], durationMs: row["duration_ms"],
                filesize: row["filesize"], audioExtension: row["audio_extension"],
                audioDownloadedAt: row["audio_downloaded_at"],
                transcribedAt: row["transcribed_at"],
                projectId: row["project_id"],
                classificationConfidence: row["classification_confidence"],
                classificationReasoning: row["classification_reasoning"],
                classifiedAt: row["classified_at"],
                classifiedBy: row["classified_by"],
                projectLinkState: Recording.LinkState(rawValue: row["project_link_state"]) ?? .none,
                linkedProjectId: row["linked_project_id"],
                lastSeenAt: row["last_seen_at"])
        }
    }

    static func fetchErrors(_ db: Database) throws -> [String: [SyncStage: StageError]] {
        var out: [String: [SyncStage: StageError]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM recording_errors") {
            let sid: String = row["source_id"]
            guard let stage = SyncStage(rawValue: row["stage"]) else { continue }
            out[sid, default: [:]][stage] = StageError(
                sourceId: sid, stage: stage,
                occurredAt: row["occurred_at"], attempt: row["attempt"],
                message: row["message"])
        }
        return out
    }

    func overrideProject(sourceId: String, newProjectId: String?) async throws {
        try recordingRepo.setClassification(
            sourceId: sourceId, projectId: newProjectId,
            confidence: 1.0, reasoning: "manual override",
            by: "user", at: Int64(Date().timeIntervalSince1970 * 1000),
            linkState: .pendingRelink)
        try await refresh()
        Task { await self.syncNow(reason: "manual_override") }
    }

    func retry(sourceId: String, stage: SyncStage) async throws {
        try recordingRepo.clearError(sourceId: sourceId, stage: stage)
        try await refresh()
    }

    func syncNow(reason: String) async {
        await dispatch(.sync, reason: reason) { try await coordinator.run(.sync, reason: reason) }
    }

    func classifyPending(reason: String) async {
        await dispatch(.classifyPending, reason: reason) {
            try await coordinator.run(.classifyPending, reason: reason)
        }
    }

    func classifyOne(sourceId: String, reason: String) async {
        await dispatch(.classifySource(sourceId), reason: reason) {
            try await coordinator.run(.classifySource(sourceId), reason: reason)
        }
    }

    func transcribePending(reason: String) async {
        await dispatch(.transcribePending, reason: reason) {
            try await coordinator.run(.transcribePending, reason: reason)
        }
    }

    func transcribeOne(sourceId: String, reason: String) async {
        await dispatch(.transcribeSource(sourceId), reason: reason) {
            try await coordinator.run(.transcribeSource(sourceId), reason: reason)
        }
    }

    private func dispatch(_ kind: SyncCoordinator.Kind, reason: String,
                          _ run: () async throws -> Int32) async {
        busy = kind
        defer { busy = nil }
        do {
            _ = try await run()
        } catch SyncCoordinator.CoordinatorError.helperBusy {
            transientMessage = "Another sync operation is in progress."
            let duration = transientDuration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: duration)
                self?.transientMessage = nil
            }
        } catch SyncCoordinator.CoordinatorError.otherOperationRunning(let other) {
            NSLog("SyncCoordinator: \(kind) requested while \(other) running")
        } catch {
            NSLog("SyncCoordinator \(kind) failed: \(error)")
        }
        try? await refresh()
    }
}
