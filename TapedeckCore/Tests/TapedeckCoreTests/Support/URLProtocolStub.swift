// ABOUTME: Test helper that intercepts URLSession requests and replays canned responses.
// ABOUTME: Handlers are keyed per-session (via an injected header) so suites can run in parallel.

import Foundation

private let stubSessionHeader = "X-Tapedeck-Stub-Session"

final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (HTTPURLResponse, Data)

    nonisolated(unsafe) private static var sessionHandlers: [String: [(String, (URLRequest) -> Bool, Handler)]] = [:]
    nonisolated(unsafe) private static let lock = NSLock()

    /// Returns a fresh session and a session id; handlers registered with that id
    /// are visible only to requests made through this session.
    static func makeSession() -> (URLSession, String) {
        let sessionId = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        var headers = config.httpAdditionalHeaders ?? [:]
        headers[stubSessionHeader] = sessionId
        config.httpAdditionalHeaders = headers
        lock.lock(); sessionHandlers[sessionId] = []; lock.unlock()
        return (URLSession(configuration: config), sessionId)
    }

    static func register(sessionId: String, _ name: String,
                         matching: @escaping (URLRequest) -> Bool,
                         handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        sessionHandlers[sessionId, default: []].append((name, matching, handler))
    }

    static func clear(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        sessionHandlers.removeValue(forKey: sessionId)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let sessionId = request.value(forHTTPHeaderField: stubSessionHeader) ?? ""
        Self.lock.lock()
        let match = Self.sessionHandlers[sessionId]?.first { $0.1(request) }
        Self.lock.unlock()
        guard let match else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (response, data) = match.2(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension URLProtocolStub {
    static func jsonResponse(for request: URLRequest, status: Int = 200, fixture: String) -> (HTTPURLResponse, Data) {
        let url = Bundle.module.url(forResource: "Fixtures/\(fixture)", withExtension: nil)!
        let data = try! Data(contentsOf: url)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        return (resp, data)
    }
}
