# Mixer: strips, buses, routing

Status: Phase 2. Written 2026-11-06. Our own design. It takes only the strip → assign → bus concept from the Windows original (`analysis/features/feature-catalog.md` §1–3). The ranges below are our design choices.

## Topology
- Up to **8 input strips**. Each strip has one **source**:
  - `device`: a hardware input device (an audio interface or a webcam mic), plus a channel pair (L, R). Picking the same channel twice gives a mono source.
  - `systemAudio`: all system audio, except the mixer's own output. It is captured with a process tap inside a private aggregate device clocked by the default output. The tap's channels come after any input channels of that device.
  - `app`: the audio of one or more running apps, chosen by bundle ID (Safari, Chrome, Music and so on).
- **6 buses:**
  - A1, A2, A3: hardware outputs (headphones, speakers). Each has an output device, or none.
  - B1, B2, B3: virtual outputs. They appear as the microphones "Mixer B1", "Mixer B2" and "Mixer B3" (`virtual-devices.md`).
- Each strip has an assign button per bus. A strip's signal is added to every bus it is assigned to.

## Strip controls
| Control | Range / values | Default |
|---|---|---|
| Gain | −60 … +12 dB (−60 dB means silent) | 0 dB |
| Pan | −1 (left) … +1 (right). Constant-power law, scaled so the centre is unity and capped at unity, so it acts as balance on stereo sources | 0 |
| Mono | on/off: (L+R)/2 to both sides, applied before pan | off |
| Mute | on/off | off |
| Solo | on/off. If any strip is soloed, the strips that are not soloed are silent on all buses | off |
| Assign | A1 A2 A3 B1 B2 B3, each on/off | B1 on, others off |

Signal order: source → mono → gain → pan → mute/solo → meter → assigned buses.

## Bus controls
| Control | Range | Default |
|---|---|---|
| Gain | −60 … +12 dB | 0 dB |
| Mute | on/off | off |
| Device (A buses only) | any output device, or none | none |

A bus meter shows the post-gain level. A soft clip is applied at ±1.0 on bus outputs, so a hot mix does not wrap around.

## Clocks and drift
- The **master clock** is the virtual driver. One mix cycle runs per I/O cycle of the hidden feed device, at 48 kHz.
- Every source runs on its own device clock. A source's audio goes into a ring buffer. An **adaptive resampler** reads it at 48 kHz, correcting the rate so the ring stays near a target fill. The correction is limited to ±1000 ppm and changes slowly enough that the pitch change can't be heard.
- A hardware output (A bus) is the reverse: the mix goes into a ring, and an adaptive resampler feeds the device at its own rate.
- Sources at 44.1 kHz (or any rate) are converted by the same resampler.
- If a ring runs dry, the strip outputs silence until it refills. This counts as an underrun. If a ring overfills, the excess is dropped. Both are counted and shown.

## Meters
Peak level per strip (post-fader) and per bus, in dBFS, updated about 20 times a second.

## Persistence
- Settings are a JSON file at `~/Library/Application Support/Mixdeck/settings.json`. It is written on every change, debounced to 0.5 s, and loaded at launch.
- Devices are stored by UID and apps by bundle ID. A device missing at launch leaves its strip in place, marked "missing", and the strip reconnects when the device returns.

## App shell
- A mixer window with one column per strip and a bus section.
- A menu-bar item: show the mixer window, mute all B buses, and quit.
- Launch at login: an on/off setting.

## Permissions
- Device sources need Microphone permission.
- System and app sources need "System Audio Recording" permission. When either is missing, the app explains why and links to the right pane of System Settings.

## Acceptance (Phase 2)
1. A Scarlett or AXE IO mic, the webcam mic and YouTube in Safari, mixed into B1, are recorded for 60 minutes in a QuickTime screen recording with no clicks. Engine counters show 0 underruns and 0 drops after warm-up.
2. A voice strip assigned only to B1 and A1 is not heard on B2.
3. The mixer's own A1 output is not captured by its `systemAudio` strip, so there is no feedback.
4. Settings survive quitting and relaunching.
