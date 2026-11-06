#!/bin/bash
# Builds Mixdeck.app and installs it in /Applications (found by Spotlight and Launchpad).
# Usage: scripts/install-app.sh [--launch-at-login]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
"$HERE/scripts/build-app.sh"
DST="/Applications/Mixdeck.app"

# Quit any running copy so it saves its settings and releases the audio devices.
if pgrep -x Mixdeck >/dev/null; then
    osascript -e 'tell application id "local.mixdeck.app" to quit' >/dev/null 2>&1 || pkill -x Mixdeck || true
    for _ in $(seq 1 50); do pgrep -x Mixdeck >/dev/null || break; sleep 0.1; done
fi

rm -rf "$DST"
mv "$HERE/build/Mixdeck.app" "$DST"   # move, so Spotlight shows a single Mixdeck
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST"
mdimport "$DST" 2>/dev/null || true

if [ "${1:-}" = "--launch-at-login" ]; then
    SETTINGS="$HOME/Library/Application Support/Mixdeck/settings.json"
    if [ -f "$SETTINGS" ]; then
        /usr/bin/python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["launchAtLogin"]=True; json.dump(d,open(p,"w"),indent=2,sort_keys=True)' "$SETTINGS"
    else
        mkdir -p "$(dirname "$SETTINGS")"
        echo '{"launchAtLogin": true}' > "$SETTINGS"
    fi
fi
open "$DST"
echo "installed $DST"
