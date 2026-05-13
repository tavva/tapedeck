# Player bar design

Persistent global audio player along the bottom of the Tapedeck window. Replaces
the local `AVAudioPlayer` state and "▶ Play" button in `DetailPane`.

## Goals

- Play, pause, scrub, and read elapsed/total time for a recording's audio.
- Playback survives changing the selected recording or project.
- One source of truth for playback state, reachable from any view.

## Audio format support

The Plaud devices produce Ogg Opus. Verified on macOS 15.7.3 that
`AVAudioPlayer` decodes these files via Core Audio (`afinfo` reads the same
container through the same framework, and pressing the existing Play button
produces audible output).

`project.yml` sets the deployment target to macOS 14.0. Native Opus support
landed in macOS 14, but this is not yet smoke-tested on a 14.x machine. The
graceful-failure path below (`try? AVAudioPlayer(contentsOf:) → nil` ⇒ bar
does not appear) covers any host where Core Audio cannot open the file, so a
worst-case 14.x regression matches the current Play-button behaviour rather
than crashing. Verifying on macOS 14 is a smoke-test item for the
implementation plan.

## Architecture

A new `PlaybackController` lives on `AppState` as `appState.playback`. It is
`@MainActor`, matching `AppState`. SwiftUI observes it directly.

Inherits `NSObject` so it can conform to `AVAudioPlayerDelegate` (the protocol
requires `NSObjectProtocol`). State and `@Observable` annotation sit on the
`NSObject` subclass.

State:

- `player: AVAudioPlayer?`
- `currentRecording: Recording?` — the loaded track, independent of
  `selectedSourceId`
- `isPlaying: Bool`
- `currentTime: TimeInterval`, `duration: TimeInterval`
- A tick timer (~10Hz) scheduled with
  `Timer.scheduledTimer(withTimeInterval:repeats:)` that runs only while
  `isPlaying` and pushes `player.currentTime` into `currentTime`. The block
  is `@Sendable`, not `@MainActor`, so it must hop explicitly with
  `Task { @MainActor in … }` before touching state. This matches the existing
  polling pattern in `AppState.swift:32`.

`AVAudioPlayerDelegate` is an Obj-C protocol with no main-actor annotation;
callbacks can arrive on any queue. `audioPlayerDidFinishPlaying(_:successfully:)`
must also `Task { @MainActor in … }` before mutating state.

Public API:

```swift
func load(_ rec: Recording)
func togglePlayPause()
func seek(to time: TimeInterval)
func stop()
```

`load(_:)` is idempotent on `sourceId`: if `currentRecording?.sourceId ==
rec.sourceId`, it returns without touching the player. So
`load(rec); togglePlayPause()` on the same track toggles between play and
pause instead of restarting from zero.

`AVAudioPlayer.currentTime` is a settable property, so `seek` is a one-liner.
`AVAudioPlayer` does not publish changes, so a poll timer is the right tool —
KVO and Combine wrappers around it are heavier and not needed.

The controller adopts `AVAudioPlayerDelegate` so it can react to
`audioPlayerDidFinishPlaying`: stop the tick, set `isPlaying = false`, leave
`currentTime = duration` so the bar reads "3:17 / 3:17". The next play tap
rewinds and restarts.

## UI

Window root becomes a `VStack(spacing: 0)`:

```
┌─────────────────────────────────────┐
│ existing content (sidebar | list |  │
│ detail pane)                        │
├─────────────────────────────────────┤
│ [▶] track title  ━━●━━━━  0:42/3:17 │   PlayerBar, ~44pt
└─────────────────────────────────────┘
```

`PlayerBar.swift` — single `HStack`, `.background(.bar)`, 1pt top `Divider`:

1. Play/pause button — SF Symbol `play.fill` / `pause.fill`
2. Track title — `currentRecording.filename`, middle-truncated, `.callout`
3. Elapsed time — monospaced digits, fixed width
4. `Slider(value: …, in: 0...duration)` with `onEditingChanged` calling
   `seek(to:)` on release only
5. Total time — monospaced digits

`formatTime`: `m:ss` under one hour, `h:mm:ss` otherwise.

Hidden (zero height) until the first track loads. After that it stays for the
session. No close button.

### Scrub-during-drag

A local `@State var draggingTime: Double?` in `PlayerBar` takes precedence over
`playback.currentTime` while non-nil, so the slider thumb stays under the
finger and the tick timer does not fight the drag. On release, write the value
through `seek(to:)` and clear `draggingTime`.

## Trigger

The existing `▶ Play` button in `DetailPane.swift:53` becomes:

```swift
appState.playback.load(rec)
appState.playback.togglePlayPause()
```

The local `@State private var player: AVAudioPlayer?` at line 9 and the
`play(_:)` method at line 73 are removed. The `audioDownloadedAt == nil`
disabled guard stays.

## Edge cases

- **New track while playing.** `load(_:)` stops the old player and replaces it.
  The caller then toggles play. Existing playback is interrupted, matching user
  expectation.
- **Missing or undecodable file.** `AVAudioPlayer(contentsOf:)` is wrapped in
  `try?`. If init fails (file missing, or a format Core Audio cannot decode),
  `currentRecording` stays nil and the bar does not appear. Log via
  `os.Logger` so we can diagnose. No user-visible error.
- **Recording deleted mid-playback.** `AVAudioPlayer` holds its own buffer,
  so playback continues. Not worth defending against.
- **File location.** Audio sits under `~/Tapedeck/audio/...` per
  `Layout.standard.audioDir`. The app is not sandboxed (entitlements declare
  only `com.apple.security.network.client`), so the player reads the path
  directly. No security-scoped bookmarks.

## Out of scope

Called out so we do not sneak them in:

- Keyboard shortcuts (space-to-pause)
- Playback speed
- Skip ±15s
- Click-transcript-line-to-seek
- `MPRemoteCommandCenter` / Now Playing integration
- Persisting position across app launches

## Files touched

- `Tapedeck/PlaybackController.swift` — new. Two-line `ABOUTME:` header
  matching existing Swift files (see `AppState.swift`, `DetailPane.swift`).
- `Tapedeck/Views/PlayerBar.swift` — new. Two-line `ABOUTME:` header.
- `Tapedeck/AppState.swift` — add `let playback = PlaybackController()`
- `Tapedeck/TapedeckApp.swift` — wrap root in `VStack` with `PlayerBar`
- `Tapedeck/Views/DetailPane.swift` — remove local player, rewire button

## Implementation plan

This document is a design. A separate implementation plan with task
checklist, expected outcomes, and verification steps will follow the
project's convention (see the `2026-05-12-tapedeck-app-design.md` →
`2026-05-12-tapedeck-app-implementation.md` pair).
