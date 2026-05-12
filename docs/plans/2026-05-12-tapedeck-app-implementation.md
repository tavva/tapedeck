# Tapedeck Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship a native macOS app `Tapedeck.app` that pulls voice recordings from the Plaud cloud, transcribes them with Deepgram, classifies them into projects with Gemini, and writes deterministic per-project folders — with background sync that runs whether the app is open or not.

**Architecture:** Two co-signed Mach-O binaries in one `.app` (`Tapedeck` SwiftUI UI + `TapedeckSyncHelper` CLI) sharing a single Swift package (`TapedeckCore`) and one SQLite store. A LaunchAgent drives the helper every 15 minutes. Sparkle handles auto-update. Cross-process state is communicated via `DistributedNotificationCenter` plus belt-and-braces polling.

**Tech Stack:** Swift 6 / SwiftUI / GRDB.swift (SQLite) / WKWebView / AVPlayer / URLSession / Sparkle 2 / XcodeGen / Swift Testing (`import Testing`) / Developer ID + hardened runtime + notarisation. Team ID `C8Q84FVJHL`.

**Reference repos:** `~/repos/countdown` (Sparkle/XcodeGen/build-release patterns) and `~/repos/plaud-downloader` (Plaud API contract — must be captured before its repo is archived, see Phase 0).

**Design doc:** `docs/plans/2026-05-12-tapedeck-app-design.md` — read this first.

---

## Conventions

Every Swift file starts with:

```swift
// ABOUTME: <one line — what this file does>
// ABOUTME: <one line — non-obvious context, dependencies, or invariants>
```

Every test method exercises one specific behaviour. Test bodies are arrange-act-assert with no shared mutable setup beyond a fresh in-memory `Store` per test.

Each task in this plan is one tight commit. The commit message subject line is given. After every task: `git status` must be clean and `swift test --package-path TapedeckCore` must pass (once Phase 1 is done).

The "Expected" line under each `Run:` is what success looks like — if the actual output differs, stop and investigate, do not push past it.

---

## Phase 0 — Capture legacy artefacts (design §9)

These artefacts unblock every later phase that touches the Plaud API. They must be committed before Phase 7 (which deletes the old downloader) and before any of the bootstrap moves in design §7.

### Task 0.0: Create fixture directories

```bash
mkdir -p TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source \
         TapedeckCore/Tests/TapedeckCoreTests/Fixtures/deepgram \
         TapedeckCore/Tests/TapedeckCoreTests/Fixtures/gemini
```

No commit yet — Git doesn't track empty directories. The first fixture commit in Task 0.1 creates them implicitly.

### Task 0.1: Capture a real `/file/simple/web` listing response

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/list_page1.json`

**Step 1: Pull the user's JWT from the existing Python downloader's config**

Run: `cat ~/.config/plaud/token | head -c 40 ; echo` — confirms a token exists (truncated so it doesn't end up in your scrollback). Ask Ben to paste it if the file is missing.

**Step 2: Fetch a page of recordings**

```bash
TOKEN=$(cat ~/.config/plaud/token)
curl -sSf 'https://api.plaud.ai/file/simple/web?skip=0&limit=2&is_trash=0&sort_by=start_time&is_desc=true' \
  -H "Authorization: bearer ${TOKEN}" \
  -H 'app-platform: web' \
  -H 'edit-from: web' \
  -H 'Origin: https://web.plaud.ai' \
  -H 'Referer: https://web.plaud.ai/' \
  -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15' \
  | jq . > TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/list_page1.json
```

Expected: a JSON object with a `data_file_list` array of two items each containing `id`, `filename`, `start_time`, `duration`, `filesize`, `is_trans`, `is_summary`, `filetag_id_list`.

**Step 3: Sanity check the shape**

Run: `jq '.data_file_list | length, .data_file_list[0] | keys' TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/list_page1.json`
Expected: `2` then a key list including the fields above.

**Step 4: Commit**

```bash
git add TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/list_page1.json
git commit -m "test(fixtures): capture Plaud list response"
```

### Task 0.2: Capture a `-302` region-redirect response

The `-302` is a JSON status, not an HTTP redirect. If Ben's account is non-US the redirect is what you actually receive on Task 0.1 if you don't already know the regional host.

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/redirect_302.json`

**Step 1: Synthesise from the live response shape**

If the Task 0.1 fetch *was* the redirect (status=-302, no `data_file_list`), copy that file to `redirect_302.json` and refetch Task 0.1 against `api-euc1.plaud.ai` (or whatever host appeared in `data.domains.api`).

Otherwise hand-craft this file from the documented shape:

```json
{
  "status": -302,
  "data": {
    "domains": {
      "api": "https://api-euc1.plaud.ai"
    }
  }
}
```

**Step 2: Commit**

```bash
git add TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/redirect_302.json
git commit -m "test(fixtures): capture Plaud -302 region redirect"
```

### Task 0.3: Capture a `/file/temp-url/{id}` response

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/temp_url.json`

**Step 1: Pick an id from Task 0.1**

```bash
ID=$(jq -r '.data_file_list[0].id' TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/list_page1.json)
HOST="https://api-euc1.plaud.ai"   # adjust to the host that worked in Task 0.1
TOKEN=$(cat ~/.config/plaud/token)
curl -sSf "${HOST}/file/temp-url/${ID}" \
  -H "Authorization: bearer ${TOKEN}" \
  -H 'app-platform: web' -H 'edit-from: web' \
  | jq . > TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/temp_url.json
```

Expected: `{"temp_url": "https://...amazonaws.com/.../<id>.<ext>?X-Amz-..."}`

**Step 2: Note the extension in the file path** — record it in `docs/plans/2026-05-12-tapedeck-app-implementation.md` if it's not already in the known set `{ogg, opus, mp3, m4a, aac, wav}`. The known set comes from `plaud-downloader`'s `KNOWN_AUDIO_EXTS`.

**Step 3: Commit**

```bash
git add TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/temp_url.json
git commit -m "test(fixtures): capture Plaud temp-url response"
```

### Task 0.4: Capture a `POST /file/list` raw metadata response

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/raw_metadata.json`

**Step 1: Fetch**

```bash
ID=$(jq -r '.data_file_list[0].id' TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/list_page1.json)
HOST="https://api-euc1.plaud.ai"
TOKEN=$(cat ~/.config/plaud/token)
curl -sSf -X POST "${HOST}/file/list" \
  -H "Authorization: bearer ${TOKEN}" \
  -H 'app-platform: web' -H 'edit-from: web' \
  -H 'Content-Type: application/json' \
  -d "[\"${ID}\"]" \
  | jq . > TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/raw_metadata.json
```

**Step 2: Commit**

```bash
git add TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/raw_metadata.json
git commit -m "test(fixtures): capture Plaud raw metadata response"
```

### Task 0.5: Capture a redacted JWT payload for region-decode tests

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/jwt_payload_redacted.json`

**Step 1: Decode the user's JWT payload (base64url, with padding), scrub identifiers**

```bash
TOKEN=$(cat ~/.config/plaud/token)
PAYLOAD=$(echo "$TOKEN" | cut -d. -f2)
# JWT base64url has no padding. Pad up to the next multiple of 4 (0–3 '=' chars),
# then translate the URL-safe alphabet to standard base64.
NEED=$(( (4 - ${#PAYLOAD} % 4) % 4 ))
PADDING=""
if [ "$NEED" -gt 0 ]; then PADDING=$(printf '%*s' "$NEED" '' | tr ' ' '='); fi
PADDED=$(printf '%s%s' "$PAYLOAD" "$PADDING" | tr '_-' '/+')
echo "$PADDED" | base64 -D 2>/dev/null | jq . > /tmp/raw.json
# Inspect /tmp/raw.json; identify the region field — likely 'aws:region' or 'region'.
# Build a redacted version preserving the region claim verbatim (incl. the 'aws:' prefix
# if present — SourceClient.regionToHost handles both forms).
jq '{
  iss: "redacted",
  sub: "redacted",
  region: .region // ."aws:region",
  "aws:region": ."aws:region",
  exp: .exp,
  iat: .iat
} | with_entries(select(.value != null))' /tmp/raw.json \
  > TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/jwt_payload_redacted.json
rm /tmp/raw.json
```

**Step 2: Note the exact claim name used for region in a comment in the file**

Add a JSON comment is impossible, so add a sibling file `TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/jwt_payload_redacted.notes.md` recording: the actual claim name (e.g. `aws:region`), what its value was (`eu-central-1`), and whether other claims (`iss`, `aud`) might be useful for future routing.

**Step 3: Commit**

```bash
git add TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/jwt_payload_redacted.json \
        TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/jwt_payload_redacted.notes.md
git commit -m "test(fixtures): capture redacted JWT payload"
```

### Task 0.6: Capture Deepgram and Gemini sample responses

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Fixtures/deepgram/short_recording.json`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Fixtures/gemini/high_confidence.json`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Fixtures/gemini/low_confidence.json`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Fixtures/gemini/null_project.json`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Fixtures/gemini/malformed.json`

**Step 1: Deepgram** — find the shortest audio file in `~/Plaud/audio/`:

```bash
find ~/Plaud/audio -type f \( -name '*.ogg' -o -name '*.mp3' -o -name '*.m4a' -o -name '*.wav' -o -name '*.opus' -o -name '*.aac' \) -print0 \
  | xargs -0 ls -lS | tail -1
```

Then POST the shortest one to Deepgram (Ben must have an API key in his shell):

```bash
SHORT=$(find ~/Plaud/audio -type f \( -name '*.ogg' -o -name '*.mp3' -o -name '*.m4a' -o -name '*.wav' \) -print0 | xargs -0 ls -lS | tail -1 | awk '{print $NF}')
curl -sSf 'https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&diarize=true&utterances=true' \
  -H "Authorization: Token ${DEEPGRAM_API_KEY}" \
  -H 'Content-Type: audio/*' \
  --data-binary "@${SHORT}" \
  | jq . > TapedeckCore/Tests/TapedeckCoreTests/Fixtures/deepgram/short_recording.json
```

The fixture must include `results.utterances[]` because `DeepgramClient` decodes that field. If the captured response doesn't have it, re-run with `utterances=true` (it has been on by default since model nova-2; verify against your account's response).

**Step 2: Gemini** — hand-author the four classifier *output* payloads. These are the inner JSON strings the model returns; the `GeminiClientTests` wrap each one in a stub `generateContent` envelope before serving it, because `GeminiClient.classify` parses the standard Gemini response shape `{ candidates: [{ content: { parts: [{ text: "<this JSON>" }] }}] }`. Saving just the inner JSON keeps fixtures tiny and intent obvious.

```bash
cat > TapedeckCore/Tests/TapedeckCoreTests/Fixtures/gemini/high_confidence.json <<'EOF'
{"project_id": "homeschool-mvp", "confidence": 0.92, "reasoning": "Speaker references curriculum planning and ages-7-and-9 sessions, both mentioned in the project description."}
EOF
cat > TapedeckCore/Tests/TapedeckCoreTests/Fixtures/gemini/low_confidence.json <<'EOF'
{"project_id": "investors", "confidence": 0.41, "reasoning": "Vague mention of fundraising; could be journaling about it rather than the project itself."}
EOF
cat > TapedeckCore/Tests/TapedeckCoreTests/Fixtures/gemini/null_project.json <<'EOF'
{"project_id": null, "confidence": 0.0, "reasoning": "Transcript is a personal voice note unrelated to any provided project."}
EOF
cat > TapedeckCore/Tests/TapedeckCoreTests/Fixtures/gemini/malformed.json <<'EOF'
Here's my analysis: project_id=homeschool-mvp confidence=0.8 (this is not JSON)
EOF
```

**Step 3: Commit**

```bash
git add TapedeckCore/Tests/TapedeckCoreTests/Fixtures/deepgram \
        TapedeckCore/Tests/TapedeckCoreTests/Fixtures/gemini
git commit -m "test(fixtures): capture Deepgram + Gemini sample responses"
```

---

## Phase 1 — Repo scaffolding

### Task 1.1: Extend `.gitignore` for Swift/Xcode/build artefacts

**Files:**
- Modify: `.gitignore`

**Step 1: Write the file**

```gitignore
# Xcode
xcuserdata/
*.xcworkspace
DerivedData/
build/
*.profraw
*.xcuserstate

# XcodeGen generates these
Tapedeck.xcodeproj/

# Swift Package Manager
.build/
Package.resolved
.swiftpm/

# Tooling
scripts/sparkle-tools/

# Secrets / local-only
Tapedeck/Config.plist
.env
```

**Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: gitignore Xcode/SwiftPM artefacts"
```

### Task 1.2: Create the `TapedeckCore` Swift package

**Files:**
- Create: `TapedeckCore/Package.swift`
- Create: `TapedeckCore/Sources/TapedeckCore/TapedeckCore.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/SmokeTests.swift`

**Step 1: Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapedeckCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TapedeckCore", targets: ["TapedeckCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "TapedeckCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TapedeckCoreTests",
            dependencies: ["TapedeckCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

**Step 2: Empty entry point**

```swift
// ABOUTME: Re-exports the public surface of the TapedeckCore package.
// ABOUTME: Implementation lives in sibling files (Store, SourceClient, etc).

public enum TapedeckCore {
    public static let schemaVersion = 1
}
```

**Step 3: Smoke test**

```swift
// ABOUTME: Build-the-package smoke test. Must pass once the package compiles.
// ABOUTME: Real tests live in feature-specific files.

import Testing
@testable import TapedeckCore

@Suite("TapedeckCore smoke")
struct SmokeTests {
    @Test func schemaVersionIsExposed() {
        #expect(TapedeckCore.schemaVersion == 1)
    }
}
```

**Step 4: Verify the package builds and tests pass**

Run: `swift test --package-path TapedeckCore`
Expected: builds; one test runs and passes.

**Step 5: Commit**

```bash
git add TapedeckCore/Package.swift TapedeckCore/Sources TapedeckCore/Tests/TapedeckCoreTests/SmokeTests.swift
git commit -m "feat(core): scaffold TapedeckCore Swift package"
```

### Task 1.3: Write `project.yml` for XcodeGen

**Files:**
- Create: `project.yml`
- Create: `Tapedeck/Info.plist`
- Create: `Tapedeck/Tapedeck.entitlements`
- Create: `TapedeckSyncHelper/Info.plist`
- Create: `TapedeckSyncHelper/TapedeckSyncHelper.entitlements`
- Create: `ExportOptions.plist`

**Step 1: project.yml**

```yaml
name: Tapedeck
options:
  deploymentTarget:
    macOS: "14.0"
  bundleIdPrefix: com.benphillips.tapedeck
settings:
  SWIFT_VERSION: "6.0"
  DEVELOPMENT_TEAM: "C8Q84FVJHL"
  CODE_SIGN_STYLE: Manual
  CODE_SIGN_IDENTITY: "Developer ID Application"
  ENABLE_HARDENED_RUNTIME: YES
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.6.0"
  TapedeckCore:
    path: TapedeckCore
targets:
  Tapedeck:
    type: application
    platform: macOS
    sources:
      - Tapedeck
    info:
      path: Tapedeck/Info.plist
      properties:
        CFBundleShortVersionString: 0.1.0
        CFBundleVersion: 0.1.0
        SUEnableAutomaticChecks: true
        SUFeedURL: https://tavva.github.io/tapedeck/appcast.xml
        SUPublicEDKey: REPLACE_ME_WITH_OUTPUT_OF_generate_keys
    settings:
      INFOPLIST_FILE: Tapedeck/Info.plist
      PRODUCT_BUNDLE_IDENTIFIER: com.benphillips.tapedeck
      PRODUCT_NAME: Tapedeck
    entitlements:
      path: Tapedeck/Tapedeck.entitlements
    dependencies:
      - package: Sparkle
      - package: TapedeckCore
      - target: TapedeckSyncHelper
        embed: true
        codeSign: true
        copy:
          destination: executables
  TapedeckSyncHelper:
    type: tool
    platform: macOS
    sources:
      - TapedeckSyncHelper
    info:
      path: TapedeckSyncHelper/Info.plist
      properties:
        CFBundleShortVersionString: 0.1.0
        CFBundleVersion: 0.1.0
    settings:
      INFOPLIST_FILE: TapedeckSyncHelper/Info.plist
      PRODUCT_BUNDLE_IDENTIFIER: com.benphillips.tapedeck.synchelper
      PRODUCT_NAME: TapedeckSyncHelper
    entitlements:
      path: TapedeckSyncHelper/TapedeckSyncHelper.entitlements
    dependencies:
      - package: TapedeckCore
  TapedeckTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - Tapedeck/Tests
    dependencies:
      - target: Tapedeck
    settings:
      GENERATE_INFOPLIST_FILE: YES
      PRODUCT_BUNDLE_IDENTIFIER: com.benphillips.tapedeck.tests
```

**Step 2: Tapedeck/Info.plist** — start with a minimum viable plist; XcodeGen merges in the `properties` block above.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>$(MACOSX_DEPLOYMENT_TARGET)</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
```

**Step 3: Tapedeck/Tapedeck.entitlements** — keychain-sharing entitlement is the load-bearing one.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.network.client</key><true/>
  <key>keychain-access-groups</key>
  <array>
    <string>$(AppIdentifierPrefix)com.benphillips.tapedeck</string>
  </array>
</dict>
</plist>
```

**Step 4: TapedeckSyncHelper/Info.plist** — a tool needs Info.plist embedded in the binary via linker flag; the minimal form:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
</dict>
</plist>
```

**Step 5: TapedeckSyncHelper.entitlements** — identical keychain group as the UI.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.network.client</key><true/>
  <key>keychain-access-groups</key>
  <array>
    <string>$(AppIdentifierPrefix)com.benphillips.tapedeck</string>
  </array>
</dict>
</plist>
```

**Step 6: ExportOptions.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>C8Q84FVJHL</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
```

**Step 7: Create minimum-buildable source files for each target**

`Tapedeck/Placeholder.swift` — must have an `@main` entry so the `application` product links:

```swift
// ABOUTME: Minimum-viable SwiftUI entry so the Tapedeck app target builds.
// ABOUTME: Replaced by TapedeckApp.swift in Phase 7. Window is intentionally bare.

import SwiftUI

@main
struct TapedeckPlaceholderApp: App {
    var body: some Scene {
        Window("Tapedeck", id: "main") { Text("Tapedeck — scaffolding") }
    }
}
```

`TapedeckSyncHelper/main.swift` — tool targets require the entry file to be named `main.swift`:

```swift
// ABOUTME: Placeholder CLI entry. Replaced by the real pipeline driver in Phase 6.
// ABOUTME: File must be called main.swift so the tool target produces an executable.

import Foundation
print("tapedeck-sync-helper placeholder")
```

`Tapedeck/Tests/Smoke.swift` (covers the `TapedeckTests` source phase):

```swift
import XCTest
final class SmokeTests: XCTestCase { func testBuilds() { XCTAssertTrue(true) } }
```

**Step 8: Generate the project and verify it builds**

```bash
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate
xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -configuration Debug build -quiet
xcodebuild -project Tapedeck.xcodeproj -scheme TapedeckSyncHelper -configuration Debug build -quiet
```

Expected: both schemes build cleanly. The UI launches as a blank window if you double-click the resulting .app — that's expected for the placeholder.

**Step 9: Commit**

```bash
git add project.yml Tapedeck TapedeckSyncHelper ExportOptions.plist
git commit -m "build: scaffold XcodeGen project with UI + helper targets"
```

---

## Phase 2 — TapedeckCore: storage

GRDB.swift is the SQLite wrapper. WAL mode is on by default for `DatabasePool`. Migrations are stored in a `DatabaseMigrator`. Reference: <https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb>.

### Task 2.1: Failing test for opening a fresh `Store`

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/StoreOpenTests.swift`

**Step 1: Test**

```swift
// ABOUTME: Verifies Store opens, runs migrations, and exposes schemaVersion.
// ABOUTME: All schema tests use an in-memory store via `Store.openInMemory()`.

import Testing
import GRDB
@testable import TapedeckCore

@Suite("Store open")
struct StoreOpenTests {
    @Test func opensInMemoryAndRunsMigrations() throws {
        let store = try Store.openInMemory()
        let version = try store.read { db in
            try Int.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'schema_version'")
        }
        #expect(version == TapedeckCore.schemaVersion)
    }
}
```

**Step 2: Run, expect failure**

Run: `swift test --package-path TapedeckCore --filter StoreOpenTests`
Expected: compile error — `Store` not defined.

**Step 3: Commit (red)**

```bash
git add TapedeckCore/Tests/TapedeckCoreTests/StoreOpenTests.swift
git commit -m "test(core): failing test for Store open"
```

### Task 2.2: Implement `Store` with first migration

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/Store.swift`

**Step 1: Implementation**

```swift
// ABOUTME: SQLite store wrapping GRDB.swift's DatabasePool. WAL mode by default.
// ABOUTME: Owns the migration ladder; both UI and helper open the same file.

import Foundation
import GRDB

public final class Store: @unchecked Sendable {
    // GRDB's DatabasePool gives concurrent reads + serialised writes for file-backed DBs.
    // DatabaseQueue is required for in-memory storage; we expose both behind DatabaseWriter.
    public let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(at url: URL) throws -> Store {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var config = Configuration()
        // GRDB enables WAL automatically for DatabasePool; setting it explicitly documents intent.
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try Store(writer: pool)
    }

    /// In-memory store backed by DatabaseQueue (DatabasePool does not support `:memory:`).
    public static func openInMemory() throws -> Store {
        let queue = try DatabaseQueue()
        return try Store(writer: queue)
    }

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.read(block)
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    created_at INTEGER NOT NULL,
                    archived_at INTEGER
                );

                CREATE TABLE recordings (
                    source_id TEXT PRIMARY KEY,
                    filename TEXT NOT NULL,
                    started_at INTEGER NOT NULL,
                    duration_ms INTEGER NOT NULL,
                    filesize INTEGER NOT NULL,
                    audio_extension TEXT,
                    audio_downloaded_at INTEGER,
                    transcribed_at INTEGER,
                    project_id TEXT REFERENCES projects(id),
                    classification_confidence REAL,
                    classification_reasoning TEXT,
                    classified_at INTEGER,
                    classified_by TEXT,
                    project_link_state TEXT NOT NULL DEFAULT 'none',
                    linked_project_id TEXT REFERENCES projects(id),
                    last_seen_at INTEGER NOT NULL
                );

                CREATE INDEX recordings_project ON recordings(project_id);
                CREATE INDEX recordings_status ON recordings(audio_downloaded_at, transcribed_at);

                CREATE TABLE recording_errors (
                    source_id TEXT NOT NULL REFERENCES recordings(source_id),
                    stage TEXT NOT NULL,
                    occurred_at INTEGER NOT NULL,
                    attempt INTEGER NOT NULL,
                    message TEXT NOT NULL,
                    PRIMARY KEY (source_id, stage)
                );

                CREATE TABLE app_state (
                    key TEXT PRIMARY KEY,
                    value TEXT
                );

                INSERT INTO app_state(key, value) VALUES('schema_version', '\(TapedeckCore.schemaVersion)');
            """)
        }
        return m
    }()
}
```

**Step 2: Run the failing test, expect pass**

Run: `swift test --package-path TapedeckCore --filter StoreOpenTests`
Expected: PASS.

**Step 3: Commit (green)**

```bash
git add TapedeckCore/Sources/TapedeckCore/Store.swift
git commit -m "feat(core): Store with v1 migration"
```

### Task 2.3: Project + Recording model types and CRUD

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/Models.swift`
- Create: `TapedeckCore/Sources/TapedeckCore/ProjectRepository.swift`
- Create: `TapedeckCore/Sources/TapedeckCore/RecordingRepository.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/ProjectRepositoryTests.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/RecordingRepositoryTests.swift`

**Step 1: Tests first** (TDD).

`ProjectRepositoryTests.swift`:
```swift
// ABOUTME: Exercises Project CRUD: insert, list active, archive, edit.
// ABOUTME: Uses Store.openInMemory() for isolation.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("ProjectRepository")
struct ProjectRepositoryTests {
    @Test func insertAndListActive() throws {
        let store = try Store.openInMemory()
        let repo = ProjectRepository(store: store)

        try repo.insert(.init(id: "homeschool-mvp", displayName: "Homeschool MVP",
                              description: "Curriculum planning for two kids", createdAt: 1, archivedAt: nil))
        try repo.insert(.init(id: "investors", displayName: "Investors",
                              description: "Fundraising conversations", createdAt: 2, archivedAt: nil))

        let active = try repo.listActive()
        #expect(active.map(\.id) == ["homeschool-mvp", "investors"])
    }

    @Test func archiveHidesProjectFromListActive() throws {
        let store = try Store.openInMemory()
        let repo = ProjectRepository(store: store)
        try repo.insert(.init(id: "p1", displayName: "P1", description: "", createdAt: 1, archivedAt: nil))
        try repo.archive(id: "p1", at: 5)

        #expect(try repo.listActive().isEmpty)
        let archived = try repo.findById("p1")
        #expect(archived?.archivedAt == 5)
    }
}
```

`RecordingRepositoryTests.swift`:
```swift
// ABOUTME: Covers idempotent upsert, error rows, and classify-state transitions.
// ABOUTME: Each test gets a fresh in-memory store.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("RecordingRepository")
struct RecordingRepositoryTests {
    private func setup() throws -> (Store, RecordingRepository) {
        let store = try Store.openInMemory()
        return (store, RecordingRepository(store: store))
    }

    @Test func upsertIsIdempotentOnSourceId() throws {
        let (_, repo) = try setup()
        let r1 = Recording(sourceId: "abc", filename: "Meeting 1", startedAt: 1000,
                           durationMs: 60_000, filesize: 1_024, audioExtension: nil,
                           lastSeenAt: 1)
        try repo.upsertFromRemote(r1)
        try repo.upsertFromRemote(r1)
        #expect(try repo.count() == 1)
    }

    @Test func recordErrorThenClearOnSuccess() throws {
        let (_, repo) = try setup()
        let r = Recording(sourceId: "abc", filename: "x", startedAt: 1, durationMs: 1,
                          filesize: 1, audioExtension: nil, lastSeenAt: 1)
        try repo.upsertFromRemote(r)
        try repo.recordError(sourceId: "abc", stage: .transcribe, at: 10, message: "boom")

        #expect(try repo.error(sourceId: "abc", stage: .transcribe)?.attempt == 1)
        try repo.recordError(sourceId: "abc", stage: .transcribe, at: 20, message: "boom again")
        #expect(try repo.error(sourceId: "abc", stage: .transcribe)?.attempt == 2)

        try repo.clearError(sourceId: "abc", stage: .transcribe)
        #expect(try repo.error(sourceId: "abc", stage: .transcribe) == nil)
    }
}
```

**Step 2: Run, expect compile failures**

Run: `swift test --package-path TapedeckCore --filter Repository`
Expected: type errors.

**Step 3: Models.swift**

```swift
// ABOUTME: Value types stored in SQLite. Mapped manually via GRDB FetchableRecord.
// ABOUTME: Field names match the snake_case schema; Swift surface is camelCase.

import Foundation
import GRDB

public struct Project: Equatable, Sendable, Codable, FetchableRecord, PersistableRecord {
    public var id: String
    public var displayName: String
    public var description: String
    public var createdAt: Int64
    public var archivedAt: Int64?

    public static let databaseTableName = "projects"
    enum Columns: String, ColumnExpression { case id, display_name, description, created_at, archived_at }

    public init(id: String, displayName: String, description: String, createdAt: Int64, archivedAt: Int64?) {
        self.id = id; self.displayName = displayName; self.description = description
        self.createdAt = createdAt; self.archivedAt = archivedAt
    }

    public init(row: Row) throws {
        id = row["id"]; displayName = row["display_name"]; description = row["description"]
        createdAt = row["created_at"]; archivedAt = row["archived_at"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id; container["display_name"] = displayName
        container["description"] = description; container["created_at"] = createdAt
        container["archived_at"] = archivedAt
    }
}

public struct Recording: Equatable, Sendable {
    public var sourceId: String
    public var filename: String
    public var startedAt: Int64
    public var durationMs: Int64
    public var filesize: Int64
    public var audioExtension: String?
    public var audioDownloadedAt: Int64?
    public var transcribedAt: Int64?
    public var projectId: String?
    public var classificationConfidence: Double?
    public var classificationReasoning: String?
    public var classifiedAt: Int64?
    public var classifiedBy: String?
    public var projectLinkState: LinkState
    public var linkedProjectId: String?
    public var lastSeenAt: Int64

    public enum LinkState: String, Sendable { case none, linked, pendingRelink = "pending_relink" }

    public init(sourceId: String, filename: String, startedAt: Int64, durationMs: Int64,
                filesize: Int64, audioExtension: String?,
                audioDownloadedAt: Int64? = nil, transcribedAt: Int64? = nil,
                projectId: String? = nil, classificationConfidence: Double? = nil,
                classificationReasoning: String? = nil, classifiedAt: Int64? = nil,
                classifiedBy: String? = nil, projectLinkState: LinkState = .none,
                linkedProjectId: String? = nil, lastSeenAt: Int64) {
        self.sourceId = sourceId; self.filename = filename; self.startedAt = startedAt
        self.durationMs = durationMs; self.filesize = filesize; self.audioExtension = audioExtension
        self.audioDownloadedAt = audioDownloadedAt; self.transcribedAt = transcribedAt
        self.projectId = projectId; self.classificationConfidence = classificationConfidence
        self.classificationReasoning = classificationReasoning; self.classifiedAt = classifiedAt
        self.classifiedBy = classifiedBy; self.projectLinkState = projectLinkState
        self.linkedProjectId = linkedProjectId; self.lastSeenAt = lastSeenAt
    }
}

public enum SyncStage: String, Sendable { case download, transcribe, classify, link }

public struct StageError: Equatable, Sendable {
    public var sourceId: String
    public var stage: SyncStage
    public var occurredAt: Int64
    public var attempt: Int
    public var message: String
}
```

**Step 4: ProjectRepository.swift**

```swift
// ABOUTME: Pure SQL access for the projects table. No business logic.
// ABOUTME: Methods are throws + synchronous; callers run them in Task.detached if needed.

import Foundation
import GRDB

public struct ProjectRepository: Sendable {
    let store: Store

    public init(store: Store) { self.store = store }

    public func insert(_ project: Project) throws {
        try store.write { db in try project.insert(db) }
    }

    public func update(_ project: Project) throws {
        try store.write { db in try project.update(db) }
    }

    public func archive(id: String, at: Int64) throws {
        try store.write { db in
            try db.execute(sql: "UPDATE projects SET archived_at = ? WHERE id = ?", arguments: [at, id])
        }
    }

    public func unarchive(id: String) throws {
        try store.write { db in
            try db.execute(sql: "UPDATE projects SET archived_at = NULL WHERE id = ?", arguments: [id])
        }
    }

    public func findById(_ id: String) throws -> Project? {
        try store.read { db in try Project.fetchOne(db, key: id) }
    }

    public func listActive() throws -> [Project] {
        try store.read { db in
            try Project.filter(sql: "archived_at IS NULL")
                .order(sql: "created_at ASC")
                .fetchAll(db)
        }
    }

    public func listAll() throws -> [Project] {
        try store.read { db in try Project.order(sql: "created_at ASC").fetchAll(db) }
    }
}
```

**Step 5: RecordingRepository.swift**

```swift
// ABOUTME: Pure SQL access for recordings and recording_errors.
// ABOUTME: Idempotent upserts use ON CONFLICT(source_id) DO UPDATE.

import Foundation
import GRDB

public struct RecordingRepository: Sendable {
    let store: Store

    public init(store: Store) { self.store = store }

    public func count() throws -> Int {
        try store.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recordings") ?? 0 }
    }

    public func upsertFromRemote(_ r: Recording) throws {
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO recordings (source_id, filename, started_at, duration_ms,
                    filesize, audio_extension, last_seen_at, project_link_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'none')
                ON CONFLICT(source_id) DO UPDATE SET
                    filename = excluded.filename,
                    started_at = excluded.started_at,
                    duration_ms = excluded.duration_ms,
                    filesize = excluded.filesize,
                    audio_extension = COALESCE(recordings.audio_extension, excluded.audio_extension),
                    last_seen_at = excluded.last_seen_at
            """, arguments: [r.sourceId, r.filename, r.startedAt, r.durationMs,
                             r.filesize, r.audioExtension, r.lastSeenAt])
        }
    }

    public func recordError(sourceId: String, stage: SyncStage, at: Int64, message: String) throws {
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO recording_errors(source_id, stage, occurred_at, attempt, message)
                VALUES (?, ?, ?, 1, ?)
                ON CONFLICT(source_id, stage) DO UPDATE SET
                    occurred_at = excluded.occurred_at,
                    attempt = recording_errors.attempt + 1,
                    message = excluded.message
            """, arguments: [sourceId, stage.rawValue, at, message])
        }
    }

    public func clearError(sourceId: String, stage: SyncStage) throws {
        try store.write { db in
            try db.execute(sql: "DELETE FROM recording_errors WHERE source_id = ? AND stage = ?",
                           arguments: [sourceId, stage.rawValue])
        }
    }

    public func error(sourceId: String, stage: SyncStage) throws -> StageError? {
        try store.read { db in
            try Row.fetchOne(db, sql: """
                SELECT source_id, stage, occurred_at, attempt, message
                FROM recording_errors WHERE source_id = ? AND stage = ?
            """, arguments: [sourceId, stage.rawValue]).map { row in
                StageError(sourceId: row["source_id"],
                           stage: SyncStage(rawValue: row["stage"])!,
                           occurredAt: row["occurred_at"],
                           attempt: row["attempt"],
                           message: row["message"])
            }
        }
    }

    public func setDownloaded(sourceId: String, ext: String, at: Int64) throws {
        try store.write { db in
            try db.execute(sql: """
                UPDATE recordings SET audio_extension = ?, audio_downloaded_at = ?
                WHERE source_id = ?
            """, arguments: [ext, at, sourceId])
        }
    }

    public func setTranscribed(sourceId: String, at: Int64) throws {
        try store.write { db in
            try db.execute(sql: "UPDATE recordings SET transcribed_at = ? WHERE source_id = ?",
                           arguments: [at, sourceId])
        }
    }

    public func setClassification(sourceId: String, projectId: String?, confidence: Double,
                                   reasoning: String, by: String, at: Int64,
                                   linkState: Recording.LinkState) throws {
        try store.write { db in
            try db.execute(sql: """
                UPDATE recordings SET project_id = ?, classification_confidence = ?,
                    classification_reasoning = ?, classified_at = ?, classified_by = ?,
                    project_link_state = ?
                WHERE source_id = ?
            """, arguments: [projectId, confidence, reasoning, at, by,
                             linkState.rawValue, sourceId])
        }
    }

    public func markLinked(sourceId: String, linkedProjectId: String?) throws {
        try store.write { db in
            try db.execute(sql: """
                UPDATE recordings SET linked_project_id = ?, project_link_state = 'linked'
                WHERE source_id = ?
            """, arguments: [linkedProjectId, sourceId])
        }
    }

    public func recordingsNeedingDownload() throws -> [Recording] { try fetchAll(where: "audio_downloaded_at IS NULL") }
    public func recordingsNeedingTranscription() throws -> [Recording] { try fetchAll(where: "audio_downloaded_at IS NOT NULL AND transcribed_at IS NULL") }
    public func recordingsNeedingClassification() throws -> [Recording] { try fetchAll(where: "transcribed_at IS NOT NULL AND classified_at IS NULL") }
    public func recordingsNeedingRelink() throws -> [Recording] { try fetchAll(where: "project_link_state = 'pending_relink'") }

    private func fetchAll(where clause: String) throws -> [Recording] {
        try store.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM recordings WHERE \(clause)").map { row in
                Recording(
                    sourceId: row["source_id"], filename: row["filename"],
                    startedAt: row["started_at"], durationMs: row["duration_ms"],
                    filesize: row["filesize"], audioExtension: row["audio_extension"],
                    audioDownloadedAt: row["audio_downloaded_at"],
                    transcribedAt: row["transcribed_at"],
                    projectId: row["project_id"],
                    classificationConfidence: row["classification_confidence"],
                    classificationReasoning: row["classification_reasoning"],
                    classifiedAt: row["classified_at"],
                    classifiedBy: row["classified_by"],
                    projectLinkState: Recording.LinkState(rawValue: row["project_link_state"]) ?? .none,
                    linkedProjectId: row["linked_project_id"],
                    lastSeenAt: row["last_seen_at"]
                )
            }
        }
    }
}
```

**Step 6: Run tests**

Run: `swift test --package-path TapedeckCore`
Expected: all tests pass.

**Step 7: Commit**

```bash
git add TapedeckCore/Sources/TapedeckCore/{Models,ProjectRepository,RecordingRepository}.swift \
        TapedeckCore/Tests/TapedeckCoreTests/{Project,Recording}RepositoryTests.swift
git commit -m "feat(core): Project + Recording repositories with TDD"
```

---

## Phase 3 — TapedeckCore: external HTTP clients

Each client uses `URLSession` with a custom `URLProtocol` for stub tests. The stub wiring is shared.

### Task 3.1: `URLProtocolStub` test helper

`URLProtocolStub.handlers` is a process-global, and Swift Testing runs suites in parallel by default. Every test suite that touches `URLProtocolStub` MUST be declared `@Suite(.serialized)` so handler registration from one suite doesn't race with another's. The reset/register/use sequence is then race-free within each suite (tests inside a suite are also serialised when the suite is).

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Support/URLProtocolStub.swift`

```swift
// ABOUTME: Test helper that intercepts URLSession requests and replays canned responses.
// ABOUTME: Register handlers per-test with URLProtocolStub.register(host:path:handler:).

import Foundation

final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (HTTPURLResponse, Data)
    nonisolated(unsafe) private static var handlers: [(String, (URLRequest) -> Bool, Handler)] = []
    nonisolated(unsafe) private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers = []
    }

    static func register(_ name: String,
                         matching: @escaping (URLRequest) -> Bool,
                         handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers.append((name, matching, handler))
    }

    static func ephemeralSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let match = Self.handlers.first { $0.1(request) }
        Self.lock.unlock()
        guard let match else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (response, data) = match.2(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension URLProtocolStub {
    static func jsonResponse(for request: URLRequest, status: Int = 200, fixture: String) -> (HTTPURLResponse, Data) {
        let url = Bundle.module.url(forResource: "Fixtures/\(fixture)", withExtension: nil)!
        let data = try! Data(contentsOf: url)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        return (resp, data)
    }
}
```

Commit: `test(core): add URLProtocolStub helper`.

### Task 3.2: `SourceClient` — JWT region decode (failing test)

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/SourceClientRegionTests.swift`

```swift
// ABOUTME: Confirms the JWT region claim drives initial host selection.
// ABOUTME: Uses the redacted JWT fixture; matches whatever claim name §0.5 captured.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("SourceClient region decode")
struct SourceClientRegionTests {
    @Test func decodesEuCentral1FromRedactedJwtClaim() throws {
        // Hand-assemble a JWT with the redacted payload's structure.
        let header = #"{"alg":"none"}"#.data(using: .utf8)!.base64URLEncoded()
        let payloadURL = Bundle.module.url(forResource: "Fixtures/source/jwt_payload_redacted",
                                            withExtension: "json")!
        let payload = try Data(contentsOf: payloadURL).base64URLEncoded()
        let token = "\(header).\(payload).sig"

        let host = SourceClient.hostFromJWT(token)
        #expect(host == URL(string: "https://api-euc1.plaud.ai")!)
    }

    @Test func returnsNilIfJwtLacksRegionClaim() throws {
        let header = #"{"alg":"none"}"#.data(using: .utf8)!.base64URLEncoded()
        let payload = #"{"sub":"x"}"#.data(using: .utf8)!.base64URLEncoded()
        let token = "\(header).\(payload).sig"
        #expect(SourceClient.hostFromJWT(token) == nil)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

Run: expect compile failure.

### Task 3.3: Implement `SourceClient.hostFromJWT`

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/SourceClient.swift`

```swift
// ABOUTME: HTTP client for the Plaud cloud API. JWT auth + -302 region discovery.
// ABOUTME: All endpoints captured in design §4 and fixtures under Tests/Fixtures/source/.

import Foundation

public actor SourceClient {
    public static let defaultHost = URL(string: "https://api.plaud.ai")!
    nonisolated static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    nonisolated let session: URLSession
    nonisolated let token: String
    public private(set) var host: URL

    public init(token: String, host: URL? = nil, session: URLSession = .shared) {
        self.token = token
        self.host = host ?? Self.hostFromJWT(token) ?? Self.defaultHost
        self.session = session
    }

    public func currentHost() -> URL { host }

    /// Returns the regional API host implied by the JWT's region claim, or nil.
    /// Region claim name is whichever §0.5 captured; check both common forms.
    /// Values may carry an `aws:` provider prefix (e.g. `aws:eu-central-1`); strip before lookup.
    public static func hostFromJWT(_ token: String) -> URL? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let raw = (obj["region"] as? String) ?? (obj["aws:region"] as? String)
        return raw.flatMap(regionToHost)
    }

    static func regionToHost(_ region: String) -> URL? {
        let normalised = region.hasPrefix("aws:") ? String(region.dropFirst(4)) : region
        // Extend this table as new regions appear in JWTs.
        let map: [String: String] = [
            "eu-central-1": "https://api-euc1.plaud.ai",
            "us-east-1": "https://api.plaud.ai",
        ]
        return map[normalised].flatMap(URL.init(string:))
    }
}
```

Run: tests pass. Commit: `feat(core): SourceClient JWT region decode`.

### Task 3.4: `SourceClient.discoverHost()` handling `-302`

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/SourceClient.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/SourceClientDiscoveryTests.swift`

**Step 1: Test (using URLProtocolStub + the redirect_302 fixture)**

```swift
import Testing
import Foundation
@testable import TapedeckCore

@Suite("SourceClient host discovery", .serialized)
struct SourceClientDiscoveryTests {
    @Test func switchesHostOn302Response() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.register("default→redirect", matching: { req in
            req.url?.host == "api.plaud.ai"
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/redirect_302.json")
        })
        URLProtocolStub.register("regional→list", matching: { req in
            req.url?.host == "api-euc1.plaud.ai"
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/list_page1.json")
        })

        let client = SourceClient(token: "token-without-region.payload.sig",
                                  host: URL(string: "https://api.plaud.ai")!,
                                  session: URLProtocolStub.ephemeralSession())
        try await client.discoverHost()
        let resolved = await client.currentHost()
        #expect(resolved.host == "api-euc1.plaud.ai")
    }
}
```

**Step 2: Implementation — append to SourceClient.swift**

```swift
extension SourceClient {
    /// Resolve the regional host by probing `/file/simple/web` and following the -302 JSON status.
    /// Idempotent — if the current host already returns recordings (status != -302), keeps it.
    public func discoverHost() async throws {
        var probe = URLRequest(url: host.appending(path: "/file/simple/web"))
        probe.url = probe.url?.appending(queryItems: [
            .init(name: "skip", value: "0"),
            .init(name: "limit", value: "1"),
            .init(name: "is_trash", value: "0"),
        ])
        addStandardHeaders(&probe)
        // Validation must run *inside* the retry closure so HTTPRetryableError triggers a retry.
        let data: Data
        do {
            data = try await RetryPolicy.run { [session] in
                let (body, response) = try await session.data(for: probe)
                try HTTPValidator.validate(response, body: body)
                return body
            }
        } catch is HTTPUnauthorised { throw SourceClientError.unauthorised }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = obj["status"] as? Int, status == -302,
           let domains = (obj["data"] as? [String: Any])?["domains"] as? [String: Any],
           let api = domains["api"] as? String, let url = URL(string: api) {
            host = url
        }
    }

    nonisolated internal func addStandardHeaders(_ req: inout URLRequest) {
        req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("web", forHTTPHeaderField: "app-platform")
        req.setValue("web", forHTTPHeaderField: "edit-from")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://web.plaud.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://web.plaud.ai/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
}
```

Run: tests pass. Commit: `feat(core): SourceClient host discovery via -302`.

### Task 3.5: `SourceClient.listPage()` and pagination

**Files:**
- Modify: `TapedeckCore/Sources/TapedeckCore/SourceClient.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/SourceClientListTests.swift`

**Step 1: Test** — list page should parse the fixture into `Recording` values with the right field mapping (Plaud `id` → `sourceId`, `start_time` ms → `startedAt`, `duration` ms → `durationMs`, etc).

```swift
import Testing
@testable import TapedeckCore

@Suite("SourceClient list", .serialized)
struct SourceClientListTests {
    @Test func parsesListResponseIntoRecordings() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.register("list", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/list_page1.json")
        })
        let client = SourceClient(token: "t.payload.sig",
                                  host: URL(string: "https://api-euc1.plaud.ai")!,
                                  session: URLProtocolStub.ephemeralSession())
        let page = try await client.listPage(skip: 0, limit: 2)
        #expect(page.count == 2)
        #expect(page.first?.startedAt ?? 0 > 1_500_000_000_000)  // ms timestamp sanity
    }
}
```

**Step 2: Implementation**

```swift
extension SourceClient {
    public func listPage(skip: Int, limit: Int = 100) async throws -> [Recording] {
        var url = host.appending(path: "/file/simple/web")
        url = url.appending(queryItems: [
            .init(name: "skip", value: "\(skip)"),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "is_trash", value: "0"),
            .init(name: "sort_by", value: "start_time"),
            .init(name: "is_desc", value: "true"),
        ])
        var req = URLRequest(url: url)
        addStandardHeaders(&req)
        let (data, response) = try await session.data(for: req)
        do { try HTTPValidator.validate(response, body: data) }
        catch is HTTPUnauthorised { throw SourceClientError.unauthorised }
        struct Envelope: Decodable { let data_file_list: [Item] }
        struct Item: Decodable {
            let id: String; let filename: String; let start_time: Int64
            let duration: Int64; let filesize: Int64
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return env.data_file_list.map {
            Recording(sourceId: $0.id, filename: $0.filename, startedAt: $0.start_time,
                      durationMs: $0.duration, filesize: $0.filesize,
                      audioExtension: nil, lastSeenAt: now)
        }
    }

    public func listAll() async throws -> [Recording] {
        var all: [Recording] = []
        var skip = 0
        let pageSize = 100
        while true {
            let page = try await listPage(skip: skip, limit: pageSize)
            all.append(contentsOf: page)
            if page.count < pageSize { break }
            skip += pageSize
        }
        return all
    }
}

/// Maps HTTP responses to typed errors. Each external client decides what 401
/// means for *its* identity — Plaud 401 means JWT expired; Deepgram/Gemini 401
/// mean wrong API key — so HTTPValidator emits a generic HTTPUnauthorised and
/// the caller wraps it appropriately.
public enum HTTPValidator {
    public static func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw HTTPUnauthorised(body: String(data: body, encoding: .utf8) ?? "")
        case 408, 429, 500..<600:
            throw HTTPRetryableError(status: http.statusCode,
                                     body: String(data: body, encoding: .utf8) ?? "")
        default:
            throw HTTPNonRetryableError(status: http.statusCode,
                                        body: String(data: body, encoding: .utf8) ?? "")
        }
    }
}

public struct HTTPUnauthorised: Error, Equatable { public let body: String }
public struct HTTPRetryableError: Error, Equatable { public let status: Int; public let body: String }
public struct HTTPNonRetryableError: Error, Equatable { public let status: Int; public let body: String }

public enum SourceClientError: Error, Equatable {
    case unauthorised
    case malformedResponse(String)
}
```

Run, commit.

### Task 3.6: `SourceClient.tempURL(for:)` and `SourceClient.rawMetadata(for:)`

Same pattern: failing test using `temp_url.json` and `raw_metadata.json` fixtures; implement; commit.

```swift
extension SourceClient {
    public func tempURL(for sourceId: String) async throws -> URL {
        var req = URLRequest(url: host.appending(path: "/file/temp-url/\(sourceId)"))
        addStandardHeaders(&req)
        let (data, response) = try await session.data(for: req)
        do { try HTTPValidator.validate(response, body: data) }
        catch is HTTPUnauthorised { throw SourceClientError.unauthorised }
        struct Envelope: Decodable { let temp_url: String }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard let url = URL(string: env.temp_url) else {
            throw SourceClientError.malformedResponse("temp_url not a URL")
        }
        return url
    }

    public func rawMetadata(for sourceIds: [String]) async throws -> Data {
        var req = URLRequest(url: host.appending(path: "/file/list"))
        req.httpMethod = "POST"
        addStandardHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: sourceIds)
        let (data, response) = try await session.data(for: req)
        do { try HTTPValidator.validate(response, body: data) }
        catch is HTTPUnauthorised { throw SourceClientError.unauthorised }
        return data
    }
}
```

Tests cover: URL extraction from `temp_url.json`; metadata POST sends a JSON array body and returns the bytes verbatim.

### Task 3.7: `SourceClient.download(from:to:)` — streaming to `.part`, then rename

The S3 URL is signed and large. Stream with `URLSession.bytes(for:)` into a `.part` file, then atomically rename. Capture extension from the URL path.

**Files:**
- Modify: `SourceClient.swift`
- Create test: `TapedeckCore/Tests/TapedeckCoreTests/SourceClientDownloadTests.swift`

**Test** — register a stub that serves arbitrary bytes for any URL whose host ends in `amazonaws.com`; assert the file lands at the target path and `.part` is gone.

```swift
extension SourceClient {
    /// Streams `url` to `target.part`, then renames atomically. Returns the extension parsed from url.path.
    public func download(from url: URL, target: URL, fileManager: FileManager = .default) async throws -> String {
        // Idempotent recovery — if a previous run wrote `target` successfully but failed
        // mid-metadata, we want this call to be a no-op fetch and just return the extension.
        if fileManager.fileExists(atPath: target.path) {
            let ext = url.pathExtension.lowercased()
            return ext.isEmpty ? "audio" : ext
        }
        let partURL = target.appendingPathExtension("part")
        try? fileManager.removeItem(at: partURL)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let (asyncBytes, response) = try await session.bytes(for: URLRequest(url: url))
        // Body bytes haven't streamed yet; only the status code is available.
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401: throw SourceClientError.unauthorised
            case 408, 429, 500..<600:
                throw HTTPRetryableError(status: http.statusCode, body: "")
            default:
                throw HTTPNonRetryableError(status: http.statusCode, body: "")
            }
        }
        fileManager.createFile(atPath: partURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        for try await byte in asyncBytes {
            try handle.write(contentsOf: [byte])
        }
        try handle.close()
        try fileManager.moveItem(at: partURL, to: target)
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "audio" : ext
    }
}
```

Commit: `feat(core): SourceClient streaming download`.

### Task 3.8: `SourceClient` retry + backoff on 5xx/429

Wrap the call sites in a retry helper. Keep it simple: 1s, 2s, 4s, then throw. One test that returns 503 twice then 200 and asserts the eventual success.

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/RetryPolicy.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/RetryPolicyTests.swift`

```swift
// ABOUTME: Exponential-backoff retry used by every external HTTP client.
// ABOUTME: Retries on HTTPRetryableError and transient URLError; never on 401/4xx.

import Foundation

public enum RetryPolicy {
    /// 4 attempts total with sleeps 1s, 2s, 4s between failures.
    public static func run<T>(maxAttempts: Int = 4,
                              sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
                              _ block: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await block() }
            catch is HTTPRetryableError where attempt < maxAttempts - 1 { /* retry */ }
            catch let url as URLError where Self.isRetryableURLError(url) && attempt < maxAttempts - 1 { /* retry */ }
            // SourceClientError.unauthorised + HTTPNonRetryableError propagate immediately.
            try await sleep(UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
            attempt += 1
        }
    }

    static func isRetryableURLError(_ e: URLError) -> Bool {
        [.timedOut, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed].contains(e.code)
    }
}
```

Test: an injected counter that throws `HTTPRetryableError(status: 503, body: "")` twice then returns 200 on the third call — assert exactly three invocations of the block and exactly two sleeps. A second test asserts `HTTPNonRetryableError(status: 404, ...)` is rethrown immediately with one invocation and zero sleeps.

### Task 3.9: `DeepgramClient`

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/DeepgramClient.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/DeepgramClientTests.swift`

**Tests** — `Fixtures/deepgram/short_recording.json` exercises both the flat transcript and the speaker-labelled utterances. Two test cases:

1. `transcript` is non-empty and matches what the fixture's `channels[0].alternatives[0].transcript` contains verbatim.
2. `utterances` contains ≥1 item with `speaker`, `start`, `end`, `transcript` fields; the formatted transcript file produced by `Pipeline` interleaves speaker labels in the form `[speaker N] <text>\n`.

Implementation — POSTs the audio bytes to `https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&diarize=true&punctuate=true&utterances=true` with `Authorization: Token <KEY>`:

```swift
// ABOUTME: Deepgram REST client for nova-3 transcription with diarization + utterances.
// ABOUTME: Returns both the flat transcript and per-speaker utterance segments.

import Foundation

public struct DeepgramClient: Sendable {
    public struct Utterance: Sendable, Equatable {
        public let speaker: Int
        public let start: Double
        public let end: Double
        public let transcript: String
    }
    public struct Result: Sendable {
        public let transcript: String
        public let utterances: [Utterance]
        public let raw: Data
    }
    public enum DeepgramError: Error, Equatable { case invalidApiKey }
    let session: URLSession
    let apiKey: String

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey; self.session = session
    }

    public func transcribe(audioAt url: URL, contentType: String) async throws -> Result {
        var req = URLRequest(url: URL(string:
            "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&diarize=true&punctuate=true&utterances=true")!)
        req.httpMethod = "POST"
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBodyStream = InputStream(url: url)
        let (data, response) = try await session.data(for: req)
        do { try HTTPValidator.validate(response, body: data) }
        catch is HTTPUnauthorised { throw DeepgramError.invalidApiKey }
        struct Envelope: Decodable {
            struct Results: Decodable {
                struct Channel: Decodable {
                    struct Alt: Decodable { let transcript: String }
                    let alternatives: [Alt]
                }
                struct Utterance: Decodable {
                    let speaker: Int; let start: Double; let end: Double; let transcript: String
                }
                let channels: [Channel]
                let utterances: [Utterance]?
            }
            let results: Results
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        let transcript = env.results.channels.first?.alternatives.first?.transcript ?? ""
        let utterances = (env.results.utterances ?? []).map {
            Utterance(speaker: $0.speaker, start: $0.start, end: $0.end, transcript: $0.transcript)
        }
        return Result(transcript: transcript, utterances: utterances, raw: data)
    }
}

/// Renders the speaker-labelled transcript that ends up in `<stem>.transcript.txt`.
/// One paragraph per utterance: `[speaker N] <text>\n`. Used by Pipeline.transcribeNew().
public func renderTranscript(_ utterances: [DeepgramClient.Utterance], fallback: String) -> String {
    guard !utterances.isEmpty else { return fallback }
    return utterances.map { "[speaker \($0.speaker)] \($0.transcript)" }.joined(separator: "\n\n")
}
```

Refine field names against the actual `short_recording.json` shape captured in §0.6. The plan's diarization assumption follows Deepgram's `utterances=true` parameter — see <https://developers.deepgram.com/docs/diarization>.

### Task 3.10: `GeminiClient`

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/GeminiClient.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/GeminiClientTests.swift`

Endpoint: `https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=<API_KEY>`. Body shape: standard Gemini generateContent with a `responseMimeType: "application/json"` and a `responseSchema` constraining the output to `{ project_id: string|null, confidence: number, reasoning: string }`. The prompt sends the project list and the truncated transcript.

```swift
public struct GeminiClient: Sendable {
    public struct ProjectHint: Sendable {
        public let id: String; public let name: String; public let description: String
    }
    public struct Decision: Sendable {
        public let projectId: String?; public let confidence: Double; public let reasoning: String
    }
    public enum GeminiError: Error { case malformedResponse(String), invalidApiKey }
    let session: URLSession; let apiKey: String

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey; self.session = session
    }

    public func classify(transcript: String, projects: [ProjectHint]) async throws -> Decision {
        let head = String(transcript.prefix(4_000))
        let tail = String(transcript.suffix(1_000))
        let truncated = head == transcript ? head : "\(head)\n…\n\(tail)"

        let prompt = """
        You're routing a voice-memo transcript to one of the user's projects.
        Pick the best fit, or null if nothing fits. Return JSON only.

        Projects:
        \(projects.map { "- id=\($0.id), name=\($0.name): \($0.description)" }.joined(separator: "\n"))

        Transcript:
        \(truncated)
        """

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "object",
                    "properties": [
                        "project_id": ["type": "string", "nullable": true],
                        "confidence": ["type": "number"],
                        "reasoning": ["type": "string"],
                    ],
                    "required": ["confidence", "reasoning"],
                ],
            ],
        ]
        var req = URLRequest(url: URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=\(apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        do { try HTTPValidator.validate(response, body: data) }
        catch is HTTPUnauthorised { throw GeminiError.invalidApiKey }

        struct Envelope: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String }
                    let parts: [Part]
                }
                let content: Content
            }
            let candidates: [Candidate]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard let json = env.candidates.first?.content.parts.first?.text,
              let payload = json.data(using: .utf8) else {
            throw GeminiError.malformedResponse("no candidate text")
        }
        struct Out: Decodable { let project_id: String?; let confidence: Double; let reasoning: String }
        do {
            let out = try JSONDecoder().decode(Out.self, from: payload)
            return .init(projectId: out.project_id, confidence: out.confidence, reasoning: out.reasoning)
        } catch {
            throw GeminiError.malformedResponse(json)
        }
    }
}
```

Tests cover the four Gemini fixtures via a stub on the generativelanguage host: high-confidence, low-confidence, null project, malformed (must throw `GeminiError.malformedResponse`).

Commit each client in its own task.

---

## Phase 4 — TapedeckCore: Layout, SyncLock, Pipeline

### Task 4.1: `Layout.swift`

```swift
// ABOUTME: Single source of truth for on-disk paths under ~/Tapedeck and Application Support.
// ABOUTME: All path construction lives here so tests can inject a tmpdir root.

import Foundation

public struct Layout: Sendable {
    public let userRoot: URL          // ~/Tapedeck
    public let supportRoot: URL       // ~/Library/Application Support/Tapedeck
    public let logsRoot: URL          // ~/Library/Logs/Tapedeck

    public init(userRoot: URL, supportRoot: URL, logsRoot: URL) {
        self.userRoot = userRoot; self.supportRoot = supportRoot; self.logsRoot = logsRoot
    }

    public static let standard: Layout = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Layout(
            userRoot: home.appending(path: "Tapedeck"),
            supportRoot: home.appending(path: "Library/Application Support/Tapedeck"),
            logsRoot: home.appending(path: "Library/Logs/Tapedeck")
        )
    }()

    public func audioDir(date: Date) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .init(identifier: "UTC")
        return userRoot.appending(path: "audio/\(f.string(from: date))")
    }

    public func stem(sourceId: String, title: String) -> String {
        let safe = title.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespaces)
        let truncated = String(safe.prefix(80))
        return "\(sourceId)_\(truncated)"
    }

    public func dbURL() -> URL { supportRoot.appending(path: "state.db") }
    public func lockURL() -> URL { supportRoot.appending(path: "sync.lock") }
    public func logURL() -> URL { logsRoot.appending(path: "sync.log") }

    public func projectDir(slug: String) -> URL { userRoot.appending(path: "projects/\(slug)") }
}
```

TDD: tests verify stem sanitisation and that `audioDir` gives stable UTC dates regardless of locale.

### Task 4.2: `SyncLock.swift` — `flock` based single-flight

```swift
// ABOUTME: Process-level exclusion via flock on sync.lock. Helper exits 0 if held.
// ABOUTME: Lock is released automatically when the holder process exits.

import Foundation

public final class SyncLock {
    private let fd: Int32

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = open(path.path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        self.fd = fd
    }

    /// Attempts a non-blocking exclusive lock. Returns false if another holder has it.
    public func tryAcquire() -> Bool {
        flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    deinit { _ = flock(fd, LOCK_UN); close(fd) }
}
```

Test: spawn a `Process` of `/bin/sleep` after locking; assert `tryAcquire()` is false in the parent process holding the lock and true once released. (Or simpler: open the lock twice in the same test process with separate `SyncLock` instances; second `tryAcquire` is false.)

### Task 4.2a: Logging protocol

`Pipeline` needs a way to emit structured events without depending on file I/O (so tests don't litter the filesystem). The concrete `SyncLogger` (Task 6.2) implements it; tests pass a `CapturedLog` that just appends to an in-memory array.

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/SyncLog.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/Support/CapturedLog.swift`

```swift
// SyncLog.swift
public protocol SyncLog: Sendable {
    func info(_ stage: String, source: String?)
    func error(_ stage: String, source: String?, message: String)
}

public struct DiscardingLog: SyncLog {
    public init() {}
    public func info(_ stage: String, source: String?) {}
    public func error(_ stage: String, source: String?, message: String) {}
}
```

```swift
// CapturedLog.swift — test helper
final class CapturedLog: SyncLog, @unchecked Sendable {
    struct Entry: Equatable { let level: String; let stage: String; let source: String?; let message: String? }
    private let lock = NSLock()
    private var entries: [Entry] = []
    var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    func info(_ stage: String, source: String?) {
        lock.lock(); entries.append(.init(level: "info", stage: stage, source: source, message: nil)); lock.unlock()
    }
    func error(_ stage: String, source: String?, message: String) {
        lock.lock(); entries.append(.init(level: "error", stage: stage, source: source, message: message)); lock.unlock()
    }
}
```

Commit: `feat(core): SyncLog protocol + DiscardingLog`.

### Task 4.3: `Pipeline.swift` — actor + cycle entry

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/Pipeline.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/PipelineCycleTests.swift`

**Step 1: Failing test** — running `runCycle()` against a token-expired DB throws `PipelineError.tokenExpired` and never invokes the source client.

**Step 2: Implementation**

```swift
// ABOUTME: One sync cycle. Idempotent. Sequential stages; bounded parallelism per stage.
// ABOUTME: Owns no state beyond Deps; safe to construct fresh per helper invocation.

import Foundation

public actor Pipeline {
    public struct Deps: Sendable {
        public let store: Store
        public let layout: Layout
        public let source: SourceClient
        public let deepgram: DeepgramClient
        public let gemini: GeminiClient
        public let logger: any SyncLog
        public let now: @Sendable () -> Int64
    }
    public enum PipelineError: Error, Equatable { case tokenExpired, tokenMissing }

    let deps: Deps
    let recordings: RecordingRepository
    let projects: ProjectRepository
    let maxConcurrency = 3
    let maxFailuresPerStage = 3

    public init(deps: Deps) {
        self.deps = deps
        self.recordings = RecordingRepository(store: deps.store)
        self.projects = ProjectRepository(store: deps.store)
    }

    public func runCycle() async throws {
        try ensureToken()
        try await deps.source.discoverHost()
        try await listRemote()
        await downloadNew()
        await transcribeNew()
        await classifyNew()
        try relinkChanged()
        try touchLastSync()
    }

    func ensureToken() throws {
        let status: String? = try deps.store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'token_status'")
        }
        if status == "expired" { throw PipelineError.tokenExpired }
    }

    func touchLastSync() throws {
        let value = String(deps.now())
        try deps.store.write { db in
            try db.execute(sql: """
                INSERT INTO app_state(key,value) VALUES('last_sync_at', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [value])
        }
    }
}
```

Commit: `feat(core): Pipeline actor with ensureToken + touchLastSync`.

### Task 4.4: `Pipeline.listRemote`

**Test** — stub `SourceClient.listPage` (override `URLProtocolStub`) to return two recordings; assert both are upserted with `last_seen_at` set to `deps.now()`.

```swift
extension Pipeline {
    func listRemote() async throws {
        let remote = try await RetryPolicy.run { try await deps.source.listAll() }
        let now = deps.now()
        for rec in remote {
            var r = rec; r.lastSeenAt = now
            try recordings.upsertFromRemote(r)
        }
        deps.logger.info("list_remote", source: nil)
    }
}
```

### Task 4.5: `Pipeline.downloadNew`

**Test** — one row needing download; stubs return a fake S3 URL + 4 bytes; assert the audio file lands in `Layout.audioDir`, `audio_downloaded_at` is set, `audio_extension` is set, and any prior `recording_errors` row for stage='download' is cleared.

```swift
extension Pipeline {
    /// Runs `body` over `items` with at most `maxConcurrency` tasks in flight.
    /// Used by every stage so the design's "max 3 in parallel" rule is single-sourced.
    func runBounded<T: Sendable>(_ items: [T],
                                  _ body: @escaping @Sendable (T) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var inflight = 0
            for item in items {
                if inflight >= maxConcurrency {
                    await group.next(); inflight -= 1
                }
                group.addTask { await body(item) }
                inflight += 1
            }
        }
    }

    func downloadNew() async {
        let pending = ((try? recordings.recordingsNeedingDownload()) ?? [])
            .filter { !shouldSkipAfterFailures(sourceId: $0.sourceId, stage: .download) }
        await runBounded(pending) { rec in await self.downloadOne(rec) }
    }

    private func downloadOne(_ rec: Recording) async {
        do {
            let tempURL = try await RetryPolicy.run {
                try await deps.source.tempURL(for: rec.sourceId)
            }
            let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
            let dir = deps.layout.audioDir(date: date)
            let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
            let target = dir.appending(path: stem)
                            .appendingPathExtension(tempURL.pathExtension.isEmpty ? "audio" : tempURL.pathExtension)
            let ext = try await RetryPolicy.run {
                try await deps.source.download(from: tempURL, target: target)
            }
            let metadata = try await RetryPolicy.run {
                try await deps.source.rawMetadata(for: [rec.sourceId])
            }
            try metadata.write(to: dir.appending(path: "\(stem).source.json"))
            try recordings.setDownloaded(sourceId: rec.sourceId, ext: ext, at: deps.now())
            try recordings.clearError(sourceId: rec.sourceId, stage: .download)
            deps.logger.info("download_ok", source: rec.sourceId)
        } catch {
            try? recordings.recordError(sourceId: rec.sourceId, stage: .download,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("download_failed", source: rec.sourceId, message: "\(error)")
        }
    }

    private func shouldSkipAfterFailures(sourceId: String, stage: SyncStage) -> Bool {
        ((try? recordings.error(sourceId: sourceId, stage: stage))?.attempt ?? 0) >= maxFailuresPerStage
    }
}
```

### Task 4.6: `Pipeline.transcribeNew`

**Test** — one downloaded row + Deepgram stub returning the `short_recording.json` fixture; assert `<stem>.deepgram.json` is written next to the audio, `<stem>.transcript.txt` contains the speaker-labelled output from `renderTranscript`, `transcribed_at` is set, and the `transcribe` error row (if any) is cleared.

```swift
extension Pipeline {
    func transcribeNew() async {
        let pending = ((try? recordings.recordingsNeedingTranscription()) ?? [])
            .filter { !shouldSkipAfterFailures(sourceId: $0.sourceId, stage: .transcribe) }
        await runBounded(pending) { rec in await self.transcribeOne(rec) }
    }

    private func transcribeOne(_ rec: Recording) async {
        do {
            let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
            let dir = deps.layout.audioDir(date: date)
            let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
            let audio = dir.appending(path: "\(stem).\(rec.audioExtension ?? "audio")")
            let result = try await RetryPolicy.run {
                try await deps.deepgram.transcribe(audioAt: audio, contentType: "audio/*")
            }
            try result.raw.write(to: dir.appending(path: "\(stem).deepgram.json"))
            let txt = renderTranscript(result.utterances, fallback: result.transcript)
            try txt.write(to: dir.appending(path: "\(stem).transcript.txt"),
                          atomically: true, encoding: .utf8)
            try recordings.setTranscribed(sourceId: rec.sourceId, at: deps.now())
            try recordings.clearError(sourceId: rec.sourceId, stage: .transcribe)
            deps.logger.info("transcribe_ok", source: rec.sourceId)
        } catch {
            try? recordings.recordError(sourceId: rec.sourceId, stage: .transcribe,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("transcribe_failed", source: rec.sourceId, message: "\(error)")
        }
    }
}
```

### Task 4.7: `Pipeline.classifyNew`

**Tests** — four cases driven by Gemini fixtures:
1. high_confidence (confidence 0.92): assigns projectId, sets `pending_relink`.
2. low_confidence (confidence 0.41): leaves projectId nil, still sets `classified_at`.
3. null_project: same as low_confidence.
4. Threshold sensitivity: with `app_state.classifier_threshold = '0.95'` written before the cycle, the high_confidence (0.92) decision now leaves projectId nil — proves the threshold is read from `app_state` rather than hardcoded.

One more test with `recording.transcribedAt = nil` asserts the row is skipped.

```swift
extension Pipeline {
    func classifyNew() async {
        let pending = ((try? recordings.recordingsNeedingClassification()) ?? [])
            .filter { !shouldSkipAfterFailures(sourceId: $0.sourceId, stage: .classify) }
        guard !pending.isEmpty else { return }
        let activeProjects = (try? projects.listActive()) ?? []
        let hints = activeProjects.map {
            GeminiClient.ProjectHint(id: $0.id, name: $0.displayName, description: $0.description)
        }
        await runBounded(pending) { rec in await self.classifyOne(rec, hints: hints) }
    }

    /// Reads `app_state.classifier_threshold`, defaulting to 0.7 if absent or malformed.
    func classifierThreshold() throws -> Double {
        let raw: String? = try deps.store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'classifier_threshold'")
        }
        return raw.flatMap(Double.init) ?? 0.7
    }

    private func classifyOne(_ rec: Recording, hints: [GeminiClient.ProjectHint]) async {
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let txtURL = deps.layout.audioDir(date: date).appending(path: "\(stem).transcript.txt")
        do {
            let transcript = (try? String(contentsOf: txtURL, encoding: .utf8)) ?? ""
            let threshold = (try? classifierThreshold()) ?? 0.7
            let decision = try await RetryPolicy.run {
                try await deps.gemini.classify(transcript: transcript, projects: hints)
            }
            let assign = decision.confidence >= threshold && decision.projectId != nil
            let linkState: Recording.LinkState = assign ? .pendingRelink : .none
            try recordings.setClassification(
                sourceId: rec.sourceId,
                projectId: assign ? decision.projectId : nil,
                confidence: decision.confidence,
                reasoning: decision.reasoning,
                by: "gemini-3-flash-preview",
                at: deps.now(),
                linkState: linkState)
            try recordings.clearError(sourceId: rec.sourceId, stage: .classify)
            deps.logger.info("classify_ok", source: rec.sourceId)
        } catch {
            try? recordings.recordError(sourceId: rec.sourceId, stage: .classify,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("classify_failed", source: rec.sourceId, message: "\(error)")
        }
    }
}
```

### Task 4.8: `Pipeline.relinkChanged`

**Test** — recording with `project_link_state='pending_relink'` and an existing `linked_project_id`; assert the old project's symlink/copies are removed, the new project's contents are written, `linked_project_id` is updated, and `project_link_state` becomes `'linked'`. A second test covers `linked_project_id == nil` (first link) writing to the new project only.

```swift
extension Pipeline {
    func relinkChanged() throws {
        let pending = (try? recordings.recordingsNeedingRelink()) ?? []
        for rec in pending {
            do {
                if let oldSlug = rec.linkedProjectId {
                    try removeProjectLinks(rec: rec, slug: oldSlug)
                }
                if let newSlug = rec.projectId {
                    try writeProjectLinks(rec: rec, slug: newSlug)
                }
                try recordings.markLinked(sourceId: rec.sourceId, linkedProjectId: rec.projectId)
                try recordings.clearError(sourceId: rec.sourceId, stage: .link)
            } catch {
                try? recordings.recordError(sourceId: rec.sourceId, stage: .link,
                                            at: deps.now(), message: "\(error)")
                deps.logger.error("relink_failed", source: rec.sourceId, message: "\(error)")
            }
        }
    }

    private func writeProjectLinks(rec: Recording, slug: String) throws {
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let audioDir = deps.layout.audioDir(date: date)
        let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let projectDir = deps.layout.projectDir(slug: slug)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Idempotent: any prior partial result is removed before re-copying.
        func replaceCopy(from src: URL, to dst: URL) throws {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
        }
        try replaceCopy(from: audioDir.appending(path: "\(stem).transcript.txt"),
                        to: projectDir.appending(path: "\(stem).transcript.txt"))
        try replaceCopy(from: audioDir.appending(path: "\(stem).deepgram.json"),
                        to: projectDir.appending(path: "\(stem).deepgram.json"))

        let ext = rec.audioExtension ?? "audio"
        let audio = audioDir.appending(path: "\(stem).\(ext)")
        let link = projectDir.appending(path: "\(stem).\(ext)")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: audio)
    }

    private func removeProjectLinks(rec: Recording, slug: String) throws {
        let projectDir = deps.layout.projectDir(slug: slug)
        let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        for ext in ["transcript.txt", "deepgram.json",
                    rec.audioExtension ?? "audio"] {
            try? FileManager.default.removeItem(at: projectDir.appending(path: "\(stem).\(ext)"))
        }
    }
}
```

### Task 4.8a: Bounded-concurrency + relink-retry tests

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/PipelineConcurrencyTests.swift`

Three tests:

1. **`bounded_concurrency_caps_at_three`** — seed 10 download-pending rows; instrument the stub so each handler counts current in-flight requests via an atomic counter; assert the observed peak ≤ 3.

2. **`transcribe_stage_uses_same_bound`** — same shape, applied to `transcribeNew`. Asserts that `runBounded` is the single mechanism.

3. **`relink_recovers_from_partial_failure`** — start with a recording whose project copies were partially written previously (transcript.txt already exists in the project dir from a prior failed run); run `relinkChanged`; assert no error and the project dir ends up consistent (both files copied, symlink present).

### Task 4.9: Full-cycle integration test

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/PipelineEndToEndTests.swift`

Asserts: a fresh DB + one stubbed listing of 2 recordings + stubbed temp-urls + stubbed downloads + stubbed Deepgram + stubbed Gemini ends with both rows fully populated, audio files on disk under `audioDir(date:)`, transcript and deepgram JSON next to the audio, project folder containing two copies plus a symlink to each audio file.

---

## Phase 5 — Keychain & cross-process notifications

### Task 5.1: `KeychainStore.swift` with `kSecUseDataProtectionKeychain`

The runtime access group must be the *resolved* team-prefixed string (`C8Q84FVJHL.com.benphillips.tapedeck`), because `$(AppIdentifierPrefix)` substitution only happens in entitlements files at build time — never in Swift source. Production code uses `KeychainStore.shared` (resolved string baked in); test code uses `KeychainStore(accessGroup: nil)` to fall back to the default file-scoped keychain so unsigned `swift test` processes work.

```swift
// ABOUTME: Keychain access for shared items between Tapedeck UI and helper.
// ABOUTME: Uses kSecUseDataProtectionKeychain on macOS so kSecAttrAccessGroup applies.

import Foundation
import Security

public struct KeychainStore: Sendable {
    /// Resolved access group (team-prefixed) — must match both binaries' entitlements verbatim.
    public static let sharedAccessGroup = "C8Q84FVJHL.com.benphillips.tapedeck"

    /// Production wiring used by both binaries.
    public static let shared = KeychainStore(accessGroup: sharedAccessGroup)

    /// nil disables access-group scoping — only safe in unsigned test processes.
    public let accessGroup: String?

    public init(accessGroup: String?) { self.accessGroup = accessGroup }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let ag = accessGroup { q[kSecAttrAccessGroup as String] = ag }
        return q
    }

    public func set(service: String, account: String, value: String) throws {
        let base = baseQuery(service: service, account: account)
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    public func get(service: String, account: String) throws -> String? {
        var q = baseQuery(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.osStatus(status) }
        return String(data: data, encoding: .utf8)
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError.osStatus(status) }
    }

    public enum KeychainError: Error { case osStatus(OSStatus) }
}
```

`KeychainStoreTests.swift` constructs `KeychainStore(accessGroup: nil)` so the file-scoped keychain handles the round-trip; cross-process verification lives in `scripts/verify-keychain-sharing.sh` against the signed `.app`.

### Task 5.2: `AppStateNotifier.swift` — `DistributedNotificationCenter`

```swift
// ABOUTME: Cross-process signalling between Tapedeck UI and TapedeckSyncHelper.
// ABOUTME: Helper posts state-changed; UI subscribes and refetches.

import Foundation

public struct AppStateNotifier: Sendable {
    public static let name = Notification.Name("com.benphillips.tapedeck.state-changed")

    public static func post(changedKey: String) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: ["key": changedKey], deliverImmediately: true)
    }

    /// Returns the observer token; caller is responsible for removeObserver(_:).
    public static func subscribe(onMain block: @escaping @Sendable (String?) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main) { note in
                block(note.userInfo?["key"] as? String)
            }
    }
}
```

No unit test — `DistributedNotificationCenter` cross-process behaviour is hard to test in `swift test`. Covered by the keychain-sharing integration script and manual smoke during Phase 11.

---

## Phase 6 — TapedeckSyncHelper binary

### Task 6.0: `SyncLogger.swift` — JSON-lines logger (synchronous writes)

`SyncLogger` is the concrete `SyncLog` (introduced in Task 4.2a) that backs the helper binary. Writes are synchronous so the process can `exit()` immediately after logging without losing the last line. Path: `~/Library/Logs/Tapedeck/sync.log`.

```swift
// ABOUTME: File-backed SyncLog. Synchronous fsync after every line — the helper
// ABOUTME: exits seconds after the last log, so async queueing would lose events.

import Foundation

public final class SyncLogger: SyncLog, @unchecked Sendable {
    let url: URL
    let lock = NSLock()

    public init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        self.url = url
    }
    public func info(_ stage: String, source: String?) {
        write(.init(level: "info", stage: stage, source: source, message: nil))
    }
    public func error(_ stage: String, source: String?, message: String) {
        write(.init(level: "error", stage: stage, source: source, message: message))
    }

    struct Event: Encodable {
        let ts: Int64; let level: String; let stage: String
        let source: String?; let message: String?
        init(level: String, stage: String, source: String?, message: String?) {
            self.ts = Int64(Date().timeIntervalSince1970 * 1000); self.level = level
            self.stage = stage; self.source = source; self.message = message
        }
    }

    private func write(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(event) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([0x0A]))
        try? handle.synchronize()
    }
}
```

Commit: `feat(core): synchronous SyncLogger`.

### Task 6.1: `TapedeckSyncHelper/main.swift`

Replace the placeholder:

```swift
// ABOUTME: CLI entry for one sync cycle. Single-flight via SyncLock. Logs structured JSON.
// ABOUTME: Launched by LaunchAgent every 15 min, by UI at launch, and by "Sync now".

import Foundation
import TapedeckCore

@main
struct TapedeckSyncHelper {
    static func main() async {
        let args = CommandLine.arguments

        // Phase 10.1 sentinel — must run before any pipeline construction so
        // verify-keychain-sharing.sh can exit cleanly without spinning up SQLite.
        if args.contains("--read-keychain-sentinel") {
            let value = (try? KeychainStore.shared.get(
                service: "tapedeck.source.jwt.sentinel", account: "default")) ?? ""
            print(value)
            exit(0)
        }

        let layout = Layout.standard
        let logger = SyncLogger(url: layout.logURL())
        do {
            let lock = try SyncLock(path: layout.lockURL())
            guard lock.tryAcquire() else {
                logger.info("sync_skipped_already_running", source: nil)
                exit(0)
            }
            let store = try Store.open(at: layout.dbURL())
            let keychain = KeychainStore.shared
            guard let token = try keychain.get(service: "tapedeck.source.jwt", account: "default") else {
                logger.error("token_missing", source: nil, message: "no JWT in keychain")
                exit(2)
            }
            guard let deepgramKey = try keychain.get(service: "tapedeck.deepgram.key", account: "default"),
                  let geminiKey = try keychain.get(service: "tapedeck.gemini.key", account: "default") else {
                logger.error("api_key_missing", source: nil, message: "Deepgram or Gemini key missing")
                exit(3)
            }
            let pipeline = Pipeline(deps: .init(
                store: store, layout: layout,
                source: SourceClient(token: token),
                deepgram: DeepgramClient(apiKey: deepgramKey),
                gemini: GeminiClient(apiKey: geminiKey),
                logger: logger, now: { Int64(Date().timeIntervalSince1970 * 1000) }
            ))
            try await pipeline.runCycle()
            AppStateNotifier.post(changedKey: "last_sync_at")
            exit(0)
        } catch SourceClientError.unauthorised {
            try? writeTokenStatus(layout: layout, value: "expired")
            AppStateNotifier.post(changedKey: "token_status")
            logger.error("token_expired", source: nil, message: "401 from upstream")
            exit(4)
        } catch Pipeline.PipelineError.tokenExpired {
            // app_state already says 'expired' — keep state, just exit.
            logger.info("token_already_expired", source: nil)
            AppStateNotifier.post(changedKey: "token_status")
            exit(4)
        } catch {
            logger.error("cycle_failed", source: nil, message: "\(error)")
            exit(1)
        }
    }
}

private func writeTokenStatus(layout: Layout, value: String) throws {
    let store = try Store.open(at: layout.dbURL())
    try store.write { db in
        try db.execute(sql: """
            INSERT INTO app_state(key,value) VALUES('token_status', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [value])
    }
}
```

`Pipeline.PipelineError.tokenExpired` propagation: `ensureToken()` already throws it from a stored `app_state.token_status = 'expired'`. The pipeline stage handlers (`downloadOne`, `transcribeOne`, etc.) must re-throw `SourceClientError.unauthorised` instead of recording it as a per-recording error — see the next task.

### Task 6.1a: 401 from any pipeline stage aborts the cycle

`downloadOne`, `transcribeOne`, `classifyOne` currently swallow every error as a `recording_errors` row. A Plaud 401 mid-stage means the JWT is dead — we cannot make progress on any subsequent recording, so the right behaviour is to propagate up to the helper's catch and exit 4.

```swift
// In Pipeline.swift, inside each stage's per-recording catch block:
catch SourceClientError.unauthorised {
    // Don't record per-recording. Let the cycle abort and the helper write
    // token_status='expired'.
    throw SourceClientError.unauthorised
}
catch { /* existing error-row logic */ }
```

Because per-recording work runs inside `TaskGroup`s, the propagation pattern is: each stage tracks whether *any* child task observed `SourceClientError.unauthorised`; after the group finishes, if the flag is set, the stage rethrows. Use an `actor AuthState { var failed = false }` injected per stage so concurrent children can flip the bit safely.

**Test** — wire a stub that returns 401 on `tempURL(for:)` for one of three pending downloads; assert `runCycle()` throws `SourceClientError.unauthorised`, no `recording_errors` rows are written for *any* of the three recordings, and `Pipeline.touchLastSync()` was not called (i.e. `app_state.last_sync_at` is unchanged).

Update `project.yml` to drop the placeholder from `TapedeckSyncHelper/Placeholder.swift` (just leave `main.swift`).

Build with `xcodebuild -scheme TapedeckSyncHelper`; should succeed. Commit.

### Task 6.2: (removed — `SyncLogger` is now Task 6.0)

<details><summary>old async-queue implementation — superseded by Task 6.0's synchronous version</summary>

```swift
public final class SyncLogger: SyncLog, @unchecked Sendable {
    let url: URL
    let queue = DispatchQueue(label: "tapedeck.logger")

    public init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
    }
    public func info(_ stage: String, source: String?) { write(.init(level: "info", stage: stage, source: source, message: nil)) }
    public func error(_ stage: String, source: String?, message: String) { write(.init(level: "error", stage: stage, source: source, message: message)) }

    struct Event: Encodable { let ts: Int64; let level: String; let stage: String; let source: String?; let message: String?
        init(level: String, stage: String, source: String?, message: String?) {
            self.ts = Int64(Date().timeIntervalSince1970 * 1000); self.level = level
            self.stage = stage; self.source = source; self.message = message
        }
    }
    private func write(_ event: Event) {
        queue.async {
            guard let data = try? JSONEncoder().encode(event) else { return }
            if !FileManager.default.fileExists(atPath: self.url.path) {
                FileManager.default.createFile(atPath: self.url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: self.url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data + Data([0x0A]))
                try? handle.close()
            }
        }
    }
}
```

</details>

---

## Phase 7 — Tapedeck UI binary

Each task implements one view or one piece of glue. Aim for ~30-line views with @Observable state objects. SwiftUI patterns are conventional; tests focus on the @Observable state classes, not the views.

### Task 7.1: `TapedeckApp.swift` + `AppDelegate.swift` + shell views

**Files:**
- Delete: `Tapedeck/Placeholder.swift` (declares the previous `@main` — must be removed before adding a new one or Swift complains about duplicate `@main`).
- Create: `Tapedeck/TapedeckApp.swift`
- Create: `Tapedeck/AppDelegate.swift`
- Create: `Tapedeck/Views/MainView.swift`
- Create: `Tapedeck/Views/SettingsView.swift`

```swift
// TapedeckApp.swift
// ABOUTME: SwiftUI entry. Owns AppDelegate + AppState. Window declares Sidebar/List/Detail.

import SwiftUI
import TapedeckCore

@main
struct TapedeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Window("Tapedeck", id: "main") {
            MainView()
                .environment(appDelegate.appState)
                .environment(appDelegate.updateManager)
        }
        Settings { SettingsView()
            .environment(appDelegate.appState)
            .environment(appDelegate.updateManager) }
    }
}
```

`Tapedeck/Views/MainView.swift` — the three-pane container; child views (Sidebar/List/Detail) come from Tasks 7.4–7.6:

```swift
struct MainView: View {
    @Environment(AppState.self) var appState
    var body: some View {
        NavigationSplitView {
            ProjectSidebar()
        } content: {
            RecordingList()
        } detail: {
            DetailPane()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Sync now") {
                    Task { try? await SyncCoordinator.shared.runOnce(reason: "ui_button") }
                }
            }
        }
        .overlay(alignment: .top) {
            if appState.tokenStatus == "expired" { ReAuthBanner() }
        }
    }
}
```

`Tapedeck/Views/SettingsView.swift` — tab container that hosts the four Settings tabs from Tasks 7.7–7.10:

```swift
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountTab().tabItem { Label("Account", systemImage: "person.crop.circle") }
            TranscriptionTab().tabItem { Label("Transcription", systemImage: "waveform") }
            ClassifierTab().tabItem { Label("Classifier", systemImage: "scope") }
            UpdatesTab().tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 480, height: 360)
    }
}
```

**Dependencies — all of these must be implemented before Task 7.1 compiles:**

- `AppState` (Task 7.2)
- `TokenWindow` (Task 7.3)
- `ProjectSidebar`, `RecordingList`, `DetailPane` (Tasks 7.4–7.6)
- `AccountTab`, `TranscriptionTab`, `ClassifierTab`, `UpdatesTab` (Tasks 7.7–7.10)
- `SyncCoordinator` (Task 7.11)
- `ReAuthBanner` (Task 7.12)
- `UpdateManager` (Task 8.1)
- `LaunchAgent` (Task 9.1)

So although Task 7.1 owns the topmost shell, it is the **last** Phase-7/8/9 task to land. The implementation order is: 7.2 → 7.3 → 7.4 → 7.5 → 7.6 → 7.7 → 7.8 → 7.9 → 7.10 → 7.11 → 7.12 → 8.1 → 9.1 → **7.1** → 7.13 (backfill, which depends on the running app). Each preceding task ships a `swift test`-passing or `xcodebuild`-passing checkpoint on its own. Until 7.1 lands, the UI scheme keeps the Phase 1 placeholder `@main`.

```swift
// AppDelegate.swift
// ABOUTME: Lifecycle, LaunchAgent install/uninstall, Sparkle, distributed-notification subscription.
// ABOUTME: Spawns TapedeckSyncHelper at app launch and on Sync-now actions.

import AppKit
import TapedeckCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let updateManager = UpdateManager()
    var notifierObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { try? await self.appState.refresh() }
        notifierObserver = AppStateNotifier.subscribe { [weak self] key in
            Task { try? await self?.appState.refresh(changedKey: key) }
        }
        LaunchAgent.installIfNeeded()
        spawnHelperOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = notifierObserver { DistributedNotificationCenter.default().removeObserver(obs) }
    }

    func spawnHelperOnLaunch() {
        Task { try? await SyncCoordinator.shared.runOnce(reason: "app_launch") }
    }
}
```

### Task 7.2: `AppState.swift` — observable wrapper around Store

```swift
// ABOUTME: Observable façade over Store for the UI. Refresh is the single read path.
// ABOUTME: Helper writes are seen via DistributedNotificationCenter + 30s fallback poll.

import Foundation
import GRDB
import Observation
import TapedeckCore

@Observable
@MainActor
final class AppState {
    var recordings: [Recording] = []
    var projects: [Project] = []
    var errors: [String: [SyncStage: StageError]] = [:]     // keyed by recording.sourceId
    var tokenStatus: String = "ok"
    var lastSyncAt: Int64? = nil
    var selectedProject: String? = "all"

    private let store: Store
    private let projectRepo: ProjectRepository
    private let recordingRepo: RecordingRepository
    private var timer: Timer?

    init() {
        self.store = try! Store.open(at: Layout.standard.dbURL())
        self.projectRepo = ProjectRepository(store: store)
        self.recordingRepo = RecordingRepository(store: store)
        startPolling()
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { try? await self.refresh() }
        }
    }

    func refresh(changedKey: String? = nil) async throws {
        let projects = try projectRepo.listActive()
        let recordings = try store.read { db in try Self.fetchAllRecordings(db) }
        let errors = try store.read { db in try Self.fetchErrors(db) }
        let storedStatus = try store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'token_status'")
        }
        // Authoritative source for "do we have a token at all?" is the keychain,
        // not app_state. app_state.token_status only carries the "expired" marker
        // that the helper writes when it sees a Plaud 401.
        let hasToken = (try? KeychainStore.shared.get(
            service: "tapedeck.source.jwt", account: "default")) != nil
        let resolved: String
        switch (hasToken, storedStatus) {
        case (false, _):        resolved = "missing"
        case (true, "expired"): resolved = "expired"
        case (true, _):         resolved = "ok"
        }
        let lastSyncAt = try store.read { db in
            try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_state WHERE key = 'last_sync_at'")
        }
        self.projects = projects
        self.recordings = recordings
        self.errors = errors
        self.tokenStatus = resolved
        self.lastSyncAt = lastSyncAt
    }

    /// Called by TokenWindow after a successful capture, by SettingsView's sign-out, etc.
    /// Clears the "expired" marker so the next cycle is allowed to run.
    func clearTokenStatus() throws {
        try store.write { db in
            try db.execute(sql: "DELETE FROM app_state WHERE key = 'token_status'")
        }
    }

    static func fetchAllRecordings(_ db: Database) throws -> [Recording] {
        try Row.fetchAll(db, sql: "SELECT * FROM recordings ORDER BY started_at DESC").map { row in
            Recording(
                sourceId: row["source_id"], filename: row["filename"],
                startedAt: row["started_at"], durationMs: row["duration_ms"],
                filesize: row["filesize"], audioExtension: row["audio_extension"],
                audioDownloadedAt: row["audio_downloaded_at"],
                transcribedAt: row["transcribed_at"],
                projectId: row["project_id"],
                classificationConfidence: row["classification_confidence"],
                classificationReasoning: row["classification_reasoning"],
                classifiedAt: row["classified_at"],
                classifiedBy: row["classified_by"],
                projectLinkState: Recording.LinkState(rawValue: row["project_link_state"]) ?? .none,
                linkedProjectId: row["linked_project_id"],
                lastSeenAt: row["last_seen_at"])
        }
    }

    static func fetchErrors(_ db: Database) throws -> [String: [SyncStage: StageError]] {
        var out: [String: [SyncStage: StageError]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM recording_errors") {
            let sid: String = row["source_id"]
            guard let stage = SyncStage(rawValue: row["stage"]) else { continue }
            out[sid, default: [:]][stage] = StageError(
                sourceId: sid, stage: stage,
                occurredAt: row["occurred_at"], attempt: row["attempt"],
                message: row["message"])
        }
        return out
    }

    /// User-initiated overrides — UI calls this from the Detail pane's project picker.
    func overrideProject(sourceId: String, newProjectId: String?) async throws {
        try recordingRepo.setClassification(
            sourceId: sourceId, projectId: newProjectId,
            confidence: 1.0, reasoning: "manual override",
            by: "user", at: Int64(Date().timeIntervalSince1970 * 1000),
            linkState: .pendingRelink)
        try await refresh()
        Task.detached { try? await SyncCoordinator.shared.runOnce(reason: "manual_override") }
    }

    /// Detail pane "Retry" button — wipes the error row so the next cycle retries.
    func retry(sourceId: String, stage: SyncStage) async throws {
        try recordingRepo.clearError(sourceId: sourceId, stage: stage)
        try await refresh()
    }
}
```

The 30s poll is the fallback. The primary push path is `AppStateNotifier.subscribe` in `AppDelegate` (Task 7.1), which calls `refresh()` immediately on each helper notification.

### Task 7.3: `TokenWindow.swift` — WKWebView

Mirror design §5: non-persistent `WKWebsiteDataStore`, Safari user-agent, 1s `evaluateJavaScript("localStorage.getItem('pld_tokenstr')")`, after 90 s reveal a paste-token TextField. Token persistence is concrete:

```swift
@MainActor
final class TokenWindowController {
    func saveCapturedToken(_ raw: String, store: AppState) throws {
        // localStorage returns a JSON-quoted string with a leading "bearer " prefix.
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let token = unquoted.hasPrefix("bearer ")
            ? String(unquoted.dropFirst("bearer ".count)) : unquoted
        try KeychainStore.shared.set(
            service: "tapedeck.source.jwt", account: "default", value: token)
        // Clear any prior 'expired' flag so the helper resumes.
        try store.clearTokenStatus()
        AppStateNotifier.post(changedKey: "token_status")
    }
}
```

`AppState.clearTokenStatus()` writes `DELETE FROM app_state WHERE key = 'token_status'`. The `Window` is closed by the caller on success.

### Task 7.4: `ProjectSidebar.swift` — left pane

Standard `List` with pseudo-rows (All, Unassigned, Archived) and a section for active projects. Right-click context menu → Rename / Archive / Edit description. `⊕ New` opens a sheet with two text fields (display name, description).

### Task 7.5: `RecordingList.swift` — centre pane

Filters by `appState.selectedProject`; sorted by `startedAt` desc. Each row: date+time, duration (`Duration.formatted(.units(...))`), three status pips (downloaded/transcribed/classified) coloured by error rows (`appState.errors[sourceId]`), and the project label.

### Task 7.6: `DetailPane.swift` — right pane

Header (title, time, duration, file size); classification block (Picker over `projects`, confidence, reasoning); `▶ Play` button using `AVAudioPlayer(contentsOf:)`; transcript as `TextEditor` (read-only) with speaker labels. Disclosure group "Show metadata" with the raw `.source.json`.

### Task 7.7: Settings → Account tab

**Files:**
- Create: `Tapedeck/Views/Settings/AccountTab.swift`

```swift
struct AccountTab: View {
    @Environment(AppState.self) var appState
    @State private var openTokenWindow = false

    var body: some View {
        Form {
            Section("Plaud") {
                switch appState.tokenStatus {
                case "ok":
                    Label("Signed in", systemImage: "checkmark.seal")
                    Button("Sign out") { try? signOut() }
                case "expired":
                    Label("Session expired — re-sign in", systemImage: "exclamationmark.triangle")
                    Button("Re-sign in via web…") { openTokenWindow = true }
                default:    // "missing"
                    Label("Not signed in", systemImage: "key")
                    Button("Sign in via web…") { openTokenWindow = true }
                }
            }
            Section("Background sync") {
                Toggle("Enable LaunchAgent",
                       isOn: Binding(get: launchAgentEnabled,
                                     set: setLaunchAgentEnabled))
            }
        }
        .sheet(isPresented: $openTokenWindow) { TokenWindow() }
    }

    private func signOut() throws {
        try KeychainStore.shared.delete(service: "tapedeck.source.jwt", account: "default")
        try appState.clearTokenStatus()
        Task { try? await appState.refresh() }
        AppStateNotifier.post(changedKey: "token_status")
    }
    private func launchAgentEnabled() -> Bool { FileManager.default.fileExists(atPath: LaunchAgent.plistURL.path) }
    private func setLaunchAgentEnabled(_ on: Bool) {
        if on { LaunchAgent.installIfNeeded() } else { LaunchAgent.uninstall() }
    }
}
```

### Task 7.8: Settings → Transcription tab (Deepgram key)

```swift
struct TranscriptionTab: View {
    @State private var key: String = ""
    @State private var saveState: SaveState = .idle
    enum SaveState { case idle, saved, invalid }

    var body: some View {
        Form {
            Section("Deepgram") {
                SecureField("API key", text: $key)
                    .onAppear {
                        key = (try? KeychainStore.shared.get(
                            service: "tapedeck.deepgram.key", account: "default")) ?? ""
                    }
                HStack {
                    Button("Save") { saveKey() }
                        .disabled(key.isEmpty)
                    Button("Test connection") { Task { await testKey() } }
                        .disabled(key.isEmpty)
                    statusLabel
                }
            }
        }
    }

    @ViewBuilder var statusLabel: some View {
        switch saveState {
        case .idle:    EmptyView()
        case .saved:   Label("Saved", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .invalid: Label("Key rejected", systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }

    private func saveKey() {
        try? KeychainStore.shared.set(service: "tapedeck.deepgram.key", account: "default", value: key)
        saveState = .saved
    }

    private func testKey() async {
        // 1-byte WAV header is enough to provoke either 200 or 401; we only care about auth.
        do {
            let c = DeepgramClient(apiKey: key)
            _ = try await c.transcribe(audioAt: URL(fileURLWithPath: "/dev/null"),
                                       contentType: "audio/wav")
            saveState = .saved
        } catch DeepgramClient.DeepgramError.invalidApiKey {
            saveState = .invalid
        } catch {
            saveState = .saved   // any non-auth error means the key was accepted
        }
    }
}
```

### Task 7.9: Settings → Classifier tab (Gemini key + confidence threshold)

Same shape as the Transcription tab but writing to `service: "tapedeck.gemini.key"` and including a `Slider("Confidence threshold", value: $threshold, in: 0.5...0.95)` that writes to `app_state.classifier_threshold`. `Pipeline.classifyOne` reads that value (defaulting to 0.7) instead of the hard-coded literal. Test the key with a 1-character transcript + empty hints; treat any non-`invalidApiKey` outcome as success.

### Task 7.10: Settings → Updates tab

Binds `Toggle("Automatically check", isOn: $automaticallyChecksForUpdates)` against `updateManager.controller.updater.automaticallyChecksForUpdates` and a `Button("Check now") { updateManager.checkForUpdates() }`.

### Task 7.11: `SyncCoordinator.swift` — non-blocking single-flight wrapper around `Process`

The helper can take minutes to finish; we must never call `waitUntilExit()` on the main actor. The actor below uses `Process.terminationHandler` + a `CheckedContinuation` so the await yields control back to SwiftUI immediately.

```swift
// ABOUTME: Spawns TapedeckSyncHelper as a child process. One concurrent run at a time.
// ABOUTME: Resolves via terminationHandler so the main actor never blocks on waitUntilExit.

import Foundation

actor SyncCoordinator {
    static let shared = SyncCoordinator()
    private var inflight: Task<Int32, Error>?

    /// Spawns the helper if not already running; returns its termination status (0 on success).
    @discardableResult
    func runOnce(reason: String) async throws -> Int32 {
        if let existing = inflight { return try await existing.value }
        let task = Task { try await self.spawn(reason: reason) }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    private func spawn(reason: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let proc = Process()
            proc.executableURL = Bundle.main.bundleURL
                .appending(path: "Contents/MacOS/TapedeckSyncHelper")
            proc.environment = ProcessInfo.processInfo.environment
                .merging(["TAPEDECK_SYNC_REASON": reason]) { _, new in new }
            proc.terminationHandler = { p in
                cont.resume(returning: p.terminationStatus)
            }
            do { try proc.run() }
            catch { cont.resume(throwing: error) }
        }
    }
}
```

Non-zero exit codes surface in the UI: `AppDelegate` awaits `SyncCoordinator.shared.runOnce(...)`, logs the status, and posts an in-app toast on values other than 0. The mapping comes from `TapedeckSyncHelper/main.swift`:

| Exit | Meaning | UI surface |
|------|---------|------------|
| 0    | success | none — refresh on notification |
| 1    | cycle threw | "Sync failed — check logs" |
| 2    | token missing | "Sign in to Plaud" banner |
| 3    | API key missing | Settings highlight |
| 4    | token expired | "Sign in to Plaud" banner |

### Task 7.12: re-auth banner

Conditional `HStack` at the top of `MainView` showing when `appState.tokenStatus == "expired"`: "Sign in to Plaud" / button opens `TokenWindow`.

### Task 7.13: first-run backfill

On `appState.init()` after migrations: if `recordings` table is empty AND `~/Tapedeck/audio` exists, scan it and seed rows with what's derivable from the filenames (sourceId is the prefix before the first `_`). Mark `audio_downloaded_at` = file mtime so the pipeline doesn't re-download. Leave transcription/classification null so the next cycle picks them up.

---

## Phase 8 — Auto-update

### Task 8.1: `UpdateManager.swift` (lifted from countdown)

```swift
// ABOUTME: Thin observable wrapper around SPUStandardUpdaterController.
// ABOUTME: Init with startingUpdater:true so background checks run immediately.

import Combine
import Sparkle

@Observable @MainActor
final class UpdateManager {
    let controller: SPUStandardUpdaterController
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
```

### Task 8.2: Generate Sparkle EdDSA keypair

Ask Ben to run this once, then paste the public key into `project.yml`:

```bash
mkdir -p scripts/sparkle-tools
scripts/download-sparkle-tools.sh   # see Task 8.3
scripts/sparkle-tools/bin/generate_keys
# Public key prints to stdout; store the private key in macOS Keychain as
# "https://sparkle-project.org" (sign_update reads it from there).
```

Update `project.yml`'s `SUPublicEDKey` placeholder.

### Task 8.3: `scripts/download-sparkle-tools.sh` (copy from countdown verbatim — see the agent report for full contents)

---

## Phase 9 — LaunchAgent

### Task 9.1: `LaunchAgent.swift` — install/uninstall + plist generation

```swift
// ABOUTME: Installs ~/Library/LaunchAgents/com.benphillips.tapedeck.synchelper.plist.
// ABOUTME: Idempotent; safe to call every launch.

import Foundation

enum LaunchAgent {
    static let label = "com.benphillips.tapedeck.synchelper"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static func installIfNeeded() {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/MacOS/TapedeckSyncHelper")
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helper.path],
            "StartInterval": 900,                 // 15 minutes
            "RunAtLoad": false,
            "StandardOutPath": "/tmp/tapedeck-sync.out.log",
            "StandardErrorPath": "/tmp/tapedeck-sync.err.log",
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: plistURL)) != data {
            try? data.write(to: plistURL)
            reload()
        }
    }

    static func uninstall() {
        _ = Process.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func reload() {
        _ = Process.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        _ = Process.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    }
}

private extension Process {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        try? p.run(); p.waitUntilExit(); return p.terminationStatus
    }
}
```

Wire `LaunchAgent.installIfNeeded()` into `AppDelegate.applicationDidFinishLaunching`. Add a "Disable background sync" toggle in Settings → Account that calls `LaunchAgent.uninstall()`.

---

## Phase 10 — Build & release scripts

### Task 10.1: Sentinel CLI flags on both binaries

Done first because `scripts/verify-keychain-sharing.sh` (Task 10.2) and `scripts/build-release.sh` (Task 10.3) both depend on these flags existing.

**Files:**
- Modify: `Tapedeck/TapedeckApp.swift` (or add `Tapedeck/SentinelMode.swift`)
- Modify: `TapedeckSyncHelper/main.swift`

The UI binary normally launches SwiftUI; we add a pre-`App.main()` switch so `--write-keychain-sentinel <UUID>` writes the sentinel and exits without ever creating a window:

```swift
// SentinelMode.swift
import Foundation
import TapedeckCore

@main
enum AppEntry {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--write-keychain-sentinel"),
           idx + 1 < args.count {
            do {
                try KeychainStore.shared.set(
                    service: "tapedeck.source.jwt.sentinel",
                    account: "default",
                    value: args[idx + 1])
                exit(0)
            } catch { fputs("\(error)\n", stderr); exit(2) }
        }
        TapedeckApp.main()
    }
}
```

(Remove `@main` from `TapedeckApp` when `AppEntry` is added.)

The helper binary gets a sibling `--read-keychain-sentinel` flag inside `TapedeckSyncHelper.main()` — see Task 6.1 for the canonical placement (it must be the first thing inside `static func main() async`, before any logger or SQLite construction, so the sentinel run is side-effect-free and exits in milliseconds).

`scripts/verify-keychain-sharing.sh` (Task 10.2) writes a UUID via the UI flag and reads it back via the helper flag; mismatch aborts the release.

### Task 10.2: `scripts/verify-keychain-sharing.sh`

```bash
#!/bin/bash
# ABOUTME: Round-trips a sentinel JWT between the UI binary and helper binary
# ABOUTME: of a freshly-signed Tapedeck.app to catch entitlement drift.
set -euo pipefail
APP="${1:?path/to/Tapedeck.app}"
SENTINEL=$(uuidgen)
UI="$APP/Contents/MacOS/Tapedeck"
HELPER="$APP/Contents/MacOS/TapedeckSyncHelper"

"$UI" --write-keychain-sentinel "$SENTINEL"
read_back=$("$HELPER" --read-keychain-sentinel)
if [ "$read_back" = "$SENTINEL" ]; then
  echo "OK keychain shared"; exit 0
else
  echo "FAIL expected $SENTINEL, got $read_back"; exit 1
fi
```

### Task 10.3: `scripts/build-release.sh`

Adapt `~/repos/countdown/scripts/build-release.sh` (full contents in the Phase 0 research above). Order is fixed below — the keychain verification runs against the signed *but unnotarised* `.app` because notarisation is non-recoverable: if the keychain check fails after notarytool submission we've burned an Apple-side notary record for nothing. Tagging is the last operation so a notarisation or upload failure never leaves a tag pointing at a release that doesn't exist on disk.

1. Bail on dirty tree or existing tag.
2. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Tapedeck/Info.plist`, `TapedeckSyncHelper/Info.plist`, and `project.yml`.
3. `git commit -m "release: v$VER"` — bump commit only, no tag yet.
4. `xcodegen generate`.
5. `xcodebuild archive` → `build/Tapedeck.xcarchive`.
6. `xcodebuild -exportArchive -exportOptionsPlist ExportOptions.plist` → `build/export/Tapedeck.app` (Developer ID signed, hardened runtime, *not yet notarised*).
7. **`scripts/verify-keychain-sharing.sh build/export/Tapedeck.app`** — round-trip a sentinel JWT between UI and helper binaries. Abort on failure before going any further; the failure mode here is entitlement drift, which would also break notarisation in subtle ways.
8. `create-dmg` → `build/Tapedeck-$VER.dmg` (wraps the signed `.app`).
9. `xcrun notarytool submit build/Tapedeck-$VER.dmg --keychain-profile tapedeck-notarize --wait` — `notarytool` accepts only `.zip`, `.pkg`, or `.dmg`, never a bare `.app`. Stapling the DMG also staples the `.app` it contains when the disk image is rebuilt on mount.
10. `xcrun stapler staple build/Tapedeck-$VER.dmg`.
11. EdDSA sign the DMG: `scripts/sparkle-tools/bin/sign_update build/Tapedeck-$VER.dmg`.
12. `scripts/sparkle-tools/bin/generate_appcast build/` → `build/appcast.xml`.
13. Push `Tapedeck-$VER.dmg` + `appcast.xml` to the `gh-pages` branch (worktree pattern — see countdown's script lines 112–157).
14. `gh release create v$VER build/Tapedeck-$VER.dmg --generate-notes` — creates the tag *and* the GitHub Release in one operation; this is when v$VER first exists.
15. Print a release-notes prompt.

`gh release create` creates the tag at HEAD if it doesn't already exist, so we don't need a separate `git tag && git push --tags` step. The order matches countdown's release script except for the inserted keychain-verification step.

### Task 10.4: CI workflow

**Files:**
- Create: `.github/workflows/test.yml`

```yaml
name: test
on: [push, pull_request]
jobs:
  swift-test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: swift-actions/setup-swift@v2
        with:
          swift-version: "6.0"
      - run: swift test --package-path TapedeckCore
```

(countdown has no workflow; Tapedeck adds one because its core has more testable surface.)

---

## Phase 11 — Bootstrap runbook

### Task 11.1: `docs/runbooks/first-launch.md`

Document the three environment moves (design §7) as a manual checklist with backup commands, plus the keychain-key entry instructions (Deepgram + Gemini), and the LaunchAgent confirmation step (`launchctl print gui/$(id -u)/com.benphillips.tapedeck.synchelper`).

### Task 11.2: Manual smoke

After Ben runs the bootstrap and signs in via TokenWindow:

1. Verify the LaunchAgent fires: `tail -F ~/Library/Logs/Tapedeck/sync.log` — should see structured events after at most 15 min.
2. Force a cycle: open Tapedeck and click "Sync now" — should see new lines in the log within seconds.
3. Inspect `~/Tapedeck/projects/<slug>/` — should contain transcript copies + symlinks for any classified recording.
4. Quit Tapedeck; confirm helper still runs on its 15-min interval.

---

## Summary

71 tasks across 11 phases. Each task is one TDD increment (red → green → commit) or one scaffolding step with explicit `xcodebuild` / `swift test` verification. The plan front-loads fixture capture (Phase 0) because Phase 7 deletes the source of those fixtures; it back-loads the destructive bootstrap (Phase 11) so failure during implementation never corrupts the existing `~/Plaud` corpus.
