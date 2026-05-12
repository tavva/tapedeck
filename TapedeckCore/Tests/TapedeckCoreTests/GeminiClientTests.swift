// ABOUTME: Exercises Gemini classifier against four hand-crafted output fixtures.
// ABOUTME: Wraps each inner JSON in a standard generateContent envelope.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("GeminiClient")
struct GeminiClientTests {
    private static let hints: [GeminiClient.ProjectHint] = [
        .init(id: "homeschool-mvp", name: "Homeschool MVP", description: "Curriculum planning."),
    ]

    private static func wrapInEnvelope(innerJSON: String) -> Data {
        let envelope: [String: Any] = [
            "candidates": [
                ["content": ["parts": [["text": innerJSON]]]]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    private static func sessionWith(fixture: String) -> (URLSession, String) {
        let (session, sid) = URLProtocolStub.makeSession()
        URLProtocolStub.register(sessionId: sid, "gem", matching: { _ in true }, handler: { req in
            let inner = try! String(contentsOf: Bundle.module.url(forResource: "Fixtures/\(fixture)", withExtension: nil)!, encoding: .utf8)
            let data = wrapInEnvelope(innerJSON: inner.trimmingCharacters(in: .whitespacesAndNewlines))
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, data)
        })
        return (session, sid)
    }

    @Test func highConfidenceParses() async throws {
        let (session, sid) = Self.sessionWith(fixture: "gemini/high_confidence.json")
        defer { URLProtocolStub.clear(sessionId: sid) }
        let c = GeminiClient(apiKey: "x", session: session)
        let d = try await c.classify(transcript: "anything", projects: Self.hints)
        #expect(d.projectId == "homeschool-mvp")
        #expect(d.confidence > 0.9)
    }

    @Test func lowConfidenceStillReturnsProjectId() async throws {
        let (session, sid) = Self.sessionWith(fixture: "gemini/low_confidence.json")
        defer { URLProtocolStub.clear(sessionId: sid) }
        let c = GeminiClient(apiKey: "x", session: session)
        let d = try await c.classify(transcript: "x", projects: Self.hints)
        #expect(d.projectId == "investors")
        #expect(d.confidence < 0.5)
    }

    @Test func nullProjectReturnsNil() async throws {
        let (session, sid) = Self.sessionWith(fixture: "gemini/null_project.json")
        defer { URLProtocolStub.clear(sessionId: sid) }
        let c = GeminiClient(apiKey: "x", session: session)
        let d = try await c.classify(transcript: "x", projects: Self.hints)
        #expect(d.projectId == nil)
    }

    @Test func malformedJsonThrows() async throws {
        let (session, sid) = Self.sessionWith(fixture: "gemini/malformed.json")
        defer { URLProtocolStub.clear(sessionId: sid) }
        let c = GeminiClient(apiKey: "x", session: session)
        do {
            _ = try await c.classify(transcript: "x", projects: Self.hints)
            Issue.record("should have thrown")
        } catch GeminiClient.GeminiError.malformedResponse {
            // expected
        }
    }
}
