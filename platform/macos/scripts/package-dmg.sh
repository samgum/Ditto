#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
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
if [[ -d "$ROOT_DIR/Resources/Localizations" ]]; then
  cp -R "$ROOT_DIR/Resources/Localizations" "$RESOURCES_DIR/Localizations"
fi
chmod +x "$MACOS_DIR/Ditto"

ICON_SOURCE="$REPO_DIR/res/Martin_Icon.png"
if [[ -f "$ICON_SOURCE" ]]; then
  ICONSET_DIR="$DIST_DIR/Ditto.iconset"
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/Ditto.icns"
fi

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
