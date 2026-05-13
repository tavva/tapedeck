// ABOUTME: Persistent audio playback for the global player bar. Lives on AppState.
// ABOUTME: NSObject subclass so it can adopt AVAudioPlayerDelegate; @MainActor + @Observable.

import AVFoundation
import Foundation
import Observation
import TapedeckCore

@Observable
@MainActor
final class PlaybackController: NSObject {
    var currentRecording: Recording?
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var tickTimer: Timer?

    override init() {
        super.init()
    }
}
