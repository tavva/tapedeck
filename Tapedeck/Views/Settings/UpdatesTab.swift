// ABOUTME: Settings → Updates tab. Sparkle automatic-check toggle + manual check.

import SwiftUI

struct UpdatesTab: View {
    @Environment(UpdateManager.self) var updateManager
    @State private var automaticallyChecks: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $automaticallyChecks) {
                    Text("Automatically check for updates")
                    Text("Sparkle checks for new versions in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Check for updates now") { updateManager.checkForUpdates() }
                        .disabled(!updateManager.canCheckForUpdates)
                }
            } header: {
                Text("Software updates")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            automaticallyChecks = updateManager.controller.updater.automaticallyChecksForUpdates
        }
        .onChange(of: automaticallyChecks) { _, value in
            updateManager.controller.updater.automaticallyChecksForUpdates = value
        }
    }
}
