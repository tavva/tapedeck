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

    @Test func transcribePendingFlagParses() {
        #expect(parseHelperArguments(["helper", "--transcribe-pending"]) == .transcribePending)
    }

    @Test func transcribeSourceFlagParsesWithId() {
        #expect(parseHelperArguments(["helper", "--transcribe-source", "abc"]) == .transcribeSource("abc"))
    }

    @Test func transcribeSourceWithoutIdFallsBackToFullCycle() {
        #expect(parseHelperArguments(["helper", "--transcribe-source"]) == .fullCycle)
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

    // MARK: transcribe-pending

    private func stubDeepgramOK(_ fx: Fixture) {
        URLProtocolStub.register(sessionId: fx.sessionId, "deepgram-ok", matching: { req in
            req.url?.host == "api.deepgram.com"
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "deepgram/short_recording.json")
        })
    }

    private func setupDownloadedRecording(_ fx: Fixture) throws -> Recording {
        let recordings = RecordingRepository(store: fx.store)
        let rec = Recording(sourceId: "rec-1", filename: "Meeting",
                            startedAt: 1, durationMs: 60_000, filesize: 4,
                            audioExtension: "opus", lastSeenAt: 1)
        try recordings.upsertFromRemote(rec)
        try recordings.setDownloaded(sourceId: "rec-1", ext: "opus", at: 2)
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let dir = fx.layout.audioDir(date: date)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = fx.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        try Data([0,1,2,3]).write(to: dir.appending(path: "\(stem).opus"))
        return rec
    }

    @Test func transcribePending_returns3_whenDeepgramKeyMissing() async throws {
        let fx = try await makeFixture(secrets: [:])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        _ = try setupDownloadedRecording(fx)

        let status = await runHelper(.transcribePending, deps: fx.deps)
        #expect(status == 3)
        #expect(fx.log.all.contains { $0.stage == "api_key_missing" })
    }

    @Test func transcribePending_returns0_andTranscribes_onSuccess() async throws {
        let fx = try await makeFixture(secrets: ["tapedeck.deepgram.key:default": "dg"])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        _ = try setupDownloadedRecording(fx)
        stubDeepgramOK(fx)

        let status = await runHelper(.transcribePending, deps: fx.deps)
        #expect(status == 0)
        let recordings = RecordingRepository(store: fx.store)
        #expect(try recordings.recordingsNeedingTranscription().isEmpty)
    }

    // MARK: transcribe-source

    @Test func transcribeSource_returns1_andRecordsError_whenSourceIdUnknown() async throws {
        let fx = try await makeFixture(secrets: ["tapedeck.deepgram.key:default": "dg"])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }

        let status = await runHelper(.transcribeSource("missing"), deps: fx.deps)
        #expect(status == 1)
        #expect(fx.log.all.contains { $0.stage == "transcribe_source_failed" })
    }

    @Test func transcribeSource_returns0_onSuccess() async throws {
        let fx = try await makeFixture(secrets: ["tapedeck.deepgram.key:default": "dg"])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let rec = try setupDownloadedRecording(fx)
        stubDeepgramOK(fx)

        let status = await runHelper(.transcribeSource(rec.sourceId), deps: fx.deps)
        #expect(status == 0)
    }

    // MARK: full-cycle conditional key requirements

    private func stubSourceEmptyList(_ fx: Fixture) {
        URLProtocolStub.register(sessionId: fx.sessionId, "source-empty",
                                 matching: { req in
            req.url?.path.contains("/file/simple/web") == true
        }, handler: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, Data(#"{"data_file_list":[]}"#.utf8))
        })
    }

    @Test func fullCycle_succeeds_withoutDeepgramOrGemini_whenAutoFlagsAreOff() async throws {
        let fx = try await makeFixture(secrets: [
            "tapedeck.source.jwt:default": "t.eyJzdWIiOiJ4In0.sig"
        ])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        stubSourceEmptyList(fx)

        let status = await runHelper(.fullCycle, deps: fx.deps)
        #expect(status == 0)
    }

    @Test func fullCycle_exitsThree_whenAutoTranscribeOnButDeepgramMissing() async throws {
        let fx = try await makeFixture(secrets: [
            "tapedeck.source.jwt:default": "t.eyJzdWIiOiJ4In0.sig"
        ])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try fx.store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES('auto_transcribe','true')
            """)
        }

        let status = await runHelper(.fullCycle, deps: fx.deps)
        #expect(status == 3)
        #expect(fx.log.all.contains {
            $0.stage == "api_key_missing" && ($0.message ?? "").contains("Deepgram")
        })
    }

    @Test func runFullCycle_writesStageTransitions_andEndsIdle() async throws {
        let fx = try await makeFixture(secrets: [
            "tapedeck.source.jwt:default": "t.eyJzdWIiOiJ4In0.sig",
            "tapedeck.deepgram.key:default": "dg",
            "tapedeck.gemini.key:default": "gm",
        ])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try fx.store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES('auto_transcribe','true')
                ON CONFLICT(key) DO UPDATE SET value='true'
            """)
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES('auto_classify','true')
                ON CONFLICT(key) DO UPDATE SET value='true'
            """)
        }
        let capture = StageCapture(store: fx.store)
        var deps = fx.deps
        deps.notify = { capture.observe($0) }
        stubSourceEmptyList(fx)
        let status = await runHelper(.fullCycle, deps: deps)
        #expect(status == 0)
        #expect(capture.stages == ["syncing", "transcribing", "classifying", "idle"])
        let finalStage = try fx.store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key='helper_stage'")
        }
        #expect(finalStage == "idle")
    }

    @Test func runFullCycle_clearsToIdle_evenWhenPipelineThrows() async throws {
        let fx = try await makeFixture(secrets: [
            "tapedeck.source.jwt:default": "t.eyJzdWIiOiJ4In0.sig",
        ])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let status = await runHelper(.fullCycle, deps: fx.deps)
        #expect(status != 0)
        let finalStage = try fx.store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key='helper_stage'")
        }
        #expect(finalStage == "idle")
    }

    @Test func fullCycle_exitsThree_whenAutoClassifyOnButGeminiMissing() async throws {
        let fx = try await makeFixture(secrets: [
            "tapedeck.source.jwt:default": "t.eyJzdWIiOiJ4In0.sig",
            "tapedeck.deepgram.key:default": "dg"
        ])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try fx.store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES
                    ('auto_transcribe','true'),
                    ('auto_classify','true')
            """)
        }

        let status = await runHelper(.fullCycle, deps: fx.deps)
        #expect(status == 3)
        #expect(fx.log.all.contains {
            $0.stage == "api_key_missing" && ($0.message ?? "").contains("Gemini")
        })
    }

    @Test func transcribeSource_refreshesProjectFolderCopy_forLinkedRecording() async throws {
        let fx = try await makeFixture(secrets: ["tapedeck.deepgram.key:default": "dg"])
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let rec = try setupDownloadedRecording(fx)
        stubDeepgramOK(fx)
        let recordings = RecordingRepository(store: fx.store)
        let projects = ProjectRepository(store: fx.store)
        try projects.insert(.init(id: "p", displayName: "P",
                                  description: "P", createdAt: 1, archivedAt: nil))
        try recordings.setClassification(sourceId: rec.sourceId, projectId: "p",
                                         confidence: 0.9, reasoning: "r",
                                         by: "test", at: 10, linkState: .pendingRelink)
        // Seed the project folder with a stale copy so we can verify refresh.
        let projectDir = fx.layout.projectDir(slug: "p")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let stem = fx.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let projectTranscript = projectDir.appending(path: "\(stem).transcript.txt")
        try "STALE".write(to: projectTranscript, atomically: true, encoding: .utf8)
        // First call: relinks the recording into the project folder. After this
        // the recording is `.linked` and the project folder has the freshly-
        // stubbed transcript content.
        let firstStatus = await runHelper(.transcribeSource(rec.sourceId), deps: fx.deps)
        #expect(firstStatus == 0)
        try "STALE-AGAIN".write(to: projectTranscript, atomically: true, encoding: .utf8)
        // Second call: retranscribes; performTranscribeOne flips linkState back
        // to pendingRelink (Task 6) and the helper's relinkChanged pass
        // overwrites the stale project-folder copy.
        let status = await runHelper(.transcribeSource(rec.sourceId), deps: fx.deps)
        #expect(status == 0)

        let updated = try #require(try recordings.find(sourceId: rec.sourceId))
        #expect(updated.projectLinkState == .linked)
        #expect(updated.linkedProjectId == "p")
        // Project-folder copy should match the source-folder transcript that
        // the retranscribe wrote — proving the relink pass picked up the
        // refresh, not just that "STALE-AGAIN" got overwritten with anything.
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let sourceTranscript = fx.layout.audioDir(date: date)
            .appending(path: "\(stem).transcript.txt")
        let copyText = try String(contentsOf: projectTranscript, encoding: .utf8)
        let sourceText = try String(contentsOf: sourceTranscript, encoding: .utf8)
        #expect(copyText == sourceText)
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

private final class NotifyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _keys: [String] = []
    func append(_ key: String) { lock.lock(); _keys.append(key); lock.unlock() }
    var keys: [String] { lock.lock(); defer { lock.unlock() }; return _keys }
}

private final class StageCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _stages: [String] = []
    let store: Store
    init(store: Store) { self.store = store }
    func observe(_ key: String) {
        guard key == "helper_stage" else { return }
        let raw = (try? store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key='helper_stage'")
        }) ?? nil
        lock.lock(); _stages.append(raw ?? "?"); lock.unlock()
    }
    var stages: [String] { lock.lock(); defer { lock.unlock() }; return _stages }
}
