# User-Triggered Transcription — Design

## Problem

Transcription currently runs unconditionally as part of `Pipeline.runCycle()`
(`TapedeckCore/Sources/TapedeckCore/Pipeline.swift:50`). Every downloaded
recording is sent to Deepgram on the next sync cycle, with no user control
over when or whether transcription happens. We want transcription to be a
user-triggered process by default, with auto-transcription available as an
opt-in. This mirrors the change already shipped for classification
(`docs/plans/2026-05-13-user-triggered-classification-design.md`); each
Deepgram call costs money and the user should decide when to spend.

## Behaviour change

`Pipeline.runCycle()` still calls `transcribeNew()`, but `transcribeNew()`
short-circuits unless a new `app_state.auto_transcribe` key is `"true"`.
Default is absent / `"false"`, so existing users stop seeing automatic
transcription on the next sync and opt in through Settings if they want it
back.

Two new user-triggered entry points cover the explicit cases:

- **Bulk**: a "Transcribe" toolbar button placed before "Classify" in
  pipeline order (Transcribe → Classify → Sync now). Transcribes every
  recording with downloaded audio but no transcript. User-triggered, so the
  `maxFailuresPerStage` skip gate is bypassed — clicking the button is
  itself the retry signal.
- **Per recording**: a "Transcribe" / "Retranscribe" button in `DetailPane`,
  placed between Play and Classify. Label switches based on whether
  `transcribedAt` is set; behaviour is identical (always runs, also bypasses
  the failure gate). Mirrors the existing Classify / Reclassify affordance.

Unlike classify, transcription does not produce new project assignments,
so the relink stage has nothing to compute. However, retranscribing an
already-linked recording leaves stale `.transcript.txt` / `.deepgram.json`
copies in the project folder (`PipelineRelink.swift:37-40` copies these
files at link time). The user-triggered transcribe paths therefore mark
linked recordings as `pendingRelink` and run a relink pass after
transcription, so the project-folder copies are refreshed. Unlinked
recordings (no prior `linkedProjectId`) skip the relink step — there is
nothing to refresh.

Classification is preserved across retranscribe. The user can hit Reclassify
separately if they want the decision rerun against the new transcript;
auto-clearing the classification would lose the project assignment for the
common "transcript had a transient error, classification was fine" case.

## Data model

No schema change. New key in the existing `app_state` table:

- `auto_transcribe` — `"true"` / `"false"`, default `"false"` when absent.

Read alongside `auto_classify` and `classifier_threshold` in `Pipeline`.

## Pipeline changes

### Error model

A new public error type nested under `Pipeline`, mirroring the existing
`Pipeline.ClassifyError` shape minus the projects case:

```swift
public enum TranscribeError: Error, Equatable {
    case unknownRecording(String)
    case audioMissing(URL)
    case providerFailed(String)
}
```

There is no `noActiveProjects` analogue — transcription has no dependency on
projects.

### `TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift`

Refactor so the core path is throwing and the batch path is the one that
swallows / records, matching the shape `PipelineClassify.swift` already has:

1. New private `performTranscribeOne(_ rec:) async throws` — the throwing
   core. Verifies the audio file exists and throws
   `TranscribeError.audioMissing(URL)` if absent (today the missing-file
   case is caught implicitly by Deepgram failing). Wraps Deepgram failure in
   `TranscribeError.providerFailed(message)`. On success, writes the
   `.deepgram.json` and `.transcript.txt` files, calls `setTranscribed`,
   clears the `.transcribe` error row, and — if `rec.linkedProjectId != nil`
   — calls a new `RecordingRepository.markPendingRelink(sourceId:)` so the
   subsequent relink pass refreshes the project-folder copies.
2. The existing private `transcribeOne(_ rec:)` becomes a thin wrapper:
   calls `performTranscribeOne`, catches all errors, records to
   `recording_errors`, returns. Behaviour unchanged for the batch path.
3. New public `transcribeOne(sourceId:) async throws` — looks up the
   recording via `RecordingRepository.find(sourceId:)`, bypasses
   `shouldSkipAfterFailures`, then calls `performTranscribeOne`. Throws
   `TranscribeError.unknownRecording` if the id isn't found. On any error
   from `performTranscribeOne`: records to `recording_errors` *and*
   rethrows so the helper can exit non-zero.
4. `transcribeNew()` reads `auto_transcribe` at the top. If not `"true"`,
   logs `transcribe_skipped_auto_disabled` and returns. Otherwise current
   behaviour.
5. New public `transcribePending() async` — runs the batch loop but without
   the `auto_transcribe` check **and** without the `shouldSkipAfterFailures`
   filter (user-triggered).

`Pipeline.swift`:

- Add a sibling to `autoClassifyEnabled()`:

  ```swift
  func autoTranscribeEnabled() throws -> Bool
  ```

  reads `app_state.auto_transcribe`, returns false when absent or
  non-`"true"`.

`RecordingRepository.swift`:

- Add a single new mutator:

  ```swift
  public func markPendingRelink(sourceId: String) throws
  ```

  Sets `project_link_state = 'pending_relink'` for the given row. Used by
  `performTranscribeOne` to schedule a relink refresh after retranscribing
  an already-linked recording.

## Helper changes

`TapedeckCore/Sources/TapedeckCore/HelperRunner.swift` gains two subcommand
cases mirroring the classify pair:

```swift
case transcribePending
case transcribeSource(String)
```

`parseHelperArguments` learns `--transcribe-pending` and
`--transcribe-source <id>`.

Subcommand semantics:

- `--transcribe-pending` → `.transcribePending`
  - Acquires `SyncLock` (same as `.fullCycle` and the classify pair). If
    already held, logs `transcribe_skipped_already_running` and exits 0.
  - Reads only what transcription actually uses: the Deepgram key from
    Keychain and the database. The source JWT and Gemini key are not
    required for this path. The existing `Pipeline.Deps` constructor takes
    all of `source` / `deepgram` / `gemini`, so the transcribe subcommands
    pass placeholder instances for the unused clients (constructed with
    empty-string tokens). They are never called in this path.
  - Calls `pipeline.transcribePending()` then `pipeline.relinkChanged()`.
    The relink pass is a no-op when no recordings were marked
    `pendingRelink`, so unlinked-only batches pay nothing for it.
  - Posts `notify("recordings")`. Exits 0 on success, 3 if the Deepgram key
    is missing, 1 on any other failure. **Does not** use exit codes 2 or 4 —
    those are reserved for the source-token paths in `.fullCycle`.
- `--transcribe-source <sourceId>` → `.transcribeSource(id)`
  - Same lock + deps setup, same Deepgram-only key requirement.
  - Calls `pipeline.transcribeOne(sourceId:)` then `pipeline.relinkChanged()`.
  - Exits 0 on success. On `TranscribeError` (or anything else thrown):
    exits 1. The error is already persisted to `recording_errors` by the
    pipeline, so the UI surfaces it via the existing error row.

A new `buildTranscribePipeline(deps:store:)` mirrors `buildClassifyPipeline`
— it requires only the Deepgram key and constructs placeholder source /
Gemini clients with empty-string tokens.

Both subcommands reuse `SyncLock` so they cannot race with a regular sync
cycle or a classify subcommand.

### `runFullCycle` conditional key requirements

Today `runFullCycle` exits 3 if either the Deepgram or Gemini key is
missing, regardless of whether those stages will run
(`HelperRunner.swift:84-88`). With both `auto_transcribe` and
`auto_classify` defaulting off, a user with only the source JWT configured
should still be able to sync — `listRemote` and `downloadNew` don't need
those keys, and the stages that do need them will short-circuit on the
`auto_*` gate.

Updated logic in `runFullCycle`:

```swift
let store = try deps.openStore(deps.layout.dbURL())
let needsDeepgram = (try? autoTranscribeEnabledRaw(store)) ?? false
let needsGemini   = (try? autoClassifyEnabledRaw(store))   ?? false

let deepgramKey = try deps.readSecret("tapedeck.deepgram.key", "default")
let geminiKey   = try deps.readSecret("tapedeck.gemini.key", "default")

if needsDeepgram && deepgramKey == nil {
    deps.logger.error("api_key_missing", source: nil,
                      message: "Deepgram key missing (auto_transcribe on)")
    return 3
}
if needsGemini && geminiKey == nil {
    deps.logger.error("api_key_missing", source: nil,
                      message: "Gemini key missing (auto_classify on)")
    return 3
}

let pipeline = Pipeline(deps: .init(
    store: store, layout: deps.layout,
    source: deps.makeSource(token),
    deepgram: deps.makeDeepgram(deepgramKey ?? ""),
    gemini:   deps.makeGemini(geminiKey ?? ""),
    logger: deps.logger, now: deps.now))
```

`autoTranscribeEnabledRaw` / `autoClassifyEnabledRaw` are file-private
helpers in `HelperRunner.swift` that read the `app_state` keys directly
(the Pipeline-instance methods aren't reachable before pipeline
construction). Placeholder empty-string clients are safe because the
`auto_*` gates inside the pipeline guarantee they're never called.

## UI changes

### `Tapedeck/SyncCoordinator.swift`

Add two `Kind` cases alongside the existing classify pair:

```swift
case transcribePending
case transcribeSource(String)
```

With matching `helperArgs`:

```swift
case .transcribePending: return ["--transcribe-pending"]
case .transcribeSource(let id): return ["--transcribe-source", id]
```

And two new actor methods that route through the existing
`dispatch(_:reason:)`:

```swift
func transcribePending(reason: String) async throws -> Int32
func transcribeOne(sourceId: String, reason: String) async throws -> Int32
```

No structural change to the coordinator — the per-kind single-flight gating
already handles "duplicate Transcribe click reuses the in-flight task" and
"Transcribe while Sync is running throws `otherOperationRunning`".

### `Tapedeck/AppState.swift`

Two thin wrappers mirroring `classifyPending` / `classifyOne`:

```swift
func transcribePending(reason: String) async {
    await dispatch(.transcribePending, reason: reason) {
        try await SyncCoordinator.shared.transcribePending(reason: reason)
    }
}

func transcribeOne(sourceId: String, reason: String) async {
    await dispatch(.transcribeSource(sourceId), reason: reason) {
        try await SyncCoordinator.shared.transcribeOne(sourceId: sourceId, reason: reason)
    }
}
```

`dispatch` flips `busy` for the duration and refreshes on completion. No
change to `dispatch` itself.

### `Tapedeck/TapedeckApp.swift` toolbar

New `ToolbarItem(placement: .primaryAction)` placed *before* the existing
Classify item, so the final toolbar order is Transcribe → Classify → Sync
now (status stays at `.status`):

- Shows `ProgressView` + "Transcribing…" when
  `appState.busy == .transcribePending`.
- Otherwise a "Transcribe" button.
- Disabled when `appState.busy != nil` or
  `appState.statusCounts.toTranscribe == 0`. No `projects.isEmpty` check —
  transcription does not depend on projects.
- Tooltip: "`N` recording[s] to transcribe".
- Action: `await appState.transcribePending(reason: "ui_transcribe_pending")`.

### `Tapedeck/Views/DetailPane.swift`

A button in the existing `HStack` between Play and Classify:

- Label: `"Transcribe"` if `recording.transcribedAt == nil`, else
  `"Retranscribe"`.
- Disabled while `appState.busy != nil` or
  `recording.audioDownloadedAt == nil` (no audio to transcribe). No
  projects check.
- Action: `await appState.transcribeOne(sourceId: recording.sourceId,
  reason: "ui_transcribe_one")`. Existing error-row UI handles failure
  display.

`DetailPane` currently calls `loadTranscript` only on `.onAppear` and
`.onChange(of: rec.sourceId)` (`DetailPane.swift:71-72`), so a successful
Retranscribe of the currently-selected recording would leave the text
editor showing the old transcript. Add:

```swift
.onChange(of: rec.transcribedAt) { _, _ in loadTranscript(rec) }
```

so the visible text refreshes after the helper writes the new
`.transcript.txt`. The `AppState.refresh()` triggered by `dispatch`'s
deferred refresh already updates `rec.transcribedAt` in place because
`recordings` is fetched fresh from the store.

### `Tapedeck/Views/Settings/TranscriptionTab.swift`

New toggle section mirroring the auto-classify toggle on `ClassifierTab`:

```swift
Section {
    Toggle("Transcribe new recordings automatically", isOn: $autoTranscribe)
} footer: {
    Text("When off, recordings wait until you click Transcribe in the toolbar or on a recording. Each call to Deepgram costs money.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

`readAutoTranscribe()` / `writeAutoTranscribe(_:)` helpers on the tab read
and write `app_state.auto_transcribe` directly, matching the
`readAutoClassify` / `writeAutoClassify` pattern on `ClassifierTab`.

## Testing

Following TDD, write the failing test first for each change.

### `PipelineTranscribeTests` (new)

- `runCycle_doesNotTranscribe_whenAutoTranscribeAbsent` — recording with
  downloaded audio and no transcript, run `runCycle()`, assert no
  `transcribed_at` written and `transcribe_skipped_auto_disabled` logged.
- `runCycle_transcribes_whenAutoTranscribeTrue` — same setup with
  `auto_transcribe = "true"`, assert transcript written.
- `transcribePending_runs_regardlessOfAutoTranscribe` — flag absent, call
  `transcribePending()` directly, assert transcript written.
- `transcribePending_bypassesFailureGate` — recording with a `.transcribe`
  error at attempt = `maxFailuresPerStage`, assert it still transcribes.
- `transcribeOne_retranscribes_whenAlreadyTranscribed` — `transcribedAt`
  set, call `transcribeOne(sourceId:)`, assert transcript rewritten and
  `transcribedAt` updated.
- `transcribeOne_ignoresFailureGate` — single-recording analogue of the
  bulk case.
- `transcribeOne_throwsAndRecordsError_whenAudioMissing` — no audio file on
  disk, assert `TranscribeError.audioMissing` is thrown *and* a
  `recording_errors` row was written.
- `transcribeOne_throws_whenSourceIdUnknown` — call with a non-existent
  id, assert `TranscribeError.unknownRecording`.
- `transcribeOne_throwsAndRecordsError_onProviderFailure` — Deepgram stub
  throws, assert `TranscribeError.providerFailed` propagates and the error
  row is written.
- `transcribeOne_marksPendingRelink_whenAlreadyLinked` — recording with
  `linkedProjectId` set and `linkState = .linked`, call
  `transcribeOne(sourceId:)`, assert the row ends with
  `linkState = .pendingRelink`.
- `transcribeOne_leavesLinkStateUnchanged_whenNotLinked` — recording with
  no `linkedProjectId`, call `transcribeOne`, assert `linkState` stays
  `.none`.

### `RecordingRepositoryTests`

- `markPendingRelink_setsLinkState` — write a row with
  `linkState = .linked`, call `markPendingRelink(sourceId:)`, read back and
  assert `linkState = .pendingRelink`.

### Existing tests

`StatusCountsTests` requires no change — `toTranscribe` already counts
downloaded-but-untranscribed recordings.

`PipelineEndToEndTests` cases that currently rely on transcription
happening during `runCycle()` are updated to set `auto_transcribe = "true"`
in their fixture so the dependency on the flag is explicit. (Same shape as
the `auto_classify` update those tests already received.)

### Helper subcommand tests

Add to `HelperRunnerTests`:

- `runHelper(.transcribePending)` exits 0 in the success path and calls
  into the pipeline's transcribe method (verified via the in-memory Store).
- `runHelper(.transcribePending)` exits 3 when the Deepgram key is missing.
- `runHelper(.transcribeSource(id))` exits 1 when `TranscribeError` is
  thrown and 0 on success.
- `runHelper(.transcribeSource("unknown"))` exits 1 with
  `TranscribeError.unknownRecording`.
- `runHelper(.transcribeSource(id))` for a linked recording refreshes the
  project-folder `.transcript.txt` copy — assert the on-disk file in the
  project directory matches the new transcript text after the call.
- Argument parsing: `["--transcribe-pending"]` → `.transcribePending`;
  `["--transcribe-source", id]` → `.transcribeSource(id)`;
  `["--transcribe-source"]` (no id) → falls through to `.fullCycle`,
  matching the existing classify-arg behaviour.

Coverage for the relaxed key requirements in `runFullCycle`:

- `runHelper(.fullCycle)_succeeds_withoutDeepgram_whenAutoTranscribeOff` —
  Deepgram key absent, `auto_transcribe = "false"` (or absent),
  `auto_classify = "false"`; assert exit 0 and that the source list /
  download stages still ran (verify via in-memory Store).
- `runHelper(.fullCycle)_exitsThree_whenAutoTranscribeOnButDeepgramMissing` —
  Deepgram key absent, `auto_transcribe = "true"`; assert exit 3 and the
  `Deepgram key missing (auto_transcribe on)` log line.
- `runHelper(.fullCycle)_exitsThree_whenAutoClassifyOnButGeminiMissing` —
  symmetric case for Gemini.

### `SyncCoordinatorTests`

Add one case mirroring the classify gating test:

- `transcribePending(reason:)` while `runOnce` is in flight throws
  `CoordinatorError.otherOperationRunning(.sync)`.

## Migration

No schema migration. Existing users get `auto_transcribe` absent → treated
as `"false"` → transcription stops happening automatically on the next
sync. The Settings toggle re-enables it.

This is a behaviour flip that affects existing users. It matches the
explicit pattern set by the classify rollout (off by default, user opts in
via Settings), chosen for cost-awareness — each Deepgram call has a real
unit price.

## Out of scope (YAGNI)

- A "Cancel running transcription" affordance. The helper finishes its
  current batch on its own; mid-flight cancellation is fiddly and not
  requested.
- Bulk transcribe scoped to a single project / date range.
- Right-click context menu on rows in `RecordingList`. The DetailPane
  button covers the per-recording case.
- Surfacing per-recording transcribe errors in a banner. The existing
  `recording_errors` row is already shown in the list and detail pane.
- Combining the toolbar Transcribe + Classify + Sync into a single Run
  menu or split-button. Three primary-action buttons is fine for now;
  SwiftUI's toolbar collapses overflow into a chevron automatically when
  the window is narrow.
