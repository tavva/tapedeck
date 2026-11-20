// ABOUTME: HTTP client for the Plaud 4.0 (workspace) API: workspace-token auth and
// ABOUTME: refresh, -302 region discovery, cursor listing and per-file detail.

import Foundation

public actor SourceClient {
    public static let defaultHost = URL(string: "https://api.plaud.ai")!
    nonisolated static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.6 Safari/605.1.15"
    /// Refresh the access token once it has this long left, as the web app does.
    static let refreshMargin: Int64 = 5 * 60 * 1000

    nonisolated let session: URLSession
    public private(set) var credentials: PlaudCredentials
    public private(set) var host: URL

    public init(credentials: PlaudCredentials, host: URL? = nil, session: URLSession = .shared) {
        self.credentials = credentials
        self.host = host ?? Self.hostFromJWT(credentials.token) ?? Self.defaultHost
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

    /// Workspace-scoped headers. `bearer` overrides the access token (refresh sends
    /// the refresh token instead).
    func addStandardHeaders(_ req: inout URLRequest, bearer: String? = nil) {
        req.setValue("Bearer \(bearer ?? credentials.token)", forHTTPHeaderField: "Authorization")
        req.setValue("workspace", forHTTPHeaderField: "X-Scope-Type")
        req.setValue(credentials.workspaceId, forHTTPHeaderField: "X-Scope-Id")
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
    /// Plaud answered with a non-zero `status` in the JSON body.
    case api(status: Int, message: String)
}

/// One page of `/file-app/v4/recordings/all`. `nextCursor` is nil on the last page.
public struct RecordingPage: Sendable {
    public let recordings: [Recording]
    public let nextCursor: String?
}

struct PlaudEnvelope<T: Decodable>: Decodable {
    let status: Int
    let msg: String?
    let data: T?
}

/// What the download stage needs about one recording.
public struct RecordingDetail: Sendable {
    /// Presigned link to the original audio.
    public let audioURL: URL
    public let audioSize: Int64
    /// The detail response, minus presigned links, for the `.source.json` sidecar.
    public let metadata: Data
}

extension SourceClient {
    /// Recordings made before Plaud's 4.0 migration have file id `of_<old id>`.
    /// Their source id stays the old id so existing rows and files keep matching.
    static let migratedFilePrefix = "of_"

    public static func sourceId(fileId: String) -> String {
        fileId.hasPrefix(migratedFilePrefix)
            ? String(fileId.dropFirst(migratedFilePrefix.count)) : fileId
    }

    /// Inverse of `sourceId(fileId:)`. Ids from 4.0 onwards carry a `<kind>_` prefix;
    /// pre-migration ids are bare hex.
    public static func fileId(sourceId: String) -> String {
        sourceId.contains("_") ? sourceId : migratedFilePrefix + sourceId
    }

    /// Resolve the regional host by probing the recordings list and following the -302 JSON status.
    /// Idempotent — if the current host already returns recordings (status != -302), keeps it.
    public func discoverHost() async throws {
        var probe = URLRequest(url: host.appending(path: "/file-app/v4/recordings/all")
            .appending(queryItems: [.init(name: "page_size", value: "1")]))
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

    /// Refreshes the access token when it expires within `refreshMargin` of `now`
    /// (milliseconds). Returns the new credentials for the caller to store, or nil
    /// when no refresh was needed. Throws `.unauthorised` when the refresh token
    /// has expired or Plaud rejects it.
    public func refreshIfNeeded(now: Int64) async throws -> PlaudCredentials? {
        guard credentials.expiresAt - now <= Self.refreshMargin else { return nil }
        guard credentials.refreshExpiresAt > now else { throw SourceClientError.unauthorised }

        var req = URLRequest(url: host.appending(
            path: "/user-app/auth/workspace/refresh/\(credentials.workspaceId)"))
        req.httpMethod = "POST"
        addStandardHeaders(&req, bearer: credentials.refreshToken)
        let reqFinal = req
        struct Tokens: Decodable {
            let workspace_token: String?
            let access_token: String?
            let expires_in: Int64?
            let refresh_token: String?
            let refresh_expires_in: Int64?
        }
        let tokens: Tokens
        do {
            let data = try await RetryPolicy.run { [session] in
                let (body, response) = try await session.data(for: reqFinal)
                try HTTPValidator.validate(response, body: body)
                return body
            }
            tokens = try Self.decodeEnvelope(Tokens.self, from: data)
        } catch is HTTPUnauthorised {
            throw SourceClientError.unauthorised
        } catch let rejected as HTTPNonRetryableError where (400..<500).contains(rejected.status) {
            throw SourceClientError.unauthorised
        } catch SourceClientError.api {
            throw SourceClientError.unauthorised
        }
        guard let token = tokens.workspace_token ?? tokens.access_token else {
            throw SourceClientError.unauthorised
        }
        var refreshed = credentials
        refreshed.token = token
        refreshed.expiresAt = now + (tokens.expires_in ?? 0) * 1000
        if let refreshToken = tokens.refresh_token { refreshed.refreshToken = refreshToken }
        if let refreshExpiresIn = tokens.refresh_expires_in {
            refreshed.refreshExpiresAt = now + refreshExpiresIn * 1000
        }
        credentials = refreshed
        return refreshed
    }

    public func listPage(cursor: String?, pageSize: Int = 100) async throws -> RecordingPage {
        var query: [URLQueryItem] = [.init(name: "page_size", value: "\(pageSize)")]
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        var req = URLRequest(url: host.appending(path: "/file-app/v4/recordings/all")
            .appending(queryItems: query))
        addStandardHeaders(&req)
        struct Page: Decodable { let items: [Item]; let next_cursor: String? }
        struct Item: Decodable {
            let file_id: String; let name: String
            let created_at_show_ms: Int64; let duration_ms: Int64
        }
        let page = try Self.decodeEnvelope(Page.self, from: try await send(req))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let recordings = page.items.map {
            // The list has no file size; the download stage records it.
            Recording(sourceId: Self.sourceId(fileId: $0.file_id), filename: $0.name,
                      startedAt: $0.created_at_show_ms, durationMs: $0.duration_ms,
                      filesize: 0, audioExtension: nil, lastSeenAt: now)
        }
        let next = page.next_cursor.flatMap { $0.isEmpty ? nil : $0 }
        return RecordingPage(recordings: recordings, nextCursor: next)
    }

    public func listAll() async throws -> [Recording] {
        var all: [Recording] = []
        var cursor: String? = nil
        repeat {
            let page = try await listPage(cursor: cursor)
            all.append(contentsOf: page.recordings)
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }

    public func fileDetail(for sourceId: String) async throws -> RecordingDetail {
        var req = URLRequest(url: host.appending(
            path: "/file-app/v4/files/detail/\(Self.fileId(sourceId: sourceId))"))
        addStandardHeaders(&req)
        let data = try await send(req)
        struct Detail: Decodable { let objects: [Object] }
        struct Object: Decodable {
            let object_type: String; let content_url: String?; let object_size: Int64?
        }
        let detail = try Self.decodeEnvelope(Detail.self, from: data)
        guard let audio = detail.objects.first(where: { $0.object_type == "AUDIO" }),
              let link = audio.content_url, let url = URL(string: link) else {
            throw SourceClientError.malformedResponse("no AUDIO object")
        }
        return RecordingDetail(audioURL: url, audioSize: audio.object_size ?? 0,
                               metadata: try Self.removingContentURLs(from: data))
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        do { try HTTPValidator.validate(response, body: data) }
        catch is HTTPUnauthorised { throw SourceClientError.unauthorised }
        return data
    }

    /// Plaud wraps payloads as `{status, msg, data}`; any non-zero status is an error.
    static func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let envelope = try JSONDecoder().decode(PlaudEnvelope<T>.self, from: data)
        guard envelope.status == 0 else {
            throw SourceClientError.api(status: envelope.status, message: envelope.msg ?? "")
        }
        guard let payload = envelope.data else {
            throw SourceClientError.malformedResponse("missing data")
        }
        return payload
    }

    /// Presigned links expire within the hour and carry a temporary AWS session token,
    /// so they are not worth keeping in the on-disk sidecar.
    static func removingContentURLs(from data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var payload = root["data"] as? [String: Any],
              let objects = payload["objects"] as? [[String: Any]] else { return data }
        payload["objects"] = objects.map { object in
            var copy = object
            copy.removeValue(forKey: "content_url")
            return copy
        }
        root["data"] = payload
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
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
