// ABOUTME: Thin observable wrapper around SPUStandardUpdaterController.
// ABOUTME: Init with startingUpdater:true so background checks run immediately.

import Combine
import Sparkle

@Observable @MainActor
final class UpdateManager {
    let controller: SPUStandardUpdaterController
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
