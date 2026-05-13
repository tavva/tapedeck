// ABOUTME: CLI entry for one sync cycle. Single-flight via SyncLock. Logs structured JSON.
// ABOUTME: Launched by LaunchAgent every 15 min, by UI at launch, and by "Sync now".

import Foundation
import TapedeckCore

let args = CommandLine.arguments

// Sentinel — must run before any pipeline construction so
// verify-keychain-sharing.sh can exit cleanly without spinning up SQLite.
if args.contains("--read-keychain-sentinel") {
    let value = (try? KeychainStore.shared.get(
        service: "tapedeck.source.jwt.sentinel", account: "default")) ?? ""
    print(value)
    exit(0)
}

let layout = Layout.standard
let logger = SyncLogger(url: layout.logURL())

let deps = HelperDeps(
    layout: layout,
    openStore: { url in try Store.open(at: url) },
    readSecret: { service, account in
        try KeychainStore.shared.get(service: service, account: account)
    },
    makeSource: { token in SourceClient(token: token) },
    makeDeepgram: { key in DeepgramClient(apiKey: key) },
    makeGemini: { key in GeminiClient(apiKey: key) },
    logger: logger,
    now: { Int64(Date().timeIntervalSince1970 * 1000) },
    notify: { key in AppStateNotifier.post(changedKey: key) }
)

let status = await Task { @MainActor in
    await runHelper(parseHelperArguments(args), deps: deps)
}.value
exit(status)
