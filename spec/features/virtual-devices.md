# Virtual devices

Status: Phase 2 (three virtual buses). Written 2026-11-06, revised for Phase 2 the same day.

## Purpose
Give any macOS app that accepts a microphone (Zoom, Meet, Teams, OBS, QuickTime) a microphone whose sound is a mix produced by the mixer app. The Windows original does the same with a virtual audio driver whose capture endpoints carry its virtual buses (see `analysis/features/feature-catalog.md` §1). This spec describes our own design.

## Devices
| Device | Direction | Visible in device lists | Who uses it |
|---|---|---|---|
| `Mixer B1`, `Mixer B2`, `Mixer B3` | input, stereo | yes | conferencing and recording apps select one as their microphone |
| `Mixdeck Feed` | output, 6 channels | no (hidden) | the mixer app plays all three B mixes into it: channels 1–2 go to B1, 3–4 to B2, 5–6 to B3 |

- UIDs are stable: `MixerB1_Input_UID`, `MixerB2_Input_UID`, `MixerB3_Input_UID` and `Mixdeck_Feed_UID`. The app finds the hidden feed device by UID.
- One feed device for all buses means the app writes all three buses in one I/O cycle, on one clock.
- Format: 32-bit float, interleaved (2 channels per mic, 6 on the feed), 48 000 Hz. The rate is fixed in Phase 1. Requests to set 48 000 Hz succeed, and any other rate is refused.
- Neither device can be the system default output. `Mixer B1` may be chosen as the default input.
- Transport type: virtual.

## Behavior
- Audio written to a channel pair of `Mixdeck Feed` is heard on the matching mic after a fixed delay. All devices share one clock, so no drift is possible between them.
- If nothing has written audio for a moment (the app is not running, has quit or has crashed), the mics output silence. It never repeats old audio.
- Several apps may record from the same mic at once, and all of them get the same audio.
- The driver contains no DSP and no mixing, apart from what Core Audio itself does when several clients write to the feed device.
- The driver never blocks on its real-time path: no locks, allocations or system calls there.

## Buffer
- The driver holds a ring of 65 536 six-channel frames, about 1.37 s at 48 kHz, indexed by sample time.
- A frame is readable when it was written within the last ring length. Anything else reads as silence.

## Acceptance (Phase 1)
1. QuickTime "New Audio Recording" and Zoom list `Mixer B1` and record from it. `Mixer B1 Feed` does not appear in their speaker lists.
2. A test tone written by the app is recorded intact.
3. Quitting or killing the app gives silence on `Mixer B1` within 0.1 s. coreaudiod does not hang.
4. Path latency, hardware input to `Mixer B1`, is at most 20 ms at a 256-frame buffer. The driver part is measured with a loopback test (impulse into the feed, detected on the input).

## Acceptance (Phase 2 additions)
5. "Mixer B1", "Mixer B2" and "Mixer B3" each carry only their own channel pair of the feed.

## Out of scope
Rates other than 48 kHz, and "virtual input" devices that other apps play into (system and app audio are captured with process taps instead; see `mixer.md`).
