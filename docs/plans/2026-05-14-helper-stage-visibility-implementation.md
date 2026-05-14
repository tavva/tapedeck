# Helper Stage Visibility Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Surface helper activity (launchd-triggered and internal-stage progress) in the toolbar, and turn silent skip-already-running exits into a visible banner.

**Architecture:** The helper writes its current stage and per-stage progress counters into `app_state` rows (`helper_stage`, `helper_started_at`, `helper_stage_done`, `helper_stage_total`) and posts a `"helper_stage"` distributed notification via the existing `HelperDeps.notify` seam. `AppState` reads those rows on `refresh()` and derives an `activity: SyncCoordinator.Kind?` that drives toolbar spinners and button disabled-state, falling back to the in-process `busy` flag during the dispatch-but-pre-stage gap. Lock-contention skip paths return exit 75; `SyncCoordinator.dispatch` maps 75 to `CoordinatorError.helperBusy(kind)`, which `AppState` catches and surfaces as a transient banner. A `lockProbe` closure clears stale non-idle stages when the helper crashed (`flock` releases on process death).

**Tech Stack:** Swift 6.0, GRDB (sqlite), Swift Testing (`@Test` / `#expect`) for the `TapedeckCore` package, XCTest for the `Tapedeck` app target, xcodegen for `project.yml` → `Tapedeck.xcodeproj`.

**Design reference:** `docs/plans/2026-05-14-helper-stage-visibility-design.md`

**Test commands (run from worktree root):**
- Core: `swift test --package-path TapedeckCore --filter "<SuiteOrTestName>"`
- App: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/<ClassName>/<methodName> | xcpretty`
- App build verify (any task touching UI): `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" build | xcpretty`. Run `xcodegen generate` first if Swift sources were added or removed.

---

## Task 1: `HelperStatus` writers in TapedeckCore

Add the helper-stage enum and three small DB writers the helper will call as it transitions between stages. They write into `app_state` and are otherwise inert.

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/HelperStatus.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/HelperStatusTests.swift`

**Step 1: Write the failing tests**

Create `HelperStatusTests.swift`:

```swift
// ABOUTME: Tests the helper-stage writers that publish helper progress into app_state.

import Testing
import Foundation
import GRDB
@testable import TapedeckCore

@Suite("HelperStatus")
struct HelperStatusTests {
    private func read(_ store: Store, key: String) throws -> String? {
        try store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?",
                                arguments: [key])
        }
    }

    @Test func writeHelperStage_writesStageAndTimestamp() throws {
        let store = try Store.openInMemory()
        try writeHelperStage(.transcribing, store: store, now: { 1700 })
        #expect(try read(store, key: "helper_stage") == "transcribing")
        #expect(try read(store, key: "helper_started_at") == "1700")
    }

    @Test func writeHelperStage_overwritesExisting() throws {
        let store = try Store.openInMemory()
        try writeHelperStage(.syncing, store: store, now: { 100 })
        try writeHelperStage(.classifying, store: store, now: { 200 })
        #expect(try read(store, key: "helper_stage") == "classifying")
        #expect(try read(store, key: "helper_started_at") == "200")
    }

    @Test func writeHelperProgress_writesDoneAndTotal() throws {
        let store = try Store.openInMemory()
        try writeHelperProgress(done: 3, total: 7, store: store)
        #expect(try read(store, key: "helper_stage_done") == "3")
        #expect(try read(store, key: "helper_stage_total") == "7")
    }

    @Test func clearHelperStage_setsIdleAndZeroesCounters() throws {
        let store = try Store.openInMemory()
        try writeHelperStage(.transcribing, store: store, now: { 100 })
        try writeHelperProgress(done: 2, total: 5, store: store)
        try clearHelperStage(store: store, now: { 999 })
        #expect(try read(store, key: "helper_stage") == "idle")
        #expect(try read(store, key: "helper_stage_done") == "0")
        #expect(try read(store, key: "helper_stage_total") == "0")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --package-path TapedeckCore --filter "HelperStatus"`
Expected: FAIL — `HelperStage`, `writeHelperStage`, `writeHelperProgress`, `clearHelperStage` are undefined.

**Step 3: Implement**

Create `HelperStatus.swift`:

```swift
// ABOUTME: Helper writes its current stage + per-stage progress into app_state so the
// ABOUTME: UI can surface launchd-triggered and internal-stage activity.

import Foundation
import GRDB

public enum HelperStage: String, Sendable, Equatable {
    case idle, syncing, transcribing, classifying
}

public func writeHelperStage(_ stage: HelperStage,
                             store: Store,
                             now: () -> Int64) throws {
    let ts = String(now())
    try store.write { db in
        try db.execute(sql: """
            INSERT INTO app_state(key, value) VALUES('helper_stage', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [stage.rawValue])
        try db.execute(sql: """
            INSERT INTO app_state(key, value) VALUES('helper_started_at', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [ts])
    }
}

public func writeHelperProgress(done: Int, total: Int, store: Store) throws {
    try store.write { db in
        try db.execute(sql: """
            INSERT INTO app_state(key, value) VALUES('helper_stage_done', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [String(done)])
        try db.execute(sql: """
            INSERT INTO app_state(key, value) VALUES('helper_stage_total', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [String(total)])
    }
}

public func clearHelperStage(store: Store, now: () -> Int64) throws {
    try writeHelperStage(.idle, store: store, now: now)
    try writeHelperProgress(done: 0, total: 0, store: store)
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --package-path TapedeckCore --filter "HelperStatus"`
Expected: PASS — 4 tests.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/HelperStatus.swift \
        TapedeckCore/Tests/TapedeckCoreTests/HelperStatusTests.swift
git commit -m "feat(core): HelperStage enum + app_state writers"
```

---

## Task 2: Extract `Pipeline.syncOnly()`

The helper needs to call sync, transcribe, and classify as separately-staged operations. Extract the first half of `runCycle()` into a new public `syncOnly()` so `runFullCycle` can wrap each piece with stage transitions.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/Pipeline.swift` (function around line 51)
- Test: `TapedeckCore/Tests/TapedeckCoreTests/PipelineEndToEndTests.swift`

**Step 1: Write the failing test**

Append to `PipelineEndToEndTests.swift`:

```swift
@Test func syncOnly_listsAndDownloads_butDoesNotTranscribeOrClassify() async throws {
    // Reuse the existing end-to-end fixture builder. After syncOnly the recording
    // must have audioDownloadedAt set, but transcribedAt and projectId should remain
    // nil even when API keys are present.
    let fx = try makeEndToEndFixture()
    try await fx.pipeline.syncOnly()
    let recs = try Self.fetchAllRecordings(fx.store)
    #expect(recs.first?.audioDownloadedAt != nil)
    #expect(recs.first?.transcribedAt == nil)
    #expect(recs.first?.projectId == nil)
}
```

If `PipelineEndToEndTests` does not currently expose `makeEndToEndFixture` / `fetchAllRecordings`, add the smallest needed factory near the existing test setup helpers. Mirror the fixture used by `freshCycleProducesArtefactsAndLinks`.

**Step 2: Run the test to verify it fails**

Run: `swift test --package-path TapedeckCore --filter "syncOnly_listsAndDownloads_butDoesNotTranscribeOrClassify"`
Expected: FAIL — `syncOnly` is not a member of `Pipeline`.

**Step 3: Implement**

In `Pipeline.swift`, replace the `runCycle()` body and add `syncOnly()`:

```swift
public func syncOnly() async throws {
    try ensureToken()
    try await deps.source.discoverHost()
    try await listRemote()
    try await downloadNew()
}

public func runCycle() async throws {
    try await syncOnly()
    try await transcribeNew()
    try await classifyNew()
    try relinkChanged()
    try touchLastSync()
}
```

Keep `relinkChanged()` and `touchLastSync()` exactly as today.

**Step 4: Run the suite to verify nothing else regressed**

Run: `swift test --package-path TapedeckCore --filter "Pipeline"`
Expected: PASS, including the new test.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/Pipeline.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineEndToEndTests.swift
git commit -m "feat(pipeline): extract syncOnly() entry point"
```

---

## Task 3: Promote `transcribeNew` / `classifyNew` to public

`runFullCycle` is moving out of `Pipeline.runCycle` and will call the per-stage entry points directly. Make `transcribeNew()` and `classifyNew()` public so the helper can call them.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift:6` (drop `internal` access on `transcribeNew`)
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineClassify.swift:9` (drop `internal` access on `classifyNew`)

**Step 1: Write the failing test (existence check)**

Append to `PipelineTranscribeTests.swift`:

```swift
@Test func transcribeNew_isPublic() {
    // Compile-only smoke: if access changes back to internal, this stops compiling.
    let _: (Pipeline) -> () async throws -> Void = { p in p.transcribeNew }
}
```

And a matching one in `PipelineClassifyTests.swift`:

```swift
@Test func classifyNew_isPublic() {
    let _: (Pipeline) -> () async throws -> Void = { p in p.classifyNew }
}
```

**Step 2: Run to verify failure**

Run: `swift test --package-path TapedeckCore --filter "transcribeNew_isPublic"`
Expected: FAIL — both `transcribeNew` and `classifyNew` are currently package-internal.

**Step 3: Promote**

In `PipelineTranscribe.swift` change `func transcribeNew()` to `public func transcribeNew()`.
In `PipelineClassify.swift` change `func classifyNew()` to `public func classifyNew()`.

**Step 4: Run to verify pass**

Run: `swift test --package-path TapedeckCore --filter "isPublic"`
Expected: PASS — 2 tests.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift \
        TapedeckCore/Sources/TapedeckCore/PipelineClassify.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineClassifyTests.swift
git commit -m "feat(pipeline): expose transcribeNew/classifyNew as public"
```

---

## Task 4: Extract `runBatchTranscribe` helper

`transcribeNew()` and `transcribePending()` duplicate the same TaskGroup-with-`maxConcurrency` loop. Extract it so progress instrumentation in the next task happens in one place.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift`

**Step 1: Write the failing test**

Append to `PipelineTranscribeTests.swift`:

```swift
@Test func runBatchTranscribe_isInternal() {
    // Compile-only smoke; ensures the helper exists and stays in-package.
    let _: (Pipeline) -> ([Recording]) async -> Void = { p in p.runBatchTranscribe }
}
```

**Step 2: Run to verify failure**

Run: `swift test --package-path TapedeckCore --filter "runBatchTranscribe_isInternal"`
Expected: FAIL — `runBatchTranscribe` does not exist.

**Step 3: Refactor**

In `PipelineTranscribe.swift`, replace the duplicated loops in `transcribeNew()` and `transcribePending()` with calls to a new shared helper:

```swift
func runBatchTranscribe(pending: [Recording]) async {
    await withTaskGroup(of: Void.self) { group in
        var inflight = 0
        for rec in pending {
            if inflight >= maxConcurrency { await group.next(); inflight -= 1 }
            group.addTask { [self] in await self.transcribeOneSilently(rec) }
            inflight += 1
        }
    }
}

public func transcribeNew() async throws {
    guard try autoTranscribeEnabled() else {
        deps.logger.info("transcribe_skipped_auto_disabled", source: nil)
        return
    }
    let pending = ((try? recordings.recordingsNeedingTranscription()) ?? [])
        .filter { !shouldSkipAfterFailures(sourceId: $0.sourceId, stage: SyncStage.transcribe) }
    await runBatchTranscribe(pending: pending)
}

public func transcribePending() async throws {
    let pending = (try? recordings.recordingsNeedingTranscription()) ?? []
    await runBatchTranscribe(pending: pending)
}
```

**Step 4: Run the whole Transcribe suite to confirm no regression**

Run: `swift test --package-path TapedeckCore --filter "PipelineTranscribe"`
Expected: PASS.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift
git commit -m "refactor(pipeline): extract runBatchTranscribe"
```

---

## Task 5: Progress writes in `runBatchTranscribe`

Tick `helper_stage_done` after each completion. Used by both `transcribeNew` and `transcribePending`.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift`
- Test: `TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift`

**Step 1: Write the failing test**

Append to `PipelineTranscribeTests.swift` (reuse the existing transcribe-pending fixture which sets up two pending recordings):

```swift
@Test func transcribePending_writesProgressDoneEqualsTotal() async throws {
    let fx = try await makeTranscribePendingFixture(pendingCount: 2)
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    try await fx.pipeline.transcribePending()
    let total = try fx.store.read { db in
        try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'helper_stage_total'")
    }
    let done = try fx.store.read { db in
        try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'helper_stage_done'")
    }
    #expect(total == 2)
    #expect(done == 2)
}
```

If `makeTranscribePendingFixture(pendingCount:)` does not exist, add a small helper at the bottom of `PipelineTranscribeTests` that builds the fixture by setting up `pendingCount` downloaded-but-untranscribed recordings and stubs Deepgram OK responses. Mirror the existing transcribe success test.

**Step 2: Run the test to verify failure**

Run: `swift test --package-path TapedeckCore --filter "transcribePending_writesProgressDoneEqualsTotal"`
Expected: FAIL — both rows return 0 because nothing writes them.

**Step 3: Implement**

Update `runBatchTranscribe` in `PipelineTranscribe.swift`:

```swift
func runBatchTranscribe(pending: [Recording]) async {
    try? writeHelperProgress(done: 0, total: pending.count, store: deps.store)
    await withTaskGroup(of: Void.self) { group in
        var inflight = 0, done = 0
        for rec in pending {
            if inflight >= maxConcurrency {
                await group.next(); inflight -= 1
                done += 1
                try? writeHelperProgress(done: done, total: pending.count, store: deps.store)
            }
            group.addTask { [self] in await self.transcribeOneSilently(rec) }
            inflight += 1
        }
        while await group.next() != nil {
            done += 1
            try? writeHelperProgress(done: done, total: pending.count, store: deps.store)
        }
    }
}
```

**Step 4: Run to verify pass**

Run: `swift test --package-path TapedeckCore --filter "PipelineTranscribe"`
Expected: PASS (including the new test).

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift
git commit -m "feat(pipeline): progress counters in runBatchTranscribe"
```

---

## Task 6: Progress writes in `runBatchClassify`

Same pattern as Task 5, for classify.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineClassify.swift` (in `runBatchClassify`, around lines 54–73)
- Test: `TapedeckCore/Tests/TapedeckCoreTests/PipelineClassifyTests.swift`

**Step 1: Write the failing test**

Append to `PipelineClassifyTests.swift` (use the existing successful-classify fixture with 2 pending recordings, or add a `pendingCount:` parameter to the existing factory):

```swift
@Test func classifyPending_writesProgressDoneEqualsTotal() async throws {
    let fx = try await makeClassifyPendingFixture(pendingCount: 2)
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    try await fx.pipeline.classifyPending()
    let total = try fx.store.read { db in
        try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'helper_stage_total'")
    }
    let done = try fx.store.read { db in
        try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'helper_stage_done'")
    }
    #expect(total == 2)
    #expect(done == 2)
}
```

**Step 2: Run the test to verify failure**

Run: `swift test --package-path TapedeckCore --filter "classifyPending_writesProgressDoneEqualsTotal"`
Expected: FAIL.

**Step 3: Implement**

Update `runBatchClassify` in `PipelineClassify.swift`:

```swift
private func runBatchClassify(pending: [Recording]) async throws {
    guard !pending.isEmpty else { return }
    let activeProjects = (try? projects.listActive()) ?? []
    guard !activeProjects.isEmpty else {
        deps.logger.info("classify_skipped_no_projects", source: nil)
        return
    }
    let hints = activeProjects.map {
        GeminiClient.ProjectHint(id: $0.id, name: $0.displayName, description: $0.description)
    }
    let threshold = (try? classifierThreshold()) ?? 0.7
    try? writeHelperProgress(done: 0, total: pending.count, store: deps.store)
    await withTaskGroup(of: Void.self) { group in
        var inflight = 0, done = 0
        for rec in pending {
            if inflight >= maxConcurrency {
                await group.next(); inflight -= 1
                done += 1
                try? writeHelperProgress(done: done, total: pending.count, store: deps.store)
            }
            group.addTask { [self] in await self.classifyOneAndRecord(rec, hints: hints, threshold: threshold) }
            inflight += 1
        }
        while await group.next() != nil {
            done += 1
            try? writeHelperProgress(done: done, total: pending.count, store: deps.store)
        }
    }
}
```

**Step 4: Run to verify pass**

Run: `swift test --package-path TapedeckCore --filter "PipelineClassify"`
Expected: PASS.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/PipelineClassify.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineClassifyTests.swift
git commit -m "feat(pipeline): progress counters in runBatchClassify"
```

---

## Task 7: Progress writes in `downloadNew`

Sync-stage progress is the download count. List/discover happen quickly before any items are known.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineDownload.swift`
- Test: `TapedeckCore/Tests/TapedeckCoreTests/PipelineEndToEndTests.swift`

**Step 1: Write the failing test**

Append to `PipelineEndToEndTests.swift`:

```swift
@Test func downloadNew_writesProgressDoneEqualsTotal() async throws {
    let fx = try makeEndToEndFixture(downloadCount: 2)
    try await fx.pipeline.syncOnly()
    let total = try fx.store.read { db in
        try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'helper_stage_total'")
    }
    let done = try fx.store.read { db in
        try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'helper_stage_done'")
    }
    #expect(total == 2)
    #expect(done == 2)
}
```

If `makeEndToEndFixture(downloadCount:)` doesn't exist as a parameterised helper, generalise the existing fixture builder accordingly.

**Step 2: Run to verify failure**

Run: `swift test --package-path TapedeckCore --filter "downloadNew_writesProgressDoneEqualsTotal"`
Expected: FAIL.

**Step 3: Implement**

Update `downloadNew` in `PipelineDownload.swift`:

```swift
func downloadNew() async throws {
    let pending = ((try? recordings.recordingsNeedingDownload()) ?? [])
        .filter { !shouldSkipAfterFailures(sourceId: $0.sourceId, stage: SyncStage.download) }
    let auth = AuthState()
    try? writeHelperProgress(done: 0, total: pending.count, store: deps.store)
    await withTaskGroup(of: Void.self) { group in
        var inflight = 0, done = 0
        for rec in pending {
            if inflight >= maxConcurrency {
                await group.next(); inflight -= 1
                done += 1
                try? writeHelperProgress(done: done, total: pending.count, store: deps.store)
            }
            group.addTask { [self] in await self.downloadOne(rec, auth: auth) }
            inflight += 1
        }
        while await group.next() != nil {
            done += 1
            try? writeHelperProgress(done: done, total: pending.count, store: deps.store)
        }
    }
    if await auth.didFail() { throw SourceClientError.unauthorised }
}
```

**Step 4: Run to verify pass**

Run: `swift test --package-path TapedeckCore --filter "Pipeline"`
Expected: PASS — all suites.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/PipelineDownload.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineEndToEndTests.swift
git commit -m "feat(pipeline): progress counters in downloadNew"
```

---

## Task 8: Progress writes for single-recording paths

`transcribeOne` and `classifyOne` should publish `(0, 1)` on entry and `(1, 1)` on success so the toolbar progress label is still meaningful.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift` (in `transcribeOne`)
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineClassify.swift` (in `classifyOne`)
- Test: `TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift`, `PipelineClassifyTests.swift`

**Step 1: Write the failing tests**

In `PipelineTranscribeTests.swift`:

```swift
@Test func transcribeOne_writes_0of1_then_1of1_onSuccess() async throws {
    let fx = try await makeTranscribeOneFixture()
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    try await fx.pipeline.transcribeOne(sourceId: fx.recordingId)
    let done = try fx.store.read { db in
        try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'helper_stage_done'")
    }
    let total = try fx.store.read { db in
        try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'helper_stage_total'")
    }
    #expect(done == 1)
    #expect(total == 1)
}
```

Mirror it in `PipelineClassifyTests.swift` (`classifyOne_writes_0of1_then_1of1_onSuccess`).

**Step 2: Run to verify failure**

Run: `swift test --package-path TapedeckCore --filter "writes_0of1_then_1of1_onSuccess"`
Expected: FAIL.

**Step 3: Implement**

In `PipelineTranscribe.swift`'s `transcribeOne`:

```swift
public func transcribeOne(sourceId: String) async throws {
    guard let rec = try recordings.find(sourceId: sourceId) else {
        throw TranscribeError.unknownRecording(sourceId)
    }
    try? writeHelperProgress(done: 0, total: 1, store: deps.store)
    do {
        try await performTranscribeOne(rec)
        try? writeHelperProgress(done: 1, total: 1, store: deps.store)
    } catch {
        try? recordings.recordError(sourceId: sourceId, stage: .transcribe,
                                    at: deps.now(), message: "\(error)")
        deps.logger.error("transcribe_failed", source: sourceId, message: "\(error)")
        throw error
    }
}
```

In `PipelineClassify.swift`'s `classifyOne`, apply the same pattern around the `performClassifyOne` call.

**Step 4: Run to verify pass**

Run: `swift test --package-path TapedeckCore --filter "writes_0of1_then_1of1_onSuccess"`
Expected: PASS — 2 tests.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift \
        TapedeckCore/Sources/TapedeckCore/PipelineClassify.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineClassifyTests.swift
git commit -m "feat(pipeline): single-recording progress (0,1)→(1,1)"
```

---

## Task 9: `runFullCycle` stage orchestration

Replace the monolithic `pipeline.runCycle()` call in `runFullCycle` with explicit stage transitions, each writing `helper_stage` and notifying.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/HelperRunner.swift` (`runFullCycle`, lines 80–130)
- Test: `TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift`

**Step 1: Write the failing test**

Add a captured-notify helper near the top of `HelperRunnerTests.swift`:

```swift
private final class NotifyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _keys: [String] = []
    func append(_ key: String) { lock.lock(); _keys.append(key); lock.unlock() }
    var keys: [String] { lock.lock(); defer { lock.unlock() }; return _keys }
}
```

Then add a test that uses a fixture wired to capture notifications:

```swift
@Test func runFullCycle_writesStageTransitions_andEndsIdle() async throws {
    let fx = try await makeFixture(secrets: ["tapedeck.deepgram.key:default": "dg",
                                              "tapedeck.gemini.key:default": "gm"])
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }

    // Turn auto flags on so transcribe + classify stages run.
    try fx.store.write { db in
        try db.execute(sql: """
            INSERT INTO app_state(key,value) VALUES('auto_transcribe','true')
            ON CONFLICT(key) DO UPDATE SET value='true'
        """)
        try db.execute(sql: """
            INSERT INTO app_state(key,value) VALUES('auto_classify','true')
            ON CONFLICT(key) DO UPDATE SET value='true'
        """)
    }

    let capture = NotifyCapture()
    var deps = fx.deps
    deps.notify = { capture.append($0) }

    // Stub remote so syncOnly walks but yields no new recordings.
    stubEmptyRemote(fx)

    let status = await runHelper(.fullCycle, deps: deps)
    #expect(status == 0)

    // helper_stage must have been written in order: syncing → transcribing → classifying → idle
    let stages = try fx.store.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key='helper_stage'")
    }
    #expect(stages == "idle")
    #expect(capture.keys.filter { $0 == "helper_stage" }.count >= 4)
}
```

If `stubEmptyRemote` is not yet defined in the suite, add it: a stub that returns 200 with `[]` for the listing endpoint and a 200 for `discoverHost`.

**Step 2: Run to verify failure**

Run: `swift test --package-path TapedeckCore --filter "runFullCycle_writesStageTransitions_andEndsIdle"`
Expected: FAIL — stage rows are not written.

**Step 3: Implement**

Replace `runFullCycle` in `HelperRunner.swift`:

```swift
@MainActor
private func runFullCycle(deps: HelperDeps) async -> Int32 {
    do {
        let lock = try SyncLock(path: deps.layout.lockURL())
        guard lock.tryAcquire() else {
            deps.logger.info("sync_skipped_already_running", source: nil)
            return 75
        }
        let store = try deps.openStore(deps.layout.dbURL())
        defer {
            try? clearHelperStage(store: store, now: deps.now)
            deps.notify("helper_stage")
        }
        guard let token = try deps.readSecret("tapedeck.source.jwt", "default") else {
            deps.logger.error("token_missing", source: nil, message: "no JWT in keychain")
            return 2
        }
        let needsDeepgram = autoFlag(store: store, key: "auto_transcribe")
        let needsGemini   = autoFlag(store: store, key: "auto_classify")
        let deepgramKey   = try deps.readSecret("tapedeck.deepgram.key", "default")
        let geminiKey     = try deps.readSecret("tapedeck.gemini.key", "default")
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

        try writeHelperStage(.syncing, store: store, now: deps.now)
        deps.notify("helper_stage")
        try await pipeline.syncOnly()

        if needsDeepgram {
            try writeHelperStage(.transcribing, store: store, now: deps.now)
            deps.notify("helper_stage")
            try await pipeline.transcribeNew()
        }
        if needsGemini {
            try writeHelperStage(.classifying, store: store, now: deps.now)
            deps.notify("helper_stage")
            try await pipeline.classifyNew()
        }
        try pipeline.relinkChanged()
        try pipeline.touchLastSync()
        deps.notify("last_sync_at")
        return 0
    } catch SourceClientError.unauthorised {
        try? writeTokenStatus(deps: deps, value: "expired")
        deps.notify("token_status")
        deps.logger.error("token_expired", source: nil, message: "401 from upstream")
        return 4
    } catch Pipeline.PipelineError.tokenExpired {
        deps.logger.info("token_already_expired", source: nil)
        deps.notify("token_status")
        return 4
    } catch {
        deps.logger.error("cycle_failed", source: nil, message: "\(error)")
        return 1
    }
}
```

Note: `relinkChanged()` and `touchLastSync()` were exposed as throwing internal methods inside `Pipeline`. If they are not currently public, mark them `public` (a one-line change in each).

**Step 4: Run to verify pass**

Run: `swift test --package-path TapedeckCore --filter "HelperRunner"`
Expected: PASS.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/HelperRunner.swift \
        TapedeckCore/Sources/TapedeckCore/Pipeline.swift \
        TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift
git commit -m "feat(helper): runFullCycle stage transitions with deps.notify"
```

---

## Task 10: Single-stage runners set/clear stage

`runTranscribePending`, `runTranscribeSource`, `runClassifyPending`, `runClassifySource` each set their stage on lock acquisition and clear in `defer`.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/HelperRunner.swift` (all four single-stage runners)
- Test: `TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift`

**Step 1: Write the failing test**

Append to `HelperRunnerTests.swift`:

```swift
@Test func runTranscribePending_setsStageThenClears() async throws {
    let fx = try await makeFixture(secrets: ["tapedeck.deepgram.key:default": "dg"])
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let capture = NotifyCapture()
    var deps = fx.deps
    deps.notify = { capture.append($0) }
    _ = await runHelper(.transcribePending, deps: deps)
    let stage = try fx.store.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key='helper_stage'")
    }
    #expect(stage == "idle")
    #expect(capture.keys.contains("helper_stage"))
}
```

Mirror three more tests for the other runners (`runTranscribeSource`, `runClassifyPending`, `runClassifySource`).

**Step 2: Run to verify failure**

Run: `swift test --package-path TapedeckCore --filter "setsStageThenClears"`
Expected: FAIL.

**Step 3: Implement**

Add the same `defer { try? clearHelperStage(...); deps.notify("helper_stage") }` block to each of the four single-stage runners, plus a `try writeHelperStage(.transcribing|.classifying, ...)` + `deps.notify("helper_stage")` immediately after lock acquisition (before the keys are checked, so the UI sees the stage even if a key is missing). The runner body is otherwise unchanged.

**Step 4: Run to verify pass**

Run: `swift test --package-path TapedeckCore --filter "HelperRunner"`
Expected: PASS.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/HelperRunner.swift \
        TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift
git commit -m "feat(helper): single-stage runners publish helper_stage"
```

---

## Task 11: All five runners return 75 on lock contention

Existing skip paths return 0; switch them all to 75 (`EX_TEMPFAIL`).

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/HelperRunner.swift`
- Test: `TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift`

**Step 1: Add the lock-contention test fixture**

flock on macOS is per-process, so a child process must hold the lock. Add a helper at the top of `HelperRunnerTests`:

```swift
private final class LockHolder {
    let process = Process()
    let path: URL
    init(path: URL) throws {
        self.path = path
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import fcntl, sys, time
        f = open(sys.argv[1], 'w')
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print('holding', flush=True)
        sys.stdin.read()
        """, path.path]
        let stdin = Pipe(); let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        // Wait for the "holding" line so the lock is actually held before we proceed.
        let handle = stdout.fileHandleForReading
        var buf = Data()
        while !String(data: buf, encoding: .utf8)!.contains("holding") {
            buf.append(handle.availableData)
        }
    }
    func release() {
        if let stdin = process.standardInput as? Pipe {
            stdin.fileHandleForWriting.closeFile()
        }
        process.waitUntilExit()
    }
}
```

**Step 2: Write the failing tests**

```swift
@Test func runFullCycle_returns75_whenLockHeld() async throws {
    let fx = try await makeFixture(secrets: [:])
    try FileManager.default.createDirectory(at: fx.layout.lockURL().deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let holder = try LockHolder(path: fx.layout.lockURL())
    defer { holder.release() }
    let status = await runHelper(.fullCycle, deps: fx.deps)
    #expect(status == 75)
}
```

Add four more (`transcribePending`, `transcribeSource("x")`, `classifyPending`, `classifySource("x")`), all identical except for the command.

**Step 3: Run to verify failure**

Run: `swift test --package-path TapedeckCore --filter "returns75_whenLockHeld"`
Expected: FAIL — current code returns 0 on lock contention.

**Step 4: Implement**

In `HelperRunner.swift`, change each of the five `return 0` paths inside the `guard lock.tryAcquire() else { ... return 0 }` blocks to `return 75`.

**Step 5: Run to verify pass**

Run: `swift test --package-path TapedeckCore --filter "returns75_whenLockHeld"`
Expected: PASS — 5 tests.

**Step 6: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/HelperRunner.swift \
        TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift
git commit -m "feat(helper): exit 75 on lock contention (EX_TEMPFAIL)"
```

---

## Task 12: `SyncCoordinator` — helperBusy error + dispatch mapping + `OperationRunner` protocol

Coordinator surfaces a typed `helperBusy(kind)` when the helper exits 75, and gains an `OperationRunner` protocol so `AppState` can be tested against a fake.

**Files:**
- Modify: `Tapedeck/SyncCoordinator.swift`
- Test: `Tapedeck/Tests/SyncCoordinatorTests.swift`

**Step 1: Write the failing test**

Append to `SyncCoordinatorTests.swift`:

```swift
func testDispatchThrowsHelperBusy_whenSpawnerReturns75() async {
    let coord = SyncCoordinator { _, _ in 75 }
    do {
        _ = try await coord.runOnce(reason: "test")
        XCTFail("expected helperBusy throw")
    } catch let SyncCoordinator.CoordinatorError.helperBusy(kind) {
        XCTAssertEqual(kind, .sync)
    } catch {
        XCTFail("unexpected: \(error)")
    }
}

func testOperationRunnerConformance_forwardsToRunOnce() async throws {
    let coord = SyncCoordinator { _, _ in 0 }
    let runner: any OperationRunner = coord
    let status = try await runner.run(.sync, reason: "test")
    XCTAssertEqual(status, 0)
}
```

**Step 2: Run to verify failure**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/SyncCoordinatorTests/testDispatchThrowsHelperBusy_whenSpawnerReturns75 | xcpretty`
Expected: FAIL — `helperBusy` case and `OperationRunner` are undefined.

**Step 3: Implement**

In `SyncCoordinator.swift`:

```swift
protocol OperationRunner: Sendable {
    func run(_ kind: SyncCoordinator.Kind, reason: String) async throws -> Int32
}

extension SyncCoordinator: OperationRunner {
    func run(_ kind: Kind, reason: String) async throws -> Int32 {
        switch kind {
        case .sync:                       return try await runOnce(reason: reason)
        case .classifyPending:            return try await classifyPending(reason: reason)
        case .classifySource(let id):     return try await classifyOne(sourceId: id, reason: reason)
        case .transcribePending:          return try await transcribePending(reason: reason)
        case .transcribeSource(let id):   return try await transcribeOne(sourceId: id, reason: reason)
        }
    }
}

enum CoordinatorError: Error, Equatable {
    case otherOperationRunning(Kind)
    case helperBusy(Kind)
}
```

Update `dispatch` to map 75 → throw:

```swift
private func dispatch(_ kind: Kind, reason: String) async throws -> Int32 {
    if let cur = current {
        if cur.kind == kind { return try await cur.task.value }
        throw CoordinatorError.otherOperationRunning(cur.kind)
    }
    let spawner = self.spawner
    let task = Task { try await spawner(kind, reason) }
    current = (kind, task)
    defer { current = nil }
    let status = try await task.value
    if status == 75 { throw CoordinatorError.helperBusy(kind) }
    return status
}
```

**Step 4: Run to verify pass**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/SyncCoordinatorTests | xcpretty`
Expected: PASS — all coordinator tests (existing + 2 new).

**Step 5: Commit**

```bash
git add Tapedeck/SyncCoordinator.swift Tapedeck/Tests/SyncCoordinatorTests.swift
git commit -m "feat(coord): helperBusy error + OperationRunner protocol"
```

---

## Task 13: `AppState` testability seam

Add an injectable initialiser. Production keeps `AppState()` as a convenience. The seam takes `layout`, optional `store`, `tokenReader`, `coordinator: any OperationRunner`, `lockProbe: (() -> Bool)?`, `polling`, and `transientDuration`.

**Files:**
- Modify: `Tapedeck/AppState.swift`
- Create: `Tapedeck/Tests/AppStateTests.swift`

**Step 1: Write the failing test**

Create `AppStateTests.swift`:

```swift
import XCTest
import TapedeckCore
@testable import Tapedeck

@MainActor
final class AppStateTests: XCTestCase {
    func testInit_acceptsInjectedDependencies() throws {
        let store = try Store.openInMemory()
        let state = AppState(layout: .standard,
                             store: store,
                             tokenReader: { true },
                             coordinator: FakeRunner(status: 0),
                             lockProbe: { false },
                             polling: false,
                             transientDuration: .milliseconds(10))
        XCTAssertEqual(state.recordings.count, 0)
    }
}

@MainActor
final class FakeRunner: OperationRunner {
    let status: Int32
    init(status: Int32) { self.status = status }
    func run(_ kind: SyncCoordinator.Kind, reason: String) async throws -> Int32 {
        status
    }
}
```

Add `AppStateTests.swift` to the test target in `project.yml` under the existing `Tests` group, then run `xcodegen generate`.

**Step 2: Run to verify failure**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/AppStateTests/testInit_acceptsInjectedDependencies | xcpretty`
Expected: FAIL — `AppState.init(layout:store:tokenReader:coordinator:lockProbe:polling:transientDuration:)` does not exist.

**Step 3: Implement**

In `AppState.swift`, add the injectable init and refactor existing `init()` to delegate:

```swift
private let layout: Layout
private let store: Store
private let projectRepo: ProjectRepository
let recordingRepo: RecordingRepository
private let tokenReader: () -> Bool
private let coordinator: any OperationRunner
private let lockProbe: () -> Bool
private let transientDuration: Duration
private var timer: Timer?
let playback = PlaybackController()

static func defaultTokenReader() -> Bool {
    (try? KeychainStore.shared.get(service: "tapedeck.source.jwt", account: "default")) != nil
}

static func probeLock(at url: URL) -> Bool {
    guard let lock = try? SyncLock(path: url) else { return false }
    return lock.tryAcquire()  // released on return when lock goes out of scope
}

init(layout: Layout = .standard,
     store: Store? = nil,
     tokenReader: @escaping () -> Bool = AppState.defaultTokenReader,
     coordinator: any OperationRunner = SyncCoordinator.shared,
     lockProbe: (() -> Bool)? = nil,
     polling: Bool = true,
     transientDuration: Duration = .seconds(4)) {
    self.layout = layout
    self.store = (try? store ?? Store.open(at: layout.dbURL()))!
    self.projectRepo = ProjectRepository(store: self.store)
    self.recordingRepo = RecordingRepository(store: self.store)
    self.tokenReader = tokenReader
    self.coordinator = coordinator
    self.lockProbe = lockProbe ?? { AppState.probeLock(at: layout.lockURL()) }
    self.transientDuration = transientDuration
    if polling { startPolling() }
}
```

Replace `try? KeychainStore.shared.get(...)` inside `refresh()` with `tokenReader()`.

Replace `SyncCoordinator.shared.runOnce(reason:)` (and the other three) inside `syncNow`/`classifyPending`/`classifyOne`/`transcribePending`/`transcribeOne` with `coordinator.run(.sync, reason: reason)` (and the corresponding kinds).

**Step 4: Run to verify pass**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/AppStateTests | xcpretty`
Expected: PASS.

**Step 5: Commit**

```bash
git add Tapedeck/AppState.swift Tapedeck/Tests/AppStateTests.swift project.yml Tapedeck.xcodeproj
git commit -m "feat(appstate): injectable seam for tests"
```

---

## Task 14: `AppState` reads helperStage + `activity` property

`refresh()` reads `helper_stage`, `helper_stage_done`, `helper_stage_total` from `app_state`. `activity` derives the equivalent `SyncCoordinator.Kind` for the toolbar.

**Files:**
- Modify: `Tapedeck/AppState.swift`
- Test: `Tapedeck/Tests/AppStateTests.swift`

**Step 1: Write the failing tests**

```swift
func testActivity_prefersHelperStageOverBusy() async throws {
    let store = try Store.openInMemory()
    try writeHelperStage(.transcribing, store: store, now: { 1 })
    let state = AppState(layout: .standard, store: store,
                         tokenReader: { true },
                         coordinator: FakeRunner(status: 0),
                         lockProbe: { false },
                         polling: false,
                         transientDuration: .milliseconds(10))
    try await state.refresh()
    XCTAssertEqual(state.helperStage, .transcribing)
    XCTAssertEqual(state.activity, .transcribePending)
}

func testActivity_fallsBackToBusy_whenStageIdle() async throws {
    let store = try Store.openInMemory()
    try clearHelperStage(store: store, now: { 1 })
    let state = AppState(layout: .standard, store: store,
                         tokenReader: { true },
                         coordinator: FakeRunner(status: 0),
                         lockProbe: { false },
                         polling: false,
                         transientDuration: .milliseconds(10))
    try await state.refresh()
    state.busy = .sync
    XCTAssertEqual(state.activity, .sync)
}

func testProgress_readsDoneAndTotal() async throws {
    let store = try Store.openInMemory()
    try writeHelperStage(.transcribing, store: store, now: { 1 })
    try writeHelperProgress(done: 3, total: 7, store: store)
    let state = AppState(layout: .standard, store: store,
                         tokenReader: { true },
                         coordinator: FakeRunner(status: 0),
                         lockProbe: { false },
                         polling: false,
                         transientDuration: .milliseconds(10))
    try await state.refresh()
    XCTAssertEqual(state.stageDone, 3)
    XCTAssertEqual(state.stageTotal, 7)
}
```

**Step 2: Run to verify failure**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/AppStateTests | xcpretty`
Expected: FAIL — `helperStage`, `stageDone`, `stageTotal`, `activity` are undefined.

**Step 3: Implement**

Add to `AppState`:

```swift
var helperStage: HelperStage = .idle
var stageDone: Int = 0
var stageTotal: Int = 0

var activity: SyncCoordinator.Kind? {
    switch helperStage {
    case .syncing:      return .sync
    case .transcribing: return .transcribePending
    case .classifying:  return .classifyPending
    case .idle:         return busy
    }
}
```

Extend `refresh()` to read the rows:

```swift
let helperStageRaw = try store.read { db in
    try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key='helper_stage'")
}
let done = try store.read { db in
    try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key='helper_stage_done'")
} ?? 0
let total = try store.read { db in
    try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key='helper_stage_total'")
} ?? 0
// ... at the end, alongside existing assignments:
self.helperStage = helperStageRaw.flatMap(HelperStage.init(rawValue:)) ?? .idle
self.stageDone = done
self.stageTotal = total
```

**Step 4: Run to verify pass**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/AppStateTests | xcpretty`
Expected: PASS.

**Step 5: Commit**

```bash
git add Tapedeck/AppState.swift Tapedeck/Tests/AppStateTests.swift
git commit -m "feat(appstate): read helper_stage rows + activity derivation"
```

---

## Task 15: `transientMessage` + helperBusy banner catch

Surface lock-contention skips as a transient banner. Use the injected `transientDuration` so tests can run in milliseconds.

**Files:**
- Modify: `Tapedeck/AppState.swift`
- Test: `Tapedeck/Tests/AppStateTests.swift`

**Step 1: Write the failing test**

```swift
func testHelperBusyCatch_setsAndClearsTransientMessage() async throws {
    let store = try Store.openInMemory()
    let runner = ThrowingHelperBusyRunner(kind: .transcribePending)
    let state = AppState(layout: .standard, store: store,
                         tokenReader: { true },
                         coordinator: runner,
                         lockProbe: { false },
                         polling: false,
                         transientDuration: .milliseconds(20))
    await state.transcribePending(reason: "test")
    XCTAssertNotNil(state.transientMessage)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertNil(state.transientMessage)
}

@MainActor
final class ThrowingHelperBusyRunner: OperationRunner {
    let kind: SyncCoordinator.Kind
    init(kind: SyncCoordinator.Kind) { self.kind = kind }
    func run(_ k: SyncCoordinator.Kind, reason: String) async throws -> Int32 {
        throw SyncCoordinator.CoordinatorError.helperBusy(kind)
    }
}
```

**Step 2: Run to verify failure**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/AppStateTests/testHelperBusyCatch_setsAndClearsTransientMessage | xcpretty`
Expected: FAIL — `transientMessage` is undefined.

**Step 3: Implement**

Add to `AppState`:

```swift
var transientMessage: String? = nil
```

Update `dispatch`:

```swift
private func dispatch(_ kind: SyncCoordinator.Kind, reason: String,
                      _ run: () async throws -> Int32) async {
    busy = kind
    defer { busy = nil }
    do {
        _ = try await run()
    } catch SyncCoordinator.CoordinatorError.helperBusy {
        transientMessage = "Another sync operation is in progress."
        let duration = transientDuration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            self?.transientMessage = nil
        }
    } catch SyncCoordinator.CoordinatorError.otherOperationRunning(let other) {
        NSLog("SyncCoordinator: \(kind) requested while \(other) running")
    } catch {
        NSLog("SyncCoordinator \(kind) failed: \(error)")
    }
    try? await refresh()
}
```

**Step 4: Run to verify pass**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/AppStateTests | xcpretty`
Expected: PASS.

**Step 5: Commit**

```bash
git add Tapedeck/AppState.swift Tapedeck/Tests/AppStateTests.swift
git commit -m "feat(appstate): transient banner on helperBusy"
```

---

## Task 16: `clearStaleStageIfNoHelper` (init + refresh)

When `helper_stage` is non-idle but the lock probe returns `true` (no helper holds the lock), clear the stage. Run in `init` and in `refresh()` whenever `helperStage != .idle`.

**Files:**
- Modify: `Tapedeck/AppState.swift`
- Test: `Tapedeck/Tests/AppStateTests.swift`

**Step 1: Write the failing tests**

```swift
func testStaleStageCleared_whenLockFree() async throws {
    let store = try Store.openInMemory()
    try writeHelperStage(.transcribing, store: store, now: { 1 })
    let state = AppState(layout: .standard, store: store,
                         tokenReader: { true },
                         coordinator: FakeRunner(status: 0),
                         lockProbe: { true },           // lock acquired = no helper
                         polling: false,
                         transientDuration: .milliseconds(10))
    try await state.refresh()
    XCTAssertEqual(state.helperStage, .idle)
}

func testStaleStageRetained_whenLockHeld() async throws {
    let store = try Store.openInMemory()
    try writeHelperStage(.transcribing, store: store, now: { 1 })
    let state = AppState(layout: .standard, store: store,
                         tokenReader: { true },
                         coordinator: FakeRunner(status: 0),
                         lockProbe: { false },          // lock held by another process
                         polling: false,
                         transientDuration: .milliseconds(10))
    try await state.refresh()
    XCTAssertEqual(state.helperStage, .transcribing)
}
```

**Step 2: Run to verify failure**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/AppStateTests | xcpretty`
Expected: FAIL — current `refresh` keeps stage as-is regardless of probe.

**Step 3: Implement**

Add to `AppState`:

```swift
private func clearStaleStageIfNoHelper() {
    guard helperStage != .idle else { return }
    guard lockProbe() else { return }
    try? clearHelperStage(store: store, now: { Int64(Date().timeIntervalSince1970 * 1000) })
    self.helperStage = .idle
    self.stageDone = 0
    self.stageTotal = 0
}
```

In `init`, call `clearStaleStageIfNoHelper()` right after the stored properties are assigned (before `startPolling`).

In `refresh()`, after reading the rows and assigning `helperStage`/`stageDone`/`stageTotal`, call `clearStaleStageIfNoHelper()`.

**Step 4: Run to verify pass**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/AppStateTests | xcpretty`
Expected: PASS.

**Step 5: Commit**

```bash
git add Tapedeck/AppState.swift Tapedeck/Tests/AppStateTests.swift
git commit -m "feat(appstate): clearStaleStageIfNoHelper on init + refresh"
```

---

## Task 17: UI wiring — toolbar, DetailPane, banner

The toolbar reads `activity` instead of `busy`. The label shows progress when `stageTotal > 0`. DetailPane's per-row Transcribe/Retranscribe disables on any activity. A new banner overlay shows `transientMessage`.

**Files:**
- Modify: `Tapedeck/TapedeckApp.swift` (toolbar section, lines 51–101; overlay, line 103)
- Modify: `Tapedeck/Views/DetailPane.swift`

No new unit tests — the UI changes are observable via `xcodebuild build` and manual run.

**Step 1: Implement the toolbar wiring**

In `TapedeckApp.swift`, add a free helper near the file top (or in a new `ToolbarLabels.swift` if you prefer):

```swift
fileprivate func progressLabel(verb: String, done: Int, total: Int) -> String {
    total > 0 ? "\(verb) \(done) of \(total)…" : "\(verb)…"
}
```

Replace each toolbar item's `if appState.busy == X` with `if appState.activity == X`, and replace each disabled predicate `appState.busy != nil` with `appState.activity != nil`. Replace each `Text("…")` literal with `Text(progressLabel(verb: "Transcribing", done: appState.stageDone, total: appState.stageTotal))` (and same for "Classifying", "Syncing").

**Step 2: Add the banner overlay**

In `TapedeckApp.swift`'s `MainView.body`, after `.overlay(alignment: .top) { if appState.tokenStatus == "expired" { ReAuthBanner() } }`, add a second overlay:

```swift
.overlay(alignment: .top) {
    if let message = appState.transientMessage {
        TransientBanner(text: message)
    }
}
```

Add a tiny view at the bottom of `TapedeckApp.swift`:

```swift
private struct TransientBanner: View {
    let text: String
    var body: some View {
        Text(text)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
```

**Step 3: DetailPane disable wiring**

In `Tapedeck/Views/DetailPane.swift`, find the Transcribe / Retranscribe button and change its `.disabled(...)` to also include `|| appState.activity != nil`. If it currently has only the per-row spinner condition, OR the new condition with the existing one (do not remove the per-row spin gating).

**Step 4: Build verify**

Run from worktree root:
```bash
xcodegen generate
xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" build | xcpretty
```
Expected: BUILD SUCCEEDED, no warnings introduced.

**Step 5: Smoke run**

Run `scripts/build-local.sh` and launch the resulting `Tapedeck.app`. Sanity-check the toolbar:

- `auto_transcribe = true`, `auto_classify = true`: trigger Sync now. Toolbar should walk through Syncing X of Y… → Transcribing X of Y… → Classifying X of Y…, then return to idle.
- With auto flags off: trigger Sync now. Toolbar shows Syncing… (no count after listRemote finishes); transcribe/classify spinners do not flash.
- While a sync is running (start one then click a DetailPane Transcribe): the per-row button should be disabled.
- Manually invoke `TapedeckSyncHelper --transcribe-pending` twice in quick succession from terminal so the second hits the locked path; in the app, the toolbar should show "Another sync operation is in progress." for ~4 seconds (need to trigger a second op from the UI for the banner to appear — the helper-only clash doesn't produce a UI signal).

Document any deviations in the commit message.

**Step 6: Commit**

```bash
git add Tapedeck/TapedeckApp.swift Tapedeck/Views/DetailPane.swift
git commit -m "feat(ui): activity-driven toolbar + transient busy banner"
```

---

## Final verification

Run from worktree root:

```bash
swift test --package-path TapedeckCore
xcodegen generate
xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test | xcpretty
```

Expected: all suites pass.

Optionally bundle and run:

```bash
scripts/build-local.sh
open build/local/Tapedeck.app
```

Watch the toolbar during a real sync cycle to confirm the three spinners light up in turn with progress counts.
