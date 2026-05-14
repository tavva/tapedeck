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
    project_id  TEXT REFERENCES projects(id),
    used_at     INTEGER NOT NULL,
    PRIMARY KEY (name, source_id)
);
CREATE INDEX speaker_usage_project ON speaker_usage(project_id);
```

`(name, source_id)` as the primary key means one row per name per
recording — re-renaming a speaker in the same recording updates which
name is recorded, not the count.

The known-speakers pool is derived from `SELECT DISTINCT name FROM
speaker_usage`. Labels matching the Deepgram default pattern `speaker N`
are excluded from the dropdown and never inserted, so unrenamed defaults
don't pollute suggestions.

Dropdown ranking is a single query, parametrised on the recording's
project id:

```sql
SELECT name,
       SUM(CASE WHEN project_id = :p THEN 1 ELSE 0 END) AS in_project,
       COUNT(*) AS total
FROM speaker_usage
WHERE name NOT LIKE 'speaker %'
GROUP BY name
ORDER BY in_project DESC, total DESC, name ASC;
```

Project speakers come first (by their in-project frequency), then the
rest by global frequency, with alphabetical as the final tiebreak. When
the recording has no project, `in_project` is zero for every row and the
ranking collapses to pure global frequency.

## Components

### `SpeakerRepository` (`TapedeckCore`)

```swift
public struct SpeakerRepository: Sendable {
    public init(store: Store)
    public func knownSpeakers(for projectId: String?) throws -> [String]
    public func recordRename(sourceId: String, projectId: String?,
                             removed: [String], added: [String]) throws
    public func clearUsage(sourceId: String) throws
}
```

`recordRename` runs the delete + upsert pair in a single transaction.
`clearUsage` is called when a recording is retranscribed, so the DB
doesn't claim names are still in use after the file is rewritten with
fresh `[speaker N]` labels.

### `TranscriptLabels` (`TapedeckCore`)

A new file with two pure functions:

```swift
public func parseLabels(_ transcript: String) -> [String]
public func renameLabel(_ transcript: String,
                        from old: String, to new: String) -> String
```

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

```
┌─ Speakers ───────────────────────────────────┐
│  [speaker 0]   →  [ Ben          ▼ ]   Apply │
│  [speaker 1]   →  [              ▼ ]   Apply │
│  [Alice]       →  [ Alice        ▼ ]         │
└──────────────────────────────────────────────┘
```

One row per label found by `parseLabels`. Each row has an editable combo
populated from `SpeakerRepository.knownSpeakers(for: rec.projectId)`.
Project speakers appear at the top of the popover, then a divider, then
the rest. Typing filters the popover by case-insensitive prefix match.
The free-text value is always accepted, even if not in the list — that
is how new names enter the pool.

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
4. **Update DB**: call
   `recordRename(sourceId:, projectId:, removed: [old], added: [new])`.
   Skip the insert if `new` matches `speaker N`.
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
- Names matching `speaker N` (where N is digits) are allowed in the file
  but never added to `speaker_usage`, so they don't appear in the
  dropdown.

## Testing

Unit tests in `TapedeckCoreTests`:

- `TranscriptLabelsTests`
  - `parseLabels` returns unique labels in first-occurrence order.
  - `parseLabels` ignores `[bracketed]` text mid-paragraph.
  - `renameLabel` rewrites only paragraph-leading labels.
  - `renameLabel` is a no-op when `old` is not present.
  - `renameLabel` correctly merges when `new` already exists (resulting
    file has both old's and new's paragraphs under `[new]`).
- `SpeakerRepositoryTests`
  - `recordRename` inserts on first use, replaces on second use for the
    same `(name, source_id)`.
  - `knownSpeakers(for: projectId)` ranks project speakers ahead of
    non-project speakers.
  - `knownSpeakers` excludes `speaker N` labels.
  - `clearUsage` removes all rows for a given source_id.

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
