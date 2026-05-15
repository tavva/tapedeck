// ABOUTME: Installs ~/Library/LaunchAgents/com.benphillips.tapedeck.synchelper.plist.
// ABOUTME: Idempotent; safe to call every launch.

import Foundation

enum LaunchAgent {
    static let label = "com.benphillips.tapedeck.synchelper"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static func installIfNeeded() {
        let helper = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/TapedeckSyncHelper.app/Contents/MacOS/TapedeckSyncHelper")
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helper.path],
            "StartInterval": 900,                 // 15 minutes
            "RunAtLoad": false,
            "StandardOutPath": "/tmp/tapedeck-sync.out.log",
            "StandardErrorPath": "/tmp/tapedeck-sync.err.log",
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        if (try? Data(contentsOf: plistURL)) != data {
            try? data.write(to: plistURL)
            reload()
        }
    }

    static func uninstall() {
        _ = LaunchctlProcess.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func reload() {
        _ = LaunchctlProcess.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        _ = LaunchctlProcess.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    }
}

private enum LaunchctlProcess {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        try? p.run(); p.waitUntilExit(); return p.terminationStatus
    }
}
