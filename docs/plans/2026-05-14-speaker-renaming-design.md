# Speaker Renaming — Design

## Problem

Deepgram transcripts return diarised paragraphs labelled `[speaker 0]`,
`[speaker 1]`, etc. (`TapedeckCore/Sources/TapedeckCore/DeepgramClient.swift:64`).
These numeric labels are not useful downstream — the user works with
transcripts outside Tapedeck and wants real names in the file. Today the
only way to substitute names is to hand-edit the `.transcript.txt` file
outside the app.

We want a way to mass-replace each speaker label inside Tapedeck. When
renaming, the user should be able to type a new name freely or pick from
a list of speakers already used elsewhere, with speakers from the current
recording's project ranked first.

## Behaviour change

The transcript file stays the canonical source of truth for names: a
rename rewrites `[speaker 0]` directly to `[Ben]` inside
`<stem>.transcript.txt`. Tapedeck stores no `(source_id, speaker_index) →
name` mapping — when the file is the artefact users consume, putting the
names in the file is the simplest design and survives any tool that reads
the file directly.

A new "Speakers" panel sits above the transcript editor in `DetailPane`.
It lists every unique label found in the current transcript, each with an
editable combo box (free-text plus a dropdown of known speaker names).
Applying a rename rewrites the file, then refreshes the editor.

The database gains a small `speaker_usage` table to power the dropdown.
Each row records "name X is currently in use in recording S, which
belongs to project P". The dropdown's ranking query floats names used in
the current project to the top, then ranks the rest by overall
frequency.

## Data model

A new migration `v2_speakers` adds one table:

```sql
CREATE TABLE speaker_usage (
    name        TEXT NOT NULL,
    source_id   TEXT NOT NULL REFERENCES recordings(source_id),
    used_at     INTEGER NOT NULL,
    PRIMARY KEY (name, source_id)
);
CREATE INDEX speaker_usage_source ON speaker_usage(source_id);
```

`(name, source_id)` as the primary key means one row per name per
recording — re-renaming a speaker in the same recording updates which
name is recorded, not the count.

`project_id` is deliberately *not* stored on `speaker_usage`. A
recording's project assignment is mutable
(`RecordingRepository.setClassification` at
`TapedeckCore/Sources/TapedeckCore/RecordingRepository.swift:85`, and
the user override in `DetailPane.swift:33`), so a cached `project_id`
would go stale. The ranking query joins `recordings` to read the
current project every time.

The same migration bumps the schema version. `TapedeckCore.schemaVersion`
goes from `1` to `2` (`TapedeckCore/Sources/TapedeckCore/TapedeckCore.swift:5`),
the assertion in `SmokeTests.schemaVersionIsExposed` is updated to
match, and the migration runs an explicit
`UPDATE app_state SET value = '2' WHERE key = 'schema_version'` so
databases created under v1 reach `schema_version = 2` (the v1 INSERT
only fires for fresh DBs).

The known-speakers pool is derived from `SELECT DISTINCT name FROM
speaker_usage`. Labels matching the Deepgram default pattern (exactly
`speaker N` where N is one or more digits) are excluded from the
dropdown and never inserted. A single helper —
`TranscriptLabels.isDefaultLabel(_:) -> Bool` — owns this rule and is
used everywhere the check matters (insert-skipping, ranking filter,
tests). SQLite's `LIKE 'speaker %'` would mis-match strings like
`speaker coach`, so the filter is applied in Swift after fetching
candidates rather than in SQL.

Dropdown ranking is a single query, parametrised on the recording's
current project id (read from the `Recording` struct at the call site):

```sql
SELECT u.name,
       SUM(CASE WHEN r.project_id = :p THEN 1 ELSE 0 END) AS in_project,
       COUNT(*) AS total
FROM speaker_usage u
JOIN recordings r ON r.source_id = u.source_id
GROUP BY u.name
ORDER BY in_project DESC, total DESC, u.name ASC;
```

The result list is then filtered through `isDefaultLabel` in Swift to
drop `speaker N` entries. Project speakers come first (by their
in-project frequency), then the rest by global frequency, with
alphabetical as the final tiebreak. When the recording has no project,
`in_project` is zero for every row and the ranking collapses to pure
global frequency.

## Components

### `SpeakerRepository` (`TapedeckCore`)

```swift
public struct KnownSpeaker: Sendable, Equatable {
    public let name: String
    public let inCurrentProject: Bool
}

public struct SpeakerRepository: Sendable {
    public init(store: Store)
    public func knownSpeakers(for projectId: String?) throws -> [KnownSpeaker]
    public func syncUsage(sourceId: String, labels: [String]) throws
    public func clearUsage(sourceId: String) throws
    public func reconcileAll(from transcripts: [(sourceId: String,
                                                  text: String)]) throws
}
```

`knownSpeakers` returns `KnownSpeaker` values, ordered by the existing
ranking rules (project speakers first, then global frequency, then
alphabetical). `inCurrentProject` lets the UI render the divider
between project and non-project speakers without re-running the query.

`syncUsage` replaces all `speaker_usage` rows for a given `sourceId`
with the supplied label list (default labels filtered out via
`isDefaultLabel`). It is called every time `SpeakerEditor` loads or
applies an edit, which keeps the DB in sync with the transcript file as
the canonical source — covering pre-existing files renamed by hand
outside the app, external edits, and any future file-write/DB-update
split failure. `syncUsage` is also the rename code path: after the file
is rewritten, the new label set is reparsed and passed in. A dedicated
`recordRename` entry point is intentionally omitted because the post-
rewrite `syncUsage` call covers it; ranking joins `recordings` for the
current `project_id`, so no per-row project value needs setting at
rename time.

`clearUsage` is called when a recording is retranscribed, so the DB
doesn't claim names are still in use after the file is rewritten with
fresh `[speaker N]` labels. (Equivalent to `syncUsage` with an empty
label list, kept as a named entry point because the call sites are
intent-different.)

`reconcileAll` ingests every existing transcript and rebuilds
`speaker_usage` rows to match. It is called once per app launch from
`AppState` startup (after `Store` opens and recordings load) so that
hand-edited names in transcripts the user has never opened in the new
UI still appear in the dropdown the first time `SpeakerEditor` opens
for any recording.

`AppState` owns the file I/O: it walks every recording with
`transcribedAt != nil`, reads the `.transcript.txt`, and passes the
`(sourceId, text)` tuples in. `SpeakerRepository` is responsible only
for rebuilding rows. To keep the work atomic without nested
transactions, `syncUsage` and `reconcileAll` share a private
DB-level helper (taking an open `Database` handle and one source's
labels). The public `syncUsage` opens a single-statement transaction
around the helper; `reconcileAll` opens one transaction and invokes the
helper for every recording inside it. Cost is one small file read per
existing transcript at startup; expected scale is hundreds, not
millions.

### `TranscriptLabels` (`TapedeckCore`)

A new file with three pure functions:

```swift
public func parseLabels(_ transcript: String) -> [String]
public func renameLabel(_ transcript: String,
                        from old: String, to new: String) -> String
public func isDefaultLabel(_ name: String) -> Bool
```

`isDefaultLabel` returns `true` iff the input matches `^speaker [0-9]+$`
exactly — the format `renderTranscript` produces. It is the single
source of truth for "is this a Deepgram default label", consumed by
`SpeakerRepository.syncUsage`, the dropdown filter, the merge-check
flow, and tests.

`parseLabels` returns labels in first-occurrence order, deduped. It
matches `^\[([^\]\n]+)\]` at the start of each paragraph (paragraphs are
separated by blank lines, matching how `renderTranscript` writes them).

`renameLabel` splits on `\n\n`, rewrites the leading `[old]` token on any
paragraph that starts with it, and rejoins. Critically it is *not* a
global string replace — body text that happens to contain `[Ben]` is
left alone.

### `SpeakerEditor` view (`Tapedeck/Views/`)

A SwiftUI view embedded in `DetailPane`, between the action buttons and
the transcript `TextEditor`. Hidden when the transcript is empty.

On appear (and whenever the loaded transcript changes), `SpeakerEditor`
calls `SpeakerRepository.syncUsage(sourceId:, labels: parseLabels(text))`
so the DB is brought into line with the current file before the
dropdown is populated. This is the reconciliation path for existing
recordings whose transcripts may have been edited outside the app.

```
┌─ Speakers ───────────────────────────────────┐
│  [speaker 0]   →  [ Ben          ▼ ]   Apply │
│  [speaker 1]   →  [              ▼ ]   Apply │
│  [Alice]       →  [ Alice        ▼ ]         │
└──────────────────────────────────────────────┘
```

One row per label found by `parseLabels`. Each row has an editable combo
populated from `SpeakerRepository.knownSpeakers(for: rec.projectId)`.
Entries where `inCurrentProject` is `true` appear at the top of the
popover, then a divider, then the rest. Typing filters the popover by
case-insensitive prefix match. The free-text value is always accepted,
even if not in the list — that is how new names enter the pool.

Apply is disabled when the input equals the current label or fails
validation. Pressing Return on the field is equivalent to clicking
Apply.

## Rename flow

On Apply for row "rename `[old]` to `[new]`":

1. **Validate**: trim `new`. Reject empty, or any string containing `[`,
   `]`, or newlines. Surface a brief inline error and abort.
2. **Merge check**: if `new` already appears as a label elsewhere in
   the current transcript (via `parseLabels`), show a confirmation alert:
   *"\[new\] already exists in this transcript. Merge \[old\] into it?
   This cannot be undone without retranscribing."* Abort on cancel.
3. **Rewrite file**: compute the new transcript with `renameLabel`,
   write to `<path>.tmp`, then atomically replace via
   `FileManager.replaceItemAt`.
4. **Update DB**: re-parse the freshly written file with `parseLabels`
   and call `SpeakerRepository.syncUsage(sourceId:, labels:)` to align
   the DB with the file. This handles the rename, the merge case (one
   fewer label after rewrite), and any drift from prior external edits
   in one place. Default labels are filtered out inside `syncUsage`
   via `isDefaultLabel`.
5. **Refresh UI**: reload `transcriptText` from disk and re-parse labels.

## Retranscribe interaction

When `PipelineTranscribe` rewrites the `.transcript.txt` for a recording,
all custom speaker labels in that file are replaced with fresh `[speaker
N]` defaults. The DB needs to forget the old usage rows for that
recording so the dropdown doesn't keep ranking those names as "still in
use".

`Pipeline.transcribeNew` and the per-recording `transcribeOne` entry
points call `SpeakerRepository.clearUsage(sourceId:)` after a successful
retranscribe (only when the file already existed before — first-time
transcription has no rows to clear, but `clearUsage` is a no-op there
anyway).

## Validation

- Name must be non-empty after trimming.
- Name must not contain `[`, `]`, or newline characters — these would
  break the paragraph-anchored label parser.
- Names where `TranscriptLabels.isDefaultLabel(_:)` returns `true`
  (exact match against `^speaker [0-9]+$`) are allowed in the file but
  never inserted into `speaker_usage`, so they don't appear in the
  dropdown. Other strings beginning with `speaker ` (e.g.
  `speaker coach`) are treated as normal names.

## Testing

Unit tests in `TapedeckCoreTests`:

- `TranscriptLabelsTests`
  - `parseLabels` returns unique labels in first-occurrence order.
  - `parseLabels` ignores `[bracketed]` text mid-paragraph.
  - `renameLabel` rewrites only paragraph-leading labels.
  - `renameLabel` is a no-op when `old` is not present.
  - `renameLabel` correctly merges when `new` already exists (resulting
    file has both old's and new's paragraphs under `[new]`).
  - `isDefaultLabel` is `true` for `speaker 0`, `speaker 12`; `false`
    for `speaker coach`, ` speaker 0`, `speaker 0x`, `Speaker 0`.
- `SpeakerRepositoryTests`
  - `recordRename` inserts on first use, replaces on second use for the
    same `(name, source_id)`.
  - `syncUsage` replaces all rows for a `sourceId` with the supplied
    labels; default labels are filtered out.
  - `knownSpeakers(for: projectId)` ranks project speakers ahead of
    non-project speakers and sets `inCurrentProject` accordingly, using
    the recording's *current* project_id (test: rename a speaker, change
    the recording's project via `RecordingRepository.setClassification`,
    confirm the ranking reflects the new project).
  - `knownSpeakers` excludes `speaker N` labels (and only those — a
    custom name `speaker coach` is preserved).
  - `clearUsage` removes all rows for a given source_id.
  - `reconcileAll` populates rows for transcripts that have never been
    opened in the speaker editor: seed two recordings A and B with
    transcript files containing different custom names, call
    `reconcileAll`, then `knownSpeakers(for: A.projectId)` should
    include B's name even though `syncUsage` was never called on B.
- `StoreOpenTests`
  - Updated assertion that `schema_version == 2` after migration.
  - New test that a v1-era DB (with `app_state.schema_version = '1'`)
    is updated to `'2'` after running migrations.
- `SmokeTests`
  - `schemaVersionIsExposed` updated to expect `2`.

UI is exercised manually — the project has no UI test harness today.

## Out of scope

- Per-paragraph re-assignment ("this paragraph was actually speaker 1,
  not speaker 0"). Diarisation errors require an inline edit, not a
  mass rename. Tracked separately if needed.
- Cross-recording bulk rename ("rename Ben to Benjamin everywhere").
  Achievable by retranscribing or by editing each file individually for
  now.
- Explicit speakers-table management UI (renaming or deleting entries
  in the pool). The pool is derived; entries become irrelevant once no
  recording uses them.
