// ABOUTME: Persistent audio playback for the global player bar. Lives on AppState.
// ABOUTME: Uses AVPlayer + AVPlayerItem so seek works for compressed formats like Opus.

import AVFoundation
import Combine
import Foundation
import Observation
import TapedeckCore

@Observable
@MainActor
final class PlaybackController {
    var currentRecording: Recording?
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var finishObserver: NSObjectProtocol?
    private var durationObservation: NSKeyValueObservation?

    static var audioURL: (Recording) -> URL = defaultAudioURL
    static let defaultAudioURL: (Recording) -> URL = { rec in
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let dir = Layout.standard.audioDir(date: date)
        let stem = Layout.standard.stem(sourceId: rec.sourceId, title: rec.filename)
        let ext = rec.audioExtension ?? "audio"
        return dir.appending(path: "\(stem).\(ext)")
    }

    init() {}

    func load(_ rec: Recording) {
        if currentRecording?.sourceId == rec.sourceId, player != nil {
            return
        }
        let url = Self.audioURL(rec)
        guard FileManager.default.fileExists(atPath: url.path) else {
            resetState()
            return
        }
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)

        teardownObservers()
        durationObservation = item.observe(\.duration, options: [.new, .initial]) { [weak self] item, _ in
            let seconds = CMTimeGetSeconds(item.duration)
            Task { @MainActor in
                guard let self else { return }
                if seconds.isFinite, seconds > 0 { self.duration = seconds }
            }
        }
        let interval = CMTime(value: 1, timescale: 10)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = CMTimeGetSeconds(time)
            }
        }
        finishObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }

        player = newPlayer
        currentRecording = rec
        currentTime = 0
        isPlaying = false
        duration = TimeInterval(rec.durationMs) / 1000.0
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(time, duration))
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 1000)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    func stop() {
        player?.pause()
        teardownObservers()
        player = nil
        resetState()
    }

    private func resetState() {
        currentRecording = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func teardownObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        durationObservation?.invalidate()
        durationObservation = nil
        if let finishObserver {
            NotificationCenter.default.removeObserver(finishObserver)
        }
        finishObserver = nil
    }
}
