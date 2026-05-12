# Tapedeck — design

A small native macOS app that captures audio recordings from a hardware
voice recorder, transcribes them with Deepgram, classifies each transcript
into a user-defined project with Gemini, and writes the result into a
deterministic per-project folder. Background sync runs whether the app is
open or not. External tools (Obsidian, Hazel, fswatch consumers) work
against the per-project folders.

This document is the validated design after brainstorming on 2026-05-12.
Implementation follows in a separate plan.

## 1. High-level architecture

Two binaries inside a single `Tapedeck.app` bundle, sharing one Swift
package and one SQLite database.

```
Tapedeck.app
├─ Contents/MacOS/Tapedeck            UI binary (SwiftUI window)
├─ Contents/MacOS/TapedeckSyncHelper  CLI binary (background work, no UI)
└─ Frameworks/PlaudCore.framework     shared Swift package (renamed: TapedeckCore)
```

- **Tapedeck** (UI) — SwiftUI window: recordings list, projects sidebar,
  settings, first-run WebView for token capture. Foreground only.
- **TapedeckSyncHelper** — headless CLI. One cycle per invocation. Run
  by a LaunchAgent every 15 minutes, by the UI at launch, and by the UI's
  "Sync now" button.
- **TapedeckCore** — shared Swift package with the source-API client,
  Deepgram client, Gemini client, SQLite store, and on-disk layout.

The split exists because a LaunchAgent that runs the GUI app would bounce
the dock icon every 15 minutes. A separate headless binary keeps the
background invisible while letting both binaries share code via the
package.

State lives in two places:

- `~/Library/Application Support/Tapedeck/state.db` — SQLite, WAL mode,
  read/written by both binaries.
- `~/Tapedeck/` — user-visible content (audio, transcripts, project
  folders).

Sensitive credentials live in Keychain, never in either file.

## 2. Components, packaging, auto-update

Repo layout, mirroring the `countdown` project:

```
tapedeck/
├─ project.yml                     XcodeGen spec
├─ Tapedeck.xcodeproj/             generated, gitignored
├─ Tapedeck/
│   ├─ TapedeckApp.swift           @main UI entry
│   ├─ AppDelegate.swift           lifecycle, LaunchAgent install/uninstall
│   ├─ UpdateManager.swift         Sparkle wrapper (same shape as countdown)
│   ├─ Views/                      RecordingList, ProjectSidebar, Settings, TokenWindow
│   └─ Info.plist                  SUFeedURL, SUPublicEDKey, etc.
├─ TapedeckSyncHelper/
│   ├─ main.swift                  CLI entry: run-once sync cycle
│   └─ Info.plist
├─ TapedeckCore/                   Swift package, both targets depend on it
│   └─ Sources/TapedeckCore/
│       ├─ SourceClient.swift      JWT auth, region discovery, list/download
│       ├─ DeepgramClient.swift
│       ├─ GeminiClient.swift
│       ├─ Store.swift             GRDB.swift wrapping SQLite
│       ├─ Layout.swift            on-disk paths
│       └─ Pipeline.swift          orchestrates one cycle
├─ TapedeckCoreTests/
├─ TapedeckTests/
├─ scripts/
│   ├─ build-release.sh            archive → sign → notarise → DMG → appcast
│   └─ generate-appcast.sh         Sparkle generate_appcast helper
└─ docs/plans/2026-05-12-tapedeck-app-design.md
```

**Auto-update via Sparkle**, identical pattern to `countdown`. Sparkle
Swift package, `UpdateManager` wraps `SPUStandardUpdaterController`,
`Info.plist` carries `SUFeedURL` pointing at a GitHub Pages-hosted
`appcast.xml`, public EdDSA key embedded for signature verification.
Releases are manual via `scripts/build-release.sh`.

**Bundle identifiers**

- UI:     `com.benphillips.tapedeck`
- Helper: `com.benphillips.tapedeck.synchelper`

Both signed with the same Developer ID Team. The LaunchAgent plist points
at the helper binary path inside the .app bundle.

**Persistence** uses GRDB.swift wrapping SQLite. Migrations versioned in
`Store.swift`. WAL mode enables concurrent reads/writes from the UI and
helper without a lock dance.

## 3. Data model

### On-disk layout

```
~/Tapedeck/
├─ audio/
│   └─ YYYY-MM-DD/
│       ├─ {source_id}_{title}.ogg              audio (or .mp3 — per recording)
│       ├─ {source_id}_{title}.source.json      upstream service metadata
│       ├─ {source_id}_{title}.deepgram.json    Deepgram raw response
│       └─ {source_id}_{title}.transcript.txt   plain-text transcript
└─ projects/
    └─ {project-slug}/
        ├─ {stem}.transcript.txt    copy (small)
        ├─ {stem}.deepgram.json     copy (small, useful for tools)
        └─ {stem}.{ogg|mp3}         symlink → ../../audio/...
```

`~/Library/Application Support/Tapedeck/state.db` holds the SQLite store.

### Schema

```sql
CREATE TABLE projects (
  id            TEXT PRIMARY KEY,           -- slug, e.g. "homeschool-mvp"
  display_name  TEXT NOT NULL,
  description   TEXT NOT NULL DEFAULT '',   -- fed to classifier
  created_at    INTEGER NOT NULL,
  archived_at   INTEGER                     -- soft delete; archived projects skipped
);

CREATE TABLE recordings (
  source_id                 TEXT PRIMARY KEY,
  filename                  TEXT NOT NULL,    -- upstream title
  started_at                INTEGER NOT NULL, -- epoch ms
  duration_ms               INTEGER NOT NULL,
  filesize                  INTEGER NOT NULL,
  audio_extension           TEXT,             -- ".ogg" / ".mp3"
  audio_downloaded_at       INTEGER,
  transcribed_at            INTEGER,
  transcription_error       TEXT,
  project_id                TEXT REFERENCES projects(id),
  classification_confidence REAL,
  classification_reasoning  TEXT,
  classified_at             INTEGER,
  classified_by             TEXT,             -- 'gemini-3-flash-preview' or 'user'
  last_seen_at              INTEGER NOT NULL
);

CREATE INDEX recordings_project ON recordings(project_id);
CREATE INDEX recordings_status  ON recordings(audio_downloaded_at, transcribed_at);

CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT);
-- app_state keys: api_host, last_sync_at, schema_version, token_status
```

### Keychain entries

| Service                  | Account   | Contents                       |
|--------------------------|-----------|--------------------------------|
| `tapedeck.source.jwt`    | `default` | JWT from WebView login         |
| `tapedeck.deepgram.key`  | `default` | Deepgram API key               |
| `tapedeck.gemini.key`    | `default` | Google AI / Gemini API key     |

Access group is the app's team ID so the helper binary in the same bundle
reads the same entries the UI writes.

## 4. Sync pipeline

The helper runs one cycle per invocation. Each cycle is idempotent. A
failure in one stage does not block later stages for unrelated recordings.

```
1. ensureToken()      Keychain → if missing/expired, exit non-zero
                      (UI will surface a "Sign in" banner)
2. discoverHost()     cached in app_state; re-probe on -302
3. listRemote()       page through /file/simple/web (workspace token)
                      upsert into recordings; set last_seen_at
4. downloadNew()      for each recording where audio_downloaded_at IS NULL:
                        get_audio_url → stream to .part → rename
                        fetch raw metadata → write .source.json
                        record audio_downloaded_at
5. transcribeNew()    for each downloaded recording where transcribed_at IS NULL:
                        POST to Deepgram (nova-3, smart_format, diarize)
                        write .deepgram.json + .transcript.txt
                        record transcribed_at, or transcription_error
6. classifyNew()      for each transcribed recording where project_id IS NULL
                      AND classified_at IS NULL:
                        call Gemini 3 Flash with:
                          { transcript: first 4k chars + last 1k,
                            projects: [{id, name, description}, …active] }
                        expect JSON: { project_id|null, confidence, reasoning }
                        if confidence ≥ 0.7 → set project_id, link files
                        else                → leave unassigned
7. relinkChanged()    if user changed a project assignment in UI since last cycle,
                      remove old links, write new ones
```

**Concurrency** within a stage: up to three in parallel via `TaskGroup`.
Stages are sequential.

**Retries** on 5xx and 429: exponential backoff (1s, 2s, 4s, give up).
Same policy across all three external HTTP clients.

**Errors** are recorded in the row (`transcription_error`) and logged to
`~/Library/Logs/Tapedeck/sync.log` as structured JSON lines. One poisoned
recording never blocks the queue. Retries on the next cycle.

**Logging**: `SyncEvent` JSON lines (stage, source_id, level, message,
ts). The UI's "Recent activity" panel reads the tail.

## 5. Token capture via WKWebView

First-run flow, and re-auth when the JWT expires:

```
TokenWindow (SwiftUI Window)
  └─ WKWebView with non-persistent WKWebsiteDataStore
       loads https://app.plaud.ai/login

  every 1s while window is open, and on every didFinish:
    evaluateJavaScript("localStorage.getItem('pld_tokenstr')")
    → if non-null:
         JSON.parse, strip leading "bearer ", save to Keychain
         close window
         notify AppState.tokenAvailable
```

Polling runs on a timer rather than navigation events alone because the
upstream client sets the token after an async XHR, not synchronously on
navigation. After 90 seconds without seeing the token, the window shows
a fallback **Paste token** field so the user always has an escape hatch.

**Configuration:**

- Non-persistent `WKWebsiteDataStore` — no cookies inherited from any
  prior session; quitting the app clears it.
- User-Agent matches the Safari string `SourceClient` sends, so the API
  treats the WebView consistently with the rest of our requests.
- Regular SwiftUI `Window`, not a sheet, so OAuth/SSO popups work.

**Re-auth on 401:** when any helper request returns 401, set
`app_state.token_status = 'expired'`, log a `token_expired` event, exit.
The UI watches `app_state` via GRDB observation and surfaces a non-blocking
banner: "Sign in to Plaud — [Open]". Clicking re-opens `TokenWindow`.
The LaunchAgent keeps running but exits cleanly until the token is valid.

**Keychain entry:** generic password, service `tapedeck.source.jwt`,
account `default`. Access group = app team ID.

**Region hint:** decode JWT payload (no signature check needed; the server
validates) and read the `region` claim. Map `eu-central-1` →
`api-euc1.plaud.ai`. Skips the `-302` round-trip on every cycle. Falls
back to the probe if the JWT lacks a region claim.

## 6. UI structure

Standard 3-pane SwiftUI `NavigationSplitView`:

```
┌─────────────┬───────────────────────────┬──────────────────────┐
│ Projects    │  Recordings (filtered)    │  Detail              │
│             │                           │                      │
│ ⊕ All       │  ◉ 2026-05-11 13:41       │  Title               │
│ ◉ Unassi…   │    2h7m  ✓✓✓  Investors   │  Started 13:41       │
│ ────        │  ○ 2026-05-11 11:10       │  2h 7m · 31MB        │
│ Homeschool  │    48m   ✓✓✓  Homeschool  │  Project: Investors▾ │
│ Investors   │  ○ 2026-05-11 11:07       │    confidence 0.92   │
│ Brainstorms │    3m    ✓✓?  Unassigned  │    "Mentions term…"  │
│             │  ○ 2026-05-10 22:14       │  ─────────────────── │
│ ⊕ New       │    14m   ✓·· Downloading… │  Transcript          │
│             │                           │  [speaker 1] ...     │
│             │                           │  [speaker 2] ...     │
│             │                           │                      │
└─────────────┴───────────────────────────┴──────────────────────┘
Toolbar:  ⟳ Sync now    ● Synced 4 min ago    ⚙ Settings
```

**Project sidebar:** pseudo-rows All / Unassigned / Archived at the top,
then active projects. Right-click → Rename, Archive, Edit description.
`⊕ New` opens an inline editor (name, multi-line description).

**Recording list:** scrollable, sorted by `started_at` desc. Each row
shows date+time, duration, status pips (`✓✓✓` = downloaded / transcribed
/ classified), and the project label. Click selects → detail. Status
pips are colour-coded; tooltip shows the error if anything failed.

**Detail pane:** header (title, time, duration, file size); classification
block (project picker, confidence, model reasoning, single-click
override); transcript as plain text with speaker labels. A "Show metadata"
disclosure expands the raw JSON for debugging. A "▶ Play" button uses
`AVPlayer` against the local audio file.

**Settings (Cmd+,):** three tabs — *Account* (signed in as …, sign out,
re-sign-in), *Transcription* (Deepgram key, model, language), *Classifier*
(Gemini key, confidence threshold). Plus *Updates*: "Check now" wired to
`UpdateManager`, "Automatically check" toggle bound to
`automaticallyChecksForUpdates`.

**No menubar item. No notifications.** Quiet app — surface state when you
open it, otherwise out of the way. Dock icon present when running.

## 7. Bootstrap (no migration needed)

Fresh start. Three moves at the start of implementation:

```
1. Unload the existing LaunchAgent from the previous Python downloader.
   launchctl bootout gui/<uid>/com.benphillips.plaud-downloader
   rm ~/Library/LaunchAgents/com.benphillips.plaud-downloader.plist

2. Remove the old downloader repo (its only commit is now obsolete).
   rm -rf ~/repos/plaud-downloader

3. Rename the user content directory.
   mv ~/Plaud ~/Tapedeck
```

The 54 recordings already on disk are real and useful as a starting
corpus to validate Deepgram and Gemini against. On first launch, the app
backfills `recordings` rows from what it finds under `~/Tapedeck/audio/`,
ignoring the existing `.json` companions (it re-fetches the upstream
metadata on the next sync cycle).

No token-file import — the user signs in through the WebView. No SQLite
import — the store starts fresh. No legacy directory inside the new repo.

## 8. Testing, build, release

### Tests

`TapedeckCoreTests` is the only suite that matters. UI tests are
out-of-scope for v1.

- **`SourceClientTests`** — JWT region decoding, host patching, `-302`
  redirect handling, paged listing. HTTP responses are fixtures saved
  from real responses, replayed via `URLProtocol` stub.
- **`DeepgramClientTests`** — request shape, response parsing (segments,
  speakers). One fixture from a real round-trip on the shortest existing
  recording (~3 s), checked in.
- **`GeminiClientTests`** — prompt assembly, JSON-output parsing.
  Fixtures cover: high-confidence match, low-confidence, `project_id:
  null`, malformed JSON (must fail gracefully).
- **`StoreTests`** — migrations, idempotent upserts, project archive /
  unarchive, the classify-confidence-threshold rule.
- **`PipelineTests`** — full cycle with all three clients stubbed,
  asserts side-effects on disk (audio file written, symlink in project
  folder, transcript text matches).

Live tests opt in via `LIVE=1` env var and run against real APIs. CI runs
only stub tests.

No mocks for things we own. The only stubs are outbound HTTP.

### Build & release

`scripts/build-release.sh`, lifted from `countdown`:

```
 1. Bail if git tree is dirty or tag v$VER already exists
 2. Bump CFBundleShortVersionString / CFBundleVersion in Info.plist
    and project.yml
 3. Commit + tag v$VER
 4. xcodegen generate
 5. xcodebuild archive → .xcarchive
 6. xcodebuild -exportArchive (Developer ID, hardened runtime)
 7. notarytool submit + staple
 8. create-dmg → build/Tapedeck-$VER.dmg
 9. generate_appcast build/ → appcast.xml
10. Push DMG + appcast.xml to the gh-pages branch
11. Print release-notes prompt
```

**Sparkle feed** at `https://tavva.github.io/tapedeck/appcast.xml`.
Public EdDSA key pinned in `Info.plist` (generated by `sign_update
--generate`). `UpdateManager` mirrors `countdown` exactly.

**CI:** GitHub Actions on push runs `swift test --package-path
TapedeckCore`. No auto-release; release is manual via the script. Same
model as `countdown`.

## Open questions for implementation

- App icon — punt to v1.1, ship without a custom icon.
- Account region discovery currently round-trips even for known JWTs.
  Decode-first is in the design; verify the EdDSA-less JWT parse handles
  the existing `aws:eu-central-1` claim correctly.
- Deepgram model — design picks `nova-3`. Confirm pricing-vs-quality on
  the first long recording during implementation; can be a Settings
  default.
- Classifier prompt — design uses first 4k + last 1k chars of the
  transcript. Adjust if early classifier accuracy is poor.
