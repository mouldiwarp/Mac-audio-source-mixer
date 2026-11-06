// AdaptiveRing: carries stereo audio from one clock domain to another.
//
// A producer thread pushes frames at its own rate. A consumer thread pulls
// frames at its own rate through a windowed-sinc resampler. The resampler's
// ratio is trimmed by a PI controller so the buffered amount stays near a
// target, which absorbs clock drift (spec/features/mixer.md, "Clocks and drift").
//
// Exactly one producer thread and one consumer thread. Real-time safe: no
// locks or allocations after creation.
#ifndef ADAPTIVE_RING_H
#define ADAPTIVE_RING_H

#include <stdbool.h>
#include <stdint.h>

typedef struct AdaptiveRing AdaptiveRing;

typedef struct {
    uint64_t underruns;     // pulls that found too little data (output silence)
    uint64_t droppedFrames; // input frames discarded because the buffer overfilled
    double ratioPPM;        // current drift correction, parts per million
    double fillFrames;      // smoothed buffered amount, in input frames
    double targetFrames;    // what the controller aims for
    bool running;           // false while priming
} AdaptiveRingStats;

// inRate: producer sample rate. outRate: consumer sample rate.
AdaptiveRing *AdaptiveRingCreate(double inRate, double outRate);
void AdaptiveRingDestroy(AdaptiveRing *r);

// `now` arguments: seconds on a clock shared by both threads (host time). They
// let the consumer estimate how full the ring is between pushes, which removes
// the sawtooth that whole-buffer pushes would otherwise put into the controller.

// Producer side. Interleaved stereo. Returns frames accepted.
uint32_t AdaptiveRingPush(AdaptiveRing *r, const float *interleavedLR, uint32_t frames, double now);
// Producer side, non-interleaved variant.
uint32_t AdaptiveRingPushSplit(AdaptiveRing *r, const float *l, const float *rch, uint32_t frames, double now);

// Consumer side. Writes `frames` output frames (non-interleaved). Returns false
// (and writes silence) if the ring is priming or ran dry.
bool AdaptiveRingPull(AdaptiveRing *r, float *outL, float *outR, uint32_t frames, double now);

// Any thread (approximate values).
void AdaptiveRingGetStats(AdaptiveRing *r, AdaptiveRingStats *out);

#endif
