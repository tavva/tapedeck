// ABOUTME: Single source of truth for on-disk paths under ~/Tapedeck and Application Support.
// ABOUTME: All path construction lives here so tests can inject a tmpdir root.

import Foundation

public struct Layout: Sendable {
    public let userRoot: URL
    public let supportRoot: URL
    public let logsRoot: URL

    public init(userRoot: URL, supportRoot: URL, logsRoot: URL) {
        self.userRoot = userRoot; self.supportRoot = supportRoot; self.logsRoot = logsRoot
    }

    public static let standard: Layout = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Layout(
            userRoot: home.appending(path: "Tapedeck"),
            supportRoot: home.appending(path: "Library/Application Support/Tapedeck"),
            logsRoot: home.appending(path: "Library/Logs/Tapedeck")
        )
    }()

    public func audioDir(date: Date) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .init(identifier: "UTC")
        return userRoot.appending(path: "audio/\(f.string(from: date))")
    }

    public func stem(sourceId: String, title: String) -> String {
        let safe = title.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespaces)
        let truncated = String(safe.prefix(80))
        return "\(sourceId)_\(truncated)"
    }

    public func dbURL() -> URL { supportRoot.appending(path: "state.db") }
    public func lockURL() -> URL { supportRoot.appending(path: "sync.lock") }
    public func logURL() -> URL { logsRoot.appending(path: "sync.log") }

    public func projectDir(slug: String) -> URL { userRoot.appending(path: "projects/\(slug)") }
}
