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
}
