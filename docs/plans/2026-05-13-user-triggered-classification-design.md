# User-Triggered Classification — Design

## Problem

Classification currently runs unconditionally as part of `Pipeline.runCycle()`
(`TapedeckCore/Sources/TapedeckCore/Pipeline.swift:44`). Every transcribed
recording is sent to Gemini on the next sync cycle, with no user control over
when or whether classification happens. We want classification to be a
user-triggered process by default, with auto-classification available as an
opt-in.

## Behaviour change

`Pipeline.runCycle()` still calls `classifyNew()`, but `classifyNew()` short-
circuits unless a new `app_state.auto_classify` key is `"true"`. Default is
absent / `"false"`, so existing users stop seeing automatic classification on
the next sync and opt in through Settings if they want it back.

Two new user-triggered entry points cover the explicit cases:

- **Bulk**: a "Classify" toolbar button next to "Sync now" that classifies
  every recording with a transcript but no classification. User-triggered, so
  the `maxFailuresPerStage` skip gate is bypassed — clicking the button is
  itself the retry signal.
- **Per recording**: a "Classify" / "Reclassify" button in `DetailPane` that
  classifies the selected recording. Label switches based on whether
  `classifiedAt` is set; behaviour is identical (always runs, also bypasses
  the failure gate).

Both user-triggered paths also run a relink pass after classification so
recordings end up in their project folders without waiting for the next sync
cycle.

## Data model

No schema change. New key in the existing `app_state` table:

- `auto_classify` — `"true"` / `"false"`, default `"false"` when absent.

Read alongside `classifier_threshold` in `Pipeline`.

## RecordingRepository changes

`TapedeckCore/Sources/TapedeckCore/RecordingRepository.swift` gains a single
lookup method:

```
public func find(sourceId: String) throws -> Recording?
```

Used by `classifyOne(sourceId:)` to resolve the recording, and by tests that
need to read a single row by id. Returns nil for unknown ids (the caller
throws an explicit `unknownRecording` error).

## Pipeline changes

### Error model

A new public error type for explicit classification:

```swift
public enum ClassifyError: Error, Equatable {
    case unknownRecording(String)
    case transcriptMissing(URL)
    case providerFailed(String)
    case noActiveProjects
}
```

### `TapedeckCore/Sources/TapedeckCore/PipelineClassify.swift`

Refactor so the core path is throwing and the batch path is the one that
swallows / records:

1. New private `performClassifyOne(_ rec:hints:threshold:) async throws` —
   the throwing core. Reads the transcript and throws
   `ClassifyError.transcriptMissing` if absent (today it silently sends an
   empty string). Wraps Gemini failure in
   `ClassifyError.providerFailed(message)`. On success, writes the
   classification row and clears the `.classify` error.
2. `classifyOne(_ rec:hints:threshold:) async` (the existing private batch
   helper) becomes a thin wrapper: calls `performClassifyOne`, catches all
   errors, records to `recording_errors`, returns. Behaviour unchanged for
   the batch path.
3. New public `classifyOne(sourceId:) async throws` — looks up the recording
   via `RecordingRepository.find(sourceId:)`, loads active projects and
   threshold, bypasses `shouldSkipAfterFailures`, then calls
   `performClassifyOne`. Throws `ClassifyError.unknownRecording` if the id
   isn't found. If there are no active projects, writes a `.classify` error
   row for the recording (so the existing error UI surfaces "no active
   projects" next to the row) and throws `ClassifyError.noActiveProjects`.
   On any error from `performClassifyOne`: records to `recording_errors`
   *and* rethrows so the helper can exit non-zero.
4. `classifyNew()` reads `auto_classify` at the top. If not `"true"`, logs
   `classify_skipped_auto_disabled` and returns. Otherwise current behaviour.
5. New public `classifyPending() async` — runs the batch loop but without
   the `auto_classify` check **and** without the `shouldSkipAfterFailures`
   filter (user-triggered). The existing no-active-projects guard
   (`classify_skipped_no_projects`) stays in place: with zero projects
   there is nothing to classify against, and silently doing nothing is
   the right batch behaviour. The toolbar button's pending-count tooltip
   already lets the user notice the no-op.

`Pipeline.swift`:

- Add a sibling to `classifierThreshold()`:

  ```
  func autoClassifyEnabled() throws -> Bool
  ```

  reads `app_state.auto_classify`, returns false when absent or non-`"true"`.

- Make `relinkChanged()` public so the helper can call it after explicit
  classification. (Today it is internal; that's fine for `runCycle` but the
  new subcommands need direct access.)

## Helper changes

`TapedeckSyncHelper/main.swift` gains a small dispatcher so the subcommand
paths are testable. The helper currently bakes in `Layout.standard`,
`KeychainStore.shared`, the concrete network clients, and `exit()` — none
of which are reachable from tests. The plan extracts the runnable parts
into a new file `TapedeckSyncHelper/HelperRunner.swift` that compiles into
both the helper binary and a new test target:

```swift
@MainActor
public enum HelperCommand: Equatable {
    case fullCycle
    case classifyPending
    case classifySource(String)
}

public struct HelperDeps {
    public var layout: Layout
    public var openStore: (URL) throws -> Store
    public var readSecret: (String, String) throws -> String?  // service, account
    public var makeSource: (String) -> SourceClient
    public var makeDeepgram: (String) -> DeepgramClient
    public var makeGemini: (String) -> GeminiClient
    public var logger: any SyncLog
    public var now: @Sendable () -> Int64
    public var notify: (String) -> Void  // wraps AppStateNotifier.post
}

@MainActor
public func runHelper(_ cmd: HelperCommand, deps: HelperDeps) async -> Int32

public func parseArguments(_ argv: [String]) -> HelperCommand
```

`main.swift` shrinks to: parse args → build a production `HelperDeps`
(real Layout, real Keychain, real clients, real logger) → call
`runHelper(_:deps:)` → `exit(status)`. The existing
`--read-keychain-sentinel` branch in `main.swift` stays where it is, since
it must run before any pipeline construction. (`--write-keychain-sentinel`
lives in `Tapedeck/TapedeckApp.swift`, not the helper, and is unaffected.)

`HelperRunnerTests` (new XCTest target alongside the existing core tests)
uses an in-memory `Store`, stub network clients, and a fake keychain
closure so the four exit-code paths can be asserted without spawning the
helper process. `project.yml` adds the new target with the helper sources
as members.

Subcommand semantics:

- `--classify-pending` → `.classifyPending`
  - Acquires `SyncLock` (same as `.fullCycle`). If already held, logs
    `classify_skipped_already_running` and exits 0 — matches the existing
    pattern but with a distinct event name so the user-triggered case is
    debuggable.
  - Reads only what classification actually uses: the Gemini key from
    Keychain and the database. The source JWT and Deepgram key are not
    required for this path. The existing `Pipeline.Deps` constructor takes
    all of `source` / `deepgram` / `gemini`, so the classify subcommands
    pass placeholder instances for the unused clients (e.g. constructed
    with empty-string tokens). They are never called in this path.
  - Calls `pipeline.classifyPending()` then `pipeline.relinkChanged()`.
  - Posts `AppStateNotifier`. Exits 0 on success, 3 if the Gemini key is
    missing, 1 on any other failure. **Does not** use exit codes 2 or 4 —
    those are reserved for the source-token paths in `.fullCycle`, and the
    classify subcommands neither call `ensureToken()` nor touch the source
    API.
- `--classify-source <sourceId>` → `.classifySource(id)`
  - Same lock + deps setup, same Gemini-only key requirement.
  - Calls `pipeline.classifyOne(sourceId:)` then `pipeline.relinkChanged()`.
  - Exits 0 on success. On `ClassifyError` (or anything else thrown): exits
    1. The error is already persisted to `recording_errors` by the
    pipeline, so the UI surfaces it via the existing error row. Same
    rationale as above for not using exit codes 2 / 4.

Both subcommands reuse `SyncLock` so they cannot race with a regular sync
cycle.

## UI changes

### `Tapedeck/SyncCoordinator.swift`

Today `runOnce(reason:)` keeps an `inflight: Task<Int32, Error>?` and any
caller gets the existing task back regardless of what it asked for. That's
unsafe once we have multiple operation kinds. Replace it with:

```swift
enum Kind: Equatable { case sync, classifyPending, classifySource(String) }
private var current: (kind: Kind, task: Task<Int32, Error>)?

enum CoordinatorError: Error { case otherOperationRunning(Kind) }
```

`Kind` is module-internal (not `private`) so the UI can observe and switch
on it via `AppState`. The actor's `current` storage remains `private`.

- If `current` is nil → start a new task for the requested kind, store it,
  return its value (clearing on completion via `defer`).
- If `current.kind == requested` (e.g. duplicate `Sync now` click) → return
  the existing task's value. Today's behaviour for the same kind.
- If `current.kind != requested` → throw `otherOperationRunning(currentKind)`
  so the caller can show a sensible message. The UI prevents this by
  disabling both buttons during any in-flight operation, but the coordinator
  is the safety net.

Public surface:

- `runOnce(reason:)` — unchanged signature, dispatches `.sync`.
- `classifyPending(reason:)` — dispatches `.classifyPending`.
- `classifyOne(sourceId:reason:)` — dispatches `.classifySource(sourceId)`.

### `Tapedeck/AppState.swift` operation state

`AppState` already owns the per-screen observable state; add a single new
observable property so all views that need to know whether a sync /
classify is in flight can read from one place:

```swift
var busy: SyncCoordinator.Kind? = nil
```

`AppState` gets thin wrappers around `SyncCoordinator` that flip this
flag for the duration of each call:

```swift
@MainActor
func syncNow(reason: String) async  // sets .sync, awaits runOnce, clears
@MainActor
func classifyPending(reason: String) async
@MainActor
func classifyOne(sourceId: String, reason: String) async
```

These methods catch `CoordinatorError.otherOperationRunning` and log it
(it shouldn't happen because the UI gates calls, but the catch is the
safety net so callers don't have to). After completion they call
`refresh()`.

**All existing direct callers of `SyncCoordinator.shared.runOnce` move
through these wrappers**, preserving their reasons:

- `AppDelegate.applicationDidFinishLaunching` — `appState.syncNow(reason: "app_launch")`.
- `AppState.overrideProject` — the existing
  `Task.detached { try? await SyncCoordinator.shared.runOnce(reason: "manual_override") }`
  becomes `Task { await self.syncNow(reason: "manual_override") }` so the
  busy flag is honoured (the `Task.detached` was load-bearing only because
  the call was made from inside a `@MainActor` method; a plain `Task` on
  `@MainActor` is fine).
- `MainView` toolbar's "Sync now" button — `appState.syncNow(reason: "ui_button")`.

After this change, the only place `SyncCoordinator.shared` is referenced
directly is from inside `AppState`. A grep check (`SyncCoordinator.shared`
should match exactly one call site after the change) is part of the
verification step.

### `Tapedeck/TapedeckApp.swift` toolbar

Both toolbar buttons read `appState.busy`:

- "Sync now":
  - Disabled when `appState.busy != nil`.
  - Shows `ProgressView` + "Syncing…" when `appState.busy == .sync`.
  - Action: `await appState.syncNow(reason: "ui_sync_now")`.
- "Classify" next to it:
  - Disabled when `appState.busy != nil` *or*
    `appState.statusCounts.toClassify == 0` *or*
    `appState.projects.isEmpty` (no projects → nothing to classify
    against; gating in the UI keeps the user-triggered
    `ClassifyError.noActiveProjects` path purely defensive).
  - Shows `ProgressView` + "Classifying…" when
    `appState.busy == .classifyPending`.
  - Tooltip shows the pending count.
  - Action: `await appState.classifyPending(reason: "ui_classify_pending")`.

The `@State private var isSyncing` flag currently in `MainView` is
removed in favour of `appState.busy`.

### `Tapedeck/Views/DetailPane.swift`

A button on the selected recording, also reading `appState.busy`:

- Label: `"Classify"` if `recording.classifiedAt == nil`, else
  `"Reclassify"`.
- Disabled while `appState.busy != nil` (any sync or classify in flight),
  or if `recording.transcribedAt` is nil (no transcript to classify
  against), or if `appState.projects.isEmpty`.
- Action: `await appState.classifyOne(sourceId: recording.sourceId,
  reason: "ui_classify_one")`. Existing error-row UI handles failure
  display.

### `Tapedeck/Views/Settings/ClassifierTab.swift`

New toggle: "Classify new recordings automatically", bound to
`app_state.auto_classify`. Off by default. Help text explains that toggling
on restores the pre-change behaviour of classifying as part of each sync.

## Testing

Following TDD, write the failing test first for each change.

### `RecordingRepositoryTests`

- `find_returnsNil_forUnknownSourceId`
- `find_returnsRecording_forKnownSourceId`

### `PipelineClassifyTests` (new) / `PipelineEndToEndTests` (updates)

- `runCycle_doesNotClassify_whenAutoClassifyAbsent` — set up a recording with
  a transcript and active project, run `runCycle()`, assert no classification
  decision was written, and the `classify_skipped_auto_disabled` log line
  was emitted.
- `runCycle_classifies_whenAutoClassifyTrue` — same setup, with
  `auto_classify = "true"`, assert decision is written. (This reframes the
  existing end-to-end behaviour as opt-in.)
- `classifyPending_runs_regardlessOfAutoClassify` — `auto_classify` absent,
  call `classifyPending()` directly, assert decision written.
- `classifyPending_bypassesFailureGate` — recording with a `.classify` error
  at attempt = `maxFailuresPerStage`, assert `classifyPending()` still
  classifies it.
- `classifyOne_reclassifies_whenAlreadyClassified` — recording with
  `classifiedAt` set, call `classifyOne(sourceId:)`, assert decision and
  `classifiedAt` updated.
- `classifyOne_ignoresFailureGate` — same as the bulk case, but for the
  single-recording path.
- `classifyOne_throwsAndRecordsError_whenTranscriptMissing` — recording
  without a transcript file, assert `ClassifyError.transcriptMissing` is
  thrown *and* a `recording_errors` row was written.
- `classifyOne_throws_whenSourceIdUnknown` — call with a non-existent id,
  assert `ClassifyError.unknownRecording`.
- `classifyOne_throws_whenNoActiveProjects` — recording present and
  transcribed, but no active projects in the database; assert
  `ClassifyError.noActiveProjects` is thrown, *and* a `.classify` row
  was written to `recording_errors`, *and* no classification decision
  was written.
- `classifyPending_isNoOp_whenNoActiveProjects` — pending recordings
  present but no active projects; assert `classify_skipped_no_projects`
  is logged and no decisions are written.
- `classifyOne_throwsAndRecordsError_onProviderFailure` — Gemini stub
  throws, assert `ClassifyError.providerFailed` propagates and the error row
  is written.
- `classifyOne_runsRelinkAfterSuccess` — assert that after a successful
  classification (with confidence above threshold), the recording's
  `project_link_state` ends up `linked` rather than `pending_relink` when
  driven through the helper path (or via a `classifyAndRelink` test helper).

### Existing tests

`StatusCountsTests` requires no change — `toClassify` already counts
transcribed-but-unclassified recordings.

`PipelineEndToEndTests` cases that currently rely on classification
happening during `runCycle()` are updated to set `auto_classify = "true"`
in their fixture so the dependency on the flag is explicit.

### Helper subcommand tests

The helper is extracted into `HelperCommand` + `runHelper(_:)` so it can be
unit-tested. Add a `HelperCommandTests` target (or extend the existing
helper test target) covering:

- `runHelper(.classifyPending)` exits 0 in the success path and calls into
  the pipeline's classify + relink methods (verified via the in-memory
  Store).
- `runHelper(.classifySource(id))` exits 1 when `ClassifyError` is thrown
  and 0 on success.
- `runHelper(.classifySource("unknown"))` exits 1 with
  `ClassifyError.unknownRecording`.
- Argument parsing: a tiny `parseArguments([String]) -> HelperCommand`
  function with tests for the three shapes (`[]`, `[--classify-pending]`,
  `[--classify-source, id]`) and for the rejection of malformed input
  (`[--classify-source]` with no id → falls through to `.fullCycle` or
  prints usage; pick one and lock it in a test).

### `SyncCoordinator` tests

A small unit test covers the new operation-kind gating:

- Concurrent `runOnce` calls share the in-flight task (existing behaviour).
- A `classifyPending(reason:)` call while a `runOnce` is in flight throws
  `CoordinatorError.otherOperationRunning(.sync)`.
- After completion, a new operation of a different kind starts cleanly.

The coordinator is refactored to take an injectable spawner closure so the
tests don't actually fork the helper binary.

## Migration

No schema migration. Existing users get `auto_classify` absent → treated as
`"false"` → classification stops happening automatically on the next sync.
The Settings toggle re-enables it.

## Out of scope (YAGNI)

- Bulk classify scoped to a single project. Defer until there's a concrete
  need (e.g. classifying against a newly added project).
- Right-click context menu on rows in `RecordingList`. The DetailPane button
  covers the per-recording case.
- A "Cancel running classification" affordance. The helper finishes its
  current batch on its own; mid-flight cancellation is fiddly and not
  requested.
- Surfacing per-recording classify errors in a banner. The existing
  `recording_errors` row is already shown in the list and detail pane.
- Queueing operations rather than rejecting cross-kind concurrency. The UI
  disables the buttons, so the queueing case shouldn't arise in practice.
