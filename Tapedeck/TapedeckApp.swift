// ABOUTME: SwiftUI entry. Owns AppDelegate + AppState. Window declares Sidebar/List/Detail.

import SwiftUI
import TapedeckCore

fileprivate func progressLabel(verb: String, done: Int, total: Int) -> String {
    total > 0 ? "\(verb) \(done) of \(total)…" : "\(verb)…"
}

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
        VStack(spacing: 0) {
            NavigationSplitView {
                ProjectSidebar()
            } content: {
                RecordingList()
            } detail: {
                DetailPane()
            }
            .toolbar {
                ToolbarItem(placement: .status) {
                    let c = appState.statusCounts
                    Text("\(c.total) · \(c.toTranscribe) to transcribe · \(c.toClassify) to classify")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    if appState.activity == .transcribePending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(progressLabel(verb: "Transcribing", done: appState.stageDone, total: appState.stageTotal)).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Transcribe") {
                            Task { await appState.transcribePending(reason: "ui_transcribe_pending") }
                        }
                        .disabled(appState.activity != nil
                                  || appState.statusCounts.toTranscribe == 0)
                        .help("\(appState.statusCounts.toTranscribe) recording\(appState.statusCounts.toTranscribe == 1 ? "" : "s") to transcribe")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if appState.activity == .classifyPending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(progressLabel(verb: "Classifying", done: appState.stageDone, total: appState.stageTotal)).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Classify") {
                            Task { await appState.classifyPending(reason: "ui_classify_pending") }
                        }
                        .disabled(appState.activity != nil
                                  || appState.statusCounts.toClassify == 0
                                  || appState.projects.isEmpty)
                        .help("\(appState.statusCounts.toClassify) recording\(appState.statusCounts.toClassify == 1 ? "" : "s") to classify")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if appState.activity == .sync {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(progressLabel(verb: "Syncing", done: appState.stageDone, total: appState.stageTotal)).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Sync now") {
                            Task { await appState.syncNow(reason: "ui_sync_now") }
                        }
                        .disabled(appState.activity != nil)
                    }
                }
            }
            .overlay(alignment: .top) {
                if appState.tokenStatus == "expired" { ReAuthBanner() }
            }
            .overlay(alignment: .top) {
                if let message = appState.transientMessage {
                    TransientBanner(text: message)
                }
            }

            PlayerBar()
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
        .frame(width: 560, height: 440)
    }
}

private struct TransientBanner: View {
    let text: String
    var body: some View {
        Text(text)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
