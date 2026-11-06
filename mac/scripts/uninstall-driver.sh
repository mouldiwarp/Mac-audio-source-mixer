#!/bin/bash
# Removes the Mixdeck virtual audio driver. Run with sudo.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
rm -rf /Library/Audio/Plug-Ins/HAL/MixdeckDriver.driver /Library/Audio/Plug-Ins/HAL/VirtualMixerTest.driver
killall coreaudiod || true
echo "removed; coreaudiod restarted"
