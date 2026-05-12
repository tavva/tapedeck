#!/bin/bash
# ABOUTME: Downloads Sparkle CLI tools (generate_keys, sign_update, generate_appcast).
# ABOUTME: Required for signing releases and generating the appcast.

set -euo pipefail

TOOLS_DIR="$(dirname "$0")/sparkle-tools"
SPARKLE_VERSION=$(gh release view --repo sparkle-project/Sparkle --json tagName -q .tagName)
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

if [ -d "$TOOLS_DIR/bin" ]; then
  echo "Sparkle tools already present at $TOOLS_DIR/bin"
  exit 0
fi

echo "==> Downloading Sparkle ${SPARKLE_VERSION} tools..."
TEMP_DIR=$(mktemp -d)
curl -sL "$SPARKLE_URL" -o "$TEMP_DIR/sparkle.tar.xz"

echo "==> Extracting..."
mkdir -p "$TOOLS_DIR"
tar -xf "$TEMP_DIR/sparkle.tar.xz" -C "$TEMP_DIR"
cp -R "$TEMP_DIR/bin" "$TOOLS_DIR/bin"

rm -rf "$TEMP_DIR"
echo "==> Sparkle tools installed to $TOOLS_DIR/bin"
echo "    generate_keys, sign_update, generate_appcast available."
