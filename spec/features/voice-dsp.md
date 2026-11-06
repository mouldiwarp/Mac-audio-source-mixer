# Voice processing (strip and bus effects)

Status: Phase 3. Written 2026-11-06. Our own design. The Windows original has a gate, compressor, 3-band EQ, parametric EQ, limiter and denoiser per strip (`analysis/features/feature-catalog.md` §2). Every range and default below is our own choice.

## Strip chain
Order: source → mono → **denoiser → gate → 3-band EQ → parametric EQ → compressor** → fader gain → **limiter** → pan → buses.

Each block has its own on/off switch, and a block that is off costs nothing. All parameters can change while audio runs, without clicks: coefficients are recomputed on the audio thread when a parameter changes, and gains are smoothed.

### Denoiser
Reduces steady background noise (fans, hiss, room tone) while speech passes.
| Parameter | Range | Default |
|---|---|---|
| Amount | 0 … 100 % (maximum reduction 0 … 24 dB) | 50 % |

- Method: short-time spectrum (512-point FFT, 75 % overlap). The per-band noise floor is tracked continuously as the quietest recent level, so no "learn noise" step is needed. Each band is attenuated according to how far it sits above that floor.
- Adds 10.7 ms of delay to the strip while it is on.
- A perfectly steady tone, such as mains hum or a test tone, counts as noise and is removed. Speech, music and other changing sounds are kept.

### Gate
Silences the strip between phrases.
| Parameter | Range | Default |
|---|---|---|
| Threshold | −80 … 0 dBFS | −50 |
| Range (attenuation when closed) | 0 … 80 dB | 40 |
| Attack | 0.1 … 50 ms | 1 |
| Hold | 0 … 500 ms | 80 |
| Release | 5 … 2000 ms | 200 |

The gate opens when the level exceeds the threshold. It closes after the hold time once the level falls 3 dB below the threshold (hysteresis). Indicator: open/closed.

### 3-band EQ
| Band | Type | Frequency | Gain |
|---|---|---|---|
| Low | low shelf | 100 Hz | −12 … +12 dB, default 0 |
| Mid | peak, Q 1.0 | 1 kHz | −12 … +12 dB, default 0 |
| High | high shelf | 8 kHz | −12 … +12 dB, default 0 |

### Parametric EQ (6 bands)
Each band has on/off, a type (peak, low shelf, high shelf, high-pass, low-pass), a frequency (20 Hz … 20 kHz), a gain (−18 … +18 dB, ignored for the pass types) and a Q (0.1 … 10). The default bands are all off: peak 100 Hz, 250 Hz, 1 kHz, 3 kHz, 6 kHz and 12 kHz, each at Q 1. Filters are standard second-order (biquad) sections.

### Compressor
Stereo-linked and feed-forward: the louder channel controls both.
| Parameter | Range | Default |
|---|---|---|
| Threshold | −60 … 0 dBFS | −20 |
| Ratio | 1 … 20 : 1 | 3 |
| Knee | 0 … 12 dB (soft knee width) | 6 |
| Attack | 0.1 … 200 ms | 10 |
| Release | 10 … 2000 ms | 150 |
| Make-up gain | −12 … +24 dB | 0 |

Static curve: below `T − K/2` it is unity. Above `T + K/2`, the output is `T + (in − T)/R`. In between, a quadratic joins the two smoothly. The UI draws this transfer curve with the live input level, and shows gain reduction in dB.

### Limiter
A brickwall limiter after the fader, so a fader boost can never clip a bus.
| Parameter | Range | Default |
|---|---|---|
| Ceiling | −24 … 0 dBFS | −1 |
| Release | 10 … 1000 ms | 100 |

It looks 1.5 ms ahead, which adds 1.5 ms of delay while it is on. No output sample exceeds the ceiling. Indicator: gain reduction in dB.

## Bus chain
Order: bus sum → **parametric EQ (6 bands)** → bus gain → **limiter** → **mode** → soft clip → output.
- Mode: `stereo` (default) or `mono` ((L+R)/2 on both sides).
- The EQ and limiter are the same blocks as on strips. The limiter's default ceiling on a bus is −1 dBFS, and it is off by default.

## Presets
- Strip presets store the whole strip chain: denoiser, gate, EQs, compressor and limiter, but not gain, pan or routing.
- Built-in presets:
  - **Flat:** everything off.
  - **Voice – clean:** gate −50, high-pass 80 Hz, compressor 3:1 at −20, limiter −1.
  - **Voice – broadcast:** high-pass 80 Hz, low shelf −2 dB at 100 Hz, presence +3 dB at 4 kHz, compressor 4:1 at −24 with +6 make-up, limiter −1.
  - **Webcam mic cleanup:** denoiser 70 %, gate −45, high-pass 120 Hz, low shelf −3 dB, compressor 3:1 at −22 with +4 make-up, limiter −1.
- User presets are saved by name in the settings file.

## Not in Phase 3
- Echo cancellation: Apple's voice processing works only through its own voice-processing I/O unit, which owns the device. That conflicts with this engine's model of one mixer per device clock. It is deferred and needs its own design.
- Reverb, delay, pitch: Phase 5.

## Acceptance (Phase 3)
1. Offline tests for each block against reference signals: EQ gains at the target frequencies, gate attenuation, the compressor's static curve, the limiter never exceeding its ceiling, and the denoiser lowering noise while keeping a tone.
2. CPU: 8 strips with every block on, at 48 kHz, cost less than 10 % of one core.
3. In the app, every parameter is adjustable live, and the gate and compressor indicators move with the signal.
