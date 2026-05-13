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
  every recording with a transcript but no classification.
- **Per recording**: a "Classify" / "Reclassify" button in `DetailPane` that
  classifies the selected recording. Label switches based on whether
  `classifiedAt` is set; behaviour is identical (always runs).

## Data model

No schema change. New key in the existing `app_state` table:

- `auto_classify` — `"true"` / `"false"`, default `"false"` when absent.

Read alongside `classifier_threshold` in `Pipeline`.

## Pipeline changes

`TapedeckCore/Sources/TapedeckCore/PipelineClassify.swift`:

- `classifyNew()` reads `auto_classify` at the top. If not `"true"`, logs
  `classify_skipped_auto_disabled` and returns. Otherwise, current behaviour
  unchanged.
- New public `classifyPending()` runs the existing batch loop unconditionally
  (the auto-classify flag only gates the `runCycle` path).
- The private `classifyOne(_:hints:threshold:)` is wrapped by a new public
  `classifyOne(sourceId:)` that:
  - Looks up the recording by id.
  - Loads active projects and threshold.
  - Bypasses `shouldSkipAfterFailures` (user explicitly requested).
  - Runs even if `classifiedAt` is set (Reclassify semantics).
  - Throws if no transcript file exists on disk.

`Pipeline.classifierThreshold()` already exists; reuse it. Add a parallel
`autoClassifyEnabled()` helper to keep the read in one place.

## Helper changes

`TapedeckSyncHelper/main.swift` learns two flags before falling through to the
default `runCycle()` path:

- `--classify-pending`
  - Acquires `SyncLock`, builds the same `Pipeline` deps as `runCycle()`,
    calls `pipeline.classifyPending()`.
  - Posts `AppStateNotifier` so the UI refreshes.
  - Exits 0 on success; uses existing exit codes for token / key failures.
- `--classify-source <sourceId>`
  - Same lock + deps setup.
  - Calls `pipeline.classifyOne(sourceId:)`.
  - Exits 0 on success, 1 on failure (transcript missing, Gemini error,
    unknown id).

Both subcommands reuse `SyncLock` so they cannot race with a regular sync
cycle.

## UI changes

### `Tapedeck/SyncCoordinator.swift`

Add:

- `classifyPending(reason:) async throws -> Int32` — spawns helper with
  `--classify-pending`.
- `classifyOne(sourceId:reason:) async throws -> Int32` — spawns helper with
  `--classify-source <id>`.

Both use the same `inflight` single-flight gate as `runOnce(reason:)` so the
user cannot double-fire.

### `Tapedeck/TapedeckApp.swift` toolbar

New "Classify" button next to "Sync now":

- Disabled when `appState.statusCounts.toClassify == 0`.
- Shows a `ProgressView` + "Classifying…" while in flight (separate
  `@State isClassifying` from `isSyncing`).
- Tooltip shows the pending count.

### `Tapedeck/Views/DetailPane.swift`

A button on the selected recording:

- Label: `"Classify"` if `recording.classifiedAt == nil`, else `"Reclassify"`.
- Disabled while classification is in flight, or if `recording.transcribedAt`
  is nil.
- Calls `SyncCoordinator.shared.classifyOne(sourceId:reason:)` then
  `appState.refresh()`.

### `Tapedeck/Views/Settings/ClassifierTab.swift`

New toggle: "Classify new recordings automatically", bound to
`app_state.auto_classify`. Off by default. Help text explains that toggling on
restores the pre-change behaviour of classifying as part of each sync.

## Testing

Following TDD, write the failing test first for each change.

### `PipelineClassifyTests` (new file, or extend `PipelineEndToEndTests`)

- `runCycle_doesNotClassify_whenAutoClassifyAbsent` — set up a recording with
  a transcript and active project, run `runCycle()`, assert no classification
  decision was written.
- `runCycle_classifies_whenAutoClassifyTrue` — same setup, with
  `auto_classify = "true"`, assert decision is written. (This is the existing
  end-to-end behaviour, just reframed.)
- `classifyPending_runs_regardlessOfAutoClassify` — `auto_classify` absent or
  `"false"`, call `classifyPending()` directly, assert decision written.
- `classifyOne_reclassifies_whenAlreadyClassified` — recording with
  `classifiedAt` set, call `classifyOne(sourceId:)`, assert decision and
  `classifiedAt` updated.
- `classifyOne_ignoresFailureGate` — recording with a `.classify` error at
  attempt = maxFailuresPerStage, assert `classifyOne` still runs.
- `classifyOne_throws_whenTranscriptMissing` — recording without a transcript
  file, assert specific error.

### Existing tests

`StatusCountsTests` requires no change — `toClassify` already counts
transcribed-but-unclassified recordings, which is exactly what we surface in
the bulk button.

`PipelineEndToEndTests` cases that currently rely on classification happening
during `runCycle()` are updated to set `auto_classify = "true"` in their
fixture, making the dependency on the flag explicit.

### Helper subcommands

Not unit-tested. The helper is exercised end-to-end via the existing harness;
add a manual smoke check to confirm both flags work after implementation.

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
