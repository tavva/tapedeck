// ABOUTME: Test SyncLog that records events in memory for assertion.

import Foundation
@testable import TapedeckCore

final class CapturedLog: SyncLog, @unchecked Sendable {
    struct Entry: Equatable { let level: String; let stage: String; let source: String?; let message: String? }
    private let lock = NSLock()
    private var entries: [Entry] = []
    var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    func info(_ stage: String, source: String?) {
        lock.lock(); entries.append(.init(level: "info", stage: stage, source: source, message: nil)); lock.unlock()
    }
    func error(_ stage: String, source: String?, message: String) {
        lock.lock(); entries.append(.init(level: "error", stage: stage, source: source, message: message)); lock.unlock()
    }
}
