// ABOUTME: Drives one full Pipeline cycle through stubbed clients. Assertions cover
// ABOUTME: rows fully populated, on-disk artefacts present, project folder contents.

import Testing
import Foundation
import GRDB
@testable import TapedeckCore

@Suite("Pipeline end-to-end")
struct PipelineEndToEndTests {
    private func makeLayout() -> Layout {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "tapedeck-e2e-\(UUID().uuidString)")
        return Layout(
            userRoot: tmp.appending(path: "user"),
            supportRoot: tmp.appending(path: "support"),
            logsRoot: tmp.appending(path: "logs"))
    }

    private func wrapInGeminiEnvelope(_ inner: String) -> Data {
        let envelope: [String: Any] = ["candidates": [["content": ["parts": [["text": inner]]]]]]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    struct EndToEndFixture {
        let layout: Layout
        let store: Store
        let pipeline: Pipeline
        let sid: String
    }

    private func makeEndToEndFixture() throws -> EndToEndFixture {
        let layout = makeLayout()
        let store = try Store.openInMemory()
        let projects = ProjectRepository(store: store)
        try projects.insert(.init(id: "homeschool-mvp", displayName: "Homeschool MVP",
                                  description: "Curriculum", createdAt: 1, archivedAt: nil))
        // Classification is opt-in; enable it for the end-to-end happy path.
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES
                    ('auto_classify','true'),
                    ('auto_transcribe','true')
            """)
        }

        let (session, sid) = URLProtocolStub.makeSession()
        let audioBytes = Data(repeating: 0x42, count: 8)

        URLProtocolStub.register(sessionId: sid, "list", matching: { req in
            req.url?.path.contains("/file/simple/web") == true
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/list_page1.json")
        })
        URLProtocolStub.register(sessionId: sid, "temp", matching: { req in
            req.url?.path.contains("/file/temp-url/") == true
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/temp_url.json")
        })
        URLProtocolStub.register(sessionId: sid, "metadata", matching: { req in
            req.url?.path == "/file/list" && req.httpMethod == "POST"
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/raw_metadata.json")
        })
        URLProtocolStub.register(sessionId: sid, "s3", matching: { req in
            req.url?.host?.contains("amazonaws.com") == true
        }, handler: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "audio/ogg"])!
            return (resp, audioBytes)
        })
        URLProtocolStub.register(sessionId: sid, "deepgram", matching: { req in
            req.url?.host == "api.deepgram.com"
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "deepgram/short_recording.json")
        })
        URLProtocolStub.register(sessionId: sid, "gemini", matching: { req in
            req.url?.host == "generativelanguage.googleapis.com"
        }, handler: { req in
            let inner = try! String(contentsOf: Bundle.module.url(
                forResource: "Fixtures/gemini/high_confidence", withExtension: "json")!,
                encoding: .utf8)
            let body = wrapInGeminiEnvelope(inner.trimmingCharacters(in: .whitespacesAndNewlines))
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, body)
        })

        let now: @Sendable () -> Int64 = { 999 }
        let source = SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                  host: URL(string: "https://api-euc1.plaud.ai")!,
                                  session: session)
        let pipeline = Pipeline(deps: .init(
            store: store, layout: layout,
            source: source,
            deepgram: DeepgramClient(apiKey: "dg", session: session),
            gemini: GeminiClient(apiKey: "gm", session: session),
            logger: DiscardingLog(),
            now: now))
        return EndToEndFixture(layout: layout, store: store, pipeline: pipeline, sid: sid)
    }

    static func fetchAllRecordings(_ store: Store) throws -> [Recording] {
        try store.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM recordings ORDER BY started_at").map { row in
                Recording(
                    sourceId: row["source_id"],
                    filename: row["filename"],
                    startedAt: row["started_at"],
                    durationMs: row["duration_ms"],
                    filesize: row["filesize"],
                    audioExtension: row["audio_extension"],
                    audioDownloadedAt: row["audio_downloaded_at"],
                    transcribedAt: row["transcribed_at"],
                    projectId: row["project_id"],
                    classificationConfidence: row["classification_confidence"],
                    classificationReasoning: row["classification_reasoning"],
                    classifiedAt: row["classified_at"],
                    classifiedBy: row["classified_by"],
                    projectLinkState: Recording.LinkState(rawValue: row["project_link_state"]) ?? .none,
                    linkedProjectId: row["linked_project_id"],
                    lastSeenAt: row["last_seen_at"])
            }
        }
    }

    @Test func freshCycleProducesArtefactsAndLinks() async throws {
        let fx = try makeEndToEndFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sid) }
        let layout = fx.layout
        let store = fx.store
        let pipeline = fx.pipeline

        try await pipeline.runCycle()

        // Recordings are fully populated.
        let recordings = RecordingRepository(store: store)
        #expect(try recordings.count() == 2)
        let needingDownload = try recordings.recordingsNeedingDownload()
        #expect(needingDownload.isEmpty)
        let needingClassification = try recordings.recordingsNeedingClassification()
        #expect(needingClassification.isEmpty)
        let needingRelink = try recordings.recordingsNeedingRelink()
        #expect(needingRelink.isEmpty)

        // Audio + sidecars on disk under the date dir, and project links.
        let projectDir = layout.projectDir(slug: "homeschool-mvp")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: projectDir.path)) ?? []
        #expect(entries.count >= 3)  // 2 recordings × (txt + json + symlink) but at minimum the high-conf assignments

        // last_sync_at was touched.
        let last = try store.read { db in
            try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'last_sync_at'")
        }
        #expect(last == 999)
    }

    @Test func classifySkippedWhenNoActiveProjects() async throws {
        let layout = makeLayout()
        let store = try Store.openInMemory()
        // auto_classify gate would otherwise short-circuit before we reach
        // the no-projects guard we're trying to exercise here.
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES
                    ('auto_classify','true'),
                    ('auto_transcribe','true')
            """)
        }
        let recordings = RecordingRepository(store: store)

        let rec = Recording(sourceId: "rec-1", filename: "a.opus",
                            startedAt: 1, durationMs: 1000, filesize: 8,
                            audioExtension: "opus", lastSeenAt: 1)
        try recordings.upsertFromRemote(rec)
        try recordings.setDownloaded(sourceId: "rec-1", ext: "opus", at: 2)
        try recordings.setTranscribed(sourceId: "rec-1", at: 3)

        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "gemini-should-not-fire", matching: { req in
            req.url?.host == "generativelanguage.googleapis.com"
        }, handler: { req in
            Issue.record("classify must not call Gemini when there are no active projects")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data())
        })

        let pipeline = Pipeline(deps: .init(
            store: store, layout: layout,
            source: SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                 host: URL(string: "https://api-euc1.plaud.ai")!, session: session),
            deepgram: DeepgramClient(apiKey: "dg", session: session),
            gemini: GeminiClient(apiKey: "gm", session: session),
            logger: DiscardingLog(),
            now: { 10 }))

        try await pipeline.classifyNew()

        let stillPending = try recordings.recordingsNeedingClassification()
        #expect(stillPending.count == 1)
        #expect(try recordings.error(sourceId: "rec-1", stage: .classify) == nil)
    }

    @Test func tokenExpiredFromAppStateAbortsBeforeNetwork() async throws {
        let layout = makeLayout()
        let store = try Store.openInMemory()
        try store.write { db in
            try db.execute(sql: "INSERT INTO app_state(key,value) VALUES('token_status', 'expired')")
        }
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        // No handlers registered — any network call would fail, but ensureToken should
        // throw before we touch the network.
        let pipeline = Pipeline(deps: .init(
            store: store, layout: layout,
            source: SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                 host: URL(string: "https://api-euc1.plaud.ai")!, session: session),
            deepgram: DeepgramClient(apiKey: "dg", session: session),
            gemini: GeminiClient(apiKey: "gm", session: session),
            logger: DiscardingLog(),
            now: { 1 }))
        do {
            try await pipeline.runCycle()
            Issue.record("expected tokenExpired")
        } catch Pipeline.PipelineError.tokenExpired {
            // expected
        }
    }

    @Test func syncOnly_listsAndDownloads_butDoesNotTranscribeOrClassify() async throws {
        // Reuse the existing end-to-end fixture builder. After syncOnly the recording
        // must have audioDownloadedAt set, but transcribedAt and projectId should remain
        // nil even when API keys are present.
        let fx = try makeEndToEndFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sid) }
        try await fx.pipeline.syncOnly()
        let recs = try Self.fetchAllRecordings(fx.store)
        #expect(recs.first?.audioDownloadedAt != nil)
        #expect(recs.first?.transcribedAt == nil)
        #expect(recs.first?.projectId == nil)
    }
}
