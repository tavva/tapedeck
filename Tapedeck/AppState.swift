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

    private let store: Store
    private let projectRepo: ProjectRepository
    let recordingRepo: RecordingRepository
    let speakers: SpeakerRepository
    private var timer: Timer?
    let playback = PlaybackController()

    init() {
        self.store = try! Store.open(at: Layout.standard.dbURL())
        self.projectRepo = ProjectRepository(store: store)
        self.recordingRepo = RecordingRepository(store: store)
        self.speakers = SpeakerRepository(store: store)
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
        Task { await self.syncNow(reason: "manual_override") }
    }

    func retry(sourceId: String, stage: SyncStage) async throws {
        try recordingRepo.clearError(sourceId: sourceId, stage: stage)
        try await refresh()
    }

    func syncNow(reason: String) async {
        await dispatch(.sync, reason: reason) { try await SyncCoordinator.shared.runOnce(reason: reason) }
    }

    func classifyPending(reason: String) async {
        await dispatch(.classifyPending, reason: reason) {
            try await SyncCoordinator.shared.classifyPending(reason: reason)
        }
    }

    func classifyOne(sourceId: String, reason: String) async {
        await dispatch(.classifySource(sourceId), reason: reason) {
            try await SyncCoordinator.shared.classifyOne(sourceId: sourceId, reason: reason)
        }
    }

    func transcribePending(reason: String) async {
        await dispatch(.transcribePending, reason: reason) {
            try await SyncCoordinator.shared.transcribePending(reason: reason)
        }
    }

    func transcribeOne(sourceId: String, reason: String) async {
        await dispatch(.transcribeSource(sourceId), reason: reason) {
            try await SyncCoordinator.shared.transcribeOne(sourceId: sourceId, reason: reason)
        }
    }

    /// Rebuilds `speaker_usage` from every transcript on disk so the dropdown
    /// surfaces names from transcripts that have never been opened in the
    /// new editor (or were hand-edited outside the app). Call after the
    /// initial `refresh()` so `self.recordings` is already populated.
    func reconcileSpeakers() async {
        let recordings = self.recordings
        let layout = Layout.standard
        let tuples = await Task.detached(priority: .utility) {
            () -> [(sourceId: String, text: String)] in
            recordings.compactMap { rec -> (sourceId: String, text: String)? in
                guard rec.transcribedAt != nil else { return nil }
                let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
                let dir = layout.audioDir(date: date)
                let stem = layout.stem(sourceId: rec.sourceId, title: rec.filename)
                let url = dir.appending(path: "\(stem).transcript.txt")
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (sourceId: rec.sourceId, text: text)
            }
        }.value
        try? speakers.reconcileAll(from: tuples)
    }

    private func dispatch(_ kind: SyncCoordinator.Kind, reason: String,
                          _ run: () async throws -> Int32) async {
        busy = kind
        defer { busy = nil }
        do {
            _ = try await run()
        } catch SyncCoordinator.CoordinatorError.otherOperationRunning(let other) {
            NSLog("SyncCoordinator: \(kind) requested while \(other) running")
        } catch {
            NSLog("SyncCoordinator \(kind) failed: \(error)")
        }
        try? await refresh()
    }
}
