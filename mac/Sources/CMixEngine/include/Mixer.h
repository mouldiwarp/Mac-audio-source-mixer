// Mixer: the Phase 2 engine (spec/features/mixer.md).
//
// Master clock: the hidden 6-channel "Mixdeck Feed" device. Each of its IO
// cycles pulls every strip's source at 48 kHz, mixes into six buses, writes
// B1..B3 to the feed and pushes A1..A3 to hardware outputs.
//
// Threads: the control functions may be called from any one non-real-time
// thread (the app's main thread). The real-time threads never block.
#ifndef MIXER_H
#define MIXER_H

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AUComponent.h>
#include "VoiceFx.h"
#include "StereoRing.h"
#include "Loudness.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MIXER_MAX_STRIPS 8
enum { MIXER_BUS_A1, MIXER_BUS_A2, MIXER_BUS_A3, MIXER_BUS_B1, MIXER_BUS_B2, MIXER_BUS_B3, MIXER_NUM_BUSES };
#define MIXER_NUM_HW_BUSES 3

typedef struct Mixer Mixer;

typedef struct {
    float peakL, peakR;        // linear peak since the last MixerGetStats call
    uint64_t underruns;        // source/sink ran dry
    uint64_t droppedFrames;
    double ratioPPM;           // drift correction in use
    bool attached;             // has a source (strip) or device (A bus)
    bool running;              // audio flowing (false while priming)
    FxMeters fx;               // voice chain indicators (spec/features/voice-dsp.md)
} MixerChannelStats;

typedef struct {
    MixerChannelStats strip[MIXER_MAX_STRIPS];
    MixerChannelStats bus[MIXER_NUM_BUSES];
    uint64_t cycles;           // master IO cycles so far
    uint32_t bufferFrames;     // master buffer size
    double load;               // fraction of the master cycle spent mixing (0..1)
} MixerStats;

// feedDevice: the "Mixdeck Feed" device. bufferFrames: requested IO size (256).
Mixer *MixerCreate(AudioObjectID feedDevice, uint32_t bufferFrames, char *err, size_t errLen);
OSStatus MixerStart(Mixer *m);
void MixerStop(Mixer *m);
void MixerDestroy(Mixer *m);

// Sources. Channels are 1-based device input channels (chA == chB: mono).
// Works for any input device, including private aggregate devices that carry
// a process tap. Replaces any existing source on the strip.
OSStatus MixerStripAttachDevice(Mixer *m, int strip, AudioObjectID device, uint32_t chA, uint32_t chB,
                                char *err, size_t errLen);
void MixerStripAttachTone(Mixer *m, int strip, double hz);   // test source, -12 dBFS sine
// File player source: the strip pulls 48 kHz stereo from `ring` (not owned; the
// caller keeps it alive until it is detached). Pause/flush via StereoRing.
void MixerStripAttachRing(Mixer *m, int strip, StereoRing *ring);
void MixerStripDetach(Mixer *m, int strip);

// Strip controls (any time, take effect within one cycle, ramped).
void MixerStripSetGainDB(Mixer *m, int strip, float dB);    // -60 (silent) .. +12
void MixerStripSetPan(Mixer *m, int strip, float pan);      // -1 .. +1
void MixerStripSetMono(Mixer *m, int strip, bool on);
void MixerStripSetMute(Mixer *m, int strip, bool on);
void MixerStripSetSolo(Mixer *m, int strip, bool on);
void MixerStripSetAssign(Mixer *m, int strip, int bus, bool on);

// Voice chain (spec/features/voice-dsp.md). Strip: every block. Bus: the
// parametric EQ, limiter and monoOut are used; the other blocks are ignored.
void MixerStripSetFx(Mixer *m, int strip, const FxParams *p);
void MixerBusSetFx(Mixer *m, int bus, const FxParams *p);

// Bus controls.
void MixerBusSetGainDB(Mixer *m, int bus, float dB);
void MixerBusSetMute(Mixer *m, int bus, bool on);
// A buses only (bus 0..2). device 0 = none. Uses the device's output channels 1-2.
OSStatus MixerBusSetDevice(Mixer *m, int bus, AudioObjectID device, char *err, size_t errLen);

// Recording taps (spec/features/control-and-recording.md §1). Every non-NULL ring
// receives that strip's post-pan signal or that bus's output, all in the same
// cycles, from the moment the set is installed. Pass NULL arrays to remove.
// Rings are not owned; the previous set is no longer used when this returns.
void MixerSetCaptures(Mixer *m, StereoRing *const strips[MIXER_MAX_STRIPS], StereoRing *const buses[MIXER_NUM_BUSES]);

// ---- Plug-in inserts (spec/features/plugins-and-balance.md §1) ------------------
// The render and pull-input blocks have the same ABI as AUAudioUnit's
// AURenderBlock / AURenderPullInputBlock, so the app passes au.renderBlock.
#define MIXER_INSERT_SLOTS 4
typedef OSStatus (^MixerAUPullInput)(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                                     uint32_t frames, long bus, AudioBufferList *input);
typedef OSStatus (^MixerAURender)(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                                  uint32_t frames, long bus, AudioBufferList *output, MixerAUPullInput pull);
typedef struct MixerInsert MixerInsert;
MixerInsert *MixerInsertCreate(MixerAURender render);
void MixerInsertDestroy(MixerInsert *ins);        // only after it was removed from its slot
void MixerInsertSetBypass(MixerInsert *ins, bool bypass);
uint64_t MixerInsertErrors(MixerInsert *ins);
int32_t MixerInsertLastError(MixerInsert *ins);     // last failing render status (diagnostics)
uint64_t MixerInsertPulls(MixerInsert *ins);        // input pulls so far (diagnostics)
// Puts ins (or NULL) into a slot. When this returns, the previous occupant is no
// longer used by the audio thread and may be destroyed.
void MixerStripSetInsert(Mixer *m, int strip, int slot, MixerInsert *ins);
void MixerBusSetInsert(Mixer *m, int bus, int slot, MixerInsert *ins);

// ---- Loudness (spec/features/plugins-and-balance.md §2) ---------------------------
// Pre-fader 100 ms K-weighted blocks of a strip; see LoudnessBlocks().
uint32_t MixerStripLoudnessBlocks(Mixer *m, int strip, float *out, uint32_t max, uint64_t since, uint64_t *total);

// Peaks reset on each call.
void MixerGetStats(Mixer *m, MixerStats *out);

#endif
