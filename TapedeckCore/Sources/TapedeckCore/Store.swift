// ABOUTME: SQLite store wrapping GRDB.swift's DatabasePool. WAL mode by default.
// ABOUTME: Owns the migration ladder; both UI and helper open the same file.

import Foundation
import GRDB

public final class Store: @unchecked Sendable {
    public let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(at url: URL) throws -> Store {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let config = Configuration()
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try Store(writer: pool)
    }

    public static func openInMemory() throws -> Store {
        let queue = try DatabaseQueue()
        return try Store(writer: queue)
    }

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.read(block)
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    nonisolated(unsafe) static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    created_at INTEGER NOT NULL,
                    archived_at INTEGER
                );

                CREATE TABLE recordings (
                    source_id TEXT PRIMARY KEY,
                    filename TEXT NOT NULL,
                    started_at INTEGER NOT NULL,
                    duration_ms INTEGER NOT NULL,
                    filesize INTEGER NOT NULL,
                    audio_extension TEXT,
                    audio_downloaded_at INTEGER,
                    transcribed_at INTEGER,
                    project_id TEXT REFERENCES projects(id),
                    classification_confidence REAL,
                    classification_reasoning TEXT,
                    classified_at INTEGER,
                    classified_by TEXT,
                    project_link_state TEXT NOT NULL DEFAULT 'none',
                    linked_project_id TEXT REFERENCES projects(id),
                    last_seen_at INTEGER NOT NULL
                );

                CREATE INDEX recordings_project ON recordings(project_id);
                CREATE INDEX recordings_status ON recordings(audio_downloaded_at, transcribed_at);

                CREATE TABLE recording_errors (
                    source_id TEXT NOT NULL REFERENCES recordings(source_id),
                    stage TEXT NOT NULL,
                    occurred_at INTEGER NOT NULL,
                    attempt INTEGER NOT NULL,
                    message TEXT NOT NULL,
                    PRIMARY KEY (source_id, stage)
                );

                CREATE TABLE app_state (
                    key TEXT PRIMARY KEY,
                    value TEXT
                );

                INSERT INTO app_state(key, value) VALUES('schema_version', '\(TapedeckCore.schemaVersion)');
            """)
        }
        m.registerMigration("v2_speakers") { db in
            try db.execute(sql: """
                CREATE TABLE speaker_usage (
                    name        TEXT NOT NULL,
                    source_id   TEXT NOT NULL REFERENCES recordings(source_id),
                    used_at     INTEGER NOT NULL,
                    PRIMARY KEY (name, source_id)
                );

                CREATE INDEX speaker_usage_source ON speaker_usage(source_id);

                UPDATE app_state SET value = '\(TapedeckCore.schemaVersion)'
                WHERE key = 'schema_version';
            """)
        }
        return m
    }()
}
