#!/bin/bash
# Installs the Mixdeck virtual audio driver. Run with sudo.
# Also removes the earlier signing spike (VirtualMixerTest.driver) if present.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/Driver/build/MixdeckDriver.driver"
DST="/Library/Audio/Plug-Ins/HAL/MixdeckDriver.driver"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -d "$SRC" ] || { echo "build first: make -C $HERE/Driver"; exit 1; }
rm -rf /Library/Audio/Plug-Ins/HAL/VirtualMixerTest.driver
rm -rf "$DST"
cp -R "$SRC" "$DST"
chown -R root:wheel "$DST"
killall coreaudiod || true
echo "installed $DST; coreaudiod restarted"
