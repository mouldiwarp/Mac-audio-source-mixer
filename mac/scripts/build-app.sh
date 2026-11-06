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
codesign --force --sign - "$APP"
echo "built $APP"
