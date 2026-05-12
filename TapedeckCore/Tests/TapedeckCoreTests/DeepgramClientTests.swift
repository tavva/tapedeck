// ABOUTME: Exercises Deepgram response parsing using the captured short_recording fixture.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("DeepgramClient")
struct DeepgramClientTests {
    private func writeTempAudio() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "deepgram-test-\(UUID().uuidString).bin")
        try Data([0]).write(to: tmp)
        return tmp
    }

    @Test func parsesTranscriptAndUtterances() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "dg", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "deepgram/short_recording.json")
        })
        let client = DeepgramClient(apiKey: "fake", session: session)
        let audio = try writeTempAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let result = try await client.transcribe(audioAt: audio, contentType: "audio/wav")
        #expect(result.transcript.contains("homeschool curriculum"))
        #expect(result.utterances.count == 3)
        #expect(result.utterances.first?.speaker == 0)
    }

    @Test func renderTranscriptInterleavesSpeakerLabels() {
        let utterances: [DeepgramClient.Utterance] = [
            .init(speaker: 0, start: 0, end: 1, transcript: "Hello."),
            .init(speaker: 1, start: 1, end: 2, transcript: "Hi there."),
        ]
        let rendered = renderTranscript(utterances, fallback: "")
        #expect(rendered.contains("[speaker 0] Hello."))
        #expect(rendered.contains("[speaker 1] Hi there."))
    }

    @Test func fallbacksToFlatTranscriptWhenNoUtterances() {
        let rendered = renderTranscript([], fallback: "Flat text.")
        #expect(rendered == "Flat text.")
    }
}
