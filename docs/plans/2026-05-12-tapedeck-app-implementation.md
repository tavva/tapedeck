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

**Step 1: Decode the user's JWT payload, scrub identifiers**

```bash
TOKEN=$(cat ~/.config/plaud/token)
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq . > /tmp/raw.json
# Inspect /tmp/raw.json; identify the region field — likely 'aws:region' or 'region'.
# Build the redacted version preserving structural keys (especially the region claim)
# but replacing any user-identifying strings with placeholders.
jq '{
  iss: "redacted",
  sub: "redacted",
  region: .region // ."aws:region" // "eu-central-1",
  exp: .exp,
  iat: .iat
}' /tmp/raw.json > TapedeckCore/Tests/TapedeckCoreTests/Fixtures/source/jwt_payload_redacted.json
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
curl -sSf 'https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&diarize=true' \
  -H "Authorization: Token ${DEEPGRAM_API_KEY}" \
  -H 'Content-Type: audio/*' \
  --data-binary "@${SHORT}" \
  | jq . > TapedeckCore/Tests/TapedeckCoreTests/Fixtures/deepgram/short_recording.json
```

**Step 2: Gemini** — hand-author the four expected response shapes:

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

**Step 7: Generate the project and verify it builds**

```bash
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate
xcodebuild -project Tapedeck.xcodeproj -scheme Tapedeck -configuration Debug build -quiet
xcodebuild -project Tapedeck.xcodeproj -scheme TapedeckSyncHelper -configuration Debug build -quiet
```

Expected: both schemes build with no errors. (Source files are empty placeholders — that's fine; XcodeGen will have wired the targets.)

**Step 8: Create one no-op source per target so the build resolves a product**

`Tapedeck/Placeholder.swift`:
```swift
// ABOUTME: Placeholder so XcodeGen's source phase has a file to compile.
// ABOUTME: Replaced by TapedeckApp.swift in Phase 7.

import Foundation
```

`TapedeckSyncHelper/Placeholder.swift`:
```swift
// ABOUTME: Placeholder so the tool target produces an executable.
// ABOUTME: Replaced by main.swift in Phase 6.

print("tapedeck-sync-helper placeholder")
```

Re-run Step 7 expectations.

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
    public let dbPool: DatabasePool

    private init(pool: DatabasePool) throws {
        self.dbPool = pool
        try Self.migrator.migrate(pool)
    }

    public static func open(at url: URL) throws -> Store {
        var config = Configuration()
        config.journalMode = .wal
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try Store(pool: pool)
    }

    public static func openInMemory() throws -> Store {
        let pool = try DatabasePool(path: ":memory:")
        return try Store(pool: pool)
    }

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbPool.read(block)
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbPool.write(block)
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

public final class SourceClient: Sendable {
    public static let defaultHost = URL(string: "https://api.plaud.ai")!
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    let session: URLSession
    let token: String
    public private(set) var host: URL

    public init(token: String, host: URL? = nil, session: URLSession = .shared) {
        self.token = token
        self.host = host ?? Self.hostFromJWT(token) ?? Self.defaultHost
        self.session = session
    }

    /// Returns the regional API host implied by the JWT's region claim, or nil.
    /// Region claim name is whichever §0.5 captured; check both common forms.
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
        let region = (obj["region"] as? String) ?? (obj["aws:region"] as? String)
        return region.flatMap(regionToHost)
    }

    static func regionToHost(_ region: String) -> URL? {
        // Extend this table as new regions appear in JWTs.
        let map: [String: String] = [
            "eu-central-1": "https://api-euc1.plaud.ai",
            "us-east-1": "https://api.plaud.ai",
        ]
        return map[region].flatMap(URL.init(string:))
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

@Suite("SourceClient host discovery")
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
        #expect(client.host.host == "api-euc1.plaud.ai")
    }
}
```

**Step 2: Implementation — append to SourceClient.swift**

```swift
public extension SourceClient {
    /// Resolve the regional host by probing `/file/simple/web` and following the -302 JSON status.
    /// Idempotent — if the current host already returns recordings (status != -302), keeps it.
    func discoverHost() async throws {
        var probe = URLRequest(url: host.appending(path: "/file/simple/web"))
        probe.url = probe.url?.appending(queryItems: [
            .init(name: "skip", value: "0"),
            .init(name: "limit", value: "1"),
            .init(name: "is_trash", value: "0"),
        ])
        addStandardHeaders(&probe)
        let (data, _) = try await session.data(for: probe)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = obj["status"] as? Int, status == -302,
           let domains = (obj["data"] as? [String: Any])?["domains"] as? [String: Any],
           let api = domains["api"] as? String, let url = URL(string: api) {
            host = url
        }
    }

    internal func addStandardHeaders(_ req: inout URLRequest) {
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

@Suite("SourceClient list")
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
public extension SourceClient {
    func listPage(skip: Int, limit: Int = 100) async throws -> [Recording] {
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
        try Self.throwIfUnauthorised(response)
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

    func listAll() async throws -> [Recording] {
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

    static func throwIfUnauthorised(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw SourceClientError.unauthorised }
    }
}

public enum SourceClientError: Error, Equatable {
    case unauthorised
    case malformedResponse(String)
}
```

Run, commit.

### Task 3.6: `SourceClient.tempURL(for:)` and `SourceClient.rawMetadata(for:)`

Same pattern: failing test using `temp_url.json` and `raw_metadata.json` fixtures; implement; commit.

```swift
public extension SourceClient {
    func tempURL(for sourceId: String) async throws -> URL {
        var req = URLRequest(url: host.appending(path: "/file/temp-url/\(sourceId)"))
        addStandardHeaders(&req)
        let (data, response) = try await session.data(for: req)
        try Self.throwIfUnauthorised(response)
        struct Envelope: Decodable { let temp_url: String }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard let url = URL(string: env.temp_url) else {
            throw SourceClientError.malformedResponse("temp_url not a URL")
        }
        return url
    }

    func rawMetadata(for sourceIds: [String]) async throws -> Data {
        var req = URLRequest(url: host.appending(path: "/file/list"))
        req.httpMethod = "POST"
        addStandardHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: sourceIds)
        let (data, response) = try await session.data(for: req)
        try Self.throwIfUnauthorised(response)
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
public extension SourceClient {
    /// Streams `url` to `target.part`, then renames atomically. Returns the extension parsed from url.path.
    func download(from url: URL, target: URL, fileManager: FileManager = .default) async throws -> String {
        let partURL = target.appendingPathExtension("part")
        try? fileManager.removeItem(at: partURL)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let (asyncBytes, response) = try await session.bytes(for: URLRequest(url: url))
        try Self.throwIfUnauthorised(response)
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

```swift
extension SourceClient {
    static func withRetry<T>(_ block: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await block() }
            catch URLError.cannotConnectToHost, URLError.timedOut where attempt < 3 {
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                attempt += 1
            } catch let e as SourceClientError where e == .unauthorised {
                throw e
            } catch {
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                    attempt += 1
                } else { throw error }
            }
        }
    }
}
```

(Refine the catch arms after running the test — the goal is retry on 5xx/429 and timeouts, not on 401.)

### Task 3.9: `DeepgramClient`

**Files:**
- Create: `TapedeckCore/Sources/TapedeckCore/DeepgramClient.swift`
- Create: `TapedeckCore/Tests/TapedeckCoreTests/DeepgramClientTests.swift`

**Test** — uses `Fixtures/deepgram/short_recording.json` to verify the parser returns `(transcript: String, raw: Data, segments: [(speaker:Int, start:Double, text:String)])`. Implementation streams the audio bytes with `Content-Type: audio/*` to `https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&diarize=true&punctuate=true` with `Authorization: Token <KEY>`.

```swift
public struct DeepgramClient: Sendable {
    public struct Result: Sendable {
        public let transcript: String
        public let raw: Data
    }
    let session: URLSession
    let apiKey: String

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey; self.session = session
    }

    public func transcribe(audioAt url: URL, contentType: String) async throws -> Result {
        var req = URLRequest(url: URL(string:
            "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&diarize=true&punctuate=true")!)
        req.httpMethod = "POST"
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBodyStream = InputStream(url: url)
        let (data, response) = try await session.data(for: req)
        try SourceClient.throwIfUnauthorised(response)
        struct Envelope: Decodable {
            struct Results: Decodable {
                struct Channel: Decodable {
                    struct Alt: Decodable { let transcript: String }
                    let alternatives: [Alt]
                }
                let channels: [Channel]
            }
            let results: Results
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        let transcript = env.results.channels.first?.alternatives.first?.transcript ?? ""
        return Result(transcript: transcript, raw: data)
    }
}
```

Refine field names against the actual `short_recording.json` shape captured in §0.6.

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
    public enum GeminiError: Error { case malformedResponse(String) }
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
        let (data, _) = try await session.data(for: req)

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

### Task 4.3: `Pipeline.swift` — orchestrate one cycle

This is the largest file; build it incrementally. Each pipeline stage gets its own test (using the existing client stubs). The shape:

```swift
// ABOUTME: One sync cycle. Idempotent. Sequential stages, parallel within a stage (max 3).
// ABOUTME: Logs structured JSON events to logURL; persists everything via Store.

public actor Pipeline {
    public struct Deps {
        public let store: Store
        public let layout: Layout
        public let source: SourceClient
        public let deepgram: DeepgramClient
        public let gemini: GeminiClient
        public let logger: SyncLogger
        public let now: () -> Int64
    }

    let deps: Deps
    public init(deps: Deps) { self.deps = deps }

    public func runCycle() async throws {
        try await ensureToken()
        try await deps.source.discoverHost()
        try await listRemote()
        try await downloadNew()
        try await transcribeNew()
        try await classifyNew()
        try await relinkChanged()
        try await touchLastSync()
    }

    func ensureToken() async throws { /* read app_state.token_status; throw if 'expired' */ }
    func listRemote() async throws { /* page through, upsert via RecordingRepository */ }
    func downloadNew() async throws { /* up to 3 in parallel via TaskGroup */ }
    func transcribeNew() async throws { /* ditto */ }
    func classifyNew() async throws { /* fetch active projects, build hints, call Gemini */ }
    func relinkChanged() async throws { /* remove old links if linkedProjectId != projectId */ }
    func touchLastSync() async throws { /* app_state.last_sync_at = now */ }
}
```

Each stage is one task in the plan; each task has a TDD test that wires Store + stubs and asserts the expected side-effects on disk and in DB. See design §4 for the exact stage rules — implement them verbatim.

**Key invariants to test:**
- `downloadNew` writes to `.part` first, renames; if the move fails, no orphaned `.audio_downloaded_at`.
- `transcribeNew` on failure: writes `recording_errors` row with stage='transcribe' and `attempt = previous + 1`; on success: clears that row.
- `classifyNew` always sets `classified_at`, even when `projectId` is null (so we don't re-call the model).
- `classifyNew` with confidence ≥ 0.7 *and* non-null projectId sets `project_link_state = 'pending_relink'`; otherwise leaves it `'none'`.
- `relinkChanged` removes links from `linked_project_id` directory and writes to `project_id` directory; sets `linked_project_id = project_id` and `project_link_state = 'linked'`.

Commit per stage.

### Task 4.4: Full-cycle integration test

**Files:**
- Create: `TapedeckCore/Tests/TapedeckCoreTests/PipelineEndToEndTests.swift`

Asserts: a fresh DB + one stubbed listing of 2 recordings + stubbed temp-urls + stubbed downloads + stubbed Deepgram + stubbed Gemini ends with both rows fully populated, audio files on disk under `audioDir(date:)`, transcript and deepgram JSON next to the audio, project folder containing two copies plus a symlink to each audio file.

---

## Phase 5 — Keychain & cross-process notifications

### Task 5.1: `KeychainStore.swift` with `kSecUseDataProtectionKeychain`

```swift
// ABOUTME: Keychain access for shared items between Tapedeck UI and helper.
// ABOUTME: Uses kSecUseDataProtectionKeychain on macOS so kSecAttrAccessGroup applies.

import Foundation
import Security

public struct KeychainStore: Sendable {
    public let accessGroup: String   // "$(AppIdentifierPrefix)com.benphillips.tapedeck"

    public init(accessGroup: String) { self.accessGroup = accessGroup }

    public func set(service: String, account: String, value: String) throws {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    public func get(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.osStatus(status) }
        return String(data: data, encoding: .utf8)
    }

    public func delete(service: String, account: String) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(q as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError.osStatus(status) }
    }

    public enum KeychainError: Error { case osStatus(OSStatus) }
}
```

Tests live in `KeychainStoreTests.swift` and only exercise pure logic against the *default* (file-scoped, no-access-group) keychain — see design §3 note: signed-only verification lives in `scripts/verify-keychain-sharing.sh`.

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
        let layout = Layout.standard
        let logger = SyncLogger(url: layout.logURL())
        do {
            let lock = try SyncLock(path: layout.lockURL())
            guard lock.tryAcquire() else {
                logger.info("sync_skipped_already_running", source: nil)
                exit(0)
            }
            let store = try Store.open(at: layout.dbURL())
            let keychain = KeychainStore(accessGroup: "$(AppIdentifierPrefix)com.benphillips.tapedeck")
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
            try? store_writeTokenExpired(layout: layout)
            AppStateNotifier.post(changedKey: "token_status")
            logger.error("token_expired", source: nil, message: "401 from upstream")
            exit(4)
        } catch {
            logger.error("cycle_failed", source: nil, message: "\(error)")
            exit(1)
        }
    }
}

private func store_writeTokenExpired(layout: Layout) throws {
    let store = try Store.open(at: layout.dbURL())
    try store.write { db in
        try db.execute(sql: "INSERT INTO app_state(key,value) VALUES('token_status','expired') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
    }
}
```

Update `project.yml` to drop the placeholder from `TapedeckSyncHelper/Placeholder.swift` (just leave `main.swift`).

Build with `xcodebuild -scheme TapedeckSyncHelper`; should succeed. Commit.

### Task 6.2: `SyncLogger.swift` — JSON-lines logger

```swift
public final class SyncLogger: Sendable {
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

---

## Phase 7 — Tapedeck UI binary

Each task implements one view or one piece of glue. Aim for ~30-line views with @Observable state objects. SwiftUI patterns are conventional; tests focus on the @Observable state classes, not the views.

### Task 7.1: `TapedeckApp.swift` + `AppDelegate.swift`

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
@Observable
@MainActor
final class AppState {
    var recordings: [Recording] = []
    var projects: [Project] = []
    var tokenStatus: String = "ok"          // "ok" | "expired" | "missing"
    var lastSyncAt: Int64? = nil
    var selectedProject: String? = nil      // "all" | "unassigned" | project.id
    private let store: Store
    private let projectRepo: ProjectRepository
    private let recordingRepo: RecordingRepository

    init() {
        self.store = try! Store.open(at: Layout.standard.dbURL())
        self.projectRepo = ProjectRepository(store: store)
        self.recordingRepo = RecordingRepository(store: store)
    }

    func refresh(changedKey: String? = nil) async throws {
        let projects = try projectRepo.listActive()
        let recordings: [Recording] = try store.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM recordings ORDER BY started_at DESC").map { /* map */ ... }
        }
        await MainActor.run { self.projects = projects; self.recordings = recordings }
    }
}
```

Plus poller — start a 30s `Timer` in `init()` that calls `refresh()` when the window is key.

### Task 7.3: `TokenWindow.swift` — WKWebView

Mirror design §5: non-persistent WKWebsiteDataStore, Safari user agent, 1s `evaluateJavaScript("localStorage.getItem('pld_tokenstr')")`, on hit JSON-parse, strip leading `bearer `, write via `KeychainStore.set(service: "tapedeck.source.jwt", account: "default", value:)`, post `AppStateNotifier.post(changedKey: "token_status")`, close window. After 90s timeout, reveal a paste-token TextField.

### Task 7.4: `ProjectSidebar.swift` — left pane

Standard `List` with pseudo-rows (All, Unassigned, Archived) and a section for active projects. Right-click context menu → Rename / Archive / Edit description. `⊕ New` opens a sheet with two text fields (display name, description).

### Task 7.5: `RecordingList.swift` — centre pane

Filters by `appState.selectedProject`; sorted by `startedAt` desc. Each row: date+time, duration (`Duration.formatted(.units(...))`), three status pips (downloaded/transcribed/classified) coloured by error rows (`appState.errors[sourceId]`), and the project label.

### Task 7.6: `DetailPane.swift` — right pane

Header (title, time, duration, file size); classification block (Picker over `projects`, confidence, reasoning); `▶ Play` button using `AVAudioPlayer(contentsOf:)`; transcript as `TextEditor` (read-only) with speaker labels. Disclosure group "Show metadata" with the raw `.source.json`.

### Task 7.7-7.10: `SettingsView.swift` — four tabs

`Account`, `Transcription`, `Classifier`, `Updates`. Updates tab binds `Toggle("Automatically check", isOn: $automaticallyChecksForUpdates)` against `updateManager.controller.updater.automaticallyChecksForUpdates` and a `Button("Check now") { updateManager.checkForUpdates() }`.

### Task 7.11: `SyncCoordinator.swift` — single-flight wrapper around `Process`

```swift
@MainActor
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    private var inflight: Task<Void, Error>?

    func runOnce(reason: String) async throws {
        if let t = inflight { try await t.value; return }
        let task = Task { try await self.spawn() }
        inflight = task
        defer { inflight = nil }
        try await task.value
    }

    private func spawn() async throws {
        let proc = Process()
        proc.executableURL = Bundle.main.bundleURL.appending(path: "Contents/MacOS/TapedeckSyncHelper")
        try proc.run()
        proc.waitUntilExit()
    }
}
```

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

### Task 10.1: `scripts/build-release.sh`

Adapt `~/repos/countdown/scripts/build-release.sh` verbatim except:
- Replace `Countdown` with `Tapedeck` throughout.
- Add Step 9: `scripts/verify-keychain-sharing.sh build/export/Tapedeck.app` between DMG creation and notarisation.
- Move `git tag v$VER && git push --tags` to after the gh-pages push (design §8).

Full pattern from countdown:
1. Bail on dirty tree or existing tag.
2. Bump versions in `Tapedeck/Info.plist`, `TapedeckSyncHelper/Info.plist`, and `project.yml`.
3. `git commit -m "release: v$VER"` (NO TAG YET).
4. `xcodegen generate`.
5. `xcodebuild archive`.
6. `xcodebuild -exportArchive` with ExportOptions.plist.
7. `xcrun notarytool submit … --wait` and `xcrun stapler staple`.
8. `create-dmg`.
9. `scripts/verify-keychain-sharing.sh` against the signed `.app`.
10. EdDSA sign DMG.
11. `generate_appcast build/`.
12. Push DMG + appcast to gh-pages worktree.
13. `git tag v$VER && git push --tags`.
14. `gh release create v$VER build/Tapedeck-$VER.dmg --generate-notes`.

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

# UI writes via a hidden --write-sentinel flag (added behind #if DEBUG_OR_RELEASE)
"$UI" --write-keychain-sentinel "$SENTINEL"
read_back=$("$HELPER" --read-keychain-sentinel)
if [ "$read_back" = "$SENTINEL" ]; then
  echo "OK keychain shared"; exit 0
else
  echo "FAIL expected $SENTINEL, got $read_back"; exit 1
fi
```

Add the matching CLI flags to both binaries. The UI flag exits immediately after writing (without showing the window); the helper flag does the same on read.

### Task 10.3: CI workflow

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
