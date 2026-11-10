#!/bin/bash
# Builds build/Mixdeck.app (release, ad-hoc signed). No Apple account needed for local use.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
swift build -c release --product Mixdeck
APP="$HERE/build/Mixdeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Mixdeck "$APP/Contents/MacOS/Mixdeck"
cp App/Info.plist "$APP/Contents/Info.plist"
cp Assets/atmosphere-bar.jpg "$APP/Contents/Resources/"   # backdrop (gm-guitars.net)
ICONSET="$HERE/build/Icon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Icon.icns"
rm -rf "$ICONSET"
codesign --force --sign - "$APP"
echo "built $APP"
