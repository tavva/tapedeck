// ABOUTME: Tests the helper subcommand dispatcher: argument parsing and the four
// ABOUTME: exit-code paths (success, key-missing, classify failure, etc.).

import Testing
import Foundation
@testable import TapedeckCore

@Suite("HelperRunner")
struct HelperRunnerTests {

    // MARK: argument parsing

    @Test func emptyArgsParseToFullCycle() {
        #expect(parseHelperArguments(["helper"]) == .fullCycle)
    }

    @Test func classifyPendingFlagParses() {
        #expect(parseHelperArguments(["helper", "--classify-pending"]) == .classifyPending)
    }

    @Test func classifySourceFlagParsesWithId() {
        #expect(parseHelperArguments(["helper", "--classify-source", "abc"]) == .classifySource("abc"))
    }

    @Test func classifySourceWithoutIdFallsBackToFullCycle() {
        #expect(parseHelperArguments(["helper", "--classify-source"]) == .fullCycle)
    }

    @Test func unknownFlagsAreIgnoredFavouringFullCycle() {
        #expect(parseHelperArguments(["helper", "--unknown"]) == .fullCycle)
    }

    // MARK: runHelper fixtures

    private func makeLayout() -> Layout {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "tapedeck-helper-\(UUID().uuidString)")
        return Layout(
            userRoot: tmp.appending(path: "user"),
            supportRoot: tmp.appending(path: "support"),
            logsRoot: tmp.appending(path: "logs"))
    }

    private func wrapInGeminiEnvelope(_ inner: String) -> Data {
        let envelope: [String: Any] = ["candidates": [["content": ["parts": [["text": inner]]]]]]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    private struct Fixture {
        let layout: Layout
        let log: CapturedLog
        let session: URLSession
        let sessionId: String
        let store: Store
        let deps: HelperDeps
    }

    private func makeFixture(secrets: [String: String]) async throws -> Fixture {
        let layout = makeLayout()
        try FileManager.default.createDirectory(at: layout.supportRoot, withIntermediateDirectories: true)
        let log = CapturedLog()
        let (session, sid) = URLProtocolStub.makeSession()
        let store = try Store.open(at: layout.dbURL())
        let secretsBox = SecretsBox(secrets: secrets)
        let deps = HelperDeps(
            layout: layout,
            openStore: { url in try Store.open(at: url) },
            readSecret: { service, account in secretsBox.get(service: service, account: account) },
            makeSource: { _ in SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                            host: URL(string: "https://api-euc1.plaud.ai")!,
                                            session: session) },
            makeDeepgram: { _ in DeepgramClient(apiKey: "dg", session: session) },
            makeGemini: { _ in GeminiClient(apiKey: "gm", session: session) },
            logger: log,
            now: { 100 },
            notify: { _ in })
        return Fixture(layout: layout, log: log, session: session, sessionId: sid,
                       store: store, deps: deps)
    }

    private func writeTranscript(layout: Layout, recording: Recording, text: String) throws {
        let date = Date(timeIntervalSince1970: TimeInterval(recording.startedAt) / 1000)
        let dir = layout.audioDir(date: date)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = layout.stem(sourceId: recording.sourceId, title: recording.filename)
        try text.write(to: dir.appending(path: "\(stem).transcript.txt"),
                       atomically: true, encoding: .utf8)
    }

    private func stubGeminiHighConfidence(_ fx: Fixture) {
        URLProtocolStub.register(sessionId: fx.sessionId, "gemini-ok", matching: { req in
            req.url?.host == "generativelanguage.googleapis.com"
        }, handler: { req in
            let inner = try! String(contentsOf: Bundle.module.url(
                forResource: "Fixtures/gemini/high_confidence", withExtension: "json")!,
                encoding: .utf8)
            let body = self.wrapInGeminiEnvelope(inner.trimmingCharacters(in: .whitespacesAndNewlines))
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, body)
        })
    }

    private func setupPendingRecording(_ fx: Fixture) throws -> Recording {
        let projects = ProjectRepository(store: fx.store)
        try projects.insert(.init(id: "homeschool-mvp", displayName: "Homeschool MVP",
                                  description: "Curriculum", createdAt: 1, archivedAt: nil))
        let recordings = RecordingRepository(store: fx.store)
        let rec = Recording(sourceId: "rec-1", filename: "Meeting",
                            startedAt: 1, durationMs: 60_000, filesize: 8,
                            audioExtension: "opus", lastSeenAt: 1)
        try recordings.upsertFromRemote(rec)
        try recordings.setDownloaded(sourceId: "rec-1", ext: "opus", at: 2)
        try recordings.setTranscribed(sourceId: "rec-1", at: 3)
        try writeTranscript(layout: fx.layout, recording: rec, text: "hello")
        return rec
    }

    // MARK: classify-pending

    @Test func classifyPending_returns3_whenGeminiKeyMissing() async throws {
        let fx = try await makeFixture(secrets: [:])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        _ = try setupPendingRecording(fx)

        let status = await runHelper(.classifyPending, deps: fx.deps)
        #expect(status == 3)
        #expect(fx.log.all.contains { $0.stage == "api_key_missing" })
    }

    @Test func classifyPending_returns0_andClassifies_onSuccess() async throws {
        let fx = try await makeFixture(secrets: ["tapedeck.gemini.key:default": "gm"])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        _ = try setupPendingRecording(fx)
        stubGeminiHighConfidence(fx)

        let status = await runHelper(.classifyPending, deps: fx.deps)
        #expect(status == 0)
        let recordings = RecordingRepository(store: fx.store)
        #expect(try recordings.recordingsNeedingClassification().isEmpty)
    }

    // MARK: classify-source

    @Test func classifySource_returns1_andRecordsError_whenSourceIdUnknown() async throws {
        let fx = try await makeFixture(secrets: ["tapedeck.gemini.key:default": "gm"])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }

        let status = await runHelper(.classifySource("missing"), deps: fx.deps)
        #expect(status == 1)
        #expect(fx.log.all.contains { $0.stage == "classify_source_failed" })
    }

    @Test func classifySource_returns0_onSuccess() async throws {
        let fx = try await makeFixture(secrets: ["tapedeck.gemini.key:default": "gm"])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let rec = try setupPendingRecording(fx)
        stubGeminiHighConfidence(fx)

        let status = await runHelper(.classifySource(rec.sourceId), deps: fx.deps)
        #expect(status == 0)
    }
}

// Helper for thread-safe in-memory secret lookups inside Sendable closures.
private final class SecretsBox: @unchecked Sendable {
    private let secrets: [String: String]
    init(secrets: [String: String]) { self.secrets = secrets }
    func get(service: String, account: String) -> String? {
        secrets["\(service):\(account)"]
    }
}
