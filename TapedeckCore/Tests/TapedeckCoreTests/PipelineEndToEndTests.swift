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

    /// Builds a Plaud 4.0 `/file-app/v4/recordings/all` response with `count`
    /// synthetic recordings on a single page. Only the fields SourceClient.listPage
    /// decodes are populated.
    static func makeListResponseBody(count: Int) -> Data {
        let items: [[String: Any]] = (0..<count).map { i in
            [
                "file_id": String(format: "f_%032d", i),
                "name": "2026-05-11 \(String(format: "%02d", i)):00:00",
                "created_at_show_ms": 1778491800000 + Int64(i) * 1000,
                "duration_ms": 7646000,
                "status": 1
            ]
        }
        let envelope: [String: Any] = [
            "status": 0,
            "data": ["items": items, "next_cursor": ""]
        ]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    struct EndToEndFixture {
        let layout: Layout
        let store: Store
        let pipeline: Pipeline
        let sid: String
    }

    private func makeEndToEndFixture(
        downloadCount: Int = 2,
        credentials: PlaudCredentials = .test(),
        saveCredentials: @escaping @Sendable (PlaudCredentials) throws -> Void = { _ in }
    ) throws -> EndToEndFixture {
        let layout = makeLayout()
        let store = try Store.openInMemory()
        let projects = ProjectRepository(store: store)
        try projects.insert(.init(id: "kitchen-reno", displayName: "Kitchen Reno",
                                  description: "Renovation", createdAt: 1, archivedAt: nil))
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
        let listBody = Self.makeListResponseBody(count: downloadCount)

        URLProtocolStub.register(sessionId: sid, "list", matching: { req in
            req.url?.path == "/file-app/v4/recordings/all"
        }, handler: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, listBody)
        })
        URLProtocolStub.register(sessionId: sid, "detail", matching: { req in
            req.url?.path.hasPrefix("/file-app/v4/files/detail/") == true
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/file_detail.json")
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
        let source = SourceClient(credentials: credentials,
                                  host: URL(string: "https://api-euc1.plaud.ai")!,
                                  session: session)
        let pipeline = Pipeline(deps: .init(
            store: store, layout: layout,
            source: source,
            deepgram: DeepgramClient(apiKey: "dg", session: session),
            gemini: GeminiClient(apiKey: "gm", session: session),
            logger: DiscardingLog(),
            now: now,
            saveCredentials: saveCredentials))
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
        let projectDir = layout.projectDir(slug: "kitchen-reno")
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
        try recordings.setDownloaded(sourceId: "rec-1", ext: "opus", filesize: 4, at: 2)
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
            source: SourceClient(credentials: .test(),
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
            source: SourceClient(credentials: .test(),
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

    @Test func downloadNew_writesProgressDoneEqualsTotal() async throws {
        let fx = try makeEndToEndFixture(downloadCount: 2)
        try await fx.pipeline.syncOnly()
        let total = try fx.store.read { db in
            try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'helper_stage_total'")
        }
        let done = try fx.store.read { db in
            try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'helper_stage_done'")
        }
        #expect(total == 2)
        #expect(done == 2)
    }

    @Test func downloadStoresAudioSizeAndMetadataSidecar() async throws {
        let fx = try makeEndToEndFixture(downloadCount: 1)
        defer { URLProtocolStub.clear(sessionId: fx.sid) }
        try await fx.pipeline.syncOnly()
        let rec = try #require(try Self.fetchAllRecordings(fx.store).first)
        #expect(rec.filesize == 46412288)
        #expect(rec.audioExtension == "ogg")
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let stem = fx.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let sidecar = fx.layout.audioDir(date: date).appending(path: "\(stem).source.json")
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(text.contains("\"file_id\""))
        #expect(!text.contains("X-Amz-Signature"))
    }

    @Test func syncOnly_refreshesANearlyExpiredTokenAndSavesIt() async throws {
        let saved = SavedCredentials()
        let fx = try makeEndToEndFixture(
            downloadCount: 1,
            credentials: .test(expiresAt: 999 + 60_000),
            saveCredentials: { saved.append($0) })
        defer { URLProtocolStub.clear(sessionId: fx.sid) }
        URLProtocolStub.register(sessionId: fx.sid, "refresh", matching: { req in
            req.url?.path == "/user-app/auth/workspace/refresh/ws_test"
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/refresh_ok.json")
        })
        try await fx.pipeline.syncOnly()
        #expect(saved.all.map(\.token) == ["refreshed-access.eyJyZWdpb24iOiJhd3M6ZXUtY2VudHJhbC0xIn0.sig"])
        #expect(try RecordingRepository(store: fx.store).count() == 1)
    }

    @Test func syncOnly_doesNotSaveCredentialsWhenTokenIsFresh() async throws {
        let saved = SavedCredentials()
        let fx = try makeEndToEndFixture(downloadCount: 1, saveCredentials: { saved.append($0) })
        defer { URLProtocolStub.clear(sessionId: fx.sid) }
        try await fx.pipeline.syncOnly()
        #expect(saved.all.isEmpty)
    }

    @Test func syncOnly_throwsUnauthorisedBeforeListing_whenRefreshTokenExpired() async throws {
        let fx = try makeEndToEndFixture(
            downloadCount: 1,
            credentials: .test(expiresAt: 999 + 60_000, refreshExpiresAt: 998))
        defer { URLProtocolStub.clear(sessionId: fx.sid) }
        await #expect(throws: SourceClientError.unauthorised) {
            try await fx.pipeline.syncOnly()
        }
        #expect(try RecordingRepository(store: fx.store).count() == 0)
    }
}

private final class SavedCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [PlaudCredentials] = []
    func append(_ c: PlaudCredentials) { lock.lock(); saved.append(c); lock.unlock() }
    var all: [PlaudCredentials] { lock.lock(); defer { lock.unlock() }; return saved }
}
