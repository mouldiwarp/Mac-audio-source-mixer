# Mixdeck (macOS)

A multi-source mixer with three virtual microphones ("Mixer B1", "Mixer B2" and "Mixer B3") and three hardware output buses. Specs: `../spec/features/mixer.md`, `../spec/features/virtual-devices.md` and `../spec/features/voice-dsp.md`.

Each strip has an **FX** button that opens its voice chain: denoiser, gate, 3-band EQ, 6-band parametric EQ, compressor with transfer curve, and limiter, plus presets. Each bus has an **FX** button for its parametric EQ, limiter and Stereo/Mono mode.

Phase 4 (`../spec/features/control-and-recording.md`):
- **Recorder:** in the window footer. Arm buses and/or strips, then record; each armed item gets its own file.
- **File player:** a strip source.
- **Scenes:** in the footer and the menu bar.
- **Settings (⌘,):** recording format, a text API on 127.0.0.1:9040, OSC on 127.0.0.1:9000, MIDI learn, and global shortcuts. The API and OSC are off by default.

      printf 'Strip[0].Gain = -10;\nStrip[0].Gain;\n' | nc 127.0.0.1 9040

## Layout
- `Driver/`: the AudioServerPlugIn (C). `make` builds it, and `make test` runs the in-process driver tests.
- `Sources/CMixEngine`: the real-time engine (C).
  - `AdaptiveRing`: clock-drift compensation, an adaptive windowed-sinc resampler with a PI controller.
  - `Mixer`: 8 strips × 6 buses, driven by the virtual driver's clock.
  - `VoiceFx`: the per-strip and per-bus processing chain.
- `Sources/AudioIO`: device discovery and process taps for system and app audio (Swift).
- `Sources/Mixdeck`: the SwiftUI app (mixer window, menu-bar item, settings, launch at login).
- `Sources/mixdeck-cli`: a command-line front end for tests and soak runs.
- `Sources/cmix-tests`: offline engine tests. They simulate drifting clocks and need no hardware.
- `scripts/`: driver install and uninstall (sudo), and `build-app.sh`.

## Build and install
    make -C Driver && make -C Driver test        # driver + its tests
    swift build -c release && .build/release/cmix-tests   # 'cmix-tests fx' = voice chain only (seconds)
    sudo scripts/install-driver.sh               # restarts coreaudiod
    scripts/install-app.sh [--launch-at-login]   # builds, installs to /Applications, opens

## Command-line checks
    .build/debug/mixdeck-cli list
    .build/debug/mixdeck-cli selftest            # routing: tone -> B2 only, read back from all three mics
    .build/debug/mixdeck-cli run --strip "AXE IO:1,1>B1,A1" --strip "BRIO>B1" --strip "system>B1" --a1 "LU28R55" --seconds 3600 --quiet

Settings: `~/Library/Application Support/Mixdeck/settings.json`.

## Known limits
- The app is ad-hoc signed, so macOS may ask for Microphone and System Audio Recording permission again after each rebuild (permission is tied to the exact build). A stable signing identity would stop that.
- App sources are matched by bundle ID when the strip is set. An app started later needs the strip re-selected.
- Safari plays audio through a shared WebKit process (`com.apple.WebKit.GPU`), so capture Safari through that entry or use System audio.
- 48 kHz master rate. A buses use output channels 1-2.
- Device connections happen on the main thread. If an output device's driver stops responding, the app can hang at launch. Restarting the audio service (`sudo killall coreaudiod`) clears it.
