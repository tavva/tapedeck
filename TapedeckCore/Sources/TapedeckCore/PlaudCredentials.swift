// ABOUTME: Plaud workspace sign-in: access and refresh tokens with their expiry times.
// ABOUTME: Pasted as JSON from the browser console and stored as JSON in KeychainStore.

import Foundation

public struct PlaudCredentials: Codable, Equatable, Sendable {
    /// KeychainStore service holding the JSON form; the account is "default".
    public static let keychainService = "tapedeck.source.session"

    /// Stand-in for pipelines that never call Plaud (classify, transcribe).
    public static let signedOut = PlaudCredentials(
        workspaceId: "", token: "", refreshToken: "", expiresAt: 0, refreshExpiresAt: 0)

    public var workspaceId: String
    public var token: String
    public var refreshToken: String
    /// Milliseconds since the epoch.
    public var expiresAt: Int64
    /// Milliseconds since the epoch.
    public var refreshExpiresAt: Int64

    public init(workspaceId: String, token: String, refreshToken: String,
                expiresAt: Int64, refreshExpiresAt: Int64) {
        self.workspaceId = workspaceId; self.token = token; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.refreshExpiresAt = refreshExpiresAt
    }

    /// Parses the console snippet's output or the stored form. Extra keys are ignored.
    public init(json: String) throws {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        self = try JSONDecoder().decode(Self.self, from: Data(trimmed.utf8))
    }

    public func json() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}
