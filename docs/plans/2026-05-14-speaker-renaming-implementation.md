# Speaker Renaming Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let users mass-replace `[speaker 0]` / `[speaker 1]` labels in Deepgram transcripts with real names from a project-aware known-speakers dropdown.

**Architecture:** Transcript file is the canonical store of names. New `speaker_usage` table powers a ranked dropdown via a join against `recordings` (project assignment is mutable). A `SpeakerEditor` view sits above the transcript in `DetailPane` and rewrites the `.transcript.txt` file atomically per rename. An `AppState` startup hook reconciles the table against existing transcripts so hand-edited names surface in the dropdown.

**Tech Stack:** Swift 6.0, SwiftUI, GRDB.swift, Swift Testing (`@Suite` / `@Test`), Swift Package Manager (TapedeckCore), Xcode project (Tapedeck app).

**Design doc:** `docs/plans/2026-05-14-speaker-renaming-design.md`

**Commands:**
- Run TapedeckCore tests: `cd TapedeckCore && swift test`
- Run a single test suite: `cd TapedeckCore && swift test --filter "<SuiteName>"`
- Build the macOS app: `./scripts/build-local.sh` (regenerates `Tapedeck.xcodeproj` via `xcodegen` and ad-hoc-signs the bundle — the Xcode project is not checked in)

Every build step in this plan uses `./scripts/build-local.sh`. Do not invoke `xcodebuild` directly: without the regenerated `.xcodeproj` it will fail with "project file not found".

---

## Task 1: Bump schema version to 2 with v2_speakers migration

Adds the `speaker_usage` table, bumps `TapedeckCore.schemaVersion`, and ensures the `app_state.schema_version` row is updated on existing DBs.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/TapedeckCore.swift`
- Modify: `TapedeckCore/Sources/TapedeckCore/Store.swift` (append migration to the migrator block)
- Modify: `TapedeckCore/Tests/TapedeckCoreTests/SmokeTests.swift:10`
- Modify: `TapedeckCore/Tests/TapedeckCoreTests/StoreOpenTests.swift`

**Step 1: Update the existing schema-version assertions to expect 2**

Edit `SmokeTests.swift:10` from `#expect(TapedeckCore.schemaVersion == 1)` to `#expect(TapedeckCore.schemaVersion == 2)`.

Add two new tests to `StoreOpenTests.swift` (preserves the existing `opensInMemoryAndRunsMigrations`):

```swift
@Test func speakerUsageTableExists() throws {
    let store = try Store.openInMemory()
    let count = try store.read { db in
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name = 'speaker_usage'
        """)
    }
    #expect(count == 1)
}

@Test func v1DatabaseUpgradesToV2() throws {
    let queue = try DatabaseQueue()
    try Store.migrator.migrate(queue, upTo: "v1_initial")
    // Force the DB into the historical v1 shape by overwriting the version row
    // with the legacy value, the way an existing on-disk file from before this
    // change would look.
    try queue.write { db in
        try db.execute(sql: "UPDATE app_state SET value = '1' WHERE key = 'schema_version'")
    }

    try Store.migrator.migrate(queue)

    let version = try queue.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'schema_version'")
    }
    let tableCount = try queue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name = 'speaker_usage'
        """)
    }
    #expect(version == "2")
    #expect(tableCount == 1)
}
```

`Store.migrator` is declared `nonisolated(unsafe) static` in `Store.swift:36` so it's reachable from tests via `@testable import TapedeckCore`. If `migrate(upTo:)` is unavailable on the bundled GRDB version, fall back to running raw v1 SQL inline (the schema is small — see `Store.swift:38`). The shape of the test stays the same.

**Step 2: Run tests to verify they fail**

```bash
cd TapedeckCore && swift test --filter "Smoke|Store open"
```

Expected: `schemaVersionIsExposed` fails (still returns 1), `speakerUsageTableExists` fails (table not created yet).

**Step 3: Bump the version constant**

Edit `TapedeckCore.swift`:

```swift
public enum TapedeckCore {
    public static let schemaVersion = 2
}
```

**Step 4: Add the migration**

Append to the `migrator` block in `Store.swift`, right after `registerMigration("v1_initial")`:

```swift
m.registerMigration("v2_speakers") { db in
    try db.execute(sql: """
        CREATE TABLE speaker_usage (
            name        TEXT NOT NULL,
            source_id   TEXT NOT NULL REFERENCES recordings(source_id),
            used_at     INTEGER NOT NULL,
            PRIMARY KEY (name, source_id)
        );

        CREATE INDEX speaker_usage_source ON speaker_usage(source_id);

        UPDATE app_state SET value = '\(TapedeckCore.schemaVersion)'
        WHERE key = 'schema_version';
    """)
}
```

The `UPDATE` covers v1 databases that were created before the new INSERT format. Fresh v2 databases will run both migrations sequentially: the v1 INSERT writes `'2'` directly (since the SQL interpolates the current `schemaVersion`), then the v2 UPDATE is a no-op.

**Step 5: Run tests to verify they pass**

```bash
cd TapedeckCore && swift test --filter "Smoke|Store open"
```

Expected: all three tests pass (`schemaVersionIsExposed`, `speakerUsageTableExists`, `v1DatabaseUpgradesToV2`).

**Step 6: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/TapedeckCore.swift \
        TapedeckCore/Sources/TapedeckCore/Store.swift \
        TapedeckCore/Tests/TapedeckCoreTests/SmokeTests.swift \
        TapedeckCore/Tests/TapedeckCoreTests/StoreOpenTests.swift
git commit -m "feat(store): v2 migration adds speaker_usage table"
```

---

## Task 2: Add TranscriptLabels.isDefaultLabel

The single source of truth for "is this label a Deepgram default like `speaker 0`". Required before `parseLabels` / `renameLabel` because filters reference it.

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/TranscriptLabels.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/TranscriptLabelsTests.swift`

**Step 1: Write the failing tests**

Create `TranscriptLabelsTests.swift`:

```swift
// ABOUTME: Tests for transcript speaker-label parsing and rewriting helpers.

import Testing
@testable import TapedeckCore

@Suite("TranscriptLabels")
struct TranscriptLabelsTests {
    @Test func isDefaultLabel_matchesSpeakerWithDigits() {
        #expect(isDefaultLabel("speaker 0"))
        #expect(isDefaultLabel("speaker 12"))
    }

    @Test func isDefaultLabel_rejectsOtherStrings() {
        #expect(!isDefaultLabel("speaker coach"))
        #expect(!isDefaultLabel("Speaker 0"))
        #expect(!isDefaultLabel(" speaker 0"))
        #expect(!isDefaultLabel("speaker 0x"))
        #expect(!isDefaultLabel("speaker"))
        #expect(!isDefaultLabel(""))
        #expect(!isDefaultLabel("Ben"))
    }
}
```

**Step 2: Run tests to verify they fail**

```bash
cd TapedeckCore && swift test --filter "TranscriptLabels"
```

Expected: compilation fails (`isDefaultLabel` not defined).

**Step 3: Create the file with the helper**

Create `TranscriptLabels.swift`:

```swift
// ABOUTME: Pure helpers for parsing and rewriting [speaker] labels in transcripts.
// ABOUTME: Used by SpeakerEditor (rename flow) and SpeakerRepository (filtering).

import Foundation

/// Returns true iff `name` matches Deepgram's default output format exactly:
/// `speaker` + single space + one or more digits, with nothing else.
public func isDefaultLabel(_ name: String) -> Bool {
    guard name.hasPrefix("speaker ") else { return false }
    let rest = name.dropFirst("speaker ".count)
    guard !rest.isEmpty else { return false }
    return rest.allSatisfy { $0.isASCII && $0.isNumber }
}
```

**Step 4: Run tests to verify they pass**

```bash
cd TapedeckCore && swift test --filter "TranscriptLabels"
```

Expected: 2 tests pass.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/TranscriptLabels.swift \
        TapedeckCore/Tests/TapedeckCoreTests/TranscriptLabelsTests.swift
git commit -m "feat(transcript): isDefaultLabel matches 'speaker N' exactly"
```

---

## Task 3: Add TranscriptLabels.parseLabels

Returns the unique labels found at the start of each paragraph, in first-occurrence order.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/TranscriptLabels.swift`
- Modify: `TapedeckCore/Tests/TapedeckCoreTests/TranscriptLabelsTests.swift`

**Step 1: Add the failing tests**

Append to `TranscriptLabelsTests.swift`:

```swift
    @Test func parseLabels_returnsUniqueInFirstOccurrenceOrder() {
        let txt = """
        [speaker 0] hello there

        [speaker 1] hi

        [speaker 0] how are you

        [Ben] good thanks
        """
        #expect(parseLabels(txt) == ["speaker 0", "speaker 1", "Ben"])
    }

    @Test func parseLabels_ignoresBracketsMidParagraph() {
        let txt = """
        [speaker 0] he said [hello] to me

        [Alice] and she said [goodbye]
        """
        #expect(parseLabels(txt) == ["speaker 0", "Alice"])
    }

    @Test func parseLabels_returnsEmptyForEmptyOrUnlabelled() {
        #expect(parseLabels("") == [])
        #expect(parseLabels("no labels here\n\njust text") == [])
    }
```

**Step 2: Run tests to verify they fail**

```bash
cd TapedeckCore && swift test --filter "TranscriptLabels"
```

Expected: compilation fails (`parseLabels` not defined).

**Step 3: Implement parseLabels**

Append to `TranscriptLabels.swift`:

```swift
/// Returns the unique speaker labels found at the start of each paragraph
/// (paragraphs separated by blank lines), in first-occurrence order.
/// A label is the text inside the leading `[...]` of a paragraph.
public func parseLabels(_ transcript: String) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for paragraph in transcript.components(separatedBy: "\n\n") {
        guard let label = leadingLabel(of: paragraph) else { continue }
        if seen.insert(label).inserted { ordered.append(label) }
    }
    return ordered
}

private func leadingLabel(of paragraph: String) -> String? {
    let trimmed = paragraph.drop(while: { $0 == " " || $0 == "\t" })
    guard trimmed.first == "[" else { return nil }
    let afterBracket = trimmed.dropFirst()
    guard let endIdx = afterBracket.firstIndex(of: "]") else { return nil }
    let label = String(afterBracket[..<endIdx])
    guard !label.isEmpty, !label.contains("\n") else { return nil }
    return label
}
```

**Step 4: Run tests to verify they pass**

```bash
cd TapedeckCore && swift test --filter "TranscriptLabels"
```

Expected: 5 tests pass.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/TranscriptLabels.swift \
        TapedeckCore/Tests/TapedeckCoreTests/TranscriptLabelsTests.swift
git commit -m "feat(transcript): parseLabels returns ordered unique speaker labels"
```

---

## Task 4: Add TranscriptLabels.renameLabel

Paragraph-anchored replace: rewrites only the leading `[old]` token on paragraphs that start with it. Body text containing `[old]` is left alone. Merging is allowed at this layer; the merge confirmation lives in the UI.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/TranscriptLabels.swift`
- Modify: `TapedeckCore/Tests/TapedeckCoreTests/TranscriptLabelsTests.swift`

**Step 1: Add the failing tests**

Append to `TranscriptLabelsTests.swift`:

```swift
    @Test func renameLabel_rewritesOnlyLeadingLabels() {
        let input = """
        [speaker 0] he said [speaker 0] earlier

        [speaker 1] noted
        """
        let expected = """
        [Ben] he said [speaker 0] earlier

        [speaker 1] noted
        """
        #expect(renameLabel(input, from: "speaker 0", to: "Ben") == expected)
    }

    @Test func renameLabel_isNoOpWhenOldNotPresent() {
        let txt = "[Alice] hello\n\n[Bob] hi"
        #expect(renameLabel(txt, from: "speaker 0", to: "Ben") == txt)
    }

    @Test func renameLabel_mergesIntoExistingLabel() {
        let input = """
        [speaker 0] alpha

        [Ben] beta

        [speaker 0] gamma
        """
        let expected = """
        [Ben] alpha

        [Ben] beta

        [Ben] gamma
        """
        #expect(renameLabel(input, from: "speaker 0", to: "Ben") == expected)
    }
```

**Step 2: Run tests to verify they fail**

```bash
cd TapedeckCore && swift test --filter "TranscriptLabels"
```

Expected: compilation fails (`renameLabel` not defined).

**Step 3: Implement renameLabel**

Append to `TranscriptLabels.swift`:

```swift
/// Rewrites every paragraph whose leading label is `old` so its label becomes
/// `new`. Splits on blank-line paragraph boundaries; the `[old]` token must
/// be the very first non-whitespace content of the paragraph to match.
public func renameLabel(_ transcript: String, from old: String, to new: String) -> String {
    let oldToken = "[\(old)]"
    let newToken = "[\(new)]"
    let paragraphs = transcript.components(separatedBy: "\n\n")
    let rewritten = paragraphs.map { paragraph -> String in
        guard leadingLabel(of: paragraph) == old else { return paragraph }
        let leadingWhitespace = paragraph.prefix(while: { $0 == " " || $0 == "\t" })
        let body = paragraph.dropFirst(leadingWhitespace.count).dropFirst(oldToken.count)
        return leadingWhitespace + newToken + body
    }
    return rewritten.joined(separator: "\n\n")
}
```

**Step 4: Run tests to verify they pass**

```bash
cd TapedeckCore && swift test --filter "TranscriptLabels"
```

Expected: 8 tests pass.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/TranscriptLabels.swift \
        TapedeckCore/Tests/TapedeckCoreTests/TranscriptLabelsTests.swift
git commit -m "feat(transcript): renameLabel rewrites paragraph-leading labels"
```

---

## Task 5: Create SpeakerRepository skeleton with KnownSpeaker struct

Empty repository plus the public `KnownSpeaker` value type. Subsequent tasks add the methods one by one against a real `Store.openInMemory()`.

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/SpeakerRepository.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/SpeakerRepositoryTests.swift`

**Step 1: Write the failing test**

Create `SpeakerRepositoryTests.swift`:

```swift
// ABOUTME: Exercises SpeakerRepository: usage upsert, ranking, reconcile.
// ABOUTME: Uses Store.openInMemory() and seeds recordings via RecordingRepository.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("SpeakerRepository")
struct SpeakerRepositoryTests {
    @Test func canConstructRepository() throws {
        let store = try Store.openInMemory()
        _ = SpeakerRepository(store: store)
    }
}
```

**Step 2: Run test to verify it fails**

```bash
cd TapedeckCore && swift test --filter "SpeakerRepository"
```

Expected: compilation fails (`SpeakerRepository` not defined).

**Step 3: Create the skeleton**

Create `SpeakerRepository.swift`:

```swift
// ABOUTME: SQL access for speaker_usage. Drives the rename-flow dropdown.
// ABOUTME: Holds no business logic — see SpeakerEditor for the rename flow.

import Foundation
import GRDB

public struct KnownSpeaker: Sendable, Equatable {
    public let name: String
    public let inCurrentProject: Bool

    public init(name: String, inCurrentProject: Bool) {
        self.name = name
        self.inCurrentProject = inCurrentProject
    }
}

public struct SpeakerRepository: Sendable {
    let store: Store

    public init(store: Store) { self.store = store }
}
```

**Step 4: Run test to verify it passes**

```bash
cd TapedeckCore && swift test --filter "SpeakerRepository"
```

Expected: 1 test passes.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/SpeakerRepository.swift \
        TapedeckCore/Tests/TapedeckCoreTests/SpeakerRepositoryTests.swift
git commit -m "feat(speakers): SpeakerRepository skeleton + KnownSpeaker struct"
```

---

## Task 6: Implement SpeakerRepository.syncUsage

Replaces all rows for a given `sourceId` with the supplied label set, filtering out default labels. Uses a private DB-level helper that will later be shared with `reconcileAll`.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/SpeakerRepository.swift`
- Modify: `TapedeckCore/Tests/TapedeckCoreTests/SpeakerRepositoryTests.swift`

**Step 1: Write the failing tests**

Append to `SpeakerRepositoryTests.swift`. A small helper inserts a recording so the foreign key is satisfied:

```swift
    @Test func syncUsage_replacesAllRowsForSource() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "S1")

        try repo.syncUsage(sourceId: "S1", labels: ["Alice", "Bob"])
        try repo.syncUsage(sourceId: "S1", labels: ["Alice", "Carol"])

        let names = try fetchNames(store: store, sourceId: "S1")
        #expect(names == ["Alice", "Carol"])
    }

    @Test func syncUsage_filtersOutDefaultLabels() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "S1")

        try repo.syncUsage(sourceId: "S1", labels: ["speaker 0", "Ben", "speaker 12"])

        let names = try fetchNames(store: store, sourceId: "S1")
        #expect(names == ["Ben"])
    }
}

private func insertProject(store: Store, projectId: String) throws {
    try store.write { db in
        try db.execute(sql: """
            INSERT OR IGNORE INTO projects(id, display_name, description, created_at)
            VALUES (?, ?, '', 0)
        """, arguments: [projectId, projectId])
    }
}

private func insertRecording(store: Store, sourceId: String, projectId: String? = nil) throws {
    if let pid = projectId { try insertProject(store: store, projectId: pid) }
    try store.write { db in
        try db.execute(sql: """
            INSERT INTO recordings(source_id, filename, started_at, duration_ms,
                                   filesize, project_link_state, last_seen_at, project_id)
            VALUES (?, 'test.ogg', 0, 0, 0, 'none', 0, ?)
        """, arguments: [sourceId, projectId])
    }
}

private func fetchNames(store: Store, sourceId: String) throws -> [String] {
    try store.read { db in
        try String.fetchAll(db, sql: """
            SELECT name FROM speaker_usage WHERE source_id = ? ORDER BY name
        """, arguments: [sourceId])
    }
}
```

Move the closing `}` of `SpeakerRepositoryTests` to before the helpers — Swift requires file-private helpers to live at file scope, not inside the struct.

**Step 2: Run tests to verify they fail**

```bash
cd TapedeckCore && swift test --filter "SpeakerRepository"
```

Expected: compilation fails (`syncUsage` not defined).

**Step 3: Implement syncUsage and the private helper**

Append to `SpeakerRepository.swift`:

```swift
    /// Replaces every `speaker_usage` row for `sourceId` with `labels`,
    /// filtering out default `speaker N` entries. Called on transcript load
    /// and after every rename so the DB tracks the file as canonical.
    public func syncUsage(sourceId: String, labels: [String]) throws {
        try store.write { db in
            try syncUsageInTx(db, sourceId: sourceId, labels: labels)
        }
    }

    /// Shared transaction body. `syncUsage` and `reconcileAll` both call this;
    /// the caller is responsible for owning the surrounding `store.write`.
    func syncUsageInTx(_ db: Database, sourceId: String, labels: [String]) throws {
        try db.execute(sql: "DELETE FROM speaker_usage WHERE source_id = ?",
                       arguments: [sourceId])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var inserted = Set<String>()
        for raw in labels {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isDefaultLabel(name) else { continue }
            guard inserted.insert(name).inserted else { continue }
            try db.execute(sql: """
                INSERT INTO speaker_usage(name, source_id, used_at) VALUES (?, ?, ?)
            """, arguments: [name, sourceId, now])
        }
    }
}
```

Add the closing `}` that the previous step left dangling.

**Step 4: Run tests to verify they pass**

```bash
cd TapedeckCore && swift test --filter "SpeakerRepository"
```

Expected: 3 tests pass.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/SpeakerRepository.swift \
        TapedeckCore/Tests/TapedeckCoreTests/SpeakerRepositoryTests.swift
git commit -m "feat(speakers): syncUsage replaces rows per source, drops defaults"
```

---

## Task 7: Implement SpeakerRepository.clearUsage

Removes all rows for a source. Called from the transcribe pipeline so re-transcribing forgets stale labels.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/SpeakerRepository.swift`
- Modify: `TapedeckCore/Tests/TapedeckCoreTests/SpeakerRepositoryTests.swift`

**Step 1: Write the failing test**

Insert before the file-scope helpers in `SpeakerRepositoryTests.swift`:

```swift
    @Test func clearUsage_removesAllRowsForSource() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "S1")
        try insertRecording(store: store, sourceId: "S2")
        try repo.syncUsage(sourceId: "S1", labels: ["Alice"])
        try repo.syncUsage(sourceId: "S2", labels: ["Bob"])

        try repo.clearUsage(sourceId: "S1")

        #expect(try fetchNames(store: store, sourceId: "S1") == [])
        #expect(try fetchNames(store: store, sourceId: "S2") == ["Bob"])
    }
```

**Step 2: Run test to verify it fails**

```bash
cd TapedeckCore && swift test --filter "SpeakerRepository"
```

Expected: compilation fails (`clearUsage` not defined).

**Step 3: Implement clearUsage**

Add inside the `SpeakerRepository` struct (next to `syncUsage`):

```swift
    /// Removes every `speaker_usage` row for `sourceId`. Called when a
    /// transcript is rewritten by re-transcription.
    public func clearUsage(sourceId: String) throws {
        try store.write { db in
            try db.execute(sql: "DELETE FROM speaker_usage WHERE source_id = ?",
                           arguments: [sourceId])
        }
    }
```

**Step 4: Run test to verify it passes**

```bash
cd TapedeckCore && swift test --filter "SpeakerRepository"
```

Expected: 4 tests pass.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/SpeakerRepository.swift \
        TapedeckCore/Tests/TapedeckCoreTests/SpeakerRepositoryTests.swift
git commit -m "feat(speakers): clearUsage drops rows for a source"
```

---

## Task 8: Implement SpeakerRepository.knownSpeakers

Returns names ranked project-first, then global frequency, then alphabetical. Joins `recordings` so the project value is always current.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/SpeakerRepository.swift`
- Modify: `TapedeckCore/Tests/TapedeckCoreTests/SpeakerRepositoryTests.swift`

**Step 1: Write the failing tests**

Insert before the file-scope helpers in `SpeakerRepositoryTests.swift`:

```swift
    @Test func knownSpeakers_ranksProjectFirstThenFrequency() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "A", projectId: "P1")
        try insertRecording(store: store, sourceId: "B", projectId: "P2")
        try insertRecording(store: store, sourceId: "C", projectId: "P2")
        try insertRecording(store: store, sourceId: "D", projectId: "P2")

        try repo.syncUsage(sourceId: "A", labels: ["Alice"])
        try repo.syncUsage(sourceId: "B", labels: ["Bob"])
        try repo.syncUsage(sourceId: "C", labels: ["Bob"])
        try repo.syncUsage(sourceId: "D", labels: ["Bob", "Carol"])

        let speakers = try repo.knownSpeakers(for: "P1")
        #expect(speakers == [
            .init(name: "Alice", inCurrentProject: true),
            .init(name: "Bob",   inCurrentProject: false),
            .init(name: "Carol", inCurrentProject: false),
        ])
    }

    @Test func knownSpeakers_followsCurrentProjectAfterReassignment() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        let recordings = RecordingRepository(store: store)
        try insertRecording(store: store, sourceId: "S1", projectId: "P1")
        // P2 must exist before setClassification because of the
        // recordings.project_id REFERENCES projects(id) foreign key.
        try insertProject(store: store, projectId: "P2")
        try repo.syncUsage(sourceId: "S1", labels: ["Ben"])

        try recordings.setClassification(
            sourceId: "S1", projectId: "P2",
            confidence: 1.0, reasoning: "manual", by: "user", at: 0,
            linkState: .linked)

        let inP1 = try repo.knownSpeakers(for: "P1")
        let inP2 = try repo.knownSpeakers(for: "P2")
        #expect(inP1 == [.init(name: "Ben", inCurrentProject: false)])
        #expect(inP2 == [.init(name: "Ben", inCurrentProject: true)])
    }

    @Test func knownSpeakers_excludesDefaultLabelsOnly() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "S1")

        // syncUsage will drop "speaker 0" but keep "speaker coach"
        try repo.syncUsage(sourceId: "S1", labels: ["speaker 0", "speaker coach", "Ben"])

        let names = try repo.knownSpeakers(for: nil).map(\.name)
        #expect(Set(names) == ["speaker coach", "Ben"])
    }
```

Check `RecordingRepository.setClassification`'s signature in `TapedeckCore/Sources/TapedeckCore/RecordingRepository.swift:85` and adjust the test call if any parameter names differ.

**Step 2: Run tests to verify they fail**

```bash
cd TapedeckCore && swift test --filter "SpeakerRepository"
```

Expected: compilation fails (`knownSpeakers` not defined).

**Step 3: Implement knownSpeakers**

Add inside the `SpeakerRepository` struct:

```swift
    /// Returns every distinct speaker name (excluding `speaker N` defaults)
    /// ordered by: rows whose recording is in `projectId` first (by their
    /// in-project frequency), then the rest by global frequency, with
    /// alphabetical name as the final tiebreak.
    public func knownSpeakers(for projectId: String?) throws -> [KnownSpeaker] {
        try store.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT u.name AS name,
                       SUM(CASE WHEN r.project_id = ? THEN 1 ELSE 0 END) AS in_project,
                       COUNT(*) AS total
                FROM speaker_usage u
                JOIN recordings r ON r.source_id = u.source_id
                GROUP BY u.name
                ORDER BY in_project DESC, total DESC, u.name ASC
            """, arguments: [projectId])

            return rows.compactMap { row in
                let name: String = row["name"]
                guard !isDefaultLabel(name) else { return nil }
                let inProject: Int = row["in_project"]
                return KnownSpeaker(name: name, inCurrentProject: inProject > 0)
            }
        }
    }
```

The `isDefaultLabel` filter is a belt-and-braces guard: `syncUsage` already filters on insert, but a future code path that bypasses the repository should not be able to leak defaults into the dropdown.

**Step 4: Run tests to verify they pass**

```bash
cd TapedeckCore && swift test --filter "SpeakerRepository"
```

Expected: 7 tests pass.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/SpeakerRepository.swift \
        TapedeckCore/Tests/TapedeckCoreTests/SpeakerRepositoryTests.swift
git commit -m "feat(speakers): knownSpeakers ranks project-first via live join"
```

---

## Task 9: Implement SpeakerRepository.reconcileAll

Replaces all `speaker_usage` rows from supplied `(sourceId, text)` tuples. The caller (AppState) owns the file I/O.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/SpeakerRepository.swift`
- Modify: `TapedeckCore/Tests/TapedeckCoreTests/SpeakerRepositoryTests.swift`

**Step 1: Write the failing test**

Insert before the file-scope helpers in `SpeakerRepositoryTests.swift`:

```swift
    @Test func reconcileAll_populatesPoolFromUnopenedTranscripts() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "A", projectId: "P1")
        try insertRecording(store: store, sourceId: "B", projectId: "P1")

        try repo.reconcileAll(from: [
            (sourceId: "A", text: "[speaker 0] hi\n\n[Alice] hello"),
            (sourceId: "B", text: "[Bob] hey"),
        ])

        let names = try repo.knownSpeakers(for: "P1").map(\.name)
        #expect(Set(names) == ["Alice", "Bob"])
    }

    @Test func reconcileAll_replacesPriorRowsForListedSources() throws {
        let store = try Store.openInMemory()
        let repo = SpeakerRepository(store: store)
        try insertRecording(store: store, sourceId: "A")
        try repo.syncUsage(sourceId: "A", labels: ["Stale"])

        try repo.reconcileAll(from: [
            (sourceId: "A", text: "[Fresh] hi"),
        ])

        #expect(try fetchNames(store: store, sourceId: "A") == ["Fresh"])
    }
```

**Step 2: Run tests to verify they fail**

```bash
cd TapedeckCore && swift test --filter "SpeakerRepository"
```

Expected: compilation fails (`reconcileAll` not defined).

**Step 3: Implement reconcileAll**

Add inside the `SpeakerRepository` struct:

```swift
    /// Rebuilds `speaker_usage` rows for every supplied `(sourceId, text)`
    /// tuple. Wraps every per-source update in a single transaction so the
    /// dropdown sees a consistent snapshot. The caller is responsible for
    /// reading the on-disk transcripts and passing the text in.
    public func reconcileAll(from transcripts: [(sourceId: String, text: String)]) throws {
        try store.write { db in
            for entry in transcripts {
                let labels = parseLabels(entry.text)
                try syncUsageInTx(db, sourceId: entry.sourceId, labels: labels)
            }
        }
    }
```

**Step 4: Run tests to verify they pass**

```bash
cd TapedeckCore && swift test --filter "SpeakerRepository"
```

Expected: 9 tests pass. Run the full suite to confirm nothing else regressed: `cd TapedeckCore && swift test`.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/SpeakerRepository.swift \
        TapedeckCore/Tests/TapedeckCoreTests/SpeakerRepositoryTests.swift
git commit -m "feat(speakers): reconcileAll rebuilds rows from supplied transcripts"
```

---

## Task 10: Clear speaker usage on re-transcribe

`PipelineTranscribe.performTranscribeOne` rewrites the transcript file with fresh `[speaker N]` labels. The DB needs to forget the old usage rows so they don't keep ranking.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/Pipeline.swift` (add `speakers` lazy member)
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift:87` (after `setTranscribed`)
- Modify: `TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift`

**Step 1: Write the failing test**

Append to `PipelineTranscribeTests.swift`, modelled on `transcribeOne_succeeds_writesTranscript_clearsError` (around line 215). It reuses the existing `makeFixture`, `insertDownloadedRecording`, `stubDeepgramOK`, and `makePipelineWith` helpers:

```swift
    @Test func transcribeOne_clearsSpeakerUsageRows() async throws {
        let fx = try makeFixture()
        defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
        let rec = try insertDownloadedRecording(fx)
        let speakers = SpeakerRepository(store: fx.store)
        try speakers.syncUsage(sourceId: rec.sourceId, labels: ["Ben", "Alice"])
        #expect(try !speakers.knownSpeakers(for: nil).isEmpty)
        stubDeepgramOK(fx)

        try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)

        let names = try speakers.knownSpeakers(for: nil).map(\.name)
        #expect(names.isEmpty)
    }
```

The pre-call `#expect` confirms the seed actually inserted rows; the post-call assertion confirms `clearUsage` ran inside `performTranscribeOne`.

**Step 2: Run test to verify it fails**

```bash
cd TapedeckCore && swift test --filter "PipelineTranscribe"
```

Expected: the new test fails (stale rows remain).

**Step 3: Add the SpeakerRepository member to Pipeline**

Edit `Pipeline.swift`. Add next to `recordings` / `projects`:

```swift
    let speakers: SpeakerRepository
```

And in `init`:

```swift
    self.speakers = SpeakerRepository(store: deps.store)
```

**Step 4: Call clearUsage after setTranscribed**

Edit `PipelineTranscribe.swift:87`. Add immediately after `try recordings.setTranscribed(...)`:

```swift
        try speakers.clearUsage(sourceId: rec.sourceId)
```

**Step 5: Run tests to verify they pass**

```bash
cd TapedeckCore && swift test --filter "PipelineTranscribe"
```

Expected: all pass. Then run the full suite: `cd TapedeckCore && swift test`.

**Step 6: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/Pipeline.swift \
        TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift
git commit -m "feat(transcribe): clear speaker usage when transcript is rewritten"
```

---

## Task 11: Reconcile speakers on app startup

`AppDelegate.applicationDidFinishLaunching` is the launch entry point. It already calls `Task { try? await appState.refresh() }` (`Tapedeck/AppDelegate.swift:16`). We add a new method on `AppState` and chain it after `refresh()` so it sees the loaded recordings list.

**Files:**
- Modify: `Tapedeck/AppState.swift`
- Modify: `Tapedeck/AppDelegate.swift`

**Step 1: Expose a SpeakerRepository on AppState**

Edit `AppState.swift`. Add the property next to `recordingRepo` (line 40) and assign it in `init` next to `projectRepo`/`recordingRepo`:

```swift
    let speakers: SpeakerRepository
```

```swift
    // in init, after recordingRepo:
    self.speakers = SpeakerRepository(store: store)
```

It must be `let` (non-private) so `SpeakerEditor` and `DetailPane` in later tasks can read it via the injected `AppState`.

**Step 2: Add reconcileSpeakers**

In `AppState.swift`:

```swift
    /// Rebuilds `speaker_usage` from every transcript on disk so the dropdown
    /// surfaces names from transcripts that have never been opened in the
    /// new editor (or were hand-edited outside the app). Call after the
    /// initial `refresh()` so `self.recordings` is already populated.
    func reconcileSpeakers() async {
        let recordings = self.recordings
        let layout = Layout.standard
        let tuples = await Task.detached(priority: .utility) {
            () -> [(sourceId: String, text: String)] in
            recordings.compactMap { rec -> (sourceId: String, text: String)? in
                guard rec.transcribedAt != nil else { return nil }
                let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
                let dir = layout.audioDir(date: date)
                let stem = layout.stem(sourceId: rec.sourceId, title: rec.filename)
                let url = dir.appending(path: "\(stem).transcript.txt")
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (sourceId: rec.sourceId, text: text)
            }
        }.value
        try? speakers.reconcileAll(from: tuples)
    }
```

**Step 3: Sequence the call in AppDelegate**

Edit `AppDelegate.swift:16`. Replace:

```swift
        Task { try? await appState.refresh() }
```

with:

```swift
        Task {
            try? await appState.refresh()
            await appState.reconcileSpeakers()
        }
```

Reconcile must run *after* `refresh()` because it iterates `appState.recordings`. Keep the existing `LaunchAgent.installIfNeeded()` and `Task { await appState.syncNow(...) }` lines unchanged — `syncNow` is independent and can race with reconcile harmlessly.

**Step 4: Build the app**

```bash
./scripts/build-local.sh 2>&1 | tail -10
```

Expected: `==> Built ./build/local/Tapedeck.app`.

**Step 5: Manual smoke test**

Launch the app:

```bash
open ./build/local/Tapedeck.app
```

Confirm no crash and that startup logs (`tail -F ~/Library/Logs/Tapedeck/sync.log`) show no reconcile-related errors. Check the DB:

```bash
sqlite3 ~/Library/Application\ Support/Tapedeck/state.db "SELECT COUNT(*) FROM speaker_usage"
```

If you have transcripts with hand-edited names, the count should be > 0. If every transcript still has Deepgram defaults, 0 is the correct result (defaults are filtered out).

**Step 6: Commit**

```bash
git add Tapedeck/AppState.swift Tapedeck/AppDelegate.swift
git commit -m "feat(appstate): reconcile speaker_usage from transcripts on launch"
```

---

## Task 12: SpeakerEditor view skeleton

Renders one row per label found in the current transcript text. No editing or dropdown yet — just the list, so DetailPane can show something before the combo arrives.

**Files:**
- Create: `Tapedeck/Views/SpeakerEditor.swift`

**Step 1: Create the view**

```swift
// ABOUTME: Speaker rename panel above the transcript editor in DetailPane.
// ABOUTME: Renders one row per [label] found in the transcript text.

import SwiftUI
import TapedeckCore

struct SpeakerEditor: View {
    let sourceId: String
    let projectId: String?
    let transcript: String
    let onApply: (_ old: String, _ new: String) async -> Void

    private var labels: [String] { parseLabels(transcript) }

    var body: some View {
        if labels.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speakers").font(.caption).foregroundStyle(.secondary)
                ForEach(labels, id: \.self) { label in
                    HStack {
                        Text("[\(label)]").font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
        }
    }
}
```

**Step 2: Build to confirm it compiles**

```bash
./scripts/build-local.sh 2>&1 | tail -5
```

Expected: `==> Built ./build/local/Tapedeck.app`.

**Step 3: Commit**

```bash
git add Tapedeck/Views/SpeakerEditor.swift
git commit -m "feat(ui): SpeakerEditor skeleton renders parsed labels"
```

---

## Task 13: SpeakerEditor combo box with project-aware filtered dropdown

Each row gets an editable text field with a dropdown of known speakers. Project entries (`inCurrentProject == true`) appear at the top, separated from the rest by a divider. The dropdown is filtered live by the text field value (case-insensitive prefix match). The dropdown reloads when the recording, its project, or the parsed labels change.

**Files:**
- Modify: `Tapedeck/Views/SpeakerEditor.swift`

**Step 1: Replace the row layout**

Edit `SpeakerEditor.swift`. Add an `@Environment` reference to `AppState` so the view can query the repository, and replace the row body:

```swift
struct SpeakerEditor: View {
    @Environment(AppState.self) private var appState
    let sourceId: String
    let projectId: String?
    let transcript: String
    let onApply: (_ old: String, _ new: String) async -> Void

    @State private var editText: [String: String] = [:]
    @State private var known: [KnownSpeaker] = []

    private var labels: [String] { parseLabels(transcript) }

    var body: some View {
        if labels.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speakers").font(.caption).foregroundStyle(.secondary)
                ForEach(labels, id: \.self) { label in
                    row(for: label)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
            // Reload when the recording changes, when its project changes,
            // or when the parsed-label set changes (after a rename).
            .task(id: ReloadKey(sourceId: sourceId, projectId: projectId,
                                 labels: labels)) {
                reload()
            }
        }
    }

    private struct ReloadKey: Equatable {
        let sourceId: String
        let projectId: String?
        let labels: [String]
    }

    @ViewBuilder
    private func row(for label: String) -> some View {
        let typed = editText[label] ?? label
        HStack(spacing: 8) {
            Text("[\(label)]")
                .font(.system(.body, design: .monospaced))
                .frame(width: 110, alignment: .leading)
            Text("→").foregroundStyle(.secondary)
            TextField("name", text: binding(for: label))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Menu("▼") {
                let filtered = filteredKnown(matching: typed)
                let inProject = filtered.filter(\.inCurrentProject)
                let others = filtered.filter { !$0.inCurrentProject }
                if !inProject.isEmpty {
                    Section("This project") {
                        ForEach(inProject, id: \.name) { s in
                            Button(s.name) { editText[label] = s.name }
                        }
                    }
                }
                if !others.isEmpty {
                    Section(inProject.isEmpty ? "All speakers" : "Other") {
                        ForEach(others, id: \.name) { s in
                            Button(s.name) { editText[label] = s.name }
                        }
                    }
                }
                if filtered.isEmpty {
                    Text(known.isEmpty ? "No saved speakers yet"
                                       : "No matches").disabled(true)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
        }
    }

    private func binding(for label: String) -> Binding<String> {
        Binding(
            get: { editText[label] ?? label },
            set: { editText[label] = $0 }
        )
    }

    /// Case-insensitive prefix match. When the field still holds the original
    /// `[speaker N]` label (untouched), return the full list so the user sees
    /// every option in their first interaction.
    private func filteredKnown(matching typed: String) -> [KnownSpeaker] {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || labels.contains(trimmed) { return known }
        let lower = trimmed.lowercased()
        return known.filter { $0.name.lowercased().hasPrefix(lower) }
    }

    func reload() {
        known = (try? appState.speakers.knownSpeakers(for: projectId)) ?? []
    }
}
```

`ReloadKey` makes `.task(id:)` fire whenever any of the three inputs change — covering project reassignment, transcript rewrites, and recording selection.

**Step 2: Build to confirm it compiles**

```bash
./scripts/build-local.sh 2>&1 | tail -5
```

Expected: `==> Built ./build/local/Tapedeck.app`. If the build complains about `appState.speakers` accessibility, double-check Task 11 step 1 made it `let speakers: SpeakerRepository` (internal), not `private let`.

**Step 3: Commit**

```bash
git add Tapedeck/Views/SpeakerEditor.swift
git commit -m "feat(ui): SpeakerEditor combo with filtered project-aware dropdown"
```

---

## Task 14: SpeakerEditor apply flow with validation, Return-to-submit, live error

Apply rewrites the transcript file and calls `syncUsage`. Validates the new name as the user types and surfaces the error inline. Pressing Return inside the text field is equivalent to clicking Apply. No merge confirmation yet — that's the next task.

**Files:**
- Modify: `Tapedeck/Views/SpeakerEditor.swift`

**Step 1: Add the Apply button, validation, Return-to-submit, and live error**

Restructure the row body so each row is wrapped in a `VStack` (text field + inline error). Append the Apply column inside the inner `HStack`, before the Menu:

```swift
    @ViewBuilder
    private func row(for label: String) -> some View {
        let typed = editText[label] ?? label
        let validationError = validate((editText[label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let candidateChanged = typed.trimmingCharacters(in: .whitespacesAndNewlines) != label
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("[\(label)]")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 110, alignment: .leading)
                Text("→").foregroundStyle(.secondary)
                TextField("name", text: binding(for: label))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { Task { await applyRename(label: label) } }
                Button("Apply") {
                    Task { await applyRename(label: label) }
                }
                .disabled(!candidateChanged || validationError != nil)
                Menu("▼") {
                    // ...unchanged Menu body from Task 13...
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }
            // Live error: only surface once the user has typed something that
            // diverges from the original label and is invalid.
            if candidateChanged, let err = validationError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(.leading, 118)
            }
        }
    }
```

Keep the existing Menu body from Task 13 in place where the comment indicates — only the surrounding row layout changes.

Add helpers inside `SpeakerEditor`:

```swift
    /// Returns the validation error for a candidate name, or nil if valid.
    /// Used both to gate the Apply button and to render the inline error.
    private func validate(_ name: String) -> String? {
        if name.isEmpty { return "Name cannot be empty" }
        if name.contains("[") || name.contains("]") || name.contains("\n") {
            return "Name cannot contain [, ], or newlines"
        }
        return nil
    }

    private func applyRename(label: String) async {
        let candidate = (editText[label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate != label else { return }
        guard validate(candidate) == nil else { return }
        await onApply(label, candidate)
        // editText is cleared by DetailPane re-reading the transcript, which
        // changes the parsed `labels` set and re-renders this view.
    }
```

Validation is recomputed on every render — no separate `rowError` state needed. SwiftUI re-evaluates `row(for:)` whenever `editText` changes (the field is bound to it), so the inline error tracks the user's typing live.

**Step 2: Build**

```bash
./scripts/build-local.sh 2>&1 | tail -5
```

Expected: `==> Built ./build/local/Tapedeck.app`.

**Step 3: Commit**

```bash
git add Tapedeck/Views/SpeakerEditor.swift
git commit -m "feat(ui): SpeakerEditor apply with live validation and Return-to-submit"
```

---

## Task 15: SpeakerEditor merge-collision confirmation

When the user types a name that already exists as a label in this transcript, show a confirmation alert before applying — merging is destructive and irreversible without re-transcribing.

**Files:**
- Modify: `Tapedeck/Views/SpeakerEditor.swift`

**Step 1: Add the pending-merge state**

Add inside `SpeakerEditor`:

```swift
    @State private var pendingMerge: PendingMerge? = nil

    private struct PendingMerge: Equatable {
        let oldLabel: String
        let newLabel: String
    }
```

**Step 2: Attach the alert modifier after the existing `.task(id:)`**

Keep the existing `.task(id: ReloadKey(...))` from Task 13 unchanged — do not replace it. Append `.alert(...)` immediately after it:

```swift
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
            .task(id: ReloadKey(sourceId: sourceId, projectId: projectId,
                                 labels: labels)) {
                reload()
            }
            .alert("Merge speakers?",
                   isPresented: Binding(
                       get: { pendingMerge != nil },
                       set: { if !$0 { pendingMerge = nil } })) {
                Button("Cancel", role: .cancel) { pendingMerge = nil }
                Button("Merge", role: .destructive) {
                    if let m = pendingMerge {
                        Task { await onApply(m.oldLabel, m.newLabel) }
                    }
                    pendingMerge = nil
                }
            } message: {
                if let m = pendingMerge {
                    Text("\"[\(m.newLabel)]\" already exists in this transcript. " +
                         "Merging cannot be undone without re-transcribing.")
                }
            }
```

**Step 3: Add the merge intercept to `applyRename`**

Edit the `applyRename` body added in Task 14 — keep its existing guards (no `rowError`, validation via the live `validate` helper) and only insert the merge check between validation and the `onApply` call:

```swift
    private func applyRename(label: String) async {
        let candidate = (editText[label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate != label else { return }
        guard validate(candidate) == nil else { return }
        if labels.contains(candidate) {
            pendingMerge = PendingMerge(oldLabel: label, newLabel: candidate)
            return
        }
        await onApply(label, candidate)
    }
```

The merge confirmation only fires when the user actively types an existing label *and* presses Return / Apply. The inline validation error from Task 14 still gates ill-formed names before they reach this point.

**Step 4: Build**

```bash
./scripts/build-local.sh 2>&1 | tail -5
```

Expected: `==> Built ./build/local/Tapedeck.app`.

**Step 5: Commit**

```bash
git add Tapedeck/Views/SpeakerEditor.swift
git commit -m "feat(ui): confirm merge when renamed speaker already exists"
```

---

## Task 16: Embed SpeakerEditor in DetailPane

Wire `SpeakerEditor` into `DetailPane`. The `onApply` closure:
1. Reads the current transcript from disk.
2. Computes the new text via `renameLabel`.
3. Atomically writes back via `String.write(to:atomically:encoding:)`.
4. Calls `speakers.syncUsage` with the new label set.
5. If the recording is currently linked to a project, marks it `pendingRelink` so `PipelineRelink` refreshes the copy in the project folder on the next sync. Without this, the file the user consumes outside Tapedeck (the project-folder copy at `projectDir/<stem>.transcript.txt`, written by `PipelineRelink.writeProjectLinks` at `PipelineRelink.swift:37-40`) keeps showing the old labels.
6. Kicks off a sync so the relink runs immediately rather than waiting for the next 30-second poll.
7. Triggers `loadTranscript` to refresh the view.

**Files:**
- Modify: `Tapedeck/Views/DetailPane.swift`

**Step 1: Read current DetailPane**

Open `Tapedeck/Views/DetailPane.swift`. Note `loadTranscript(_:)` already reads the file into `transcriptText`. The transcript URL is derived from `Layout.standard.audioDir(...)` + the stem.

**Step 2: Insert the SpeakerEditor**

Inside `detailView(_ rec:)`, add between the action HStack and the `TextEditor`:

```swift
                if !transcriptText.isEmpty {
                    SpeakerEditor(
                        sourceId: rec.sourceId,
                        projectId: rec.projectId,
                        transcript: transcriptText,
                        onApply: { old, new in
                            await applyRename(rec: rec, old: old, new: new)
                        }
                    )
                }
```

Add the helpers:

```swift
    private func applyRename(rec: Recording, old: String, new: String) async {
        let url = transcriptURL(for: rec)
        guard let current = try? String(contentsOf: url, encoding: .utf8) else { return }
        let updated = renameLabel(current, from: old, to: new)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            try appState.speakers.syncUsage(
                sourceId: rec.sourceId,
                labels: parseLabels(updated))

            // If a project-folder copy exists (linked recording), refresh it
            // so the downstream consumer sees the new labels. Same mechanism
            // PipelineTranscribe uses on retranscribe.
            if rec.linkedProjectId != nil {
                try appState.recordingRepo.markPendingRelink(sourceId: rec.sourceId)
                await appState.refresh()
                Task { await appState.syncNow(reason: "speaker_rename") }
            }
            loadTranscript(rec)
        } catch {
            NSLog("SpeakerEditor apply failed: \(error)")
        }
    }

    private func transcriptURL(for rec: Recording) -> URL {
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let dir = Layout.standard.audioDir(date: date)
        let stem = Layout.standard.stem(sourceId: rec.sourceId, title: rec.filename)
        return dir.appending(path: "\(stem).transcript.txt")
    }
```

`appState.recordingRepo` is already exposed as `let recordingRepo` in `Tapedeck/AppState.swift:40`, so no additional access work is needed.

Replace the duplicated URL construction inside `loadTranscript` with a call to `transcriptURL(for:)`.

Also call `syncUsage` whenever a transcript is loaded so the DB stays in sync if the file was edited externally:

```swift
    private func loadTranscript(_ rec: Recording) {
        let url = transcriptURL(for: rec)
        transcriptText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? appState.speakers.syncUsage(
            sourceId: rec.sourceId,
            labels: parseLabels(transcriptText))
    }
```

**Step 3: Build the app**

```bash
./scripts/build-local.sh 2>&1 | tail -10
```

Expected: `==> Built ./build/local/Tapedeck.app`.

**Step 4: Manual smoke test**

```bash
open ./build/local/Tapedeck.app
tail -F ~/Library/Logs/Tapedeck/sync.log  # in another terminal
```

1. Pick a recording with a transcript that has `[speaker 0]` / `[speaker 1]`.
2. In the Speakers panel, type `Ben` opposite `[speaker 0]` and click Apply (or press Return).
3. The transcript editor should refresh: every `[speaker 0]` becomes `[Ben]`.
4. Open a *different* recording: the dropdown should now offer `Ben`.
5. Re-rename `[Ben]` to `[Alice]` in the original recording: confirm `Ben` falls out of the pool once no recording uses it (`sqlite3 ~/Library/Application\ Support/Tapedeck/state.db "SELECT DISTINCT name FROM speaker_usage"`).
6. Try renaming `[speaker 1]` to `Ben` in a recording that already has `[Ben]`: the merge alert should appear; confirm "Merge" combines them.
7. Type a name containing `]`: the inline error appears, Apply is disabled, Return does nothing.
8. Rename a speaker in a *linked* recording (one with a value in the "Project" picker), then inspect the project-folder copy directly:

   ```bash
   cat ~/Tapedeck/projects/<slug>/<stem>.transcript.txt | head -3
   ```

   It should show the new label. `PipelineRelink` only logs `relink_failed`, so success is silent — the file contents are the authoritative check. If the contents still show the old label, the `markPendingRelink` + `syncNow` path is misbehaving; check `sync.log` for `relink_failed` entries.
9. Click "Retranscribe" on a recording with named speakers: after it returns, the names should reset to `[speaker N]` and the `speaker_usage` rows for that source should be gone.

**Step 5: Commit**

```bash
git add Tapedeck/Views/DetailPane.swift
git commit -m "feat(ui): embed SpeakerEditor in DetailPane with rename flow"
```

---

## Task 17: Final verification

**Step 1: Run the full TapedeckCore test suite**

```bash
cd TapedeckCore && swift test 2>&1 | tail -10
```

Expected: all tests pass — pre-existing suites plus the new ones added across tasks 1–10.

**Step 2: Build the app one more time**

```bash
./scripts/build-local.sh 2>&1 | tail -5
```

Expected: `==> Built ./build/local/Tapedeck.app`.

**Step 3: Confirm the working tree is clean**

```bash
git status
```

Expected: clean. The feature branch `feature/speaker-renaming` is ready to merge or PR.

---

## Out of scope (do not implement here)

- Per-paragraph diarisation correction ("this line was actually speaker 1").
- Cross-recording bulk rename ("rename Ben → Benjamin everywhere").
- Speakers-pool management UI (manual deletion / global rename).
