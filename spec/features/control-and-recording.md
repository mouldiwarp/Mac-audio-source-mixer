# Control and recording

Status: Phase 4. Written 2026-11-06. This is our own design. From the Windows original it takes only these concepts: the recorder arm, mode and format options; the `Strip[i].X = v;` script grammar; MIDI learn; and global shortcuts (`analysis/features/feature-catalog.md` §5–6). Ranges, defaults, ports and the parameter list are our own choices.

## 1. Recorder
- **Arm:** any of the 6 buses and any of the 8 strips can be armed. A strip is recorded post-fader and post-pan, which is what its meter shows. A bus is recorded as it is sent out.
- **One track per armed item.** One armed item gives one file. Several armed items give one file each, all started on the same mix cycle, so the tracks are sample-aligned. This is multitrack mode.
- **File name:** `<prefix> YYYY-MM-DD at HHhMMmSSs`. With more than one track, ` - <item>` is added, for example ` - B1` or ` - Mic`.
  - Prefix default: `Record`.
  - Directory default: `~/Music/Mixdeck Recordings`. It is created if missing.
- **Formats:**
| Format | Options | Default |
|---|---|---|
| WAV | 16-bit, 24-bit, 32-bit float | 24-bit |
| CAF | 16-bit, 24-bit, 32-bit float | 24-bit |
| M4A (AAC) | 96, 128, 192, 256 kbps | 192 |
- **Channels:** stereo (default), or mono ((L+R)/2).
- **Sample rate:** 48 kHz, the mix rate. Converting to another rate is not offered.
- **Pre-record:** 0–10 s (default 0). While anything is armed, the last N seconds are kept in memory, and a recording starts with them.
- **Transport:**
  - Record starts.
  - Record again while recording pauses. The file stays open, and the gap leaves no silence in the file.
  - Stop closes the files.
- **Timer stop:** off (default), or stop after 1–600 minutes.
- **Recording never touches the audio thread's timing.** The audio thread copies samples into a ring, and a background writer drains it. If the writer falls more than 4 s behind, samples are dropped and counted, and the UI shows a warning.
- **The UI shows:** elapsed time, the armed items, and an error if a file cannot be created.

## 2. File player
- A strip source **Audio file** plays a file through the strip's whole chain: FX, gain and routing. Any number of strips can play files.
- **Formats:** anything macOS Audio Toolbox reads, which includes WAV, AIFF, CAF, MP3, M4A/AAC and FLAC.
  - Files are converted to 48 kHz stereo; a mono file goes to both sides.
  - Audio tracks inside video files are not supported.
- **Transport:** play/pause, stop (rewinds to the start), loop (on or off, default off), and a position display of elapsed / total time.
- At the end without loop, playback stops and rewinds.
- **Persistence:** the path and loop setting are saved. After a relaunch the player is stopped at the start.

## 3. Parameter paths
One list of parameter paths serves the control API, OSC, MIDI and shortcuts. Indices are 0-based. Values: numbers, booleans (`0`/`1`), or quoted strings.

| Path | Value |
|---|---|
| `Strip[i].Gain` | −60 … 12 dB |
| `Strip[i].Pan` | −1 … 1 |
| `Strip[i].Mono` `.Mute` `.Solo` | 0/1 |
| `Strip[i].A1` … `.A3`, `.B1` … `.B3` | 0/1 (assign) |
| `Strip[i].Denoiser` `.Gate` `.EQ` `.PEQ` `.Comp` `.Limiter` | 0/1 (block on/off) |
| `Strip[i].Denoiser.Amount` | 0 … 1 |
| `Strip[i].Gate.Threshold` | −80 … 0 dB |
| `Strip[i].EQ.Low` `.Mid` `.High` | −12 … 12 dB |
| `Strip[i].Comp.Threshold` | −60 … 0 dB |
| `Strip[i].Comp.Ratio` | 1 … 20 |
| `Strip[i].Comp.Makeup` | −12 … 24 dB |
| `Strip[i].Limiter.Ceiling` | −24 … 0 dB |
| `Strip[i].Play` `.Loop` | 0/1 (file player strips) |
| `Strip[i].Label` | string |
| `Bus[i].Gain` | −60 … 12 dB (i: 0–5 = A1, A2, A3, B1, B2, B3) |
| `Bus[i].Mute` `.Mono` `.PEQ` `.Limiter` | 0/1 |
| `Recorder.Record` | 1 = start (or resume), 0 = stop |
| `Recorder.Pause` | 0/1 |
| `Recorder.ArmStrip[i]` `Recorder.ArmBus[i]` | 0/1 |
| `Scene.Load` `Scene.Save` | string (scene name) |

- Out-of-range numbers are clamped.
- Indices for strips that don't exist, unknown paths and wrong value types are errors.
- Set-only paths are `Scene.*`. Every other path can be read.

## 4. Control API (local text protocol)
- Off by default. When on, it listens on **TCP 127.0.0.1:9040** (port configurable) and accepts local connections only.
- Requests are UTF-8 statements, each ended by `;` or a newline:
  - `Path = value;` sets a value. There is no reply unless the statement fails.
  - `Path;` reads a value. The reply is `Path = value;` on its own line.
  - Several statements may share a line: `Strip[0].Mute = 1; Bus[3].Gain = -6;`.
- An error is answered with `error: <message>` on its own line. The connection stays open.
- Up to 8 clients at once.

## 5. OSC bridge
- Off by default. When on, it listens on **UDP 127.0.0.1:9000** (port configurable).
- **Address:** the parameter path with `/` in place of `.` and `[i]`, matched case-insensitively. For example `/strip/0/gain` and `/bus/3/mute`.
- **Arguments:**
  - One `f`, `i` or `s` argument sets the value.
  - For boolean paths, any value above 0.5 is on.
  - No argument is a query. The reply goes to the sender's address with the same path and one `f` argument (`s` for strings).
- OSC bundles are accepted, and each message in a bundle is applied.

## 6. MIDI
- Listens to every MIDI input; new devices are picked up automatically. MIDI 1.0 Control Change, Note On and Note Off messages are used.
- **Mapping:** a source message (channel 1–16, plus CC number or note number) maps to one parameter path.
  - CC on a number path: 0–127 maps linearly across the path's range. Gain paths use the fader law, the same as the on-screen fader.
  - CC on a boolean path: values of 64 or above mean on.
  - A note on a boolean path toggles it on each Note On (the default), or follows the key while held (momentary: Note On = 1, Note Off = 0).
  - A note on a number path sets the maximum on Note On.
- **Learn:** pick a path, press Learn, then move a control. The next CC or Note On becomes the mapping. Esc or Cancel aborts.
- Mappings are saved in the settings file.
- MIDI output (feedback to motorized faders and LEDs) is not in Phase 4.

## 7. Global shortcuts
- A shortcut is a key plus modifiers (at least one of ⌘ ⌥ ⌃ ⇧). It works while other apps are in front, and needs no Accessibility permission.
- **Actions:**
  - toggle a boolean path;
  - set a path to a value;
  - load a scene.
- If a shortcut is already taken by the system or another app, it can't be registered; the UI says so.

## 8. Scenes
- A scene is a named snapshot of the mixing state.
  - Saved: per strip by position, the label, gain, pan, mono, mute, solo, assign and FX; per bus, the gain, mute and FX.
  - Not saved: sources and output devices. Loading a scene never changes what is plugged in where.
- Strips that don't exist at load time are skipped.
- Scenes can be saved, loaded and deleted from the mixer window and the menu-bar item, and loaded through the control paths.

## Acceptance (Phase 4)
1. A 10-minute recording of B1 plus a strip, in WAV 24-bit, CAF float and M4A, opens in QuickTime. The tracks have the same length to the sample, and no samples are dropped.
2. Pre-record of 5 s: the file starts 5 s before Record was pressed.
3. A file strip plays an MP3 into B1, loops seamlessly, and stops and rewinds correctly.
4. `printf 'Strip[0].Gain = -10;\nStrip[0].Gain;\n' | nc 127.0.0.1 9040` returns `Strip[0].Gain = -10.0;`, and the fader moves.
5. OSC `/strip/0/mute 1` mutes strip 1, and a query returns its state.
6. A MIDI CC learned to `Strip[0].Gain` moves the fader, and a learned note toggles mute.
7. A global shortcut toggles `Bus[3].Mute` while another app is in front.
8. Saving a scene, changing the mix and loading the scene restores it, without changing sources.
