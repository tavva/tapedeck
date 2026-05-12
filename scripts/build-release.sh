#!/bin/bash
# ABOUTME: Builds, signs, notarises, and packages Tapedeck into a DMG for distribution.
# ABOUTME: Requires Developer ID Application cert + stored notarisation profile + Sparkle key.

set -euo pipefail

VERSION="${1:?Usage: $0 <version> (e.g. 0.1.0)}"

PROJECT="Tapedeck.xcodeproj"
SCHEME="Tapedeck"
TEAM_ID="C8Q84FVJHL"
BUILD_DIR="./build"
ARCHIVE_PATH="$BUILD_DIR/Tapedeck.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/Tapedeck-${VERSION}.dmg"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-countdown-notarize}"

# Step 1: Bail on dirty tree or pre-existing tag.
if ! git diff --quiet HEAD; then
  echo "Error: working tree has uncommitted changes. Commit or stash first."
  exit 1
fi
TAG="v${VERSION}"
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: tag $TAG already exists."
  exit 1
fi

# Step 2: Bump version in plists + project.yml.
echo "==> Setting version to ${VERSION}..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "Tapedeck/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "Tapedeck/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "TapedeckSyncHelper/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "TapedeckSyncHelper/Info.plist"
/usr/bin/sed -i '' -E "s/(CFBundleShortVersionString: )[0-9.]+/\1${VERSION}/" project.yml
/usr/bin/sed -i '' -E "s/(CFBundleVersion: )[0-9.]+/\1${VERSION}/" project.yml
git add Tapedeck/Info.plist TapedeckSyncHelper/Info.plist project.yml
git commit -m "release: v${VERSION}"

# Step 3: Regenerate project + clean build dir.
rm -rf "$BUILD_DIR"
xcodegen generate

# Step 4-5: Archive.
echo "==> Archiving..."
xcodebuild -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  archive \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  -quiet

# Step 6: Export (signed, not yet notarised).
echo "==> Exporting archive..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist ExportOptions.plist

# Step 7: Verify keychain sharing BEFORE notarisation (because notarisation is
# non-recoverable per Apple).
echo "==> Verifying keychain sharing..."
./scripts/verify-keychain-sharing.sh "$EXPORT_PATH/Tapedeck.app"

# Step 8: DMG packaging.
echo "==> Creating DMG..."
DMG_TEMP="$BUILD_DIR/Tapedeck-temp.dmg"
hdiutil create -volname "Tapedeck" -fs HFS+ -size 80m -ov "$DMG_TEMP"
hdiutil attach "$DMG_TEMP" -readwrite -noautoopen
cp -R "$EXPORT_PATH/Tapedeck.app" "/Volumes/Tapedeck/"
ln -s /Applications "/Volumes/Tapedeck/Applications"
sync
hdiutil detach "/Volumes/Tapedeck"
hdiutil convert "$DMG_TEMP" -format UDZO -o "$DMG_PATH"
rm -f "$DMG_TEMP"

# Step 9-10: Notarise + staple.
echo "==> Notarising..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARIZE_PROFILE" \
  --wait
echo "==> Stapling..."
xcrun stapler staple "$DMG_PATH"

# Step 11-12: EdDSA sign + generate appcast.
SPARKLE_TOOLS="$(dirname "$0")/sparkle-tools/bin"
if [ ! -f "$SPARKLE_TOOLS/sign_update" ]; then
  echo "Error: Sparkle tools not found. Run scripts/download-sparkle-tools.sh first."
  exit 1
fi
echo "==> Signing DMG with EdDSA..."
EDDSA_SIGNATURE=$("$SPARKLE_TOOLS/sign_update" "$DMG_PATH")

echo "==> Updating appcast..."
APPCAST_DIR="$BUILD_DIR/appcast-work"
git worktree add "$APPCAST_DIR" gh-pages
APPCAST_FILE="$APPCAST_DIR/appcast.xml"

PUB_DATE=$(date -R)
DMG_URL="https://github.com/tavva/tapedeck/releases/download/${TAG}/Tapedeck-${VERSION}.dmg"

if [ ! -f "$APPCAST_FILE" ]; then
cat > "$APPCAST_FILE" << 'APPCAST_HEADER'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Tapedeck Updates</title>
  </channel>
</rss>
APPCAST_HEADER
fi

ITEM_FILE="$BUILD_DIR/appcast-item.xml"
cat > "$ITEM_FILE" << ITEM_EOF
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${DMG_URL}"
                 type="application/octet-stream"
                 ${EDDSA_SIGNATURE} />
    </item>
ITEM_EOF

CLOSE_LINE=$(grep -n '</channel>' "$APPCAST_FILE" | head -1 | cut -d: -f1)
{ head -n $((CLOSE_LINE - 1)) "$APPCAST_FILE"; cat "$ITEM_FILE"; tail -n +$CLOSE_LINE "$APPCAST_FILE"; } > "$APPCAST_FILE.tmp"
mv "$APPCAST_FILE.tmp" "$APPCAST_FILE"
rm "$ITEM_FILE"

cd "$APPCAST_DIR"
git add appcast.xml
git commit -m "Update appcast for ${TAG}"
git push origin gh-pages
cd -
git worktree remove "$APPCAST_DIR"

# Step 14: gh release create — creates tag + release atomically.
echo "==> Creating GitHub release..."
gh release create "$TAG" "$DMG_PATH" \
  --title "Tapedeck $TAG" \
  --generate-notes

echo "==> Done! Release $TAG published."
echo "==> Next step: write the release notes in GitHub if --generate-notes isn't enough."
