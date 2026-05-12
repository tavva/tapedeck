// ABOUTME: Logging protocol used by Pipeline. Concrete implementations are file-backed
// ABOUTME: (SyncLogger in the helper) or in-memory (CapturedLog in tests).

import Foundation

public protocol SyncLog: Sendable {
    func info(_ stage: String, source: String?)
    func error(_ stage: String, source: String?, message: String)
}

public struct DiscardingLog: SyncLog {
    public init() {}
    public func info(_ stage: String, source: String?) {}
    public func error(_ stage: String, source: String?, message: String) {}
}
