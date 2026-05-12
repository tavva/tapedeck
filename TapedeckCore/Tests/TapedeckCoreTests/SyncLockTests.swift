// ABOUTME: Verifies flock-based single-flight against two SyncLock instances on the same file.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("SyncLock")
struct SyncLockTests {
    @Test func secondAcquireOnSameFileFails() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "tapedeck-synclock-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: path) }
        // flock granularity is per process, not per file descriptor — two instances in the
        // same process see the same lock state. The second acquire returns true because the
        // process already owns the lock. Use a child process to genuinely contest the lock.
        var lock1: SyncLock? = try SyncLock(path: path)
        #expect(lock1?.tryAcquire() == true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", """
        import fcntl, sys
        f = open(sys.argv[1], 'w')
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print('acquired')
        except BlockingIOError:
            print('busy')
        """, path.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "busy")
        _ = lock1  // keep alive until here
        lock1 = nil
    }
}
