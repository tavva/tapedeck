// ABOUTME: Dispatch + execution for TapedeckSyncHelper CLI subcommands.
// ABOUTME: Pure logic with injectable deps so the helper binary stays a thin shim.

import Foundation

public enum HelperCommand: Equatable, Sendable {
    case fullCycle
    case classifyPending
    case classifySource(String)
    case transcribePending
    case transcribeSource(String)
}

public func parseHelperArguments(_ argv: [String]) -> HelperCommand {
    var i = 1
    while i < argv.count {
        switch argv[i] {
        case "--classify-pending":
            return .classifyPending
        case "--classify-source":
            if i + 1 < argv.count { return .classifySource(argv[i + 1]) }
            return .fullCycle
        case "--transcribe-pending":
            return .transcribePending
        case "--transcribe-source":
            if i + 1 < argv.count { return .transcribeSource(argv[i + 1]) }
            return .fullCycle
        default:
            i += 1
        }
    }
    return .fullCycle
}

public struct HelperDeps: Sendable {
    public var layout: Layout
    public var openStore: @Sendable (URL) throws -> Store
    public var readSecret: @Sendable (_ service: String, _ account: String) throws -> String?
    public var makeSource: @Sendable (String) -> SourceClient
    public var makeDeepgram: @Sendable (String) -> DeepgramClient
    public var makeGemini: @Sendable (String) -> GeminiClient
    public var logger: any SyncLog
    public var now: @Sendable () -> Int64
    public var notify: @Sendable (String) -> Void

    public init(
        layout: Layout,
        openStore: @escaping @Sendable (URL) throws -> Store,
        readSecret: @escaping @Sendable (String, String) throws -> String?,
        makeSource: @escaping @Sendable (String) -> SourceClient,
        makeDeepgram: @escaping @Sendable (String) -> DeepgramClient,
        makeGemini: @escaping @Sendable (String) -> GeminiClient,
        logger: any SyncLog,
        now: @escaping @Sendable () -> Int64,
        notify: @escaping @Sendable (String) -> Void
    ) {
        self.layout = layout
        self.openStore = openStore
        self.readSecret = readSecret
        self.makeSource = makeSource
        self.makeDeepgram = makeDeepgram
        self.makeGemini = makeGemini
        self.logger = logger
        self.now = now
        self.notify = notify
    }
}

@MainActor
public func runHelper(_ cmd: HelperCommand, deps: HelperDeps) async -> Int32 {
    switch cmd {
    case .fullCycle: return await runFullCycle(deps: deps)
    case .classifyPending: return await runClassifyPending(deps: deps)
    case .classifySource(let sid): return await runClassifySource(sid, deps: deps)
    case .transcribePending: return await runTranscribePending(deps: deps)
    case .transcribeSource(let sid): return await runTranscribeSource(sid, deps: deps)
    }
}

@MainActor
private func runFullCycle(deps: HelperDeps) async -> Int32 {
    do {
        let lock = try SyncLock(path: deps.layout.lockURL())
        guard lock.tryAcquire() else {
            deps.logger.info("sync_skipped_already_running", source: nil)
            return 0
        }
        let store = try deps.openStore(deps.layout.dbURL())
        guard let token = try deps.readSecret("tapedeck.source.jwt", "default") else {
            deps.logger.error("token_missing", source: nil, message: "no JWT in keychain")
            return 2
        }
        guard let deepgramKey = try deps.readSecret("tapedeck.deepgram.key", "default"),
              let geminiKey = try deps.readSecret("tapedeck.gemini.key", "default") else {
            deps.logger.error("api_key_missing", source: nil, message: "Deepgram or Gemini key missing")
            return 3
        }
        let pipeline = Pipeline(deps: .init(
            store: store, layout: deps.layout,
            source: deps.makeSource(token),
            deepgram: deps.makeDeepgram(deepgramKey),
            gemini: deps.makeGemini(geminiKey),
            logger: deps.logger, now: deps.now))
        try await pipeline.runCycle()
        deps.notify("last_sync_at")
        return 0
    } catch SourceClientError.unauthorised {
        try? writeTokenStatus(deps: deps, value: "expired")
        deps.notify("token_status")
        deps.logger.error("token_expired", source: nil, message: "401 from upstream")
        return 4
    } catch Pipeline.PipelineError.tokenExpired {
        deps.logger.info("token_already_expired", source: nil)
        deps.notify("token_status")
        return 4
    } catch {
        deps.logger.error("cycle_failed", source: nil, message: "\(error)")
        return 1
    }
}

@MainActor
private func runClassifyPending(deps: HelperDeps) async -> Int32 {
    do {
        let lock = try SyncLock(path: deps.layout.lockURL())
        guard lock.tryAcquire() else {
            deps.logger.info("classify_skipped_already_running", source: nil)
            return 0
        }
        let store = try deps.openStore(deps.layout.dbURL())
        guard let pipeline = try buildClassifyPipeline(deps: deps, store: store) else {
            return 3
        }
        try await pipeline.classifyPending()
        try await pipeline.relinkChanged()
        deps.notify("recordings")
        return 0
    } catch {
        deps.logger.error("classify_pending_failed", source: nil, message: "\(error)")
        return 1
    }
}

@MainActor
private func runClassifySource(_ sourceId: String, deps: HelperDeps) async -> Int32 {
    do {
        let lock = try SyncLock(path: deps.layout.lockURL())
        guard lock.tryAcquire() else {
            deps.logger.info("classify_skipped_already_running", source: sourceId)
            return 0
        }
        let store = try deps.openStore(deps.layout.dbURL())
        guard let pipeline = try buildClassifyPipeline(deps: deps, store: store) else {
            return 3
        }
        try await pipeline.classifyOne(sourceId: sourceId)
        try await pipeline.relinkChanged()
        deps.notify("recordings")
        return 0
    } catch {
        deps.logger.error("classify_source_failed", source: sourceId, message: "\(error)")
        return 1
    }
}

@MainActor
private func buildClassifyPipeline(deps: HelperDeps, store: Store) throws -> Pipeline? {
    guard let geminiKey = try deps.readSecret("tapedeck.gemini.key", "default") else {
        deps.logger.error("api_key_missing", source: nil, message: "Gemini key missing")
        return nil
    }
    return Pipeline(deps: .init(
        store: store, layout: deps.layout,
        source: deps.makeSource(""),
        deepgram: deps.makeDeepgram(""),
        gemini: deps.makeGemini(geminiKey),
        logger: deps.logger, now: deps.now))
}

@MainActor
private func runTranscribePending(deps: HelperDeps) async -> Int32 {
    do {
        let lock = try SyncLock(path: deps.layout.lockURL())
        guard lock.tryAcquire() else {
            deps.logger.info("transcribe_skipped_already_running", source: nil)
            return 0
        }
        let store = try deps.openStore(deps.layout.dbURL())
        guard let pipeline = try buildTranscribePipeline(deps: deps, store: store) else {
            return 3
        }
        try await pipeline.transcribePending()
        try await pipeline.relinkChanged()
        deps.notify("recordings")
        return 0
    } catch {
        deps.logger.error("transcribe_pending_failed", source: nil, message: "\(error)")
        return 1
    }
}

@MainActor
private func runTranscribeSource(_ sourceId: String, deps: HelperDeps) async -> Int32 {
    do {
        let lock = try SyncLock(path: deps.layout.lockURL())
        guard lock.tryAcquire() else {
            deps.logger.info("transcribe_skipped_already_running", source: sourceId)
            return 0
        }
        let store = try deps.openStore(deps.layout.dbURL())
        guard let pipeline = try buildTranscribePipeline(deps: deps, store: store) else {
            return 3
        }
        try await pipeline.transcribeOne(sourceId: sourceId)
        try await pipeline.relinkChanged()
        deps.notify("recordings")
        return 0
    } catch {
        deps.logger.error("transcribe_source_failed", source: sourceId, message: "\(error)")
        return 1
    }
}

@MainActor
private func buildTranscribePipeline(deps: HelperDeps, store: Store) throws -> Pipeline? {
    guard let deepgramKey = try deps.readSecret("tapedeck.deepgram.key", "default") else {
        deps.logger.error("api_key_missing", source: nil, message: "Deepgram key missing")
        return nil
    }
    return Pipeline(deps: .init(
        store: store, layout: deps.layout,
        source: deps.makeSource(""),
        deepgram: deps.makeDeepgram(deepgramKey),
        gemini: deps.makeGemini(""),
        logger: deps.logger, now: deps.now))
}

private func writeTokenStatus(deps: HelperDeps, value: String) throws {
    let store = try deps.openStore(deps.layout.dbURL())
    try store.write { db in
        try db.execute(sql: """
            INSERT INTO app_state(key,value) VALUES('token_status', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [value])
    }
}
