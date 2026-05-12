# Tapedeck first-launch runbook

Follow these steps once, in order, when installing Tapedeck on a fresh
machine — or when migrating an existing `~/Plaud/` corpus to the new
layout. Steps 1 and 2 are **destructive** to the existing Plaud
downloader's directory tree, so back up first.

## Prerequisites

- macOS 14 or later.
- Plaud account with a working web sign-in.
- Deepgram API key (saved as a secret in 1Password or similar).
- Google AI Studio key for Gemini (model `gemini-3-flash-preview`).
- The signed-and-notarised `Tapedeck.dmg` from
  <https://github.com/tavva/tapedeck/releases/latest>.

## Step 1 — Back up existing audio

If the legacy Python downloader (`plaud-downloader`) is already pulling
recordings into `~/Plaud/audio`, capture a snapshot before Tapedeck
starts moving files:

```bash
cd "$HOME"
tar -czf "$HOME/Desktop/plaud-backup-$(date +%F).tgz" Plaud
```

Keep this archive until the Tapedeck cycle has been observed completing
end-to-end at least once.

## Step 2 — Move the existing tree (skip if installing fresh)

Tapedeck's `Layout.standard` looks under `~/Tapedeck`, not `~/Plaud`. If
you have an existing `~/Plaud` corpus, move it:

```bash
mv "$HOME/Plaud"   "$HOME/Tapedeck"
mv "$HOME/Tapedeck/audio" "$HOME/Tapedeck/audio.legacy" # see step 8
```

Tapedeck's first-run backfill (Task 7.13) scans `~/Tapedeck/audio` and
seeds DB rows from filenames whose prefix matches a Plaud sourceId. Files
in `audio.legacy` are *not* picked up — that's deliberate; you can pick
out which legacy recordings to re-import manually.

## Step 3 — Install Tapedeck

1. Mount `Tapedeck-<version>.dmg`.
2. Drag `Tapedeck.app` to `/Applications`.
3. Eject the DMG.

## Step 4 — First launch

1. Double-click `Tapedeck.app` from `/Applications`.
2. macOS will Gatekeeper-prompt the first time. Click **Open**.
3. The main window appears empty.

## Step 5 — Sign in to Plaud

1. Open **Settings → Account**.
2. Click **Sign in via web…**. A web view opens at
   <https://web.plaud.ai/>.
3. Sign in normally. After ~1 second of being signed in, the window
   self-dismisses — the JWT has been captured to the keychain.
4. If 90 seconds pass with no capture, a paste field appears.
   In Safari, open the JS console on web.plaud.ai and run
   `localStorage.getItem('pld_tokenstr')`. Copy the value (including the
   leading `bearer ` prefix), paste it in, click **Save pasted token**.

## Step 6 — Enter API keys

1. **Settings → Transcription**: paste your Deepgram key, click **Save**.
   Optionally click **Test connection** — anything except “Key rejected”
   means the key is fine.
2. **Settings → Classifier**: paste your Gemini key, **Save**, **Test**.
   Adjust the confidence threshold slider if the default (0.70) is too
   lenient.

## Step 7 — Confirm the LaunchAgent

In **Settings → Account**, the **Enable LaunchAgent** toggle should be
on. Verify from the terminal:

```bash
launchctl print "gui/$(id -u)/com.benphillips.tapedeck.synchelper" | head -20
```

A matching entry confirms the agent is registered. The schedule is every
900 s.

## Step 8 — Force a first cycle

Back in the main window, click **Sync now**. The helper logs to
`~/Library/Logs/Tapedeck/sync.log`:

```bash
tail -F ~/Library/Logs/Tapedeck/sync.log
```

Expect to see `list_remote`, `download_ok`, `transcribe_ok`,
`classify_ok` events for each recording.

## Step 9 — Create some projects

In the sidebar, click **+** and enter a project (display name +
description). Recordings the next cycle classifies into that project
will land in `~/Tapedeck/projects/<slug>/` as a symlink to the audio in
`~/Tapedeck/audio/<date>/` plus copies of the transcript and Deepgram
JSON.

If the classifier confidence is below threshold, the recording stays
unassigned and shows up in the **Unassigned** view in the sidebar — pick
the right project from the detail pane's project picker to override.
