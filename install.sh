#!/bin/bash
# Builds Mixdeck from source and installs it on this Mac.
#
#   ./install.sh                     build and install the driver and the app
#   ./install.sh --launch-at-login   the same, and start Mixdeck when you log in
#   ./install.sh --check             only check prerequisites and build (installs nothing)
#   ./install.sh --app-only          rebuild and reinstall the app, leaving the driver alone
#   ./install.sh --test              also run the driver and engine tests before installing
#   ./install.sh --uninstall         remove the app and the driver (settings are kept)
#
# Installing the driver asks for your admin password and briefly restarts macOS audio.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MAC="$ROOT/mac"
APP_DST="/Applications/Mixdeck.app"
DRIVER_DST="/Library/Audio/Plug-Ins/HAL/MixdeckDriver.driver"
MIN_MACOS="14.4"

CHECK_ONLY=0 APP_ONLY=0 RUN_TESTS=0 LOGIN=0 UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        --app-only) APP_ONLY=1 ;;
        --test) RUN_TESTS=1 ;;
        --launch-at-login) LOGIN=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (see ./install.sh --help)"; exit 1 ;;
    esac
done

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

quit_running_app() {
    if pgrep -x Mixdeck >/dev/null; then
        osascript -e 'tell application id "local.mixdeck.app" to quit' >/dev/null 2>&1 || pkill -x Mixdeck || true
        for _ in $(seq 1 50); do pgrep -x Mixdeck >/dev/null || break; sleep 0.1; done
    fi
}

# --- Uninstall ---------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    bold "Removing Mixdeck"
    quit_running_app
    rm -rf "$APP_DST" && echo "Removed $APP_DST"
    echo "Removing the driver needs your admin password; macOS audio restarts briefly."
    sudo "$MAC/scripts/uninstall-driver.sh"
    echo "Your settings are kept in ~/Library/Application Support/Mixdeck (delete that folder to remove them)."
    exit 0
fi

# --- Prerequisites -----------------------------------------------------------
bold "Checking prerequisites"
[ "$(uname -s)" = "Darwin" ] || fail "Mixdeck only runs on macOS."
OS_VER="$(sw_vers -productVersion)"
if [ "$(printf '%s\n%s\n' "$MIN_MACOS" "$OS_VER" | sort -V | head -1)" != "$MIN_MACOS" ]; then
    fail "macOS $MIN_MACOS or later is needed (this Mac has $OS_VER)."
fi
echo "macOS $OS_VER on $(uname -m)"

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null || ! command -v clang >/dev/null; then
    echo "Apple's command line developer tools are needed to build Mixdeck."
    echo "A window will open to install them. Run ./install.sh again when that has finished."
    xcode-select --install 2>/dev/null || true
    exit 1
fi
SWIFT_VER="$(swift --version 2>/dev/null | grep -Eo 'Swift version [0-9]+\.[0-9]+' | grep -Eo '[0-9]+\.[0-9]+' || echo 0)"
if [ "$(printf '%s\n%s\n' "5.9" "$SWIFT_VER" | sort -V | head -1)" != "5.9" ]; then
    fail "Swift 5.9 or later is needed (found $SWIFT_VER). Update Xcode or the command line tools."
fi
echo "Swift $SWIFT_VER"

# --- Build -------------------------------------------------------------------
if [ "$APP_ONLY" -eq 0 ]; then
    bold "Building the virtual audio driver"
    make -C "$MAC/Driver" >/dev/null
    echo "Built $MAC/Driver/build/MixdeckDriver.driver"
fi

if [ "$RUN_TESTS" -eq 1 ]; then
    bold "Running tests"
    [ "$APP_ONLY" -eq 1 ] || make -C "$MAC/Driver" test
    (cd "$MAC" && swift build -c release --product cmix-tests && .build/release/cmix-tests)
fi

bold "Building the app (the first build takes a few minutes)"
"$MAC/scripts/build-app.sh"

if [ "$CHECK_ONLY" -eq 1 ]; then
    bold "Build finished. Nothing was installed (--check)."
    exit 0
fi

# --- Install -----------------------------------------------------------------
if [ "$APP_ONLY" -eq 0 ]; then
    bold "Installing the driver"
    echo "This needs your admin password, and macOS audio will stop for a moment while it restarts."
    quit_running_app
    sudo "$MAC/scripts/install-driver.sh"
    # Give Core Audio a moment to come back before the app looks for the driver.
    for _ in $(seq 1 30); do
        system_profiler SPAudioDataType 2>/dev/null | grep -q "Mixer B1" && break
        sleep 1
    done
fi

bold "Installing the app"
if [ "$LOGIN" -eq 1 ]; then
    "$MAC/scripts/install-app.sh" --launch-at-login
else
    "$MAC/scripts/install-app.sh"
fi

bold "Done"
cat <<EOF
Mixdeck is in $APP_DST and runs from the slider icon in the menu bar.

The first time it runs, macOS asks for:
  - Microphone access, to read input devices
  - System Audio Recording access, to capture app and system audio
Allow both. If a prompt was missed, use System Settings > Privacy & Security.

Pick "Mixer B1", "Mixer B2" or "Mixer B3" as the microphone in other apps to hear the mix.
To remove Mixdeck later: ./install.sh --uninstall
EOF
