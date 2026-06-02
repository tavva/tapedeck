# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## What this is

Tapedeck is a native macOS app (Swift 6, macOS 14+) that syncs Plaud voice
recordings, transcribes them with Deepgram, classifies them into projects with
Gemini, and writes stable files into `~/Tapedeck/` for automation. The README
covers the user-facing story; this file covers the bits you can't infer by
reading one file.

## Project generation (read first)

`Tapedeck.xcodeproj/` is **generated and git-ignored**. `project.yml` is the
source of truth, consumed by [XcodeGen](https://github.com/yonaskolb/XcodeGen).

- After editing `project.yml` (or adding/removing/renaming files in a way that
  changes targets), run `xcodegen generate`.
- Never hand-edit `Tapedeck.xcodeproj` — changes are blown away on the next
  generate.

## Build & test

```bash
xcodegen generate                          # regenerate the Xcode project
swift test --package-path TapedeckCore      # TapedeckCore tests — this is what CI runs
./scripts/check-ci.sh                       # exactly the GitHub Actions check (TapedeckCore tests)
./scripts/build-local.sh                    # ad-hoc-signed debug Tapedeck.app into build/local/
TEAM_ID=<id> ./scripts/build-release.sh 0.1.0  # signed, notarised DMG + appcast (needs clean tree)
```

Run a single TapedeckCore test:

```bash
swift test --package-path TapedeckCore --filter TranscriptLabelsTests
```

App-target (XCTest) tests run through Xcode, not `swift test`:

```bash
xcodebuild test -project Tapedeck.xcodeproj -scheme Tapedeck \
  -only-testing:TapedeckTests/SyncCoordinatorTests
```

**Two test frameworks live side by side.** `TapedeckCore/Tests` uses
swift-testing (`import Testing`, `@Test`). `Tapedeck/Tests` uses XCTest.
CI only runs the TapedeckCore suite — if you change app-target behaviour, run
the XCTest suite locally yourself; the pre-push hook won't.

Pre-push hooks are gitleaks + `check-ci.sh`. Install once with
`pre-commit install --hook-type pre-push`.

## Architecture

One `.app` bundle ships **two binaries** plus a shared package:

- **`Tapedeck/`** — the SwiftUI app (sidebar, recording list, detail pane,
  player, settings, Sparkle updates).
- **`TapedeckSyncHelper/`** — a headless CLI that runs exactly one sync cycle
  and exits. Launched three ways: by a LaunchAgent every 15 min
  (`com.benphillips.tapedeck.synchelper`), by the UI at launch, and by "Sync
  now". `main.swift` is a thin shim over `HelperRunner` in TapedeckCore.
- **`TapedeckCore/`** — the SwiftPM package both binaries depend on. Owns the
  Plaud/Deepgram/Gemini clients, the GRDB store, the pipeline, filesystem
  layout, transcript rendering, and relinking.

### How the UI and helper talk

There is **no XPC**. Coordination is entirely through:

1. **The shared SQLite store** (`~/Library/Application Support/Tapedeck/state.db`,
   GRDB, WAL). Both binaries open the same file. `Store` owns the migration
   ladder.
2. **`AppStateNotifier`** — the helper posts a Darwin notification naming a
   changed key (`helper_stage`, `last_sync_at`, `token_status`, `recordings`);
   the UI re-reads the store in response.
3. **Child-process spawn** — `SyncCoordinator` (an actor in the app) runs the
   helper binary as a subprocess, one operation at a time, scoped by `Kind`
   (sync / classify / transcribe, pending or per-source).

### The pipeline

`Pipeline` (actor, `TapedeckCore`) is the heart. One `runCycle()` is
idempotent and sequential:

```
ensureToken → discoverHost → listRemote → downloadNew
            → transcribeNew → classifyNew → relinkChanged → touchLastSync
```

It owns no state beyond an injected `Deps` struct, so it's safe to construct
fresh per invocation. Bounded per-stage parallelism (`maxConcurrency = 3`) and
a per-stage failure cap (`maxFailuresPerStage = 3`) that records errors in
`recording_errors`.

### `app_state` is a key/value table

Flags and settings are rows in `app_state`, not columns or files. Notable keys:
`auto_transcribe`, `auto_classify` (both default **off** — paid API calls are
opt-in; manual toolbar actions always run regardless), `classifier_threshold`
(default `0.7`), `token_status` (`expired` halts sync), `last_sync_at`,
`helper_stage`.

### Secrets

`KeychainStore.shared` probes its entitlement at runtime and picks a backend:
signed builds use the data-protection keychain via the team-prefixed
`keychain-access-groups` access group; ad-hoc/unsigned/test builds (no
entitlement) fall back to a `0600` JSON file at
`Layout.standard.devSecretsURL()` (`dev-secrets.json`). This is why
`build-local.sh` strips `keychain-access-groups` — ad-hoc builds have no
provisioning profile and would otherwise fail. Don't "fix" that strip.

### Filesystem layout

`Layout` is the single source of truth for every on-disk path. All path
construction goes through it so tests inject a tmpdir root rather than touching
`~`. Dated `~/Tapedeck/audio/YYYY-MM-DD/` folders are the source of truth;
`~/Tapedeck/projects/<slug>/` is a relinked view (transcript/JSON copies +
symlinks back to audio).

### Helper exit codes

`runHelper` returns process exit codes the UI reads: `0` ok, `1` generic
failure, `2` token missing, `3` required API key missing, `4` token expired,
`75` skipped because another run holds the `SyncLock`. `SyncLock` is the
single-flight file lock that stops LaunchAgent and UI runs from colliding.

## Conventions

- **Dependency injection via `Deps` structs** (`Pipeline.Deps`, `HelperDeps`)
  with `@Sendable` closures for clock, secret reads, and client construction.
  Tests inject stubs; HTTP is faked with `URLProtocolStub`, never live network.
- Swift 6 strict concurrency: actors (`Pipeline`, `SyncCoordinator`) and
  `Sendable` boundaries are load-bearing — keep them.
- Design and implementation notes live in `docs/plans/`; operator checklists in
  `docs/runbooks/` (`first-launch.md`, `smoke.md`).
