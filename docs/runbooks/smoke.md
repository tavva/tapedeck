# Tapedeck post-install smoke checklist

Once the first-launch runbook is complete, work through this checklist to
prove Tapedeck is healthy end-to-end. Stop on the first failure and
investigate.

1. **LaunchAgent fires unattended.**
   Quit Tapedeck.app entirely. Wait 15 minutes (or run
   `launchctl kickstart "gui/$(id -u)/com.benphillips.tapedeck.synchelper"`
   to force it now). Observe `~/Library/Logs/Tapedeck/sync.log` — at
   least one fresh `list_remote` event should appear.

2. **UI sync-now matches.**
   Open Tapedeck. Click **Sync now**. The log gains new events within
   seconds.

3. **Per-project folders are populated.**
   For each project with classified recordings:

   ```bash
   ls ~/Tapedeck/projects/<slug>/
   ```

   Each row in the project should have `<stem>.transcript.txt`,
   `<stem>.deepgram.json`, and `<stem>.<audio-extension>` (symlink).

4. **Audio plays.**
   Select any recording in the centre pane, click **▶ Play** — audio
   starts within ~1 s.

5. **Background-only operation still works.**
   Quit Tapedeck. After 15 minutes confirm the log shows the next cycle
   running.

6. **Re-auth recovery.**
   In Settings → Account, click **Sign out**. Within seconds the UI
   should show the "Not signed in" state. Re-sign in via the web flow —
   classification of the next cycle resumes.

If any step fails, capture the relevant log slice plus the output of
`launchctl print gui/$(id -u)/com.benphillips.tapedeck.synchelper` and
file an issue at <https://github.com/tavva/tapedeck/issues>.
