// ABOUTME: Pure SQL access for recordings and recording_errors.
// ABOUTME: Idempotent upserts use ON CONFLICT(source_id) DO UPDATE.

import Foundation
import GRDB

public struct RecordingRepository: Sendable {
    let store: Store

    public init(store: Store) { self.store = store }

    public func count() throws -> Int {
        try store.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recordings") ?? 0 }
    }

    public func upsertFromRemote(_ r: Recording) throws {
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO recordings (source_id, filename, started_at, duration_ms,
                    filesize, audio_extension, last_seen_at, project_link_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'none')
                ON CONFLICT(source_id) DO UPDATE SET
                    filename = excluded.filename,
                    started_at = excluded.started_at,
                    duration_ms = excluded.duration_ms,
                    filesize = excluded.filesize,
                    audio_extension = COALESCE(recordings.audio_extension, excluded.audio_extension),
                    last_seen_at = excluded.last_seen_at
            """, arguments: [r.sourceId, r.filename, r.startedAt, r.durationMs,
                             r.filesize, r.audioExtension, r.lastSeenAt])
        }
    }

    public func recordError(sourceId: String, stage: SyncStage, at: Int64, message: String) throws {
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO recording_errors(source_id, stage, occurred_at, attempt, message)
                VALUES (?, ?, ?, 1, ?)
                ON CONFLICT(source_id, stage) DO UPDATE SET
                    occurred_at = excluded.occurred_at,
                    attempt = recording_errors.attempt + 1,
                    message = excluded.message
            """, arguments: [sourceId, stage.rawValue, at, message])
        }
    }

    public func clearError(sourceId: String, stage: SyncStage) throws {
        try store.write { db in
            try db.execute(sql: "DELETE FROM recording_errors WHERE source_id = ? AND stage = ?",
                           arguments: [sourceId, stage.rawValue])
        }
    }

    public func error(sourceId: String, stage: SyncStage) throws -> StageError? {
        try store.read { db in
            try Row.fetchOne(db, sql: """
                SELECT source_id, stage, occurred_at, attempt, message
                FROM recording_errors WHERE source_id = ? AND stage = ?
            """, arguments: [sourceId, stage.rawValue]).map { row in
                StageError(sourceId: row["source_id"],
                           stage: SyncStage(rawValue: row["stage"])!,
                           occurredAt: row["occurred_at"],
                           attempt: row["attempt"],
                           message: row["message"])
            }
        }
    }

    public func setDownloaded(sourceId: String, ext: String, at: Int64) throws {
        try store.write { db in
            try db.execute(sql: """
                UPDATE recordings SET audio_extension = ?, audio_downloaded_at = ?
                WHERE source_id = ?
            """, arguments: [ext, at, sourceId])
        }
    }

    public func setTranscribed(sourceId: String, at: Int64) throws {
        try store.write { db in
            try db.execute(sql: "UPDATE recordings SET transcribed_at = ? WHERE source_id = ?",
                           arguments: [at, sourceId])
        }
    }

    public func setClassification(sourceId: String, projectId: String?, confidence: Double,
                                   reasoning: String, by: String, at: Int64,
                                   linkState: Recording.LinkState) throws {
        try store.write { db in
            try db.execute(sql: """
                UPDATE recordings SET project_id = ?, classification_confidence = ?,
                    classification_reasoning = ?, classified_at = ?, classified_by = ?,
                    project_link_state = ?
                WHERE source_id = ?
            """, arguments: [projectId, confidence, reasoning, at, by,
                             linkState.rawValue, sourceId])
        }
    }

    public func markLinked(sourceId: String, linkedProjectId: String?) throws {
        try store.write { db in
            try db.execute(sql: """
                UPDATE recordings SET linked_project_id = ?, project_link_state = 'linked'
                WHERE source_id = ?
            """, arguments: [linkedProjectId, sourceId])
        }
    }

    public func recordingsNeedingDownload() throws -> [Recording] { try fetchAll(where: "audio_downloaded_at IS NULL") }
    public func recordingsNeedingTranscription() throws -> [Recording] { try fetchAll(where: "audio_downloaded_at IS NOT NULL AND transcribed_at IS NULL") }
    public func recordingsNeedingClassification() throws -> [Recording] { try fetchAll(where: "transcribed_at IS NOT NULL AND classified_at IS NULL") }
    public func recordingsNeedingRelink() throws -> [Recording] { try fetchAll(where: "project_link_state = 'pending_relink'") }

    private func fetchAll(where clause: String) throws -> [Recording] {
        try store.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM recordings WHERE \(clause)").map { row in
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
    }
}
