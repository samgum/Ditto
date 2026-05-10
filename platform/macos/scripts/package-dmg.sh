#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/Ditto.app"
STAGING_DIR="$DIST_DIR/dmg"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

swift build --package-path "$ROOT_DIR" -c release

BINARY_PATH="$ROOT_DIR/.build/release/DittoMac"
if [[ ! -f "$BINARY_PATH" ]]; then
  BINARY_PATH="$(find "$ROOT_DIR/.build" -path "*/release/DittoMac" -type f | head -n 1)"
fi

if [[ -z "${BINARY_PATH:-}" || ! -f "$BINARY_PATH" ]]; then
  echo "DittoMac release binary was not found" >&2
  exit 1
fi

rm -rf "$APP_DIR" "$STAGING_DIR" "$DIST_DIR/Ditto-macOS.dmg"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY_PATH" "$MACOS_DIR/Ditto"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/Ditto"

mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/Ditto.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "Ditto" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/Ditto-macOS.dmg"

echo "Created $DIST_DIR/Ditto-macOS.dmg"
