// ABOUTME: HTTP client for the Plaud cloud API. JWT auth + -302 region discovery.
// ABOUTME: All endpoints captured in design §4 and fixtures under Tests/Fixtures/source/.

import Foundation

public actor SourceClient {
    public static let defaultHost = URL(string: "https://api.plaud.ai")!
    nonisolated static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    nonisolated let session: URLSession
    nonisolated let token: String
    public private(set) var host: URL

    public init(token: String, host: URL? = nil, session: URLSession = .shared) {
        self.token = token
        self.host = host ?? Self.hostFromJWT(token) ?? Self.defaultHost
        self.session = session
    }

    public func currentHost() -> URL { host }

    /// Returns the regional API host implied by the JWT's region claim, or nil.
    /// Region claim name is whichever §0.5 captured; check both common forms.
    /// Values may carry an `aws:` provider prefix (e.g. `aws:eu-central-1`); strip before lookup.
    public static func hostFromJWT(_ token: String) -> URL? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let raw = (obj["region"] as? String) ?? (obj["aws:region"] as? String)
        return raw.flatMap(regionToHost)
    }

    static func regionToHost(_ region: String) -> URL? {
        let normalised = region.hasPrefix("aws:") ? String(region.dropFirst(4)) : region
        let map: [String: String] = [
            "eu-central-1": "https://api-euc1.plaud.ai",
            "us-east-1": "https://api.plaud.ai",
        ]
        return map[normalised].flatMap(URL.init(string:))
    }

    nonisolated internal func addStandardHeaders(_ req: inout URLRequest) {
        req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("web", forHTTPHeaderField: "app-platform")
        req.setValue("web", forHTTPHeaderField: "edit-from")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://web.plaud.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://web.plaud.ai/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
}

/// Maps HTTP responses to typed errors. Each external client decides what 401
/// means for *its* identity — Plaud 401 means JWT expired; Deepgram/Gemini 401
/// mean wrong API key — so HTTPValidator emits a generic HTTPUnauthorised and
/// the caller wraps it appropriately.
public enum HTTPValidator {
    public static func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw HTTPUnauthorised(body: String(data: body, encoding: .utf8) ?? "")
        case 408, 429, 500..<600:
            throw HTTPRetryableError(status: http.statusCode,
                                     body: String(data: body, encoding: .utf8) ?? "")
        default:
            throw HTTPNonRetryableError(status: http.statusCode,
                                        body: String(data: body, encoding: .utf8) ?? "")
        }
    }
}

public struct HTTPUnauthorised: Error, Equatable { public let body: String }
public struct HTTPRetryableError: Error, Equatable { public let status: Int; public let body: String }
public struct HTTPNonRetryableError: Error, Equatable { public let status: Int; public let body: String }

public enum SourceClientError: Error, Equatable {
    case unauthorised
    case malformedResponse(String)
}

extension SourceClient {
    /// Resolve the regional host by probing `/file/simple/web` and following the -302 JSON status.
    /// Idempotent — if the current host already returns recordings (status != -302), keeps it.
    public func discoverHost() async throws {
        var probe = URLRequest(url: host.appending(path: "/file/simple/web"))
        probe.url = probe.url?.appending(queryItems: [
            .init(name: "skip", value: "0"),
            .init(name: "limit", value: "1"),
            .init(name: "is_trash", value: "0"),
        ])
        addStandardHeaders(&probe)
        let probeFinal = probe
        let data: Data
        do {
            data = try await RetryPolicy.run { [session] in
                let (body, response) = try await session.data(for: probeFinal)
                try HTTPValidator.validate(response, body: body)
                return body
            }
        } catch is HTTPUnauthorised { throw SourceClientError.unauthorised }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = obj["status"] as? Int, status == -302,
           let domains = (obj["data"] as? [String: Any])?["domains"] as? [String: Any],
           let api = domains["api"] as? String, let url = URL(string: api) {
            host = url
        }
    }

    public func listPage(skip: Int, limit: Int = 100) async throws -> [Recording] {
        var url = host.appending(path: "/file/simple/web")
        url = url.appending(queryItems: [
            .init(name: "skip", value: "\(skip)"),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "is_trash", value: "0"),
            .init(name: "sort_by", value: "start_time"),
            .init(name: "is_desc", value: "true"),
        ])
        var req = URLRequest(url: url)
        addStandardHeaders(&req)
        let (data, response) = try await session.data(for: req)
        do { try HTTPValidator.validate(response, body: data) }
        catch is HTTPUnauthorised { throw SourceClientError.unauthorised }
        struct Envelope: Decodable { let data_file_list: [Item] }
        struct Item: Decodable {
            let id: String; let filename: String; let start_time: Int64
            let duration: Int64; let filesize: Int64
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return env.data_file_list.map {
            Recording(sourceId: $0.id, filename: $0.filename, startedAt: $0.start_time,
                      durationMs: $0.duration, filesize: $0.filesize,
                      audioExtension: nil, lastSeenAt: now)
        }
    }

    public func listAll() async throws -> [Recording] {
        var all: [Recording] = []
        var skip = 0
        let pageSize = 100
        while true {
            let page = try await listPage(skip: skip, limit: pageSize)
            all.append(contentsOf: page)
            if page.count < pageSize { break }
            skip += pageSize
        }
        return all
    }

    public func tempURL(for sourceId: String) async throws -> URL {
        var req = URLRequest(url: host.appending(path: "/file/temp-url/\(sourceId)"))
        addStandardHeaders(&req)
        let (data, response) = try await session.data(for: req)
        do { try HTTPValidator.validate(response, body: data) }
        catch is HTTPUnauthorised { throw SourceClientError.unauthorised }
        struct Envelope: Decodable { let temp_url: String }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard let url = URL(string: env.temp_url) else {
            throw SourceClientError.malformedResponse("temp_url not a URL")
        }
        return url
    }

    public func rawMetadata(for sourceIds: [String]) async throws -> Data {
        var req = URLRequest(url: host.appending(path: "/file/list"))
        req.httpMethod = "POST"
        addStandardHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: sourceIds)
        let (data, response) = try await session.data(for: req)
        do { try HTTPValidator.validate(response, body: data) }
        catch is HTTPUnauthorised { throw SourceClientError.unauthorised }
        return data
    }

    /// Streams `url` to `target.part`, then renames atomically. Returns the extension parsed from url.path.
    public nonisolated func download(from url: URL, target: URL, fileManager: FileManager = .default) async throws -> String {
        if fileManager.fileExists(atPath: target.path) {
            let ext = url.pathExtension.lowercased()
            return ext.isEmpty ? "audio" : ext
        }
        let partURL = target.appendingPathExtension("part")
        try? fileManager.removeItem(at: partURL)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let (asyncBytes, response) = try await session.bytes(for: URLRequest(url: url))
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401: throw SourceClientError.unauthorised
            case 408, 429, 500..<600:
                throw HTTPRetryableError(status: http.statusCode, body: "")
            default:
                throw HTTPNonRetryableError(status: http.statusCode, body: "")
            }
        }
        fileManager.createFile(atPath: partURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partURL)
        var buffer = Data()
        buffer.reserveCapacity(65_536)
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 65_536 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.close()
        try fileManager.moveItem(at: partURL, to: target)
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "audio" : ext
    }
}
