// ABOUTME: Process-level exclusion via flock on sync.lock. Helper exits 75 if held.
// ABOUTME: Lock is released automatically when the holder process exits.

import Foundation

public final class SyncLock {
    private let fd: Int32

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = open(path.path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        self.fd = fd
    }

    /// Attempts a non-blocking exclusive lock. Returns false if another holder has it.
    public func tryAcquire() -> Bool {
        flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    deinit { _ = flock(fd, LOCK_UN); close(fd) }
}
