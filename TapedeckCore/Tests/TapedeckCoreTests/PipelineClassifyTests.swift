// ABOUTME: Exercises auto_classify gating, bulk classifyPending, and explicit
// ABOUTME: classifyOne(sourceId:) including error / no-projects / reclassify paths.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("PipelineClassify")
struct PipelineClassifyTests {

    // MARK: setup helpers

    private func makeLayout() -> Layout {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "tapedeck-classify-\(UUID().uuidString)")
        return Layout(
            userRoot: tmp.appending(path: "user"),
            supportRoot: tmp.appending(path: "support"),
            logsRoot: tmp.appending(path: "logs"))
    }

    private func wrapInGeminiEnvelope(_ inner: String) -> Data {
        let envelope: [String: Any] = ["candidates": [["content": ["parts": [["text": inner]]]]]]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    private func writeTranscript(layout: Layout, recording: Recording, text: String) throws {
        let date = Date(timeIntervalSince1970: TimeInterval(recording.startedAt) / 1000)
        let dir = layout.audioDir(date: date)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = layout.stem(sourceId: recording.sourceId, title: recording.filename)
        try text.write(to: dir.appending(path: "\(stem).transcript.txt"),
                       atomically: true, encoding: .utf8)
    }

    private struct Fixture {
        let layout: Layout
        let store: Store
        let recordings: RecordingRepository
        let projects: ProjectRepository
        let session: URLSession
        let sessionId: String
        let log: CapturedLog
    }

    private func makeFixture() throws -> Fixture {
        let layout = makeLayout()
        let store = try Store.openInMemory()
        let (session, sid) = URLProtocolStub.makeSession()
        return Fixture(
            layout: layout, store: store,
            recordings: RecordingRepository(store: store),
            projects: ProjectRepository(store: store),
            session: session, sessionId: sid,
            log: CapturedLog())
    }

    private func makePipeline(_ fx: Fixture) -> Pipeline {
        Pipeline(deps: .init(
            store: fx.store, layout: fx.layout,
            source: SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                 host: URL(string: "https://api-euc1.plaud.ai")!,
                                 session: fx.session),
            deepgram: DeepgramClient(apiKey: "dg", session: fx.session),
            gemini: GeminiClient(apiKey: "gm", session: fx.session),
            logger: fx.log,
            now: { 100 }))
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

    private func stubGeminiServerError(_ fx: Fixture) {
        URLProtocolStub.register(sessionId: fx.sessionId, "gemini-500", matching: { req in
            req.url?.host == "generativelanguage.googleapis.com"
        }, handler: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data("oops".utf8))
        })
    }

    private func failOnGeminiCall(_ fx: Fixture) {
        URLProtocolStub.register(sessionId: fx.sessionId, "gemini-must-not-fire", matching: { req in
            req.url?.host == "generativelanguage.googleapis.com"
        }, handler: { req in
            Issue.record("Gemini must not be called in this scenario")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data())
        })
    }

    private func insertProject(_ fx: Fixture) throws {
        try fx.projects.insert(.init(id: "homeschool-mvp", displayName: "Homeschool MVP",
                                     description: "Curriculum", createdAt: 1, archivedAt: nil))
    }

    private func insertRecording(_ fx: Fixture, sourceId: String = "rec-1",
                                  transcribed: Bool = true) throws -> Recording {
        let r = Recording(sourceId: sourceId, filename: "Meeting",
                          startedAt: 1, durationMs: 60_000, filesize: 8,
                          audioExtension: "opus", lastSeenAt: 1)
        try fx.recordings.upsertFromRemote(r)
        try fx.recordings.setDownloaded(sourceId: sourceId, ext: "opus", at: 2)
        if transcribed { try fx.recordings.setTranscribed(sourceId: sourceId, at: 3) }
        return r
    }

    private func setAutoClassify(_ fx: Fixture, _ value: Bool) throws {
        try fx.store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES('auto_classify', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [value ? "true" : "false"])
        }
    }

    // MARK: tests

    @Test func runCycle_doesNotClassify_whenAutoClassifyAbsent() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try insertProject(fx)
        let rec = try insertRecording(fx)
        try writeTranscript(layout: fx.layout, recording: rec, text: "hello world")
        failOnGeminiCall(fx)

        try await makePipeline(fx).classifyNew()

        let stillPending = try fx.recordings.recordingsNeedingClassification()
        #expect(stillPending.count == 1)
        #expect(fx.log.all.contains { $0.stage == "classify_skipped_auto_disabled" })
    }

    @Test func classifyNew_classifies_whenAutoClassifyTrue() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try insertProject(fx)
        try setAutoClassify(fx, true)
        let rec = try insertRecording(fx)
        try writeTranscript(layout: fx.layout, recording: rec, text: "hello")
        stubGeminiHighConfidence(fx)

        try await makePipeline(fx).classifyNew()

        let stillPending = try fx.recordings.recordingsNeedingClassification()
        #expect(stillPending.isEmpty)
    }

    @Test func classifyPending_runs_regardlessOfAutoClassify() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try insertProject(fx)
        // auto_classify intentionally absent
        let rec = try insertRecording(fx)
        try writeTranscript(layout: fx.layout, recording: rec, text: "hello")
        stubGeminiHighConfidence(fx)

        try await makePipeline(fx).classifyPending()

        let stillPending = try fx.recordings.recordingsNeedingClassification()
        #expect(stillPending.isEmpty)
    }

    @Test func classifyPending_bypassesFailureGate() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try insertProject(fx)
        let rec = try insertRecording(fx)
        try writeTranscript(layout: fx.layout, recording: rec, text: "hello")
        // Drive the .classify error attempt count up to the gate.
        for _ in 0..<3 {
            try fx.recordings.recordError(sourceId: rec.sourceId, stage: .classify,
                                          at: 10, message: "earlier failure")
        }
        stubGeminiHighConfidence(fx)

        try await makePipeline(fx).classifyPending()

        let stillPending = try fx.recordings.recordingsNeedingClassification()
        #expect(stillPending.isEmpty)
    }

    @Test func classifyPending_isNoOp_whenNoActiveProjects() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let rec = try insertRecording(fx)
        try writeTranscript(layout: fx.layout, recording: rec, text: "hello")
        failOnGeminiCall(fx)

        try await makePipeline(fx).classifyPending()

        let stillPending = try fx.recordings.recordingsNeedingClassification()
        #expect(stillPending.count == 1)
        #expect(fx.log.all.contains { $0.stage == "classify_skipped_no_projects" })
        #expect(try fx.recordings.error(sourceId: rec.sourceId, stage: .classify) == nil)
    }

    @Test func classifyOne_reclassifies_whenAlreadyClassified() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try insertProject(fx)
        let rec = try insertRecording(fx)
        try writeTranscript(layout: fx.layout, recording: rec, text: "hello")
        // Pre-populate as classified by something stale.
        try fx.recordings.setClassification(
            sourceId: rec.sourceId, projectId: nil, confidence: 0.0,
            reasoning: "stale", by: "test", at: 50, linkState: .none)
        stubGeminiHighConfidence(fx)

        try await makePipeline(fx).classifyOne(sourceId: rec.sourceId)

        let updated = try #require(try fx.recordings.find(sourceId: rec.sourceId))
        #expect(updated.classifiedBy == "gemini-3-flash-preview")
        #expect(updated.projectId == "homeschool-mvp")
    }

    @Test func classifyOne_ignoresFailureGate() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try insertProject(fx)
        let rec = try insertRecording(fx)
        try writeTranscript(layout: fx.layout, recording: rec, text: "hello")
        for _ in 0..<3 {
            try fx.recordings.recordError(sourceId: rec.sourceId, stage: .classify,
                                          at: 10, message: "earlier failure")
        }
        stubGeminiHighConfidence(fx)

        try await makePipeline(fx).classifyOne(sourceId: rec.sourceId)

        let updated = try #require(try fx.recordings.find(sourceId: rec.sourceId))
        #expect(updated.classifiedAt != nil)
        #expect(try fx.recordings.error(sourceId: rec.sourceId, stage: .classify) == nil)
    }

    @Test func classifyOne_throwsAndRecordsError_whenTranscriptMissing() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try insertProject(fx)
        let rec = try insertRecording(fx)
        // Do not write a transcript.
        failOnGeminiCall(fx)

        do {
            try await makePipeline(fx).classifyOne(sourceId: rec.sourceId)
            Issue.record("expected transcriptMissing")
        } catch Pipeline.ClassifyError.transcriptMissing {
            // expected
        }

        let err = try fx.recordings.error(sourceId: rec.sourceId, stage: .classify)
        #expect(err?.attempt == 1)
    }

    @Test func classifyOne_throws_whenSourceIdUnknown() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try insertProject(fx)
        failOnGeminiCall(fx)

        do {
            try await makePipeline(fx).classifyOne(sourceId: "nope")
            Issue.record("expected unknownRecording")
        } catch Pipeline.ClassifyError.unknownRecording(let sid) {
            #expect(sid == "nope")
        }
    }

    @Test func classifyOne_throwsAndRecordsError_whenNoActiveProjects() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let rec = try insertRecording(fx)
        try writeTranscript(layout: fx.layout, recording: rec, text: "hello")
        failOnGeminiCall(fx)

        do {
            try await makePipeline(fx).classifyOne(sourceId: rec.sourceId)
            Issue.record("expected noActiveProjects")
        } catch Pipeline.ClassifyError.noActiveProjects {
            // expected
        }

        let err = try fx.recordings.error(sourceId: rec.sourceId, stage: .classify)
        #expect(err != nil)
        let updated = try #require(try fx.recordings.find(sourceId: rec.sourceId))
        #expect(updated.classifiedAt == nil)
    }

    @Test func classifyOne_throwsAndRecordsError_onProviderFailure() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        try insertProject(fx)
        let rec = try insertRecording(fx)
        try writeTranscript(layout: fx.layout, recording: rec, text: "hello")
        stubGeminiServerError(fx)

        do {
            try await makePipeline(fx).classifyOne(sourceId: rec.sourceId)
            Issue.record("expected providerFailed")
        } catch Pipeline.ClassifyError.providerFailed {
            // expected
        }

        let err = try fx.recordings.error(sourceId: rec.sourceId, stage: .classify)
        #expect(err?.attempt == 1)
    }
}
