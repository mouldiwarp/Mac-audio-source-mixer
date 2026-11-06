// Voice processing chain (spec/features/voice-dsp.md).
//
// One FxChain per strip and per bus. Parameters are set from one control
// thread and picked up by the audio thread at the start of its next block
// (lock-free). Processing never allocates or blocks.
#ifndef VOICEFX_H
#define VOICEFX_H

#include <stdbool.h>
#include <stdint.h>

#define FX_PEQ_BANDS 6

typedef enum { FX_PEQ_PEAK, FX_PEQ_LOWSHELF, FX_PEQ_HIGHSHELF, FX_PEQ_HIGHPASS, FX_PEQ_LOWPASS } FxPeqType;

typedef struct { bool on; float amount; } FxDenoise;                       // amount 0..1
typedef struct { bool on; float thresholdDB, rangeDB, attackMs, holdMs, releaseMs; } FxGate;
typedef struct { bool on; float lowDB, midDB, highDB; } FxEq3;
typedef struct { bool on; int32_t type; float freq, gainDB, q; } FxPeqBand;
typedef struct { bool on; FxPeqBand band[FX_PEQ_BANDS]; } FxPeq;
typedef struct { bool on; float thresholdDB, ratio, kneeDB, attackMs, releaseMs, makeupDB; } FxComp;
typedef struct { bool on; float ceilingDB, releaseMs; } FxLimiter;

typedef struct {
    FxDenoise denoise;
    FxGate gate;
    FxEq3 eq3;
    FxPeq peq;
    FxComp comp;
    FxLimiter limiter;
    bool monoOut;          // bus mode "mono": (L+R)/2 after the limiter
} FxParams;

typedef struct {
    bool gateOpen;
    float compInputDB;     // detector level, peak since last read (-120 if silent)
    float compGainReductionDB;   // max since last read (>= 0)
    float limiterGainReductionDB;
} FxMeters;

typedef struct FxChain FxChain;

// Fills p with the spec defaults (every block off).
void FxParamsDefault(FxParams *p);

FxChain *FxChainCreate(double sampleRate);
void FxChainDestroy(FxChain *c);

// Control thread.
void FxChainSetParams(FxChain *c, const FxParams *p);
void FxChainGetMeters(FxChain *c, FxMeters *out);   // resets peak values

// Audio thread. n <= 4096.
// Pre: denoiser, gate, 3-band EQ, parametric EQ, compressor (strip, before the fader).
void FxChainProcessPre(FxChain *c, float *l, float *r, uint32_t n);
// Post: limiter, then mono mode (after the fader).
void FxChainProcessPost(FxChain *c, float *l, float *r, uint32_t n);

// Static compressor curve: output level (dBFS) for an input level, given p.
float FxCompStaticCurve(const FxComp *p, float inDB);

#endif
