# Helper stage visibility — design

## Problem

Two related gaps in current behaviour:

1. **Background helper activity is invisible.** `TapedeckSyncHelper` runs in
   three contexts: launchd every 15 min, app launch, and UI buttons. Only the
   UI-button path flips `AppState.busy`, so the toolbar spinner. Activity from
   launchd or from internal stages of `runFullCycle` is silent in the UI.
   `runFullCycle` walks sync → transcribe → classify, but even when triggered
   from the UI the toolbar only shows "Syncing…" for the whole cycle.

2. **Individual Transcribe / Classify silently no-op.** The in-process
   `SyncCoordinator` only knows about helpers this app spawned. If launchd has
   a helper running, the UI happily spawns a second one, which fails to
   acquire `SyncLock`, logs `transcribe_skipped_already_running`, and exits 0.
   The UI reads exit 0 as success. Same path exists for classify and full
   sync.

## Approach

Helper writes its current stage and progress to `app_state`. The UI reads
those rows and derives toolbar / button state from them. The skip case
becomes a distinct exit code that the UI surfaces as a transient banner.

## Data model

Four `app_state` rows owned by the helper:

| key                  | values                                                | meaning                          |
|----------------------|-------------------------------------------------------|----------------------------------|
| `helper_stage`       | `idle`, `syncing`, `transcribing`, `classifying`      | What the helper is doing now     |
| `helper_started_at`  | epoch-ms                                              | When current stage entered       |
| `helper_stage_done`  | Int                                                   | Items completed in current stage |
| `helper_stage_total` | Int                                                   | Total items in current stage     |

Defaults: `idle`, 0, 0, 0. `total == 0` means "no count applicable" (e.g.
discover/list portion of sync).

## Helper changes

### Stage writer

Add `HelperStatus.swift` in `TapedeckCore` with:

```swift
public enum HelperStage: String, Sendable { case idle, syncing, transcribing, classifying }

public func writeHelperStage(_ stage: HelperStage, store: Store, now: () -> Int64) throws
public func writeHelperProgress(done: Int, total: Int, store: Store) throws
```

Each call writes the relevant `app_state` rows in a single transaction. The
caller is responsible for posting via `deps.notify("helper_stage")` after
writes (reusing the existing `HelperDeps.notify` seam so tests can observe
transitions without hooking the system-wide `DistributedNotificationCenter`).

### Pipeline split

Promote `transcribeNew` and `classifyNew` from `internal` so the helper can
compose them. Add `syncOnly()` (rename of the first half of `runCycle()`):

```swift
public func syncOnly() async throws {
    try ensureToken()
    try await deps.source.discoverHost()
    try await listRemote()
    try await downloadNew()
}
```

`runCycle()` stays as a convenience that calls `syncOnly()` →
`transcribeNew()` → `classifyNew()` → `relinkChanged()` → `touchLastSync()`.
Tests keep using it.

### Per-stage progress

`downloadNew`, `transcribeNew` / `transcribePending`, `classifyNew` /
`classifyPending` all iterate pending items inside `withTaskGroup` with
`maxConcurrency = 3`. Add ticks on the controlling task after each
`group.next()`:

```swift
let total = pending.count
try writeProgress(done: 0, total: total)
await withTaskGroup(of: Void.self) { group in
    var inflight = 0, done = 0
    for rec in pending {
        if inflight >= maxConcurrency {
            await group.next(); inflight -= 1
            done += 1; try? writeProgress(done: done, total: total)
        }
        group.addTask { [self] in await self.transcribeOneSilently(rec) }
        inflight += 1
    }
    while await group.next() != nil {
        done += 1; try? writeProgress(done: done, total: total)
    }
}
```

One DB write per item. Item duration is seconds at minimum, so the write
rate is low.

`transcribeOne` / `classifyOne` write `total = 1`, tick to `done = 1` on
completion.

### `runFullCycle` orchestration

`runFullCycle` becomes a thin orchestrator with explicit stage transitions:

```swift
let lock = try SyncLock(...)
guard lock.tryAcquire() else {
    deps.logger.info("sync_skipped_already_running", source: nil)
    return 75   // EX_TEMPFAIL
}
defer {
    try? writeHelperStage(.idle, store: store, now: deps.now)
    deps.notify("helper_stage")
}

try writeHelperStage(.syncing, store: store, now: deps.now)
deps.notify("helper_stage")
try await pipeline.syncOnly()

if autoFlag(...auto_transcribe) {
    try writeHelperStage(.transcribing, ...); deps.notify("helper_stage")
    try await pipeline.transcribeNew()
}
if autoFlag(...auto_classify) {
    try writeHelperStage(.classifying, ...); deps.notify("helper_stage")
    try await pipeline.classifyNew()
}
try pipeline.relinkChanged()
try pipeline.touchLastSync()
```

The single-stage runners (`runTranscribePending`, `runTranscribeSource`,
`runClassifyPending`, `runClassifySource`) set their stage on lock
acquisition and clear in `defer`, same pattern.

### Skip exit code

When `tryAcquire()` fails in any helper command, log as today and return
**75** (`EX_TEMPFAIL`). The helper never writes `helper_stage` in this path
— it doesn't own the running stage.

## UI changes

### `SyncCoordinator`

```swift
enum CoordinatorError: Error, Equatable {
    case otherOperationRunning(Kind)
    case helperBusy(Kind)   // helper exited 75
}
```

The mapping lives in `dispatch`, not `spawnHelper`. `Spawner` keeps its
current `(Kind, String) async throws -> Int32` signature so injected test
spawners can simply return raw status codes:

```swift
private func dispatch(_ kind: Kind, reason: String) async throws -> Int32 {
    // ... existing in-process exclusion check ...
    let status = try await spawner(kind, reason)
    if status == 75 { throw CoordinatorError.helperBusy(kind) }
    return status
}
```

All other non-zero codes continue to surface as the helper's own logged
failure (UI doesn't currently treat those specially).

### `AppState`

```swift
var helperStage: HelperStage = .idle
var stageDone: Int = 0
var stageTotal: Int = 0
var transientMessage: String? = nil

var activity: SyncCoordinator.Kind? {
    switch helperStage {
    case .syncing:      return .sync
    case .transcribing: return .transcribePending
    case .classifying:  return .classifyPending
    case .idle:         return busy
    }
}
```

`refresh()` reads all four `helper_*` rows from `app_state` in the same read
block it already uses for `last_sync_at`.

### `AppState` testability seam

The current `AppState.init()` opens `Layout.standard`, starts a 30 s timer,
reads `KeychainStore.shared` synchronously, and calls `SyncCoordinator.shared`
from inside `dispatch`, all of which make the new `AppStateTests` impossible
without leaking real-system access. Add an injectable initialiser before the
new tests:

```swift
protocol OperationRunner: Sendable {
    func run(_ kind: SyncCoordinator.Kind, reason: String) async throws -> Int32
}

init(layout: Layout = .standard,
     store: Store? = nil,
     tokenReader: @escaping () -> Bool = AppState.defaultTokenReader,
     coordinator: any OperationRunner = SyncCoordinator.shared,
     lockProbe: (() -> Bool)? = nil,
     polling: Bool = true,
     transientDuration: Duration = .seconds(4))
```

Inside `init`, `lockProbe ?? { AppState.probeLock(at: layout.lockURL()) }`
binds the default to the injected `layout`. `probeLock(at:)` is a small
static helper that opens `SyncLock`, calls `tryAcquire()`, and lets the
lock release on return.

`SyncCoordinator` gains a conformance to `OperationRunner` whose `run` is
a thin wrapper over the existing `dispatch`. `AppState.dispatch` calls
`coordinator.run(kind, reason:)` instead of `SyncCoordinator.shared.runOnce`
etc. The default `lockProbe` performs the `flock(LOCK_EX | LOCK_NB)` against
`layout.lockURL()` and releases on return.

The convenience initialiser used by production stays at `AppState()` — it
forwards to this with defaults. Tests construct `AppState` with an
in-memory store, a stubbed token reader, a fake `OperationRunner` whose
`run` throws `SyncCoordinator.CoordinatorError.helperBusy(kind)` to
exercise the banner path (the raw-status mapping lives in
`SyncCoordinator.dispatch`, so a fake that returns `75` would not throw),
a stub `lockProbe` closure that returns true/false per test, `polling:
false`, and a short `transientDuration` so the auto-clear assertion runs
in milliseconds.

`dispatch` catches `helperBusy`:

```swift
} catch SyncCoordinator.CoordinatorError.helperBusy(let kind) {
    transientMessage = "Another sync operation is in progress."
    Task { try? await Task.sleep(for: transientDuration); transientMessage = nil }
}
```

### Toolbar (`TapedeckApp.swift`)

Replace `appState.busy == X` with `appState.activity == X` for the three
spinners and the disable predicates. The label uses the progress count when
available:

```swift
Text(progressLabel(for: .transcribePending, done: stageDone, total: stageTotal))
// "Transcribing 3 of 7…" when total > 0, else "Transcribing…"
```

Same for syncing and classifying.

### `DetailPane`

Per-row Transcribe / Retranscribe button gets `.disabled(appState.activity != nil)`.
The existing per-row spinner stays as-is for the case where the user
specifically dispatched this recording.

### Transient banner

In `MainView.overlay(alignment: .top)`, add a banner shown when
`appState.transientMessage != nil`, styled like the existing `ReAuthBanner`
but auto-dismissed by the `AppState` task.

## Edge cases

### Stale `helper_stage` after a SIGKILL

`flock` releases automatically when the holding process dies, so we can
detect the stale-DB-row case by probing the lock. The probe runs in two
places:

1. **`AppState.init`**, before the first `refresh()` — covers the case
   where the app starts after a previous helper crash.
2. **`refresh()`**, whenever `helperStage != .idle` — covers the case
   where a helper is SIGKILL'd while the app is already running. Without
   this, the 30-second poll and the notification channel both stay silent
   (the dead helper can't post `"helper_stage"`), so the UI would stay
   disabled indefinitely.

```swift
private func clearStaleStageIfNoHelper() {
    guard lockProbe() else { return }
    // No helper is running; any non-idle stage is stale.
    try? clearHelperStage()
}
```

The probe is the injected `lockProbe` closure described under the
testability seam. Its default implementation opens a `SyncLock` at
`layout.lockURL()`, calls `tryAcquire()`, and releases on return.
`AppState` stores the injected `layout` so tests with a temp-directory
`Layout` never touch the real app lock path. Tests stub `lockProbe`
directly because `flock` does not contest same-process fds on macOS,
so a "lock-held" scenario can't be faked by a second `open()` in the
test process.

The probe is cheap (one non-blocking `flock` syscall) and only fires in
`refresh()` when the cached `helperStage != .idle`, so steady-state
overhead is zero. No timestamp-based fallback unless we observe flakiness
in practice.

### Notification storms

The helper posts `"helper_stage"` on every stage transition and never on
progress ticks — progress shows up via the 30-second poll. If that feels
laggy we can selectively notify on every Nth tick later, but YAGNI for now.

### Migrations

New `app_state` rows default to absent. `AppState` treats missing rows as
`(idle, 0, 0, 0)`. No SQL migration needed.

## Testing

- `HelperRunnerTests`:
  - `runFullCycle` writes `helper_stage` transitions in expected order and
    ends on `idle`.
  - `runFullCycle` ends on `idle` even when the pipeline throws.
  - `runTranscribePending` / `runClassifyPending` set their stage on acquire
    and clear on exit.
  - `runFullCycle` and all four single-stage runners return exit code 75
    when the lock is already held.
- `SyncCoordinatorTests`:
  - Spawner returning 75 throws `helperBusy(kind)`.
- `PipelineTranscribeTests` / `PipelineClassifyTests` / `PipelineDownloadTests`:
  - `helper_stage_done` and `helper_stage_total` end at `(N, N)` after
    processing N items.
- `AppStateTests`:
  - `activity` derives correctly from `helperStage` and `busy`.
  - `transientMessage` is set on `helperBusy` and cleared after the
    configured `transientDuration`.
  - `clearStaleStageIfNoHelper` clears a non-idle `helper_stage` when the
    injected `lockProbe` returns `true`, and leaves it untouched when the
    probe returns `false`.

## What we are not doing

- No richer per-stage progress (e.g. "Transcribing 3 of 7 — current.ogg…").
- No telemetry / history of past stage durations.
- No backward-compat shims — the helper and UI ship together.
- No cancellation. Stages run to completion of the current pipeline call.
