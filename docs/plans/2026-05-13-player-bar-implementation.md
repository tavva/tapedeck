# Player bar implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a persistent global audio player along the bottom of the Tapedeck
window with play/pause, scrub, and elapsed/total time. Implements
[2026-05-13-player-bar-design.md](2026-05-13-player-bar-design.md).

**Architecture:** A `@MainActor @Observable` `PlaybackController` (inherits
`NSObject` for `AVAudioPlayerDelegate`) lives on `AppState`. SwiftUI observes
it directly. `PlayerBar` renders the controls under the existing
`NavigationSplitView` in `MainView`. The "▶ Play" button in `DetailPane`
becomes `playback.load(rec); playback.togglePlayPause()`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, AVFoundation
(`AVAudioPlayer`), XCTest, `xcodegen` + `xcodebuild`.

**Branch:** `feat/player-bar` (already created).

**Working directory:** `/Users/ben/repos/tapedeck`. All paths below are
relative to this.

---

## Build & test commands

Use these everywhere this plan calls for "verify build" or "verify tests".

**Build the app:**
```bash
xcodegen generate
xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck \
  -configuration Debug -derivedDataPath build/dd build -quiet
```
Expected: exit 0, no warnings about new files.

**Run unit tests:**
```bash
xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck \
  -derivedDataPath build/dd -destination 'platform=macOS' \
  -only-testing:TapedeckTests test -quiet
```
Expected: `** TEST SUCCEEDED **`.

**Run a single test:**
```bash
xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck \
  -derivedDataPath build/dd -destination 'platform=macOS' \
  -only-testing:TapedeckTests/PlaybackControllerTests/<testName> test -quiet
```

If `xcodegen generate` is needed, it is also fine to run before every build
— it is idempotent and fast.

---

## Test fixture strategy

`PlaybackController` needs a real audio file on disk to exercise. Tests
generate a tiny silent WAV in `setUpWithError()` using
`Tapedeck/Tests/WAVFixture.swift` (a single helper that writes a valid PCM
WAV header + 0.1s of silence to a temp URL).

This is not mocking — `AVAudioPlayer` opens a real file. We control the file
because we own its bytes. No external fixture data is committed; everything
is generated at test time.

---

## Task 1: PlaybackController skeleton

**Files:**
- Create: `Tapedeck/PlaybackController.swift`
- Modify: `Tapedeck/AppState.swift` (add one stored property)

**Step 1: Create the skeleton file**

```swift
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
```

**Step 2: Wire into AppState**

In `Tapedeck/AppState.swift`, after line 23 (`private var timer: Timer?`),
add:

```swift
    let playback = PlaybackController()
```

**Step 3: Verify build**

Run the build command. Expected: success.

**Step 4: Commit**

```bash
git add Tapedeck/PlaybackController.swift Tapedeck/AppState.swift
git commit -m "feat(playback): add PlaybackController skeleton on AppState"
```

---

## Task 2: WAV fixture helper + first failing test

**Files:**
- Create: `Tapedeck/Tests/WAVFixture.swift`
- Create: `Tapedeck/Tests/PlaybackControllerTests.swift`

**Step 1: Write the WAV helper**

`Tapedeck/Tests/WAVFixture.swift`:

```swift
// ABOUTME: Test helper. Writes a tiny PCM WAV to a temp URL so tests can exercise
// ABOUTME: AVAudioPlayer against a real file without committing binary fixtures.

import Foundation

enum WAVFixture {
    /// Writes ~100ms of mono 16-bit silence at 44.1kHz to a temp URL.
    /// Returns the URL; caller is responsible for cleanup.
    static func writeSilent() throws -> URL {
        let sampleRate: UInt32 = 44_100
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let numFrames: UInt32 = 4_410  // ~100ms
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = numFrames * UInt32(blockAlign)
        let chunkSize = 36 + dataSize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(uint32LE(chunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(uint32LE(16))                 // fmt chunk size
        data.append(uint16LE(1))                  // PCM
        data.append(uint16LE(numChannels))
        data.append(uint32LE(sampleRate))
        data.append(uint32LE(byteRate))
        data.append(uint16LE(blockAlign))
        data.append(uint16LE(bitsPerSample))
        data.append("data".data(using: .ascii)!)
        data.append(uint32LE(dataSize))
        data.append(Data(count: Int(dataSize)))   // zeros = silence

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-test-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
              UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }
}
```

**Step 2: Write the first failing test**

`Tapedeck/Tests/PlaybackControllerTests.swift`:

```swift
// ABOUTME: Unit tests for PlaybackController state machine. Uses a real silent WAV
// ABOUTME: written to a temp dir so AVAudioPlayer exercises real Core Audio code paths.

import XCTest
@testable import Tapedeck
import TapedeckCore

@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testInitialState() {
        let controller = PlaybackController()
        XCTAssertNil(controller.currentRecording)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.currentTime, 0)
        XCTAssertEqual(controller.duration, 0)
    }
}
```

**Step 3: Run the test to confirm it passes**

Run the test command. Expected: PASS (PlaybackController initial state matches).

This first test is a sanity check on the skeleton, not a "drive the design"
test. The next tasks drive the design.

**Step 4: Commit**

```bash
git add Tapedeck/Tests/WAVFixture.swift Tapedeck/Tests/PlaybackControllerTests.swift
git commit -m "test(playback): add WAV fixture helper and initial state test"
```

---

## Task 3: `load(_:)` sets currentRecording when audio exists

**Files:**
- Modify: `Tapedeck/Tests/PlaybackControllerTests.swift` (add test)
- Modify: `Tapedeck/PlaybackController.swift` (add `load(_:)`)

**Step 1: Write the failing test**

Add to `PlaybackControllerTests`:

```swift
func testLoadSetsCurrentRecording() throws {
    let url = try WAVFixture.writeSilent()
    defer { try? FileManager.default.removeItem(at: url) }
    let rec = Recording.test(sourceId: "src-1", audioURL: url)

    let controller = PlaybackController()
    controller.load(rec)

    XCTAssertEqual(controller.currentRecording?.sourceId, "src-1")
    XCTAssertGreaterThan(controller.duration, 0)
}
```

And a `Recording.test` helper file. **Create**
`Tapedeck/Tests/RecordingTestHelpers.swift`:

```swift
// ABOUTME: Test helpers for synthesising Recording instances pointing at temp audio.

import Foundation
import TapedeckCore

extension Recording {
    /// Synthesises a Recording whose computed audio path equals the given URL.
    /// Achieves this by routing the URL's parent dir + filename through the
    /// existing fields. Caller must supply a URL the test owns.
    static func test(sourceId: String, audioURL: URL) -> Recording {
        // The audio path is built by DetailPane / PipelineRelink from
        // Layout.standard.audioDir(date:) + stem + audioExtension.
        // For tests we override the path by giving the controller a recording
        // whose helper resolveAudioURL (introduced in PlaybackController) returns
        // this URL directly. See PlaybackController.audioURL(for:) override
        // discussed in Task 3 implementation.
        Recording(
            sourceId: sourceId,
            filename: audioURL.lastPathComponent,
            startedAt: 0,
            durationMs: 100,
            filesize: 0,
            audioExtension: audioURL.pathExtension,
            lastSeenAt: 0
        )
    }
}
```

**Note on URL resolution:** `PlaybackController` needs to derive a file URL
from a `Recording`. The same logic exists in `DetailPane.play(_:)` (lines
73–80 of `Tapedeck/Views/DetailPane.swift`). Extract it into a static
function on `PlaybackController` so tests can override it.

In `PlaybackController.swift`, add:

```swift
    static var audioURL: (Recording) -> URL = { rec in
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let dir = Layout.standard.audioDir(date: date)
        let stem = Layout.standard.stem(sourceId: rec.sourceId, title: rec.filename)
        let ext = rec.audioExtension ?? "audio"
        return dir.appending(path: "\(stem).\(ext)")
    }
```

Tests override this closure in `setUp` to return the fixture URL. **Revise
the test** to:

```swift
override func setUp() {
    super.setUp()
    PlaybackController.audioURL = { _ in self.fixtureURL }
}

var fixtureURL: URL!

override func setUpWithError() throws {
    fixtureURL = try WAVFixture.writeSilent()
}

override func tearDownWithError() throws {
    if let url = fixtureURL { try? FileManager.default.removeItem(at: url) }
    PlaybackController.audioURL = PlaybackController.defaultAudioURL
}
```

And add to `PlaybackController.swift`:

```swift
    static let defaultAudioURL: (Recording) -> URL = audioURL
```

**Step 2: Run the test, confirm it fails**

Expected failure: `controller.load(_:)` not defined.

**Step 3: Implement `load(_:)`**

In `PlaybackController.swift`:

```swift
    func load(_ rec: Recording) {
        let url = Self.audioURL(rec)
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
            currentRecording = nil
            player = nil
            duration = 0
            currentTime = 0
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
```

`AVAudioPlayerDelegate` conformance is not yet implemented; add a stub
extension to satisfy the protocol (callbacks land on arbitrary queues, so
hop):

```swift
extension PlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = self.duration
            self.stopTickTimer()
        }
    }
}
```

Add `private func stopTickTimer() { tickTimer?.invalidate(); tickTimer = nil }`.

**Step 4: Run the test, confirm pass**

Expected: PASS.

**Step 5: Commit**

```bash
git add Tapedeck/PlaybackController.swift Tapedeck/Tests/PlaybackControllerTests.swift Tapedeck/Tests/RecordingTestHelpers.swift
git commit -m "feat(playback): load recording from disk into AVAudioPlayer"
```

---

## Task 4: `load(_:)` is graceful when file is missing

**Files:**
- Modify: `Tapedeck/Tests/PlaybackControllerTests.swift`

**Step 1: Write the failing test**

```swift
func testLoadMissingFileLeavesCurrentRecordingNil() {
    PlaybackController.audioURL = { _ in
        URL(fileURLWithPath: "/nonexistent/path/missing.wav")
    }
    let rec = Recording.test(sourceId: "src-missing", audioURL: URL(fileURLWithPath: "/tmp/x"))

    let controller = PlaybackController()
    controller.load(rec)

    XCTAssertNil(controller.currentRecording)
    XCTAssertEqual(controller.duration, 0)
}
```

**Step 2: Run the test**

Expected: PASS already (the `try?` guard in `load` handles this), but the
test pins the behaviour so future refactors cannot regress it silently.

**Step 3: Commit**

```bash
git add Tapedeck/Tests/PlaybackControllerTests.swift
git commit -m "test(playback): pin graceful failure when audio file is missing"
```

---

## Task 5: `load(_:)` is idempotent on same sourceId

**Files:**
- Modify: `Tapedeck/Tests/PlaybackControllerTests.swift`
- Modify: `Tapedeck/PlaybackController.swift`

**Step 1: Write the failing test**

```swift
func testLoadSameSourceIdIsIdempotent() throws {
    let rec = Recording.test(sourceId: "src-1", audioURL: fixtureURL)

    let controller = PlaybackController()
    controller.load(rec)
    controller.currentTime = 1.5            // simulate progress

    controller.load(rec)                    // load same recording again

    XCTAssertEqual(controller.currentTime, 1.5, "Same-sourceId load must not reset position")
    XCTAssertEqual(controller.currentRecording?.sourceId, "src-1")
}
```

**Step 2: Run the test, confirm it fails**

Expected failure: second `load` resets `currentTime` to 0.

**Step 3: Add the idempotency guard**

In `PlaybackController.load(_:)`, before the `AVAudioPlayer` init, add:

```swift
        if currentRecording?.sourceId == rec.sourceId, player != nil {
            return
        }
```

**Step 4: Run the test, confirm pass**

Expected: PASS.

**Step 5: Commit**

```bash
git add Tapedeck/PlaybackController.swift Tapedeck/Tests/PlaybackControllerTests.swift
git commit -m "feat(playback): make load idempotent on same sourceId"
```

---

## Task 6: `togglePlayPause()` and `seek(to:)`

**Files:**
- Modify: `Tapedeck/PlaybackController.swift`
- Modify: `Tapedeck/Tests/PlaybackControllerTests.swift`

**Step 1: Write the failing tests**

```swift
func testTogglePlayPauseFlipsState() throws {
    let rec = Recording.test(sourceId: "src-1", audioURL: fixtureURL)
    let controller = PlaybackController()
    controller.load(rec)

    XCTAssertFalse(controller.isPlaying)
    controller.togglePlayPause()
    XCTAssertTrue(controller.isPlaying)
    controller.togglePlayPause()
    XCTAssertFalse(controller.isPlaying)
}

func testSeekUpdatesCurrentTime() throws {
    let rec = Recording.test(sourceId: "src-1", audioURL: fixtureURL)
    let controller = PlaybackController()
    controller.load(rec)

    controller.seek(to: 0.05)
    XCTAssertEqual(controller.currentTime, 0.05, accuracy: 0.01)
}

func testTogglePlayPauseWithoutLoadIsNoOp() {
    let controller = PlaybackController()
    controller.togglePlayPause()
    XCTAssertFalse(controller.isPlaying)
}
```

**Step 2: Implement the methods**

In `PlaybackController.swift`:

```swift
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
```

**Step 3: Run the tests, confirm pass**

Expected: all three new tests PASS.

**Step 4: Commit**

```bash
git add Tapedeck/PlaybackController.swift Tapedeck/Tests/PlaybackControllerTests.swift
git commit -m "feat(playback): togglePlayPause, seek, stop"
```

---

## Task 7: `PlayerBar` view

**Files:**
- Create: `Tapedeck/Views/PlayerBar.swift`

No unit tests for this view (UI is verified manually via the smoke checklist
in Task 9). The skill rules permit this: SwiftUI views without business
logic don't benefit from XCTest scaffolding.

**Step 1: Write the view**

```swift
// ABOUTME: Persistent player bar along the bottom of the main window. Reads state
// ABOUTME: from AppState.playback and routes button/slider events back to it.

import SwiftUI

struct PlayerBar: View {
    @Environment(AppState.self) var appState
    @State private var draggingTime: Double?

    var body: some View {
        if let rec = appState.playback.currentRecording {
            HStack(spacing: 12) {
                Button {
                    appState.playback.togglePlayPause()
                } label: {
                    Image(systemName: appState.playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)

                Text(rec.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)

                Text(formatTime(displayTime))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { draggingTime ?? appState.playback.currentTime },
                        set: { draggingTime = $0 }
                    ),
                    in: 0...max(appState.playback.duration, 0.01),
                    onEditingChanged: { editing in
                        if !editing, let t = draggingTime {
                            appState.playback.seek(to: t)
                            draggingTime = nil
                        }
                    }
                )

                Text(formatTime(appState.playback.duration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(height: 44)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var displayTime: TimeInterval {
        draggingTime ?? appState.playback.currentTime
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
```

**Step 2: Verify build**

Run the build command. Expected: success.

**Step 3: Commit**

```bash
git add Tapedeck/Views/PlayerBar.swift
git commit -m "feat(playback): add PlayerBar view"
```

---

## Task 8: Wire PlayerBar into MainView and remove local player from DetailPane

**Files:**
- Modify: `Tapedeck/TapedeckApp.swift` (wrap `MainView`'s body in VStack)
- Modify: `Tapedeck/Views/DetailPane.swift` (remove local player, rewire button)

**Step 1: Update `MainView` in `Tapedeck/TapedeckApp.swift`**

Replace the body of `MainView` (currently lines 43–73) so the
`NavigationSplitView` and toolbar sit inside a `VStack` with `PlayerBar` at
the bottom:

```swift
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
                ToolbarItem(placement: .primaryAction) {
                    if isSyncing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Syncing…").foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Sync now") {
                            isSyncing = true
                            Task {
                                _ = try? await SyncCoordinator.shared.runOnce(reason: "ui_button")
                                try? await appState.refresh()
                                isSyncing = false
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                if appState.tokenStatus == "expired" { ReAuthBanner() }
            }

            PlayerBar()
        }
    }
```

**Step 2: Update `Tapedeck/Views/DetailPane.swift`**

Remove:
- Line 9: `@State private var player: AVAudioPlayer?`
- Lines 73–81: the `play(_:)` method

Change the play button (line 53) from:

```swift
Button("▶ Play") { play(rec) }
```

to:

```swift
Button("▶ Play") {
    appState.playback.load(rec)
    appState.playback.togglePlayPause()
}
```

If `import AVKit` is no longer used after removing the local player, remove
that import too. (Check the file — if other views or code in DetailPane
still use `AVKit`, leave it.)

**Step 3: Verify build and tests**

```bash
xcodegen generate
xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck \
  -configuration Debug -derivedDataPath build/dd build -quiet
xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck \
  -derivedDataPath build/dd -destination 'platform=macOS' \
  -only-testing:TapedeckTests test -quiet
```

Expected: both succeed.

**Step 4: Commit**

```bash
git add Tapedeck/TapedeckApp.swift Tapedeck/Views/DetailPane.swift
git commit -m "feat(playback): mount PlayerBar in MainView, route DetailPane play button through controller"
```

---

## Task 9: Manual smoke test

This task is human-in-the-loop. Ben runs the app and ticks each item, or
reports the failure.

**Step 1: Build the local app**

```bash
./scripts/build-local.sh
open build/local/Tapedeck.app
```

**Step 2: Smoke checklist**

1. App launches with no player bar visible (no track loaded).
2. Click a recording with `audioDownloadedAt` set, press **▶ Play** in the
   detail pane. → Bar appears at the bottom with track title, ▶ becomes pause
   icon, elapsed time advances, total time matches the recording duration,
   audio is audible.
3. Click pause on the bar. → Icon flips to play, elapsed time stops
   advancing, audio stops.
4. Click play again. → Resumes from current position (not restart).
5. Drag the scrub bar to a new position and release. → Playback jumps to
   that position; elapsed time matches.
6. Click play on the same recording's detail-pane **▶ Play** button. →
   Toggles (does not restart at 0).
7. Click play on a different recording's detail-pane **▶ Play** button. →
   Bar swaps to the new track and starts playing.
8. Change selection in the recording list while audio is playing. → Audio
   keeps playing; bar still shows the original track.
9. Let a short recording play to the end. → Icon returns to play, elapsed
   time stays at total, no crash.
10. Click play on a recording whose `audioExtension` Core Audio cannot
    decode (or rename a file on disk to break it). → No crash; bar may stay
    empty or current track is unchanged.

**Step 3: macOS 14 verification (deferred)**

If a macOS 14.x test machine or VM is available, repeat checklist items
2 and 9 there. Otherwise note as outstanding in the PR description.

**Step 4: Done**

No commit for this task; smoke results inform whether anything needs fixing.

---

## Out of scope (do not implement)

- Keyboard shortcuts (space-to-pause)
- Playback speed
- Skip ±15s
- Click-transcript-line-to-seek
- `MPRemoteCommandCenter` / Now Playing integration
- Persisting position across app launches
- Tests of UI rendering (XCUITest, snapshot tests)
