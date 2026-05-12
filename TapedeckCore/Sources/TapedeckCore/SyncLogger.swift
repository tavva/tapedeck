// ABOUTME: File-backed SyncLog. Synchronous fsync after every line — the helper
// ABOUTME: exits seconds after the last log, so async queueing would lose events.

import Foundation

public final class SyncLogger: SyncLog, @unchecked Sendable {
    let url: URL
    let lock = NSLock()

    public init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        self.url = url
    }
    public func info(_ stage: String, source: String?) {
        write(.init(level: "info", stage: stage, source: source, message: nil))
    }
    public func error(_ stage: String, source: String?, message: String) {
        write(.init(level: "error", stage: stage, source: source, message: message))
    }

    struct Event: Encodable {
        let ts: Int64; let level: String; let stage: String
        let source: String?; let message: String?
        init(level: String, stage: String, source: String?, message: String?) {
            self.ts = Int64(Date().timeIntervalSince1970 * 1000); self.level = level
            self.stage = stage; self.source = source; self.message = message
        }
    }

    private func write(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(event) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([0x0A]))
        try? handle.synchronize()
    }
}
