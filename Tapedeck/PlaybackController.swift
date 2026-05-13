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

    static var audioURL: (Recording) -> URL = defaultAudioURL
    static let defaultAudioURL: (Recording) -> URL = { rec in
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let dir = Layout.standard.audioDir(date: date)
        let stem = Layout.standard.stem(sourceId: rec.sourceId, title: rec.filename)
        let ext = rec.audioExtension ?? "audio"
        return dir.appending(path: "\(stem).\(ext)")
    }

    override init() {
        super.init()
    }

    func load(_ rec: Recording) {
        if currentRecording?.sourceId == rec.sourceId, player != nil {
            return
        }
        let url = Self.audioURL(rec)
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
            currentRecording = nil
            player = nil
            duration = 0
            currentTime = 0
            isPlaying = false
            return
        }
        newPlayer.delegate = self
        newPlayer.prepareToPlay()
        player = newPlayer
        currentRecording = rec
        duration = newPlayer.duration
        currentTime = 0
        isPlaying = false
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            stopTickTimer()
        } else {
            player.play()
            isPlaying = true
            startTickTimer()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(time, duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    func stop() {
        player?.stop()
        player = nil
        currentRecording = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTickTimer()
    }

    private func startTickTimer() {
        stopTickTimer()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }
}

extension PlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = self.duration
            self.stopTickTimer()
        }
    }
}
