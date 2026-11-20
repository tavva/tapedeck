# Secrets register

Where Tapedeck's secrets live. Values never go in this file.

The app's runtime secrets are stored through `KeychainStore` (account `default`).
Signed builds use the data-protection keychain in the team-prefixed
`keychain-access-groups` access group; ad-hoc local builds and tests fall back to
`~/Library/Application Support/Tapedeck/dev-secrets.json` (mode 0600). Both the
app and `TapedeckSyncHelper` read the same store.

| Name (KeychainStore service) | Provider / account | Purpose | Scope | Where it lives |
| --- | --- | --- | --- | --- |
| `tapedeck.source.session` | Plaud, the user's own Plaud account (one workspace) | JSON `PlaudCredentials`: workspace id, access token, refresh token and their expiry times. Lists and downloads recordings; the helper refreshes the access token and writes the new values back. | Plaud workspace token (`X-Scope-Type: workspace`), full access to that workspace's files. Access token ~24 h, refresh token ~30 days. | KeychainStore on the user's Mac (keychain or `dev-secrets.json`). Pasted from the user's browser session at web.plaud.ai. |
| `tapedeck.deepgram.key` | Deepgram, the user's own account | Transcribing audio | Whatever the user's key grants | KeychainStore on the user's Mac |
| `tapedeck.gemini.key` | Google AI Studio (Gemini), the user's own account | Classifying transcripts into projects | Whatever the user's key grants | KeychainStore on the user's Mac |
| notarytool keychain profile (`NOTARIZE_PROFILE`, default `countdown-notarize`) | Apple Developer account used for releases | Notarising release DMGs in `scripts/build-release.sh` | App Store Connect / Apple ID app-specific credentials for notarisation | Login keychain of the release machine |
| Sparkle EdDSA private key | Sparkle, generated for Tapedeck releases | Signing the DMG for the appcast (`sign_update` in `scripts/build-release.sh`) | Update signing only | Login keychain of the release machine |
