// ABOUTME: Lifecycle, LaunchAgent install/uninstall, Sparkle, distributed-notification subscription.
// ABOUTME: Spawns TapedeckSyncHelper at app launch and on Sync-now actions.

import AppKit
import TapedeckCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let updateManager = UpdateManager()
    var notifierObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        let appState = self.appState
        Task { try? await appState.refresh() }
        notifierObserver = AppStateNotifier.subscribe { key in
            Task { @MainActor in try? await appState.refresh(changedKey: key) }
        }
        LaunchAgent.installIfNeeded()
        Task { await appState.syncNow(reason: "app_launch") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = notifierObserver { DistributedNotificationCenter.default().removeObserver(obs) }
    }
}
