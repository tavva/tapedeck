// ABOUTME: Exercises auto_transcribe gating, bulk transcribePending, and explicit
// ABOUTME: transcribeOne(sourceId:) including error / relink paths.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("PipelineTranscribe")
struct PipelineTranscribeTests {

    private func makeStore() throws -> Store { try Store.openInMemory() }

    private func makePipeline(store: Store) -> Pipeline {
        let layout = Layout(
            userRoot: FileManager.default.temporaryDirectory.appending(path: "u-\(UUID())"),
            supportRoot: FileManager.default.temporaryDirectory.appending(path: "s-\(UUID())"),
            logsRoot: FileManager.default.temporaryDirectory.appending(path: "l-\(UUID())"))
        return Pipeline(deps: .init(
            store: store, layout: layout,
            source: SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                 host: URL(string: "https://api-euc1.plaud.ai")!,
                                 session: .shared),
            deepgram: DeepgramClient(apiKey: "dg", session: .shared),
            gemini: GeminiClient(apiKey: "gm", session: .shared),
            logger: CapturedLog(), now: { 100 }))
    }

    @Test func autoTranscribeEnabled_returnsFalse_whenAbsent() async throws {
        let store = try makeStore()
        let pipeline = makePipeline(store: store)
        #expect(try await pipeline.autoTranscribeEnabled() == false)
    }

    @Test func autoTranscribeEnabled_returnsTrue_whenSetTrue() async throws {
        let store = try makeStore()
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES('auto_transcribe','true')
            """)
        }
        let pipeline = makePipeline(store: store)
        #expect(try await pipeline.autoTranscribeEnabled() == true)
    }

    @Test func autoTranscribeEnabled_returnsFalse_whenSetFalse() async throws {
        let store = try makeStore()
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES('auto_transcribe','false')
            """)
        }
        let pipeline = makePipeline(store: store)
        #expect(try await pipeline.autoTranscribeEnabled() == false)
    }

    @Test func transcribeNew_doesNothing_whenAutoTranscribeAbsent() async throws {
        let store = try makeStore()
        let layout = Layout(
            userRoot: FileManager.default.temporaryDirectory.appending(path: "u-\(UUID())"),
            supportRoot: FileManager.default.temporaryDirectory.appending(path: "s-\(UUID())"),
            logsRoot: FileManager.default.temporaryDirectory.appending(path: "l-\(UUID())"))
        let log = CapturedLog()
        let pipeline = Pipeline(deps: .init(
            store: store, layout: layout,
            source: SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                 host: URL(string: "https://api-euc1.plaud.ai")!,
                                 session: .shared),
            deepgram: DeepgramClient(apiKey: "dg", session: .shared),
            gemini: GeminiClient(apiKey: "gm", session: .shared),
            logger: log, now: { 100 }))
        let recordings = RecordingRepository(store: store)
        try recordings.upsertFromRemote(.init(
            sourceId: "rec-1", filename: "M",
            startedAt: 1, durationMs: 1, filesize: 1,
            audioExtension: "opus", lastSeenAt: 1))
        try recordings.setDownloaded(sourceId: "rec-1", ext: "opus", at: 2)

        try await pipeline.transcribeNew()

        #expect(try recordings.recordingsNeedingTranscription().count == 1)
        #expect(log.all.contains { $0.stage == "transcribe_skipped_auto_disabled" })
    }

    // MARK: fixture helpers for transcribeOne(sourceId:) tests

    private struct Fixture {
        let layout: Layout
        let store: Store
        let recordings: RecordingRepository
        let session: URLSession
        let sessionId: String
        let log: CapturedLog
    }

    private func makeFixture() throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "tapedeck-tx-\(UUID())")
        let layout = Layout(userRoot: tmp.appending(path: "user"),
                            supportRoot: tmp.appending(path: "support"),
                            logsRoot: tmp.appending(path: "logs"))
        let store = try Store.openInMemory()
        let (session, sid) = URLProtocolStub.makeSession()
        return Fixture(layout: layout, store: store,
                       recordings: RecordingRepository(store: store),
                       session: session, sessionId: sid, log: CapturedLog())
    }

    private func makePipelineWith(_ fx: Fixture) -> Pipeline {
        Pipeline(deps: .init(
            store: fx.store, layout: fx.layout,
            source: SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                 host: URL(string: "https://api-euc1.plaud.ai")!,
                                 session: fx.session),
            deepgram: DeepgramClient(apiKey: "dg", session: fx.session),
            gemini: GeminiClient(apiKey: "gm", session: fx.session),
            logger: fx.log, now: { 100 }))
    }

    private func stubDeepgramOK(_ fx: Fixture) {
        URLProtocolStub.register(sessionId: fx.sessionId, "deepgram-ok", matching: { req in
            req.url?.host == "api.deepgram.com"
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "deepgram/short_recording.json")
        })
    }

    private func stubDeepgramServerError(_ fx: Fixture) {
        URLProtocolStub.register(sessionId: fx.sessionId, "deepgram-500", matching: { req in
            req.url?.host == "api.deepgram.com"
        }, handler: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data("oops".utf8))
        })
    }

    private func insertDownloadedRecording(_ fx: Fixture, audioBytes: Data? = Data([0,1,2,3])) throws -> Recording {
        let r = Recording(sourceId: "rec-1", filename: "Meeting",
                          startedAt: 1, durationMs: 60_000, filesize: 4,
                          audioExtension: "opus", lastSeenAt: 1)
        try fx.recordings.upsertFromRemote(r)
        try fx.recordings.setDownloaded(sourceId: "rec-1", ext: "opus", at: 2)
        if let bytes = audioBytes {
            let date = Date(timeIntervalSince1970: TimeInterval(r.startedAt) / 1000)
            let dir = fx.layout.audioDir(date: date)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stem = fx.layout.stem(sourceId: r.sourceId, title: r.filename)
            try bytes.write(to: dir.appending(path: "\(stem).opus"))
        }
        return r
    }

    // MARK: transcribeOne(sourceId:) tests

    @Test func transcribeOne_throws_whenSourceIdUnknown() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        do {
            try await makePipelineWith(fx).transcribeOne(sourceId: "nope")
            Issue.record("expected unknownRecording")
        } catch Pipeline.TranscribeError.unknownRecording(let sid) {
            #expect(sid == "nope")
        }
    }

    @Test func transcribeOne_throwsAndRecordsError_whenAudioMissing() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let rec = try insertDownloadedRecording(fx, audioBytes: nil)

        do {
            try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)
            Issue.record("expected audioMissing")
        } catch Pipeline.TranscribeError.audioMissing {
            // expected
        }

        let err = try fx.recordings.error(sourceId: rec.sourceId, stage: .transcribe)
        #expect(err?.attempt == 1)
    }

    @Test func transcribeOne_throwsAndRecordsError_onProviderFailure() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let rec = try insertDownloadedRecording(fx)
        stubDeepgramServerError(fx)

        do {
            try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)
            Issue.record("expected providerFailed")
        } catch Pipeline.TranscribeError.providerFailed {
            // expected
        }
        let err = try fx.recordings.error(sourceId: rec.sourceId, stage: .transcribe)
        #expect(err?.attempt == 1)
    }

    @Test func transcribeOne_succeeds_writesTranscript_clearsError() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let rec = try insertDownloadedRecording(fx)
        try fx.recordings.recordError(sourceId: rec.sourceId, stage: .transcribe,
                                      at: 5, message: "earlier")
        stubDeepgramOK(fx)

        try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)

        let updated = try #require(try fx.recordings.find(sourceId: rec.sourceId))
        #expect(updated.transcribedAt != nil)
        #expect(try fx.recordings.error(sourceId: rec.sourceId, stage: .transcribe) == nil)
    }

    @Test func transcribeOne_retranscribes_whenAlreadyTranscribed() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let rec = try insertDownloadedRecording(fx)
        try fx.recordings.setTranscribed(sourceId: rec.sourceId, at: 50)
        stubDeepgramOK(fx)

        try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)

        let updated = try #require(try fx.recordings.find(sourceId: rec.sourceId))
        #expect(updated.transcribedAt == 100)
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let dir = fx.layout.audioDir(date: date)
        let stem = fx.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let txt = try String(contentsOf: dir.appending(path: "\(stem).transcript.txt"),
                             encoding: .utf8)
        #expect(!txt.isEmpty)
    }

    @Test func transcribeOne_ignoresFailureGate() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let rec = try insertDownloadedRecording(fx)
        for _ in 0..<3 {
            try fx.recordings.recordError(sourceId: rec.sourceId, stage: .transcribe,
                                          at: 5, message: "earlier failure")
        }
        stubDeepgramOK(fx)

        try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)

        let updated = try #require(try fx.recordings.find(sourceId: rec.sourceId))
        #expect(updated.transcribedAt != nil)
        #expect(try fx.recordings.error(sourceId: rec.sourceId, stage: .transcribe) == nil)
    }
}
