// ABOUTME: One sync cycle. Idempotent. Sequential stages; bounded parallelism per stage.
// ABOUTME: Owns no state beyond Deps; safe to construct fresh per helper invocation.

import Foundation

public actor Pipeline {
    public struct Deps: Sendable {
        public let store: Store
        public let layout: Layout
        public let source: SourceClient
        public let deepgram: DeepgramClient
        public let gemini: GeminiClient
        public let logger: any SyncLog
        public let now: @Sendable () -> Int64

        public init(store: Store, layout: Layout, source: SourceClient,
                    deepgram: DeepgramClient, gemini: GeminiClient,
                    logger: any SyncLog, now: @Sendable @escaping () -> Int64) {
            self.store = store; self.layout = layout; self.source = source
            self.deepgram = deepgram; self.gemini = gemini
            self.logger = logger; self.now = now
        }
    }
    public enum PipelineError: Error, Equatable { case tokenExpired, tokenMissing }

    public enum ClassifyError: Error, Equatable {
        case unknownRecording(String)
        case transcriptMissing(URL)
        case providerFailed(String)
        case noActiveProjects
    }

    public enum TranscribeError: Error, Equatable {
        case unknownRecording(String)
        case audioMissing(URL)
        case providerFailed(String)
    }

    let deps: Deps
    let recordings: RecordingRepository
    let projects: ProjectRepository
    let maxConcurrency = 3
    let maxFailuresPerStage = 3

    public init(deps: Deps) {
        self.deps = deps
        self.recordings = RecordingRepository(store: deps.store)
        self.projects = ProjectRepository(store: deps.store)
    }

    public func syncOnly() async throws {
        try ensureToken()
        try await deps.source.discoverHost()
        try await listRemote()
        try await downloadNew()
    }

    public func runCycle() async throws {
        try await syncOnly()
        try await transcribeNew()
        try await classifyNew()
        try relinkChanged()
        try touchLastSync()
    }

    func ensureToken() throws {
        let status: String? = try deps.store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'token_status'")
        }
        if status == "expired" { throw PipelineError.tokenExpired }
    }

    func touchLastSync() throws {
        let value = String(deps.now())
        try deps.store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES('last_sync_at', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [value])
        }
    }

    func listRemote() async throws {
        let remote = try await RetryPolicy.run { [source = deps.source] in try await source.listAll() }
        let now = deps.now()
        for rec in remote {
            var r = rec; r.lastSeenAt = now
            try recordings.upsertFromRemote(r)
        }
        deps.logger.info("list_remote", source: nil)
    }

    func shouldSkipAfterFailures(sourceId: String, stage: SyncStage) -> Bool {
        ((try? recordings.error(sourceId: sourceId, stage: stage))?.attempt ?? 0) >= maxFailuresPerStage
    }

    /// Reads `app_state.classifier_threshold`, defaulting to 0.7 if absent or malformed.
    func classifierThreshold() throws -> Double {
        let raw: String? = try deps.store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'classifier_threshold'")
        }
        return raw.flatMap(Double.init) ?? 0.7
    }

    /// Reads `app_state.auto_classify`, defaulting to false when absent or non-`"true"`.
    func autoClassifyEnabled() throws -> Bool {
        let raw: String? = try deps.store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'auto_classify'")
        }
        return raw == "true"
    }

    /// Reads `app_state.auto_transcribe`, defaulting to false when absent or non-`"true"`.
    func autoTranscribeEnabled() throws -> Bool {
        let raw: String? = try deps.store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'auto_transcribe'")
        }
        return raw == "true"
    }
}
