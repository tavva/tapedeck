// ABOUTME: Cross-process signalling between Tapedeck UI and TapedeckSyncHelper.
// ABOUTME: Helper posts state-changed; UI subscribes and refetches.

import Foundation

public struct AppStateNotifier: Sendable {
    public static let name = Notification.Name("com.benphillips.tapedeck.state-changed")

    public static func post(changedKey: String) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: ["key": changedKey], deliverImmediately: true)
    }

    /// Returns the observer token; caller is responsible for removeObserver(_:).
    public static func subscribe(onMain block: @escaping @Sendable (String?) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main) { note in
                block(note.userInfo?["key"] as? String)
            }
    }
}
