// Voice processing chain. See include/VoiceFx.h and spec/features/voice-dsp.md.

#include "VoiceFx.h"
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define MAXN 4096u

static inline double clampd(double v, double lo, double hi) { return v < lo ? lo : v > hi ? hi : v; }
static inline float lin2db(float v) { return v > 1e-6f ? 20.0f * log10f(v) : -120.0f; }
static inline float db2lin(float d) { return powf(10.0f, d / 20.0f); }
// One-pole coefficient for a time constant in ms.
static inline float tc(double ms, double fs) { return (float)exp(-1.0 / (fmax(ms, 0.01) * 1e-3 * fs)); }

// ---- Biquad (stereo, transposed direct form II, double precision) --------------

typedef struct { double b0, b1, b2, a1, a2, z[2][2]; } Biquad;

static void bqDesign(Biquad *q, int type, double fs, double f, double gainDB, double Q) {
    f = clampd(f, 10.0, fs * 0.49);
    Q = clampd(Q, 0.05, 20.0);
    double A = pow(10.0, gainDB / 40.0), w = 2 * M_PI * f / fs, cw = cos(w), sw = sin(w);
    double al = sw / (2 * Q), b0, b1, b2, a0, a1, a2, sA = 2 * sqrt(A) * al;
    switch (type) {
    case FX_PEQ_LOWSHELF:
        b0 = A * ((A + 1) - (A - 1) * cw + sA); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - sA);
        a0 = (A + 1) + (A - 1) * cw + sA;       a1 = -2 * ((A - 1) + (A + 1) * cw);    a2 = (A + 1) + (A - 1) * cw - sA;
        break;
    case FX_PEQ_HIGHSHELF:
        b0 = A * ((A + 1) + (A - 1) * cw + sA); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - sA);
        a0 = (A + 1) - (A - 1) * cw + sA;       a1 = 2 * ((A - 1) - (A + 1) * cw);      a2 = (A + 1) - (A - 1) * cw - sA;
        break;
    case FX_PEQ_HIGHPASS:
        b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al;
        break;
    case FX_PEQ_LOWPASS:
        b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al;
        break;
    default: // peak
        b0 = 1 + al * A; b1 = -2 * cw; b2 = 1 - al * A; a0 = 1 + al / A; a1 = -2 * cw; a2 = 1 - al / A;
        break;
    }
    q->b0 = b0 / a0; q->b1 = b1 / a0; q->b2 = b2 / a0; q->a1 = a1 / a0; q->a2 = a2 / a0;
}

static void bqReset(Biquad *q) { memset(q->z, 0, sizeof q->z); }

static void bqRun(Biquad *q, float *l, float *r, uint32_t n) {
    float *ch[2] = { l, r };
    for (int c = 0; c < 2; c++) {
        double z1 = q->z[c][0], z2 = q->z[c][1];
        float *x = ch[c];
        for (uint32_t i = 0; i < n; i++) {
            double in = x[i], out = q->b0 * in + z1;
            z1 = q->b1 * in - q->a1 * out + z2;
            z2 = q->b2 * in - q->a2 * out;
            x[i] = (float)out;
        }
        // Flush denormals.
        if (fabs(z1) < 1e-20) z1 = 0;
        if (fabs(z2) < 1e-20) z2 = 0;
        q->z[c][0] = z1; q->z[c][1] = z2;
    }
}

// ---- Limiter (look-ahead, provably never above the ceiling) ---------------------
//
// The required gain for each sample is min(1, ceiling / peak). A sliding minimum
// over the look-ahead window, a release-only smoother, and a moving average over
// the same window give a gain curve that is at or below every requirement for
// the sample it is applied to, so the delayed output never exceeds the ceiling.

#define LIM_MAXW 256

typedef struct {
    uint32_t w;                      // window = delay + 1
    float dl[2][LIM_MAXW];          // delay lines
    float dqVal[LIM_MAXW];
    uint64_t dqIdx[LIM_MAXW];
    uint32_t dqHead, dqCount;
    float ma[LIM_MAXW];
    double maSum;
    uint32_t pos;
    uint64_t n;
    float env, rel, ceil;
    float minGain;                   // for the meter
} Limiter;

static void limInit(Limiter *L, double fs) {
    memset(L, 0, sizeof *L);
    L->w = (uint32_t)clampd(round(1.5e-3 * fs), 2, LIM_MAXW);
    for (uint32_t i = 0; i < L->w; i++) L->ma[i] = 1.0f;
    L->maSum = L->w;
    L->env = 1.0f;
    L->minGain = 1.0f;
}

static void limRun(Limiter *L, float *l, float *r, uint32_t n) {
    const uint32_t W = L->w;
    const float ceil = L->ceil, target = ceil * 0.9995f;
    for (uint32_t i = 0; i < n; i++) {
        float pk = fmaxf(fabsf(l[i]), fabsf(r[i]));
        float req = pk > target ? target / pk : 1.0f;
        uint64_t idx = L->n++;
        // sliding minimum over the last W requirements (expire first so the deque never overflows)
        while (L->dqCount && L->dqIdx[L->dqHead] + W <= idx) { L->dqHead = (L->dqHead + 1) % W; L->dqCount--; }
        while (L->dqCount && L->dqVal[(L->dqHead + L->dqCount - 1) % W] >= req) L->dqCount--;
        uint32_t slot = (L->dqHead + L->dqCount) % W;
        L->dqVal[slot] = req; L->dqIdx[slot] = idx; L->dqCount++;
        float m = L->dqVal[L->dqHead];
        // instant down, released up
        L->env = m < L->env ? m : m + (L->env - m) * L->rel;
        // moving average over W
        L->maSum += (double)L->env - L->ma[L->pos];
        L->ma[L->pos] = L->env;
        float g = (float)(L->maSum / W);
        // delay line: write, advance, then read the sample written W-1 samples ago
        L->dl[0][L->pos] = l[i]; L->dl[1][L->pos] = r[i];
        L->pos = (L->pos + 1) % W;
        float ol = L->dl[0][L->pos] * g, orr = L->dl[1][L->pos] * g;
        // Rounding guard (the construction already keeps us below the ceiling).
        l[i] = fmaxf(-ceil, fminf(ceil, ol));
        r[i] = fmaxf(-ceil, fminf(ceil, orr));
        if (g < L->minGain) L->minGain = g;
    }
    // Keep the running sum exact over long runs.
    if ((L->n & 0xFFFF) < n) { double s = 0; for (uint32_t k = 0; k < W; k++) s += L->ma[k]; L->maSum = s; }
}

// ---- Denoiser (STFT, minimum-tracking noise floor, spectral gain) ---------------

#define DN_N    512
#define DN_LOG2 9
#define DN_HOP  128
#define DN_BINS (DN_N / 2)

typedef struct {
    FFTSetup fft;
    float win[DN_N];
    float in[2][DN_N];
    float acc[2][DN_N];
    float out[2][DN_HOP];
    uint32_t k;
    float re[2][DN_BINS], im[2][DN_BINS];
    float ps[DN_BINS], noise[DN_BINS], gs[DN_BINS];
    float buf[DN_N];
    bool primed;
} Denoiser;

static bool dnInit(Denoiser *d) {
    memset(d, 0, sizeof *d);
    d->fft = vDSP_create_fftsetup(DN_LOG2, kFFTRadix2);
    if (!d->fft) return false;
    for (int i = 0; i < DN_N; i++) d->win[i] = (float)sqrt(0.5 - 0.5 * cos(2 * M_PI * i / DN_N));   // sqrt periodic Hann
    return true;
}

static void dnReset(Denoiser *d) {
    memset(d->in, 0, sizeof d->in); memset(d->acc, 0, sizeof d->acc); memset(d->out, 0, sizeof d->out);
    d->k = 0; d->primed = false;
    for (int b = 0; b < DN_BINS; b++) { d->gs[b] = 1.0f; d->ps[b] = 0; d->noise[b] = 1e30f; }
}

static void dnFrame(Denoiser *d, float amount) {
    const float floorG = db2lin(-24.0f * amount), beta = 3.0f;
    const float rise = 1.00307f;        // noise floor may rise ~5 dB/s (375 frames/s)
    for (int c = 0; c < 2; c++) {
        vDSP_vmul(d->in[c], 1, d->win, 1, d->buf, 1, DN_N);
        DSPSplitComplex z = { d->re[c], d->im[c] };
        vDSP_ctoz((const DSPComplex *)d->buf, 2, &z, 1, DN_BINS);
        vDSP_fft_zrip(d->fft, &z, 1, DN_LOG2, kFFTDirection_Forward);
    }
    float g[DN_BINS];
    for (int b = 1; b < DN_BINS; b++) {
        float p = 0.5f * (d->re[0][b] * d->re[0][b] + d->im[0][b] * d->im[0][b] +
                          d->re[1][b] * d->re[1][b] + d->im[1][b] * d->im[1][b]) + 1e-20f;
        d->ps[b] = d->primed ? 0.9f * d->ps[b] + 0.1f * p : p;
        if (d->ps[b] < d->noise[b]) d->noise[b] = d->ps[b]; else d->noise[b] *= rise;
        float gb = 1.0f - beta * d->noise[b] / p;
        if (gb < floorG) gb = floorG;
        // open fast, close gently (reduces "musical noise")
        d->gs[b] = gb > d->gs[b] ? gb : 0.6f * d->gs[b] + 0.4f * gb;
        g[b] = d->gs[b];
    }
    d->primed = true;
    g[0] = g[1];
    const float scale = 1.0f / (2.0f * DN_N) * 0.5f;   // zrip round trip (2N) x window overlap sum (2)
    for (int c = 0; c < 2; c++) {
        float nyq = d->im[c][0] * g[DN_BINS - 1];
        vDSP_vmul(d->re[c], 1, g, 1, d->re[c], 1, DN_BINS);
        vDSP_vmul(d->im[c], 1, g, 1, d->im[c], 1, DN_BINS);
        d->im[c][0] = nyq;
        DSPSplitComplex z = { d->re[c], d->im[c] };
        vDSP_fft_zrip(d->fft, &z, 1, DN_LOG2, kFFTDirection_Inverse);
        vDSP_ztoc(&z, 1, (DSPComplex *)d->buf, 2, DN_BINS);
        vDSP_vmul(d->buf, 1, d->win, 1, d->buf, 1, DN_N);
        vDSP_vsma(d->buf, 1, &scale, d->acc[c], 1, d->acc[c], 1, DN_N);
        memcpy(d->out[c], d->acc[c], DN_HOP * sizeof(float));
        memmove(d->acc[c], d->acc[c] + DN_HOP, (DN_N - DN_HOP) * sizeof(float));
        memset(d->acc[c] + DN_N - DN_HOP, 0, DN_HOP * sizeof(float));
        memmove(d->in[c], d->in[c] + DN_HOP, (DN_N - DN_HOP) * sizeof(float));
    }
}

static void dnRun(Denoiser *d, float *l, float *r, uint32_t n, float amount) {
    for (uint32_t i = 0; i < n; i++) {
        d->in[0][DN_N - DN_HOP + d->k] = l[i];
        d->in[1][DN_N - DN_HOP + d->k] = r[i];
        l[i] = d->out[0][d->k];
        r[i] = d->out[1][d->k];
        if (++d->k == DN_HOP) { d->k = 0; dnFrame(d, amount); }
    }
}

// ---- Chain ----------------------------------------------------------------------

struct FxChain {
    double fs;
    // parameter hand-off (seqlock: odd = being written)
    _Atomic uint32_t seq;
    FxParams shared;
    uint32_t seenSeq;
    FxParams cur;          // audio thread's copy
    bool have;             // cur valid

    Denoiser dn;
    // gate
    float gEnv, gDB, gDet, gAtkStep, gRelStep, gThr, gThrLo, gRangeDB;
    uint32_t gHold, gHoldN;
    bool gOpen;
    // EQs
    Biquad eq3[3];
    Biquad peq[FX_PEQ_BANDS];
    // compressor
    float cGr, cAtk, cRel, cMakeup, cMakeupTarget, cMakeupCoef;
    // limiter
    Limiter lim;

    // meters
    _Atomic bool mGateOpen;
    _Atomic uint32_t mCompIn, mCompGr, mLimGr;   // float bits, peak-hold until read
};

void FxParamsDefault(FxParams *p) {
    memset(p, 0, sizeof *p);
    p->denoise = (FxDenoise){ false, 0.5f };
    p->gate = (FxGate){ false, -50, 40, 1, 80, 200 };
    p->eq3 = (FxEq3){ false, 0, 0, 0 };
    static const float f[FX_PEQ_BANDS] = { 100, 250, 1000, 3000, 6000, 12000 };
    p->peq.on = false;
    for (int b = 0; b < FX_PEQ_BANDS; b++) p->peq.band[b] = (FxPeqBand){ false, FX_PEQ_PEAK, f[b], 0, 1 };
    p->comp = (FxComp){ false, -20, 3, 6, 10, 150, 0 };
    p->limiter = (FxLimiter){ false, -1, 100 };
    p->monoOut = false;
}

static void meterMax(_Atomic uint32_t *slot, float v) {
    uint32_t cur = atomic_load_explicit(slot, memory_order_relaxed);
    float f; memcpy(&f, &cur, 4);
    if (v > f) { memcpy(&cur, &v, 4); atomic_store_explicit(slot, cur, memory_order_relaxed); }
}
static float meterTake(_Atomic uint32_t *slot, float reset) {
    uint32_t r; memcpy(&r, &reset, 4);
    uint32_t v = atomic_exchange(slot, r);
    float f; memcpy(&f, &v, 4);
    return f;
}

FxChain *FxChainCreate(double fs) {
    FxChain *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->fs = fs;
    if (!dnInit(&c->dn)) { free(c); return NULL; }
    dnReset(&c->dn);
    limInit(&c->lim, fs);
    c->cMakeup = 1.0f;
    float lo = -120.0f, zero = 0.0f;
    uint32_t b; memcpy(&b, &lo, 4); atomic_init(&c->mCompIn, b);
    memcpy(&b, &zero, 4); atomic_init(&c->mCompGr, b); atomic_init(&c->mLimGr, b);
    FxParams p; FxParamsDefault(&p);
    FxChainSetParams(c, &p);
    return c;
}

void FxChainDestroy(FxChain *c) {
    if (!c) return;
    if (c->dn.fft) vDSP_destroy_fftsetup(c->dn.fft);
    free(c);
}

void FxChainSetParams(FxChain *c, const FxParams *p) {
    uint32_t s = atomic_load_explicit(&c->seq, memory_order_relaxed);
    atomic_store_explicit(&c->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    memcpy(&c->shared, p, sizeof *p);
    atomic_store_explicit(&c->seq, s + 2, memory_order_release);
}

void FxChainGetMeters(FxChain *c, FxMeters *out) {
    out->gateOpen = atomic_load_explicit(&c->mGateOpen, memory_order_relaxed);
    out->compInputDB = meterTake(&c->mCompIn, -120.0f);
    out->compGainReductionDB = meterTake(&c->mCompGr, 0.0f);
    out->limiterGainReductionDB = meterTake(&c->mLimGr, 0.0f);
}

float FxCompStaticCurve(const FxComp *p, float x) {
    float T = p->thresholdDB, R = fmaxf(1.0f, p->ratio), K = fmaxf(0.0f, p->kneeDB);
    float d = x - T;
    if (2 * d < -K) return x;
    if (K > 0 && 2 * fabsf(d) <= K) { float t = d + K / 2; return x + (1.0f / R - 1.0f) * t * t / (2 * K); }
    return T + d / R;
}

// Applies new parameters on the audio thread: coefficients, time constants, and
// resets of blocks that were just switched on.
static void applyParams(FxChain *c, const FxParams *np) {
    const double fs = c->fs;
    FxParams old = c->cur;
    bool first = !c->have;
    c->cur = *np;
    FxParams *p = &c->cur;

    if (p->denoise.on && (first || !old.denoise.on)) dnReset(&c->dn);
    p->denoise.amount = (float)clampd(p->denoise.amount, 0, 1);

    FxGate *g = &p->gate;
    c->gThr = db2lin((float)clampd(g->thresholdDB, -80, 0));
    c->gThrLo = c->gThr * 0.70795f;   // -3 dB hysteresis
    c->gRangeDB = (float)clampd(g->rangeDB, 0, 80);
    // Attack/release are the times to travel the whole range (linear in dB).
    c->gAtkStep = (float)(fmax(c->gRangeDB, 1) / (clampd(g->attackMs, 0.1, 50) * 1e-3 * fs));
    c->gRelStep = (float)(fmax(c->gRangeDB, 1) / (clampd(g->releaseMs, 5, 2000) * 1e-3 * fs));
    c->gDet = tc(20, fs);
    c->gHoldN = (uint32_t)(clampd(g->holdMs, 0, 500) * 1e-3 * fs);
    if (g->on && (first || !old.gate.on)) { c->gEnv = 0; c->gDB = 0; c->gOpen = true; c->gHold = c->gHoldN; }

    const double f3[3] = { 100, 1000, 8000 };
    const int t3[3] = { FX_PEQ_LOWSHELF, FX_PEQ_PEAK, FX_PEQ_HIGHSHELF };
    const float g3[3] = { p->eq3.lowDB, p->eq3.midDB, p->eq3.highDB };
    for (int i = 0; i < 3; i++) {
        bqDesign(&c->eq3[i], t3[i], fs, f3[i], clampd(g3[i], -12, 12), i == 1 ? 1.0 : M_SQRT1_2);
        if (p->eq3.on && (first || !old.eq3.on)) bqReset(&c->eq3[i]);
    }
    for (int b = 0; b < FX_PEQ_BANDS; b++) {
        FxPeqBand *pb = &p->peq.band[b];
        bqDesign(&c->peq[b], pb->type, fs, clampd(pb->freq, 20, 20000), clampd(pb->gainDB, -18, 18), clampd(pb->q, 0.1, 10));
        bool wasOn = !first && old.peq.on && old.peq.band[b].on && old.peq.band[b].type == pb->type;
        if (!wasOn) bqReset(&c->peq[b]);
    }

    FxComp *k = &p->comp;
    k->ratio = (float)clampd(k->ratio, 1, 20);
    k->kneeDB = (float)clampd(k->kneeDB, 0, 12);
    k->thresholdDB = (float)clampd(k->thresholdDB, -60, 0);
    c->cAtk = tc(clampd(k->attackMs, 0.1, 200), fs);
    c->cRel = tc(clampd(k->releaseMs, 10, 2000), fs);
    c->cMakeupTarget = db2lin((float)clampd(k->makeupDB, -12, 24));
    c->cMakeupCoef = tc(10, fs);
    if (k->on && (first || !old.comp.on)) { c->cGr = 0; c->cMakeup = c->cMakeupTarget; }

    FxLimiter *L = &p->limiter;
    c->lim.ceil = db2lin((float)clampd(L->ceilingDB, -24, 0));
    c->lim.rel = tc(clampd(L->releaseMs, 10, 1000), fs);
    if (L->on && (first || !old.limiter.on)) { float ce = c->lim.ceil, re = c->lim.rel; limInit(&c->lim, fs); c->lim.ceil = ce; c->lim.rel = re; }

    if (!g->on) atomic_store_explicit(&c->mGateOpen, true, memory_order_relaxed);
    c->have = true;
}

static void pickUpParams(FxChain *c) {
    uint32_t s1 = atomic_load_explicit(&c->seq, memory_order_acquire);
    if ((s1 & 1) || (c->have && s1 == c->seenSeq)) return;
    FxParams tmp;
    memcpy(&tmp, &c->shared, sizeof tmp);
    atomic_thread_fence(memory_order_acquire);
    if (atomic_load_explicit(&c->seq, memory_order_relaxed) != s1) return;   // torn; next block
    c->seenSeq = s1;
    applyParams(c, &tmp);
}

static void gateRun(FxChain *c, float *l, float *r, uint32_t n) {
    float env = c->gEnv, gdb = c->gDB;
    const float det = c->gDet, up = c->gAtkStep, down = c->gRelStep, thr = c->gThr, lo = c->gThrLo, floorDB = -c->gRangeDB;
    bool open = c->gOpen;
    uint32_t hold = c->gHold;
    for (uint32_t i = 0; i < n; i++) {
        float lv = fmaxf(fabsf(l[i]), fabsf(r[i]));
        env = lv > env ? lv : env * det;
        if (env > thr) { open = true; hold = c->gHoldN; }
        else if (env < lo) { if (hold) hold--; else open = false; }
        if (open) gdb = fminf(0.0f, gdb + up); else gdb = fmaxf(floorDB, gdb - down);
        if (gdb < floorDB) gdb = floorDB;            // range changed while closed
        float g = gdb == 0.0f ? 1.0f : expf(gdb * 0.115129255f);
        l[i] *= g; r[i] *= g;
    }
    if (env < 1e-20f) env = 0;
    c->gEnv = env; c->gDB = gdb; c->gOpen = open; c->gHold = hold;
    atomic_store_explicit(&c->mGateOpen, open, memory_order_relaxed);
}

static void compRun(FxChain *c, float *l, float *r, uint32_t n) {
    const FxComp *p = &c->cur.comp;
    const float atk = c->cAtk, rel = c->cRel, mt = c->cMakeupTarget, mc = c->cMakeupCoef;
    float gr = c->cGr, mk = c->cMakeup, maxIn = -120.0f, maxGr = 0.0f;
    for (uint32_t i = 0; i < n; i++) {
        float lv = fmaxf(fabsf(l[i]), fabsf(r[i]));
        float x = lin2db(lv);
        float want = x - FxCompStaticCurve(p, x);
        gr = want + (gr - want) * (want > gr ? atk : rel);
        mk = mt + (mk - mt) * mc;
        float g = db2lin(-gr) * mk;
        l[i] *= g; r[i] *= g;
        if (x > maxIn) maxIn = x;
        if (gr > maxGr) maxGr = gr;
    }
    c->cGr = gr; c->cMakeup = mk;
    meterMax(&c->mCompIn, maxIn);
    meterMax(&c->mCompGr, maxGr);
}

void FxChainProcessPre(FxChain *c, float *l, float *r, uint32_t n) {
    pickUpParams(c);
    if (!c->have || n == 0 || n > MAXN) return;
    const FxParams *p = &c->cur;
    if (p->denoise.on) dnRun(&c->dn, l, r, n, p->denoise.amount);
    if (p->gate.on) gateRun(c, l, r, n);
    if (p->eq3.on) for (int i = 0; i < 3; i++) bqRun(&c->eq3[i], l, r, n);
    if (p->peq.on)
        for (int b = 0; b < FX_PEQ_BANDS; b++) if (p->peq.band[b].on) bqRun(&c->peq[b], l, r, n);
    if (p->comp.on) compRun(c, l, r, n);
}

void FxChainProcessPost(FxChain *c, float *l, float *r, uint32_t n) {
    pickUpParams(c);
    if (!c->have || n == 0 || n > MAXN) return;
    const FxParams *p = &c->cur;
    if (p->limiter.on) {
        c->lim.minGain = 1.0f;
        limRun(&c->lim, l, r, n);
        meterMax(&c->mLimGr, -lin2db(c->lim.minGain));
    }
    if (p->monoOut) for (uint32_t i = 0; i < n; i++) l[i] = r[i] = 0.5f * (l[i] + r[i]);
}
