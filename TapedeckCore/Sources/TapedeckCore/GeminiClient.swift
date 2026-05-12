// ABOUTME: Gemini classifier client. Sends transcript + project hints; receives JSON decision.
// ABOUTME: Threshold logic lives in Pipeline; this client only parses the model output.

import Foundation

public struct GeminiClient: Sendable {
    public struct ProjectHint: Sendable {
        public let id: String; public let name: String; public let description: String
        public init(id: String, name: String, description: String) {
            self.id = id; self.name = name; self.description = description
        }
    }
    public struct Decision: Sendable, Equatable {
        public let projectId: String?; public let confidence: Double; public let reasoning: String
        public init(projectId: String?, confidence: Double, reasoning: String) {
            self.projectId = projectId; self.confidence = confidence; self.reasoning = reasoning
        }
    }
    public enum GeminiError: Error, Equatable { case malformedResponse(String); case invalidApiKey }

    let session: URLSession
    let apiKey: String

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey; self.session = session
    }

    public func classify(transcript: String, projects: [ProjectHint]) async throws -> Decision {
        let head = String(transcript.prefix(4_000))
        let tail = String(transcript.suffix(1_000))
        let truncated = head == transcript ? head : "\(head)\n…\n\(tail)"

        let prompt = """
        You're routing a voice-memo transcript to one of the user's projects.
        Pick the best fit, or null if nothing fits. Return JSON only.

        Projects:
        \(projects.map { "- id=\($0.id), name=\($0.name): \($0.description)" }.joined(separator: "\n"))

        Transcript:
        \(truncated)
        """

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "nullable": true],
                        "confidence": ["type": "number"],
                        "reasoning": ["type": "string"],
                    ],
                    "required": ["confidence", "reasoning"],
                ],
            ],
        ]
        var req = URLRequest(url: URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=\(apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        do { try HTTPValidator.validate(response, body: data) }
        catch is HTTPUnauthorised { throw GeminiError.invalidApiKey }

        struct Envelope: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String }
                    let parts: [Part]
                }
                let content: Content
            }
            let candidates: [Candidate]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard let json = env.candidates.first?.content.parts.first?.text,
              let payload = json.data(using: .utf8) else {
            throw GeminiError.malformedResponse("no candidate text")
        }
        struct Out: Decodable { let project_id: String?; let confidence: Double; let reasoning: String }
        do {
            let out = try JSONDecoder().decode(Out.self, from: payload)
            return .init(projectId: out.project_id, confidence: out.confidence, reasoning: out.reasoning)
        } catch {
            throw GeminiError.malformedResponse(json)
        }
    }
}
