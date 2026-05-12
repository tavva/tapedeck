// ABOUTME: Test helper that intercepts URLSession requests and replays canned responses.
// ABOUTME: Register handlers per-test with URLProtocolStub.register(host:path:handler:).

import Foundation

final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (HTTPURLResponse, Data)
    nonisolated(unsafe) private static var handlers: [(String, (URLRequest) -> Bool, Handler)] = []
    nonisolated(unsafe) private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers = []
    }

    static func register(_ name: String,
                         matching: @escaping (URLRequest) -> Bool,
                         handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers.append((name, matching, handler))
    }

    static func ephemeralSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let match = Self.handlers.first { $0.1(request) }
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
