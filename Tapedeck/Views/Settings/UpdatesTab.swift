// ABOUTME: Settings → Updates tab. Sparkle automatic-check toggle + manual check.

import SwiftUI

struct UpdatesTab: View {
    @Environment(UpdateManager.self) var updateManager
    @State private var automaticallyChecks: Bool = false

    var body: some View {
        Form {
            Toggle("Automatically check for updates", isOn: $automaticallyChecks)
                .onAppear {
                    automaticallyChecks = updateManager.controller.updater.automaticallyChecksForUpdates
                }
                .onChange(of: automaticallyChecks) { _, value in
                    updateManager.controller.updater.automaticallyChecksForUpdates = value
                }
            Button("Check for updates now") { updateManager.checkForUpdates() }
                .disabled(!updateManager.canCheckForUpdates)
        }
    }
}
