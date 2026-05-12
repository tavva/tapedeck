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
