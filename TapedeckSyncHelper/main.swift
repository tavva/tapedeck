// ABOUTME: CLI entry for one sync cycle. Single-flight via SyncLock. Logs structured JSON.
// ABOUTME: Launched by LaunchAgent every 15 min, by UI at launch, and by "Sync now".

import Foundation
import TapedeckCore

let args = CommandLine.arguments

// Phase 10.1 sentinel — must run before any pipeline construction so
// verify-keychain-sharing.sh can exit cleanly without spinning up SQLite.
if args.contains("--read-keychain-sentinel") {
    let value = (try? KeychainStore.shared.get(
        service: "tapedeck.source.jwt.sentinel", account: "default")) ?? ""
    print(value)
    exit(0)
}

let layout = Layout.standard
let logger = SyncLogger(url: layout.logURL())

func writeTokenStatus(_ value: String) throws {
    let store = try Store.open(at: layout.dbURL())
    try store.write { db in
        try db.execute(sql: """
            INSERT INTO app_state(key,value) VALUES('token_status', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [value])
    }
}

@MainActor
func runCycle() async -> Int32 {
    do {
        let lock = try SyncLock(path: layout.lockURL())
        guard lock.tryAcquire() else {
            logger.info("sync_skipped_already_running", source: nil)
            return 0
        }
        let store = try Store.open(at: layout.dbURL())
        let keychain = KeychainStore.shared
        guard let token = try keychain.get(service: "tapedeck.source.jwt", account: "default") else {
            logger.error("token_missing", source: nil, message: "no JWT in keychain")
            return 2
        }
        guard let deepgramKey = try keychain.get(service: "tapedeck.deepgram.key", account: "default"),
              let geminiKey = try keychain.get(service: "tapedeck.gemini.key", account: "default") else {
            logger.error("api_key_missing", source: nil, message: "Deepgram or Gemini key missing")
            return 3
        }
        let pipeline = Pipeline(deps: .init(
            store: store, layout: layout,
            source: SourceClient(token: token),
            deepgram: DeepgramClient(apiKey: deepgramKey),
            gemini: GeminiClient(apiKey: geminiKey),
            logger: logger, now: { Int64(Date().timeIntervalSince1970 * 1000) }
        ))
        try await pipeline.runCycle()
        AppStateNotifier.post(changedKey: "last_sync_at")
        return 0
    } catch SourceClientError.unauthorised {
        try? writeTokenStatus("expired")
        AppStateNotifier.post(changedKey: "token_status")
        logger.error("token_expired", source: nil, message: "401 from upstream")
        return 4
    } catch Pipeline.PipelineError.tokenExpired {
        logger.info("token_already_expired", source: nil)
        AppStateNotifier.post(changedKey: "token_status")
        return 4
    } catch {
        logger.error("cycle_failed", source: nil, message: "\(error)")
        return 1
    }
}

let status = await Task { @MainActor in
    await runCycle()
}.value
exit(status)
