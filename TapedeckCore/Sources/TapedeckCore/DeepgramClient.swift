// ABOUTME: Deepgram REST client for nova-3 transcription with diarization + utterances.
// ABOUTME: Returns both the flat transcript and per-speaker utterance segments.

import Foundation

public struct DeepgramClient: Sendable {
    public struct Utterance: Sendable, Equatable {
        public let speaker: Int
        public let start: Double
        public let end: Double
        public let transcript: String
    }
    public struct Result: Sendable {
        public let transcript: String
        public let utterances: [Utterance]
        public let raw: Data
    }
    public enum DeepgramError: Error, Equatable { case invalidApiKey }
    let session: URLSession
    let apiKey: String

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey; self.session = session
    }

    public func transcribe(audioAt url: URL, contentType: String) async throws -> Result {
        var req = URLRequest(url: URL(string:
            "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&diarize=true&punctuate=true&utterances=true")!)
        req.httpMethod = "POST"
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let audioData = try Data(contentsOf: url)
        req.httpBody = audioData
        let (data, response) = try await session.data(for: req)
        do { try HTTPValidator.validate(response, body: data) }
        catch is HTTPUnauthorised { throw DeepgramError.invalidApiKey }
        struct Envelope: Decodable {
            struct Results: Decodable {
                struct Channel: Decodable {
                    struct Alt: Decodable { let transcript: String }
                    let alternatives: [Alt]
                }
                struct Utterance: Decodable {
                    let speaker: Int; let start: Double; let end: Double; let transcript: String
                }
                let channels: [Channel]
                let utterances: [Utterance]?
            }
            let results: Results
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        let transcript = env.results.channels.first?.alternatives.first?.transcript ?? ""
        let utterances = (env.results.utterances ?? []).map {
            Utterance(speaker: $0.speaker, start: $0.start, end: $0.end, transcript: $0.transcript)
        }
        return Result(transcript: transcript, utterances: utterances, raw: data)
    }
}

/// Renders the speaker-labelled transcript that ends up in `<stem>.transcript.txt`.
/// One paragraph per utterance: `[speaker N] <text>\n`. Used by Pipeline.transcribeNew().
public func renderTranscript(_ utterances: [DeepgramClient.Utterance], fallback: String) -> String {
    guard !utterances.isEmpty else { return fallback }
    return utterances.map { "[speaker \($0.speaker)] \($0.transcript)" }.joined(separator: "\n\n")
}
