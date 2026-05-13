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

    private let store: Store
    private let projectRepo: ProjectRepository
    let recordingRepo: RecordingRepository
    private var timer: Timer?
    let playback = PlaybackController()

    init() {
        self.store = try! Store.open(at: Layout.standard.dbURL())
        self.projectRepo = ProjectRepository(store: store)
        self.recordingRepo = RecordingRepository(store: store)
        startPolling()
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
        let hasToken = (try? KeychainStore.shared.get(
            service: "tapedeck.source.jwt", account: "default")) != nil
        let resolved: String
        switch (hasToken, storedStatus) {
        case (false, _):        resolved = "missing"
        case (true, "expired"): resolved = "expired"
        case (true, _):         resolved = "ok"
        }
        let lastSyncAt = try store.read { db in
            try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'last_sync_at'")
        }
        self.projects = projects
        self.recordings = recordings
        self.errors = errors
        self.tokenStatus = resolved
        self.lastSyncAt = lastSyncAt
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
        Task.detached { try? await SyncCoordinator.shared.runOnce(reason: "manual_override") }
    }

    func retry(sourceId: String, stage: SyncStage) async throws {
        try recordingRepo.clearError(sourceId: sourceId, stage: stage)
        try await refresh()
    }
}
