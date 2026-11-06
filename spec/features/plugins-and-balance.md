# Plug-in inserts and level balance

Status: Phase 5 (owner-selected subset). Written 2026-11-06. This is our own design. The plug-in insert replaces the Windows "virtual insert" concept (`analysis/features/feature-catalog.md`, `Strip[i].VAIO`). Level balance has no counterpart in the original.

## 1. Plug-in inserts (Audio Units)
- **Format:** Audio Unit effects, v2 and v3: types `aufx` (effect) and `aumf` (music effect). These are the formats in which IK Multimedia, Waves, FabFilter, Apple and others ship on macOS.
- **VST/VST3 is not hosted.** Vendors that ship both formats also ship AU, so AU covers them.
- **Slots:** each strip and each bus has **4 insert slots**, processed in order. Each slot can be bypassed, edited or removed.
  - **Strip:** source → mono → voice chain (denoiser … compressor) → **inserts** → fader → limiter → pan → buses.
  - **Bus:** bus sum → parametric EQ → **inserts** → bus gain → limiter → mode → soft clip.
- **Audio format:** 48 kHz, stereo, 32-bit float. A plug-in that does not accept stereo in and out cannot be added, and the UI says why.
- **Editing:** the plug-in's own window, if it has one. Otherwise a generic window with a slider for each parameter.
- **Persistence:** the plug-in's identity (type, subtype, manufacturer), its name, the bypass flag, and its full state.
  - The state is saved when the plug-in window closes, at quit, and with every settings save.
  - A plug-in that is no longer installed leaves its slot marked "missing" and passes audio through unchanged.
- **Real-time safety:** a plug-in renders on the mixer's audio thread.
  - If it returns an error, the slot passes audio through unchanged for that cycle, and the error is counted and shown.
  - Plug-in latency is shown in the slot. It is not compensated, so other strips are not delayed to match.
- **Diagnostics:** `Strip[i].Insert[k]` (read-only) returns the slot's name, status, render-error count and bypass state.
- **Scenes do not include inserts.** Scene loading never adds, removes or reconfigures plug-ins.
- **Licensing:** plug-ins that need activation (for example through IK Product Manager) must be activated as usual. The app only loads what macOS reports as installed.

## 2. Level balance
- **Purpose:** make two or more strips equally loud with one click, then let the owner fine-tune. It is a one-shot measurement, not a continuous automatic gain.
- **Selection:** each strip has a **Balance** toggle (⚖). Balancing needs 2 or more selected strips that have a source.
- **Measurement:**
  - **Where:** pre-fader, after the voice chain and inserts, so the fader alone sets the result.
  - **What:** integrated loudness per ITU-R BS.1770 (K-weighted, 400 ms blocks, absolute gate −70 LUFS, relative gate −10 LU), over a chosen window.
  - **Window:** 3–30 s, default 8 s. The owner speaks or plays normally while it measures.
  - A strip with nothing above the absolute gate is reported as "no signal" and left unchanged.
- **Result:**
  - **Target:** the mean of the selected strips' current post-fader loudness (pre-fader loudness plus fader gain), so the overall level stays about the same.
  - **Each strip's fader:** set to `target − measured + trim`, clamped to −60 … +12 dB. A clamped strip is flagged.
  - The previous fader values can be restored with **Undo** until the next balance.
- **Trim:**
  - Each selected strip has −1 dB / +1 dB buttons. Each press moves the fader by exactly 1 dB and adds ±1 to the strip's trim.
  - The trim is shown as, for example, "+2 dB", and it is held: re-running the balance re-applies each strip's trim on top of the new equal-loudness value.
  - **Reset trims** sets all trims to 0. It does not move the faders.
  - Trims range from −24 to +24 dB.
- **Persistence:** the selection and the trims are saved.
- **Control paths** (`control-and-recording.md` §3):
  - `Strip[i].Balance` (0/1, selection);
  - `Strip[i].Trim` (−24 … 24 dB; setting it moves the fader by the difference);
  - `Balance.Run` (set 1 to start a measurement using the current window; set only).

## Acceptance (Phase 5 subset)
1. An IK Multimedia AU (or any AU effect) loads on a strip, shows its own window, processes audio heard on B1, bypasses cleanly, and comes back with the same settings after a relaunch.
2. A failing or missing plug-in never interrupts the mix: the slot passes audio through.
3. Offline: the loudness meter reads a 1 kHz sine at −20 dBFS (both channels) as −20.0 ± 0.2 LUFS, and its gating ignores silence.
4. Two strips with a 10 dB level difference come out within 0.5 LU of each other after a balance. Trims of +2 and −1 dB survive a re-balance.
