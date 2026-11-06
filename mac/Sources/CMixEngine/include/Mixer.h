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
#include "VoiceFx.h"
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

// Peaks reset on each call.
void MixerGetStats(Mixer *m, MixerStats *out);

#endif
