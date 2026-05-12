// ABOUTME: SwiftUI entry. Owns AppDelegate + AppState. Window declares Sidebar/List/Detail.

import SwiftUI
import TapedeckCore

@main
enum AppEntry {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--write-keychain-sentinel"),
           idx + 1 < args.count {
            do {
                try KeychainStore.shared.set(
                    service: "tapedeck.source.jwt.sentinel",
                    account: "default",
                    value: args[idx + 1])
                exit(0)
            } catch { fputs("\(error)\n", stderr); exit(2) }
        }
        TapedeckApp.main()
    }
}

struct TapedeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Window("Tapedeck", id: "main") {
            MainView()
                .environment(appDelegate.appState)
                .environment(appDelegate.updateManager)
        }
        Settings {
            SettingsView()
                .environment(appDelegate.appState)
                .environment(appDelegate.updateManager)
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) var appState
    var body: some View {
        NavigationSplitView {
            ProjectSidebar()
        } content: {
            RecordingList()
        } detail: {
            DetailPane()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Sync now") {
                    Task { try? await SyncCoordinator.shared.runOnce(reason: "ui_button") }
                }
            }
        }
        .overlay(alignment: .top) {
            if appState.tokenStatus == "expired" { ReAuthBanner() }
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountTab().tabItem { Label("Account", systemImage: "person.crop.circle") }
            TranscriptionTab().tabItem { Label("Transcription", systemImage: "waveform") }
            ClassifierTab().tabItem { Label("Classifier", systemImage: "scope") }
            UpdatesTab().tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 480, height: 360)
    }
}
