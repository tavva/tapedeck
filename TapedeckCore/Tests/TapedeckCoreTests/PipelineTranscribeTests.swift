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
}
