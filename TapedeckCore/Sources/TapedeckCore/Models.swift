// ABOUTME: Value types stored in SQLite. Mapped manually via GRDB FetchableRecord.
// ABOUTME: Field names match the snake_case schema; Swift surface is camelCase.

import Foundation
import GRDB

public struct Project: Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var id: String
    public var displayName: String
    public var description: String
    public var createdAt: Int64
    public var archivedAt: Int64?

    public static let databaseTableName = "projects"

    public init(id: String, displayName: String, description: String, createdAt: Int64, archivedAt: Int64?) {
        self.id = id; self.displayName = displayName; self.description = description
        self.createdAt = createdAt; self.archivedAt = archivedAt
    }

    public init(row: Row) throws {
        id = row["id"]; displayName = row["display_name"]; description = row["description"]
        createdAt = row["created_at"]; archivedAt = row["archived_at"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id; container["display_name"] = displayName
        container["description"] = description; container["created_at"] = createdAt
        container["archived_at"] = archivedAt
    }
}

public struct Recording: Equatable, Sendable {
    public var sourceId: String
    public var filename: String
    public var startedAt: Int64
    public var durationMs: Int64
    public var filesize: Int64
    public var audioExtension: String?
    public var audioDownloadedAt: Int64?
    public var transcribedAt: Int64?
    public var projectId: String?
    public var classificationConfidence: Double?
    public var classificationReasoning: String?
    public var classifiedAt: Int64?
    public var classifiedBy: String?
    public var projectLinkState: LinkState
    public var linkedProjectId: String?
    public var lastSeenAt: Int64

    public enum LinkState: String, Sendable { case none, linked, pendingRelink = "pending_relink" }

    public init(sourceId: String, filename: String, startedAt: Int64, durationMs: Int64,
                filesize: Int64, audioExtension: String?,
                audioDownloadedAt: Int64? = nil, transcribedAt: Int64? = nil,
                projectId: String? = nil, classificationConfidence: Double? = nil,
                classificationReasoning: String? = nil, classifiedAt: Int64? = nil,
                classifiedBy: String? = nil, projectLinkState: LinkState = .none,
                linkedProjectId: String? = nil, lastSeenAt: Int64) {
        self.sourceId = sourceId; self.filename = filename; self.startedAt = startedAt
        self.durationMs = durationMs; self.filesize = filesize; self.audioExtension = audioExtension
        self.audioDownloadedAt = audioDownloadedAt; self.transcribedAt = transcribedAt
        self.projectId = projectId; self.classificationConfidence = classificationConfidence
        self.classificationReasoning = classificationReasoning; self.classifiedAt = classifiedAt
        self.classifiedBy = classifiedBy; self.projectLinkState = projectLinkState
        self.linkedProjectId = linkedProjectId; self.lastSeenAt = lastSeenAt
    }
}

public enum SyncStage: String, Sendable { case download, transcribe, classify, link }

public struct StageError: Equatable, Sendable {
    public var sourceId: String
    public var stage: SyncStage
    public var occurredAt: Int64
    public var attempt: Int
    public var message: String

    public init(sourceId: String, stage: SyncStage, occurredAt: Int64, attempt: Int, message: String) {
        self.sourceId = sourceId; self.stage = stage; self.occurredAt = occurredAt
        self.attempt = attempt; self.message = message
    }
}
