# User-Triggered Transcription Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add user-triggered Transcribe affordances mirroring the existing user-triggered Classify path, plus an `auto_transcribe` opt-in toggle that gates `Pipeline.transcribeNew()`.

**Architecture:** Mirror the shape of the classify rollout already in the codebase (`PipelineClassify.swift`, `HelperRunner` classify subcommands, `SyncCoordinator.Kind.classifyPending`/`classifySource`, `AppState.classifyPending`/`classifyOne`, ClassifierTab toggle). The throwing core / silent-batch split inside `PipelineTranscribe.swift` matches `PipelineClassify.swift`. Retranscribing a linked recording marks `project_link_state = 'pending_relink'` so the helper's post-transcribe `relinkChanged()` pass refreshes the project-folder copies of `.transcript.txt` / `.deepgram.json`. The full sync path drops its blanket Deepgram + Gemini key requirement and only demands the keys whose stages are enabled.

**Tech Stack:** Swift 6.0, GRDB (sqlite), Swift Testing (`@Test` / `#expect`) for the `TapedeckCore` package, XCTest for the `Tapedeck` app target, xcodegen for `project.yml` → `Tapedeck.xcodeproj`.

**Design reference:** `docs/plans/2026-05-13-user-triggered-transcription-design.md`

**Test commands (run from repo root):**
- Core (Swift Package, Swift Testing): `swift test --package-path TapedeckCore --filter "<SuiteOrTestName>"`
- App (XCTest under xcodegen): `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/<ClassName>/<methodName> | xcpretty`
- Full app run before any task that touches UI files: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" build | xcpretty` (xcodegen regenerates the project from `project.yml`; if new sources are added you may need `xcodegen generate` first)

---

## Task 1: `RecordingRepository.markPendingRelink`

Add a single mutator so `performTranscribeOne` can schedule a relink refresh after retranscribing a linked recording.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/RecordingRepository.swift` (insert after `markLinked`, ~line 106)
- Test: `TapedeckCore/Tests/TapedeckCoreTests/RecordingRepositoryTests.swift`

**Step 1: Write the failing test**

Append to `RecordingRepositoryTests.swift`:

```swift
@Test func markPendingRelink_flipsLinkedRowToPendingRelink() throws {
    let store = try Store.openInMemory()
    let projects = ProjectRepository(store: store)
    try projects.insert(.init(id: "p", displayName: "P", description: "P",
                              createdAt: 1, archivedAt: nil))
    let repo = RecordingRepository(store: store)
    let rec = Recording(sourceId: "rec-1", filename: "M",
                        startedAt: 1, durationMs: 1, filesize: 1,
                        audioExtension: "opus", lastSeenAt: 1)
    try repo.upsertFromRemote(rec)
    try repo.setClassification(sourceId: "rec-1", projectId: "p",
                               confidence: 0.9, reasoning: "r", by: "test",
                               at: 10, linkState: .pendingRelink)
    try repo.markLinked(sourceId: "rec-1", linkedProjectId: "p")
    #expect(try #require(repo.find(sourceId: "rec-1")).projectLinkState == .linked)

    try repo.markPendingRelink(sourceId: "rec-1")

    #expect(try #require(repo.find(sourceId: "rec-1")).projectLinkState == .pendingRelink)
}
```

> **FK note:** `recordings.project_id` and `recordings.linked_project_id` are
> declared as foreign keys into `projects(id)` (`Store.swift:57,63`) and GRDB
> enforces them by default. Every test that passes a non-nil `projectId` or
> `linkedProjectId` to `setClassification` / `markLinked` must insert a
> matching project row first, otherwise the insert errors out with an FK
> constraint failure.

**Step 2: Run test to verify it fails**

Run: `swift test --package-path TapedeckCore --filter "markPendingRelink_flipsLinkedRowToPendingRelink"`
Expected: FAIL — `markPendingRelink` is not a member of `RecordingRepository`.

**Step 3: Implement the minimal code**

In `RecordingRepository.swift`, insert after `markLinked` (line 106):

```swift
public func markPendingRelink(sourceId: String) throws {
    try store.write { db in
        try db.execute(sql: """
            UPDATE recordings SET project_link_state = 'pending_relink'
            WHERE source_id = ?
        """, arguments: [sourceId])
    }
}
```

**Step 4: Run the test to verify it passes**

Run: `swift test --package-path TapedeckCore --filter "markPendingRelink_flipsLinkedRowToPendingRelink"`
Expected: PASS.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/RecordingRepository.swift \
        TapedeckCore/Tests/TapedeckCoreTests/RecordingRepositoryTests.swift
git commit -m "feat(repo): add markPendingRelink for retranscribe relink refresh"
```

---

## Task 2: `Pipeline.autoTranscribeEnabled`

Mirror `autoClassifyEnabled()` so `transcribeNew()` can short-circuit on the new flag.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/Pipeline.swift` (append after `autoClassifyEnabled`, ~line 101)
- Test: extend an existing suite — add to `TapedeckCore/Tests/TapedeckCoreTests/PipelineEndToEndTests.swift` *or* introduce the new `PipelineTranscribeTests.swift` here. Use the new file; it'll fill out across Tasks 4, 5, 7.

**Step 1: Write the failing test**

Create `TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift`:

```swift
// ABOUTME: Exercises auto_transcribe gating, bulk transcribePending, and explicit
// ABOUTME: transcribeOne(sourceId:) including error / relink paths.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("PipelineTranscribe")
struct PipelineTranscribeTests {

    private func makeStore() throws -> Store { try Store.openInMemory() }

    private func makePipeline(store: Store) -> Pipeline {
        let layout = Layout(
            userRoot: FileManager.default.temporaryDirectory.appending(path: "u-\(UUID())"),
            supportRoot: FileManager.default.temporaryDirectory.appending(path: "s-\(UUID())"),
            logsRoot: FileManager.default.temporaryDirectory.appending(path: "l-\(UUID())"))
        return Pipeline(deps: .init(
            store: store, layout: layout,
            source: SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                 host: URL(string: "https://api-euc1.plaud.ai")!,
                                 session: .shared),
            deepgram: DeepgramClient(apiKey: "dg", session: .shared),
            gemini: GeminiClient(apiKey: "gm", session: .shared),
            logger: CapturedLog(), now: { 100 }))
    }

    @Test func autoTranscribeEnabled_returnsFalse_whenAbsent() async throws {
        let store = try makeStore()
        let pipeline = makePipeline(store: store)
        #expect(try await pipeline.autoTranscribeEnabled() == false)
    }

    @Test func autoTranscribeEnabled_returnsTrue_whenSetTrue() async throws {
        let store = try makeStore()
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES('auto_transcribe','true')
            """)
        }
        let pipeline = makePipeline(store: store)
        #expect(try await pipeline.autoTranscribeEnabled() == true)
    }

    @Test func autoTranscribeEnabled_returnsFalse_whenSetFalse() async throws {
        let store = try makeStore()
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES('auto_transcribe','false')
            """)
        }
        let pipeline = makePipeline(store: store)
        #expect(try await pipeline.autoTranscribeEnabled() == false)
    }
}
```

> **Actor note:** `Pipeline` is declared `public actor Pipeline` in
> `Pipeline.swift:6`. Every method call from a test is asynchronous, including
> the synchronous-looking `autoTranscribeEnabled()` reader. Use
> `try await pipeline.method()` and mark the test `async throws`. The same
> applies to every other test in this plan that touches a `Pipeline` instance.

**Step 2: Run test to verify it fails**

Run: `swift test --package-path TapedeckCore --filter "PipelineTranscribe"`
Expected: FAIL — `autoTranscribeEnabled` does not exist.

**Step 3: Implement the minimal code**

In `Pipeline.swift`, after `autoClassifyEnabled()` (~line 101):

```swift
/// Reads `app_state.auto_transcribe`, defaulting to false when absent or non-`"true"`.
func autoTranscribeEnabled() throws -> Bool {
    let raw: String? = try deps.store.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'auto_transcribe'")
    }
    return raw == "true"
}
```

(`autoClassifyEnabled` is `internal`; match that — UI / settings code reads/writes `app_state` directly.)

**Step 4: Run the test to verify it passes**

Run: `swift test --package-path TapedeckCore --filter "PipelineTranscribe"`
Expected: PASS (three tests).

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/Pipeline.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift
git commit -m "feat(pipeline): add autoTranscribeEnabled flag reader"
```

---

## Task 3: Update existing tests to opt in to auto-transcribe

`PipelineEndToEndTests` and any other suite that relies on `runCycle()` actually transcribing must set `auto_transcribe = "true"` *before* Task 4 flips the gate, so the existing assertions don't start failing.

**Files:**
- Modify: `TapedeckCore/Tests/TapedeckCoreTests/PipelineEndToEndTests.swift`

**Step 1: Find every test that depends on transcription happening during `runCycle`**

Run: `grep -n "transcribedAt\|setTranscribed\|deepgram/short_recording\|recordingsNeedingTranscription" TapedeckCore/Tests/TapedeckCoreTests/PipelineEndToEndTests.swift`

For each test that lets `runCycle()` perform transcription (typically the ones that already set `auto_classify = "true"`), the SQL setup that inserts `auto_classify` should be extended to insert `auto_transcribe = "true"` as well.

Tests that bypass transcription by pre-setting `transcribed_at` (search hit on `setTranscribed`) do not need changes — they never expected `runCycle` to transcribe them.

**Step 2: Apply the fixture update**

For each affected test, replace the existing `auto_classify` insert with the
two-row form. Note that the e2e tests use a local `store` variable, not a
fixture wrapper — match the surrounding style:

```swift
try store.write { db in
    try db.execute(sql: """
        INSERT INTO app_state(key,value) VALUES
            ('auto_classify','true'),
            ('auto_transcribe','true')
    """)
}
```

**Step 3: Run the full e2e suite to confirm nothing else regresses**

Run: `swift test --package-path TapedeckCore --filter "PipelineEndToEnd"`
Expected: PASS — same as before the change (Task 4 hasn't gated `transcribeNew` yet, so the new fixture rows are no-ops).

**Step 4: Commit**

```bash
git add TapedeckCore/Tests/TapedeckCoreTests/PipelineEndToEndTests.swift
git commit -m "test(e2e): set auto_transcribe alongside auto_classify in fixtures"
```

---

## Task 4: Gate `Pipeline.transcribeNew()` on `auto_transcribe`

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift`
- Test: `TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift`

**Step 1: Write the failing test**

Add to `PipelineTranscribeTests`:

```swift
@Test func transcribeNew_doesNothing_whenAutoTranscribeAbsent() async throws {
    let store = try makeStore()
    let layout = Layout(
        userRoot: FileManager.default.temporaryDirectory.appending(path: "u-\(UUID())"),
        supportRoot: FileManager.default.temporaryDirectory.appending(path: "s-\(UUID())"),
        logsRoot: FileManager.default.temporaryDirectory.appending(path: "l-\(UUID())"))
    let log = CapturedLog()
    let pipeline = Pipeline(deps: .init(
        store: store, layout: layout,
        source: SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                             host: URL(string: "https://api-euc1.plaud.ai")!,
                             session: .shared),
        deepgram: DeepgramClient(apiKey: "dg", session: .shared),
        gemini: GeminiClient(apiKey: "gm", session: .shared),
        logger: log, now: { 100 }))
    let recordings = RecordingRepository(store: store)
    try recordings.upsertFromRemote(.init(
        sourceId: "rec-1", filename: "M",
        startedAt: 1, durationMs: 1, filesize: 1,
        audioExtension: "opus", lastSeenAt: 1))
    try recordings.setDownloaded(sourceId: "rec-1", ext: "opus", at: 2)

    try await pipeline.transcribeNew()

    #expect(try recordings.recordingsNeedingTranscription().count == 1)
    #expect(log.all.contains { $0.stage == "transcribe_skipped_auto_disabled" })
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --package-path TapedeckCore --filter "transcribeNew_doesNothing_whenAutoTranscribeAbsent"`
Expected: FAIL — without the gate, `transcribeNew` will try to call Deepgram on `.shared` (which will error somewhere) or no log line of that name will be emitted.

**Step 3: Implement the gate**

In `PipelineTranscribe.swift`, prepend the auto-flag check inside `transcribeNew()`:

```swift
func transcribeNew() async throws {
    guard try autoTranscribeEnabled() else {
        deps.logger.info("transcribe_skipped_auto_disabled", source: nil)
        return
    }
    let pending = ((try? recordings.recordingsNeedingTranscription()) ?? [])
        .filter { !shouldSkipAfterFailures(sourceId: $0.sourceId, stage: SyncStage.transcribe) }
    // existing body unchanged
    ...
}
```

**Step 4: Run the test + the e2e suite**

Run: `swift test --package-path TapedeckCore --filter "PipelineTranscribe|PipelineEndToEnd"`
Expected: PASS (both suites — Task 3 already opted the e2e tests in).

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift
git commit -m "feat(pipeline): gate transcribeNew on auto_transcribe (default off)"
```

---

## Task 5: `Pipeline.TranscribeError` + `performTranscribeOne` + public `transcribeOne(sourceId:)`

Refactor `PipelineTranscribe.swift` so the throwing core is separated from the silent batch wrapper, and expose a public single-recording entry point.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/Pipeline.swift` (declare `TranscribeError` next to `ClassifyError`)
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift`
- Test: `TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift`

**Step 1: Write the failing tests**

Add to `PipelineTranscribeTests`. First add the shared deepgram fixture stub helpers (mirror `PipelineClassifyTests` shape):

```swift
private struct Fixture {
    let layout: Layout
    let store: Store
    let recordings: RecordingRepository
    let session: URLSession
    let sessionId: String
    let log: CapturedLog
}

private func makeFixture() throws -> Fixture {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "tapedeck-tx-\(UUID())")
    let layout = Layout(userRoot: tmp.appending(path: "user"),
                        supportRoot: tmp.appending(path: "support"),
                        logsRoot: tmp.appending(path: "logs"))
    let store = try Store.openInMemory()
    let (session, sid) = URLProtocolStub.makeSession()
    return Fixture(layout: layout, store: store,
                   recordings: RecordingRepository(store: store),
                   session: session, sessionId: sid, log: CapturedLog())
}

private func makePipelineWith(_ fx: Fixture) -> Pipeline {
    Pipeline(deps: .init(
        store: fx.store, layout: fx.layout,
        source: SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                             host: URL(string: "https://api-euc1.plaud.ai")!,
                             session: fx.session),
        deepgram: DeepgramClient(apiKey: "dg", session: fx.session),
        gemini: GeminiClient(apiKey: "gm", session: fx.session),
        logger: fx.log, now: { 100 }))
}

private func stubDeepgramOK(_ fx: Fixture) {
    URLProtocolStub.register(sessionId: fx.sessionId, "deepgram-ok", matching: { req in
        req.url?.host == "api.deepgram.com"
    }, handler: { req in
        URLProtocolStub.jsonResponse(for: req, fixture: "deepgram/short_recording.json")
    })
}

private func stubDeepgramServerError(_ fx: Fixture) {
    URLProtocolStub.register(sessionId: fx.sessionId, "deepgram-500", matching: { req in
        req.url?.host == "api.deepgram.com"
    }, handler: { req in
        let resp = HTTPURLResponse(url: req.url!, statusCode: 500,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        return (resp, Data("oops".utf8))
    })
}

private func insertDownloadedRecording(_ fx: Fixture, audioBytes: Data? = Data([0,1,2,3])) throws -> Recording {
    let r = Recording(sourceId: "rec-1", filename: "Meeting",
                      startedAt: 1, durationMs: 60_000, filesize: 4,
                      audioExtension: "opus", lastSeenAt: 1)
    try fx.recordings.upsertFromRemote(r)
    try fx.recordings.setDownloaded(sourceId: "rec-1", ext: "opus", at: 2)
    if let bytes = audioBytes {
        let date = Date(timeIntervalSince1970: TimeInterval(r.startedAt) / 1000)
        let dir = fx.layout.audioDir(date: date)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = fx.layout.stem(sourceId: r.sourceId, title: r.filename)
        try bytes.write(to: dir.appending(path: "\(stem).opus"))
    }
    return r
}
```

Then the three failing tests:

```swift
@Test func transcribeOne_throws_whenSourceIdUnknown() async throws {
    let fx = try makeFixture()
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    do {
        try await makePipelineWith(fx).transcribeOne(sourceId: "nope")
        Issue.record("expected unknownRecording")
    } catch Pipeline.TranscribeError.unknownRecording(let sid) {
        #expect(sid == "nope")
    }
}

@Test func transcribeOne_throwsAndRecordsError_whenAudioMissing() async throws {
    let fx = try makeFixture()
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let rec = try insertDownloadedRecording(fx, audioBytes: nil) // no file on disk

    do {
        try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)
        Issue.record("expected audioMissing")
    } catch Pipeline.TranscribeError.audioMissing {
        // expected
    }

    let err = try fx.recordings.error(sourceId: rec.sourceId, stage: .transcribe)
    #expect(err?.attempt == 1)
}

@Test func transcribeOne_throwsAndRecordsError_onProviderFailure() async throws {
    let fx = try makeFixture()
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let rec = try insertDownloadedRecording(fx)
    stubDeepgramServerError(fx)

    do {
        try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)
        Issue.record("expected providerFailed")
    } catch Pipeline.TranscribeError.providerFailed {
        // expected
    }
    let err = try fx.recordings.error(sourceId: rec.sourceId, stage: .transcribe)
    #expect(err?.attempt == 1)
}

@Test func transcribeOne_succeeds_writesTranscript_clearsError() async throws {
    let fx = try makeFixture()
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let rec = try insertDownloadedRecording(fx)
    // pre-existing failure should be cleared on success
    try fx.recordings.recordError(sourceId: rec.sourceId, stage: .transcribe,
                                  at: 5, message: "earlier")
    stubDeepgramOK(fx)

    try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)

    let updated = try #require(try fx.recordings.find(sourceId: rec.sourceId))
    #expect(updated.transcribedAt != nil)
    #expect(try fx.recordings.error(sourceId: rec.sourceId, stage: .transcribe) == nil)
}

@Test func transcribeOne_retranscribes_whenAlreadyTranscribed() async throws {
    let fx = try makeFixture()
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let rec = try insertDownloadedRecording(fx)
    try fx.recordings.setTranscribed(sourceId: rec.sourceId, at: 50)
    stubDeepgramOK(fx)

    try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)

    let updated = try #require(try fx.recordings.find(sourceId: rec.sourceId))
    #expect(updated.transcribedAt == 100)  // updated to the now() the test pipeline uses
    let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
    let dir = fx.layout.audioDir(date: date)
    let stem = fx.layout.stem(sourceId: rec.sourceId, title: rec.filename)
    let txt = try String(contentsOf: dir.appending(path: "\(stem).transcript.txt"),
                         encoding: .utf8)
    #expect(!txt.isEmpty)
}

@Test func transcribeOne_ignoresFailureGate() async throws {
    let fx = try makeFixture()
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let rec = try insertDownloadedRecording(fx)
    for _ in 0..<3 {
        try fx.recordings.recordError(sourceId: rec.sourceId, stage: .transcribe,
                                      at: 5, message: "earlier failure")
    }
    stubDeepgramOK(fx)

    try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)

    let updated = try #require(try fx.recordings.find(sourceId: rec.sourceId))
    #expect(updated.transcribedAt != nil)
    #expect(try fx.recordings.error(sourceId: rec.sourceId, stage: .transcribe) == nil)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --package-path TapedeckCore --filter "transcribeOne"`
Expected: FAIL — `transcribeOne(sourceId:)` is not a public member of `Pipeline`, `Pipeline.TranscribeError` is undefined. All six new tests fail.

**Step 3: Implement**

In `Pipeline.swift`, add the new error type next to `ClassifyError` (~line 26):

```swift
public enum TranscribeError: Error, Equatable {
    case unknownRecording(String)
    case audioMissing(URL)
    case providerFailed(String)
}
```

In `PipelineTranscribe.swift`, refactor so the existing private `transcribeOne(_ rec:)` becomes a wrapper around a new throwing core, and add the public single-recording entry point. **Note the existing private method's signature shadows the new public one — rename the private wrapper to `transcribeOneSilently(_ rec:)` so call sites in `transcribeNew()` keep working.**

```swift
extension Pipeline {
    // unchanged transcribeNew above ...

    /// User-triggered single-recording transcription. Bypasses the failure
    /// gate; records errors to `recording_errors` and rethrows.
    public func transcribeOne(sourceId: String) async throws {
        guard let rec = try recordings.find(sourceId: sourceId) else {
            throw TranscribeError.unknownRecording(sourceId)
        }
        do {
            try await performTranscribeOne(rec)
        } catch {
            try? recordings.recordError(sourceId: sourceId, stage: .transcribe,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("transcribe_failed", source: sourceId, message: "\(error)")
            throw error
        }
    }

    /// Batch path. Silent on per-recording failure: records and continues.
    private func transcribeOneSilently(_ rec: Recording) async {
        do {
            try await performTranscribeOne(rec)
        } catch {
            try? recordings.recordError(sourceId: rec.sourceId, stage: .transcribe,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("transcribe_failed", source: rec.sourceId, message: "\(error)")
        }
    }

    private func performTranscribeOne(_ rec: Recording) async throws {
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let dir = deps.layout.audioDir(date: date)
        let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let audio = dir.appending(path: "\(stem).\(rec.audioExtension ?? "audio")")
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw TranscribeError.audioMissing(audio)
        }
        let result: DeepgramClient.Result
        do {
            result = try await RetryPolicy.run { [deepgram = deps.deepgram] in
                try await deepgram.transcribe(audioAt: audio, contentType: "audio/*")
            }
        } catch {
            throw TranscribeError.providerFailed("\(error)")
        }
        try result.raw.write(to: dir.appending(path: "\(stem).deepgram.json"))
        let txt = renderTranscript(result.utterances, fallback: result.transcript)
        try txt.write(to: dir.appending(path: "\(stem).transcript.txt"),
                      atomically: true, encoding: .utf8)
        try recordings.setTranscribed(sourceId: rec.sourceId, at: deps.now())
        try recordings.clearError(sourceId: rec.sourceId, stage: .transcribe)
        deps.logger.info("transcribe_ok", source: rec.sourceId)
    }
}
```

Update the call site inside `transcribeNew()` from `await self.transcribeOne(rec)` to `await self.transcribeOneSilently(rec)`.

**Step 4: Run the tests to verify they pass**

Run: `swift test --package-path TapedeckCore --filter "PipelineTranscribe|PipelineEndToEnd"`
Expected: PASS (all PipelineTranscribe tests + unbroken e2e suite).

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/Pipeline.swift \
        TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift
git commit -m "feat(pipeline): public transcribeOne(sourceId:) with throwing core"
```

---

## Task 6: `performTranscribeOne` marks `pendingRelink` for linked recordings

So retranscribing a linked recording schedules a relink refresh of the project-folder transcript copies.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift`
- Test: `TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift`

**Step 1: Write the failing tests**

```swift
@Test func transcribeOne_marksPendingRelink_whenAlreadyLinked() async throws {
    let fx = try makeFixture()
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let projects = ProjectRepository(store: fx.store)
    try projects.insert(.init(id: "p", displayName: "P", description: "P",
                              createdAt: 1, archivedAt: nil))
    let rec = try insertDownloadedRecording(fx)
    try fx.recordings.setClassification(sourceId: rec.sourceId, projectId: "p",
                                        confidence: 0.9, reasoning: "r",
                                        by: "test", at: 10, linkState: .pendingRelink)
    try fx.recordings.markLinked(sourceId: rec.sourceId, linkedProjectId: "p")
    stubDeepgramOK(fx)

    try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)

    let updated = try #require(try fx.recordings.find(sourceId: rec.sourceId))
    #expect(updated.projectLinkState == .pendingRelink)
}

@Test func transcribeOne_leavesLinkStateUnchanged_whenNotLinked() async throws {
    let fx = try makeFixture()
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let rec = try insertDownloadedRecording(fx)
    stubDeepgramOK(fx)

    try await makePipelineWith(fx).transcribeOne(sourceId: rec.sourceId)

    let updated = try #require(try fx.recordings.find(sourceId: rec.sourceId))
    #expect(updated.projectLinkState == .none)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --package-path TapedeckCore --filter "transcribeOne_marksPendingRelink_whenAlreadyLinked|transcribeOne_leavesLinkStateUnchanged_whenNotLinked"`
Expected: FAIL — `markPendingRelink` is not called by `performTranscribeOne`.

**Step 3: Implement**

In `PipelineTranscribe.swift`, inside `performTranscribeOne`, after `clearError(...)` and before the logger call:

```swift
if rec.linkedProjectId != nil {
    try recordings.markPendingRelink(sourceId: rec.sourceId)
}
```

**Step 4: Run the tests to verify they pass**

Run: `swift test --package-path TapedeckCore --filter "transcribeOne_marksPendingRelink_whenAlreadyLinked|transcribeOne_leavesLinkStateUnchanged_whenNotLinked"`
Expected: PASS.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift
git commit -m "feat(pipeline): mark pending_relink after retranscribe of linked rec"
```

---

## Task 7: `Pipeline.transcribePending()` public batch method

User-triggered bulk transcription — ignores `auto_transcribe`, ignores the failure gate.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift`
- Test: `TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift`

**Step 1: Write the failing tests**

```swift
@Test func transcribePending_runs_regardlessOfAutoTranscribe() async throws {
    let fx = try makeFixture()
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let rec = try insertDownloadedRecording(fx)
    // auto_transcribe intentionally absent
    stubDeepgramOK(fx)

    try await makePipelineWith(fx).transcribePending()

    #expect(try fx.recordings.recordingsNeedingTranscription().isEmpty)
}

@Test func transcribePending_bypassesFailureGate() async throws {
    let fx = try makeFixture()
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let rec = try insertDownloadedRecording(fx)
    for _ in 0..<3 {
        try fx.recordings.recordError(sourceId: rec.sourceId, stage: .transcribe,
                                      at: 5, message: "earlier")
    }
    stubDeepgramOK(fx)

    try await makePipelineWith(fx).transcribePending()

    #expect(try fx.recordings.recordingsNeedingTranscription().isEmpty)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --package-path TapedeckCore --filter "transcribePending_runs_regardlessOfAutoTranscribe|transcribePending_bypassesFailureGate"`
Expected: FAIL — `transcribePending()` does not exist.

**Step 3: Implement**

In `PipelineTranscribe.swift`, add:

```swift
/// User-triggered bulk transcription. Ignores `auto_transcribe` and the
/// `maxFailuresPerStage` filter — the click is itself the retry signal.
public func transcribePending() async throws {
    let pending = (try? recordings.recordingsNeedingTranscription()) ?? []
    await withTaskGroup(of: Void.self) { group in
        var inflight = 0
        for rec in pending {
            if inflight >= maxConcurrency { await group.next(); inflight -= 1 }
            group.addTask { [self] in await self.transcribeOneSilently(rec) }
            inflight += 1
        }
    }
}
```

**Step 4: Run the tests to verify they pass**

Run: `swift test --package-path TapedeckCore --filter "PipelineTranscribe"`
Expected: PASS (whole suite, including the new pair).

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/PipelineTranscribe.swift \
        TapedeckCore/Tests/TapedeckCoreTests/PipelineTranscribeTests.swift
git commit -m "feat(pipeline): public transcribePending bulk entry point"
```

---

## Task 8: `HelperCommand` cases + parser

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/HelperRunner.swift` (`HelperCommand` enum + `parseHelperArguments`)
- Test: `TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift`

**Step 1: Write the failing tests**

Append to the existing argument-parsing section:

```swift
@Test func transcribePendingFlagParses() {
    #expect(parseHelperArguments(["helper", "--transcribe-pending"]) == .transcribePending)
}

@Test func transcribeSourceFlagParsesWithId() {
    #expect(parseHelperArguments(["helper", "--transcribe-source", "abc"]) == .transcribeSource("abc"))
}

@Test func transcribeSourceWithoutIdFallsBackToFullCycle() {
    #expect(parseHelperArguments(["helper", "--transcribe-source"]) == .fullCycle)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --package-path TapedeckCore --filter "transcribePendingFlagParses|transcribeSourceFlagParsesWithId|transcribeSourceWithoutIdFallsBackToFullCycle"`
Expected: FAIL — `HelperCommand` has no `transcribePending` / `transcribeSource` cases.

**Step 3: Implement**

In `HelperRunner.swift`, extend `HelperCommand`:

```swift
public enum HelperCommand: Equatable, Sendable {
    case fullCycle
    case classifyPending
    case classifySource(String)
    case transcribePending
    case transcribeSource(String)
}
```

In `parseHelperArguments`, add cases inside the `switch`:

```swift
case "--transcribe-pending":
    return .transcribePending
case "--transcribe-source":
    if i + 1 < argv.count { return .transcribeSource(argv[i + 1]) }
    return .fullCycle
```

**Step 4: Run the tests to verify they pass**

Run: `swift test --package-path TapedeckCore --filter "HelperRunner"`
Expected: PASS — every parser test, including the existing classify ones (we only added cases).

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/HelperRunner.swift \
        TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift
git commit -m "feat(helper): HelperCommand cases + parsing for transcribe subcommands"
```

---

## Task 9: `runTranscribePending` + `buildTranscribePipeline`

Wire `.transcribePending` to its execution path.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/HelperRunner.swift`
- Test: `TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift`

**Step 1: Write the failing tests**

```swift
private func stubDeepgramOK(_ fx: Fixture) {
    URLProtocolStub.register(sessionId: fx.sessionId, "deepgram-ok", matching: { req in
        req.url?.host == "api.deepgram.com"
    }, handler: { req in
        URLProtocolStub.jsonResponse(for: req, fixture: "deepgram/short_recording.json")
    })
}

private func setupDownloadedRecording(_ fx: Fixture) throws -> Recording {
    let recordings = RecordingRepository(store: fx.store)
    let rec = Recording(sourceId: "rec-1", filename: "Meeting",
                        startedAt: 1, durationMs: 60_000, filesize: 4,
                        audioExtension: "opus", lastSeenAt: 1)
    try recordings.upsertFromRemote(rec)
    try recordings.setDownloaded(sourceId: "rec-1", ext: "opus", at: 2)
    let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
    let dir = fx.layout.audioDir(date: date)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stem = fx.layout.stem(sourceId: rec.sourceId, title: rec.filename)
    try Data([0,1,2,3]).write(to: dir.appending(path: "\(stem).opus"))
    return rec
}

@Test func transcribePending_returns3_whenDeepgramKeyMissing() async throws {
    let fx = try await makeFixture(secrets: [:])
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    _ = try setupDownloadedRecording(fx)

    let status = await runHelper(.transcribePending, deps: fx.deps)
    #expect(status == 3)
    #expect(fx.log.all.contains { $0.stage == "api_key_missing" })
}

@Test func transcribePending_returns0_andTranscribes_onSuccess() async throws {
    let fx = try await makeFixture(secrets: ["tapedeck.deepgram.key:default": "dg"])
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    _ = try setupDownloadedRecording(fx)
    stubDeepgramOK(fx)

    let status = await runHelper(.transcribePending, deps: fx.deps)
    #expect(status == 0)
    let recordings = RecordingRepository(store: fx.store)
    #expect(try recordings.recordingsNeedingTranscription().isEmpty)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --package-path TapedeckCore --filter "transcribePending_returns3_whenDeepgramKeyMissing|transcribePending_returns0_andTranscribes_onSuccess"`
Expected: FAIL — `runHelper` has no `.transcribePending` arm.

**Step 3: Implement**

Extend the switch in `runHelper`:

```swift
case .transcribePending: return await runTranscribePending(deps: deps)
case .transcribeSource(let sid): return await runTranscribeSource(sid, deps: deps)
```

Add the helpers (the source one is filled in Task 10; stub it here returning 1 so the switch compiles):

```swift
@MainActor
private func runTranscribePending(deps: HelperDeps) async -> Int32 {
    do {
        let lock = try SyncLock(path: deps.layout.lockURL())
        guard lock.tryAcquire() else {
            deps.logger.info("transcribe_skipped_already_running", source: nil)
            return 0
        }
        let store = try deps.openStore(deps.layout.dbURL())
        guard let pipeline = try buildTranscribePipeline(deps: deps, store: store) else {
            return 3
        }
        try await pipeline.transcribePending()
        try await pipeline.relinkChanged()
        deps.notify("recordings")
        return 0
    } catch {
        deps.logger.error("transcribe_pending_failed", source: nil, message: "\(error)")
        return 1
    }
}

@MainActor
private func runTranscribeSource(_ sourceId: String, deps: HelperDeps) async -> Int32 {
    // implemented in Task 10
    return 1
}

@MainActor
private func buildTranscribePipeline(deps: HelperDeps, store: Store) throws -> Pipeline? {
    guard let deepgramKey = try deps.readSecret("tapedeck.deepgram.key", "default") else {
        deps.logger.error("api_key_missing", source: nil, message: "Deepgram key missing")
        return nil
    }
    return Pipeline(deps: .init(
        store: store, layout: deps.layout,
        source: deps.makeSource(""),
        deepgram: deps.makeDeepgram(deepgramKey),
        gemini: deps.makeGemini(""),
        logger: deps.logger, now: deps.now))
}
```

**Step 4: Run the tests to verify they pass**

Run: `swift test --package-path TapedeckCore --filter "transcribePending_returns3_whenDeepgramKeyMissing|transcribePending_returns0_andTranscribes_onSuccess"`
Expected: PASS.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/HelperRunner.swift \
        TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift
git commit -m "feat(helper): --transcribe-pending subcommand"
```

---

## Task 10: `runTranscribeSource`

Single-recording variant + the linked-recording relink-refresh end-to-end assertion.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/HelperRunner.swift`
- Test: `TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift`

**Step 1: Write the failing tests**

```swift
@Test func transcribeSource_returns1_andRecordsError_whenSourceIdUnknown() async throws {
    let fx = try await makeFixture(secrets: ["tapedeck.deepgram.key:default": "dg"])
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }

    let status = await runHelper(.transcribeSource("missing"), deps: fx.deps)
    #expect(status == 1)
    #expect(fx.log.all.contains { $0.stage == "transcribe_source_failed" })
}

@Test func transcribeSource_returns0_onSuccess() async throws {
    let fx = try await makeFixture(secrets: ["tapedeck.deepgram.key:default": "dg"])
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let rec = try setupDownloadedRecording(fx)
    stubDeepgramOK(fx)

    let status = await runHelper(.transcribeSource(rec.sourceId), deps: fx.deps)
    #expect(status == 0)
}

@Test func transcribeSource_refreshesProjectFolderCopy_forLinkedRecording() async throws {
    let fx = try await makeFixture(secrets: ["tapedeck.deepgram.key:default": "dg"])
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    let rec = try setupDownloadedRecording(fx)
    stubDeepgramOK(fx)
    let recordings = RecordingRepository(store: fx.store)
    let projects = ProjectRepository(store: fx.store)
    try projects.insert(.init(id: "p", displayName: "P",
                              description: "P", createdAt: 1, archivedAt: nil))
    try recordings.setClassification(sourceId: rec.sourceId, projectId: "p",
                                     confidence: 0.9, reasoning: "r",
                                     by: "test", at: 10, linkState: .pendingRelink)
    // Seed the project folder with a stale copy so we can verify refresh.
    let projectDir = fx.layout.projectDir(slug: "p")
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let stem = fx.layout.stem(sourceId: rec.sourceId, title: rec.filename)
    let projectTranscript = projectDir.appending(path: "\(stem).transcript.txt")
    try "STALE".write(to: projectTranscript, atomically: true, encoding: .utf8)
    // First call links the recording into the project folder. After this the
    // recording is `.linked` and the project folder has the freshly-stubbed
    // transcript.
    let firstStatus = await runHelper(.transcribeSource(rec.sourceId), deps: fx.deps)
    #expect(firstStatus == 0)
    try "STALE-AGAIN".write(to: projectTranscript, atomically: true, encoding: .utf8)
    // Second call retranscribes; the linkedProjectId is now set, so
    // performTranscribeOne flips linkState back to pendingRelink and the
    // helper's relinkChanged pass overwrites the stale project-folder copy.
    let status = await runHelper(.transcribeSource(rec.sourceId), deps: fx.deps)
    #expect(status == 0)

    let updated = try #require(try recordings.find(sourceId: rec.sourceId))
    #expect(updated.projectLinkState == .linked)
    #expect(updated.linkedProjectId == "p")
    // The project-folder copy should match the source-folder transcript that
    // the second retranscribe wrote — proving the relink pass picked up the
    // refresh, not just that "STALE-AGAIN" got overwritten with anything.
    let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
    let stem = fx.layout.stem(sourceId: rec.sourceId, title: rec.filename)
    let sourceTranscript = fx.layout.audioDir(date: date)
        .appending(path: "\(stem).transcript.txt")
    let copyText = try String(contentsOf: projectTranscript, encoding: .utf8)
    let sourceText = try String(contentsOf: sourceTranscript, encoding: .utf8)
    #expect(copyText == sourceText)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --package-path TapedeckCore --filter "transcribeSource_returns1_andRecordsError_whenSourceIdUnknown|transcribeSource_returns0_onSuccess|transcribeSource_refreshesProjectFolderCopy_forLinkedRecording"`
Expected: FAIL — `runTranscribeSource` is still the stub returning 1.

**Step 3: Implement**

Replace the stub `runTranscribeSource` in `HelperRunner.swift`:

```swift
@MainActor
private func runTranscribeSource(_ sourceId: String, deps: HelperDeps) async -> Int32 {
    do {
        let lock = try SyncLock(path: deps.layout.lockURL())
        guard lock.tryAcquire() else {
            deps.logger.info("transcribe_skipped_already_running", source: sourceId)
            return 0
        }
        let store = try deps.openStore(deps.layout.dbURL())
        guard let pipeline = try buildTranscribePipeline(deps: deps, store: store) else {
            return 3
        }
        try await pipeline.transcribeOne(sourceId: sourceId)
        try await pipeline.relinkChanged()
        deps.notify("recordings")
        return 0
    } catch {
        deps.logger.error("transcribe_source_failed", source: sourceId, message: "\(error)")
        return 1
    }
}
```

**Step 4: Run the tests to verify they pass**

Run: `swift test --package-path TapedeckCore --filter "HelperRunner"`
Expected: PASS (whole HelperRunner suite).

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/HelperRunner.swift \
        TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift
git commit -m "feat(helper): --transcribe-source subcommand with relink refresh"
```

---

## Task 11: `runFullCycle` conditional key requirements

Drop the blanket "must have Deepgram + Gemini" gate; require each key only when its `auto_*` flag is on.

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/HelperRunner.swift` (`runFullCycle`)
- Test: `TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift`

**Step 1: Write the failing tests**

The existing `HelperRunner` test fixture (line ~58) already accepts a
`secrets: [String: String]` dict where each key is `"<service>:<account>"`. To
exercise `runFullCycle`, every test needs a source JWT entry
(`"tapedeck.source.jwt:default"`) plus stubs for the source endpoints used by
`discoverHost` and `listAll`. The simplest happy path returns an empty file
list, so the cycle has nothing to download / transcribe / classify and exits 0.

Add a fixture helper near the existing stubs:

```swift
private func stubSourceEmptyList(_ fx: Fixture) {
    URLProtocolStub.register(sessionId: fx.sessionId, "source-empty",
                             matching: { req in
        req.url?.path.contains("/file/simple/web") == true
    }, handler: { req in
        let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        return (resp, Data(#"{"data_file_list":[]}"#.utf8))
    })
}
```

Then the three tests:

```swift
@Test func fullCycle_succeeds_withoutDeepgramOrGemini_whenAutoFlagsAreOff() async throws {
    let fx = try await makeFixture(secrets: [
        "tapedeck.source.jwt:default": "t.eyJzdWIiOiJ4In0.sig"
    ])
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    stubSourceEmptyList(fx)

    let status = await runHelper(.fullCycle, deps: fx.deps)
    #expect(status == 0)
}

@Test func fullCycle_exitsThree_whenAutoTranscribeOnButDeepgramMissing() async throws {
    let fx = try await makeFixture(secrets: [
        "tapedeck.source.jwt:default": "t.eyJzdWIiOiJ4In0.sig"
    ])
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    try fx.store.write { db in
        try db.execute(sql: """
            INSERT INTO app_state(key,value) VALUES('auto_transcribe','true')
        """)
    }

    let status = await runHelper(.fullCycle, deps: fx.deps)
    #expect(status == 3)
    #expect(fx.log.all.contains {
        $0.stage == "api_key_missing" && ($0.message ?? "").contains("Deepgram")
    })
}

@Test func fullCycle_exitsThree_whenAutoClassifyOnButGeminiMissing() async throws {
    let fx = try await makeFixture(secrets: [
        "tapedeck.source.jwt:default": "t.eyJzdWIiOiJ4In0.sig",
        "tapedeck.deepgram.key:default": "dg"
    ])
    defer { URLProtocolStub.clear(sessionId: fx.sessionId) }
    try fx.store.write { db in
        try db.execute(sql: """
            INSERT INTO app_state(key,value) VALUES
                ('auto_transcribe','true'),
                ('auto_classify','true')
        """)
    }

    let status = await runHelper(.fullCycle, deps: fx.deps)
    #expect(status == 3)
    #expect(fx.log.all.contains {
        $0.stage == "api_key_missing" && ($0.message ?? "").contains("Gemini")
    })
}
```

Notes for the implementer:
- `Fixture.deps` already wires `readSecret` to the in-memory `SecretsBox`
  populated from the `secrets:` dict passed to `makeFixture`.
- `Fixture.store` is open for direct SQL inserts (used by the existing
  classify tests too).
- `CapturedLog`'s `all` exposes log lines with `stage` and `message` strings
  — the existing classify tests use the same pattern (see
  `classifyPending_returns3_whenGeminiKeyMissing`).
- `discoverHost` is the first source call; if the empty-list stub above
  doesn't match the discoverHost probe, look at
  `SourceClientDiscoveryTests.swift` (lines ~13–25) which registers
  `redirect_302.json` for the discovery probe followed by the list endpoint.
  If `discoverHost` errors out before reaching `listAll`, copy that pattern
  exactly. The current `PipelineEndToEndTests` happy-path test does *not*
  stub a separate discovery response, which suggests the empty 200 from the
  list endpoint also satisfies `discoverHost` — verify when running.

**Step 2: Run tests to verify they fail**

Run: `swift test --package-path TapedeckCore --filter "fullCycle_succeeds_withoutDeepgramOrGemini_whenAutoFlagsAreOff|fullCycle_exitsThree_whenAutoTranscribeOnButDeepgramMissing|fullCycle_exitsThree_whenAutoClassifyOnButGeminiMissing"`
Expected: FAIL — `runFullCycle` still exits 3 unconditionally.

**Step 3: Implement**

In `HelperRunner.swift`, rewrite the secrets-check block of `runFullCycle` (currently lines 80–88):

```swift
let store = try deps.openStore(deps.layout.dbURL())
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
    gemini: deps.makeGemini(geminiKey ?? ""),
    logger: deps.logger, now: deps.now))
```

And add the file-private helper at the bottom of `HelperRunner.swift`:

```swift
private func autoFlag(store: Store, key: String) -> Bool {
    let raw: String? = (try? store.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?",
                            arguments: [key])
    }) ?? nil
    return raw == "true"
}
```

**Step 4: Run all helper tests + e2e**

Run: `swift test --package-path TapedeckCore --filter "HelperRunner|PipelineEndToEnd"`
Expected: PASS — the existing fullCycle tests already set both auto flags (Task 3), so they still get past the key checks; the new tests cover the conditional gate.

**Step 5: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/HelperRunner.swift \
        TapedeckCore/Tests/TapedeckCoreTests/HelperRunnerTests.swift
git commit -m "feat(helper): only require Deepgram/Gemini keys when their auto flag is on"
```

---

## Task 12: `SyncCoordinator` Kind cases + dispatch methods

App-side actor gains the two new operation kinds.

**Files:**
- Modify: `Tapedeck/SyncCoordinator.swift`
- Test: `Tapedeck/Tests/SyncCoordinatorTests.swift`

**Step 1: Write the failing test**

Append to `SyncCoordinatorTests.swift`:

```swift
func testTranscribePending_throws_whenSyncInFlight() async throws {
    let gate = Gate()
    let coord = SyncCoordinator(spawner: { kind, _ in
        if kind == .sync { await gate.wait() }
        return 0
    })

    async let _ = try? coord.runOnce(reason: "first")
    try await Task.sleep(nanoseconds: 10_000_000)

    do {
        _ = try await coord.transcribePending(reason: "second")
        XCTFail("expected otherOperationRunning")
    } catch SyncCoordinator.CoordinatorError.otherOperationRunning(let kind) {
        XCTAssertEqual(kind, .sync)
    }
    await gate.open()
}
```

(`Gate` is the existing test helper at the bottom of
`Tapedeck/Tests/SyncCoordinatorTests.swift` — same one used by the existing
classify-pending-throws-when-sync-in-flight test.)

**Step 2: Run test to verify it fails**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/SyncCoordinatorTests/testTranscribePending_throws_whenSyncInFlight | xcpretty`
Expected: FAIL — `transcribePending(reason:)` is not a member of `SyncCoordinator`.

**Step 3: Implement**

In `Tapedeck/SyncCoordinator.swift`:

```swift
enum Kind: Equatable, Sendable {
    case sync
    case classifyPending
    case classifySource(String)
    case transcribePending
    case transcribeSource(String)

    var helperArgs: [String] {
        switch self {
        case .sync: return []
        case .classifyPending: return ["--classify-pending"]
        case .classifySource(let id): return ["--classify-source", id]
        case .transcribePending: return ["--transcribe-pending"]
        case .transcribeSource(let id): return ["--transcribe-source", id]
        }
    }
}
```

And add two new public methods, mirroring `classifyPending` / `classifyOne`:

```swift
@discardableResult
func transcribePending(reason: String) async throws -> Int32 {
    try await dispatch(.transcribePending, reason: reason)
}

@discardableResult
func transcribeOne(sourceId: String, reason: String) async throws -> Int32 {
    try await dispatch(.transcribeSource(sourceId), reason: reason)
}
```

**Step 4: Run the test to verify it passes**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test -only-testing:TapedeckTests/SyncCoordinatorTests | xcpretty`
Expected: PASS (all existing + new SyncCoordinator tests).

**Step 5: Commit**

```bash
git add Tapedeck/SyncCoordinator.swift Tapedeck/Tests/SyncCoordinatorTests.swift
git commit -m "feat(coord): transcribePending / transcribeOne dispatch kinds"
```

---

## Task 13: `AppState.transcribePending` + `transcribeOne` wrappers

**Files:**
- Modify: `Tapedeck/AppState.swift`

**Step 1: Write the failing test**

This pair is a thin two-line wrapper around the coordinator and the existing `dispatch` helper. There is no behavior in `AppState` worth covering with a unit test beyond what `SyncCoordinatorTests` already exercises (the actor is the testable seam). Skip the test step and rely on integration verification in Tasks 14–16.

**Step 2: Implement**

In `Tapedeck/AppState.swift`, after `classifyOne` (~line 150):

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

**Step 3: Verify the app still builds**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" build | xcpretty`
Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add Tapedeck/AppState.swift
git commit -m "feat(appstate): transcribePending / transcribeOne wrappers"
```

---

## Task 14: Toolbar Transcribe button

**Files:**
- Modify: `Tapedeck/TapedeckApp.swift` (MainView toolbar, ~lines 51–87)

**Step 1: Implement**

In `MainView.body`, add a new `ToolbarItem(placement: .primaryAction)` *before* the existing Classify item, so the final order is status → Transcribe → Classify → Sync now:

```swift
ToolbarItem(placement: .primaryAction) {
    if appState.busy == .transcribePending {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Transcribing…").foregroundStyle(.secondary)
        }
    } else {
        Button("Transcribe") {
            Task { await appState.transcribePending(reason: "ui_transcribe_pending") }
        }
        .disabled(appState.busy != nil
                  || appState.statusCounts.toTranscribe == 0)
        .help("\(appState.statusCounts.toTranscribe) recording\(appState.statusCounts.toTranscribe == 1 ? "" : "s") to transcribe")
    }
}
```

Place this block *immediately above* the existing classify `ToolbarItem` (currently at line 58).

**Step 2: Manual verification**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" build | xcpretty`
Expected: BUILD SUCCEEDED.

Then launch the app (`open` the built bundle or run from Xcode) with at least one recording in the downloaded-but-not-transcribed state. Verify:
- The Transcribe button appears before Classify.
- It's enabled when `toTranscribe > 0`.
- It's disabled when `toTranscribe == 0`.
- Clicking it triggers the helper (you can grep the log for `transcribe_pending_failed` or success).
- During the call, the button is replaced by the "Transcribing…" spinner; afterwards it returns.

If you cannot run the app interactively, document this explicitly in the commit message.

**Step 3: Commit**

```bash
git add Tapedeck/TapedeckApp.swift
git commit -m "feat(ui): toolbar Transcribe button + Transcribing… spinner"
```

---

## Task 15: DetailPane Transcribe button + transcript reload on retranscribe

**Files:**
- Modify: `Tapedeck/Views/DetailPane.swift`

**Step 1: Implement**

In the `HStack(spacing: 8)` block (currently lines 51–64), insert a new button *between* Play and Classify:

```swift
Button(rec.transcribedAt == nil ? "Transcribe" : "Retranscribe") {
    Task { await appState.transcribeOne(sourceId: rec.sourceId,
                                        reason: "ui_transcribe_one") }
}
.disabled(appState.busy != nil
          || rec.audioDownloadedAt == nil)
```

Then add a transcript reloader at the bottom of `detailView`, alongside the existing `.onAppear` and `.onChange(of: rec.sourceId)` (line ~71):

```swift
.onChange(of: rec.transcribedAt) { _, _ in loadTranscript(rec) }
```

**Step 2: Manual verification**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" build | xcpretty`
Expected: BUILD SUCCEEDED.

Launch the app. Select a downloaded-but-not-yet-transcribed recording: the button reads "Transcribe" and is enabled. Click it; the transcript text editor should populate after the helper completes. Select a recording that's already transcribed: the button reads "Retranscribe" and is enabled. Click it; the transcript should refresh in place (the `.onChange` is what makes this work).

**Step 3: Commit**

```bash
git add Tapedeck/Views/DetailPane.swift
git commit -m "feat(ui): DetailPane Transcribe/Retranscribe + reload on transcribedAt"
```

---

## Task 16: TranscriptionTab auto-transcribe toggle

**Files:**
- Modify: `Tapedeck/Views/Settings/TranscriptionTab.swift`

**Step 1: Implement**

Mirror `ClassifierTab`'s auto-classify section. First, add `import GRDB` at the
top of the file alongside the existing imports — the new `readAutoTranscribe`
/ `writeAutoTranscribe` helpers use `String.fetchOne` and `db.execute`, both of
which come from GRDB (and which is why `ClassifierTab` imports it too).

Add `@State` properties:

```swift
@State private var autoTranscribe: Bool = false
```

Inside `Form`, after the Deepgram section, add a new `Section`:

```swift
Section {
    Toggle("Transcribe new recordings automatically", isOn: $autoTranscribe)
} footer: {
    Text("When off, recordings wait until you click Transcribe in the toolbar or on a recording. Each call to Deepgram costs money.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

In the existing `.onAppear`, append:

```swift
autoTranscribe = readAutoTranscribe()
```

Add an `.onChange` directly on the form:

```swift
.onChange(of: autoTranscribe) { _, newValue in writeAutoTranscribe(newValue) }
```

Add private helpers (copy-paste-adapt from `ClassifierTab.readAutoClassify` / `writeAutoClassify`):

```swift
private func readAutoTranscribe() -> Bool {
    guard let store = try? Store.open(at: Layout.standard.dbURL()) else { return false }
    let raw: String? = (try? store.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'auto_transcribe'")
    }) ?? nil
    return raw == "true"
}

private func writeAutoTranscribe(_ value: Bool) {
    guard let store = try? Store.open(at: Layout.standard.dbURL()) else { return }
    try? store.write { db in
        try db.execute(sql: """
            INSERT INTO app_state(key,value) VALUES('auto_transcribe', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [value ? "true" : "false"])
    }
}
```

**Step 2: Manual verification**

Run: `xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" build | xcpretty`
Expected: BUILD SUCCEEDED.

Open Settings → Transcription. The toggle appears and persists across app relaunches. Flip it on and confirm `runCycle()` actually transcribes pending recordings (use the existing `Sync now` button to trigger a cycle).

**Step 3: Commit**

```bash
git add Tapedeck/Views/Settings/TranscriptionTab.swift
git commit -m "feat(settings): auto-transcribe toggle on Transcription tab"
```

---

## Final verification

After all 16 tasks land, run the full test suite end-to-end:

```bash
swift test --package-path TapedeckCore
xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -destination "platform=macOS" test | xcpretty
```

Expected: every suite green.

Then launch the app and walk the golden path:

1. Open Settings → Transcription. Confirm the toggle reads as off by default after a fresh `auto_transcribe` row is absent (delete the row from the db if needed).
2. Verify a recording downloaded but not yet transcribed has the DetailPane "Transcribe" button enabled.
3. Click toolbar "Transcribe". Confirm the count drops, button spinner appears, and the transcript text editor populates when the recording is selected.
4. Classify the recording. Confirm the project folder under `~/Tapedeck/projects/<slug>/` has the transcript + deepgram.json copies.
5. Click "Retranscribe" on the DetailPane. Confirm the project-folder transcript copy is updated (compare contents — should match the newly-stubbed text, or pull the file's mtime to confirm).
6. Open Settings → Transcription, flip auto-transcribe on. Add a new downloaded recording. Run Sync now. Confirm the recording auto-transcribes without the user clicking Transcribe.

If anything in steps 1–6 fails, treat it as a bug in the corresponding task and revisit the task's code + tests rather than patching elsewhere.
