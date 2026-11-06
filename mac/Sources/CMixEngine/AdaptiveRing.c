// AdaptiveRing implementation. See include/AdaptiveRing.h.
//
// Resampler: 32-tap Kaiser-windowed sinc, 256 polyphase steps with linear
// interpolation between steps. Controller: PI on the smoothed buffered amount.

#include "AdaptiveRing.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define RING_CAP   32768u          // frames, power of two
#define HIST_CAP   16384u          // consumer-side history, frames
#define TAPS       32
#define HALF       (TAPS / 2)
#define PHASES     256
#define MARGIN_S   0.002           // jitter headroom, seconds
#define MAX_CORR   1.0e-3          // ±1000 ppm
// PI controller on the buffered amount in seconds, critically damped:
// the loop is d(err)/dt = -corr, so corr = KP*err + KI*∫err with KI = (KP/2)^2.
#define KP         0.25            // 1/s   (4 s time constant)
#define KI         (KP * KP / 4.0) // 1/s^2
#define FILL_TAU   0.2             // seconds, per stage (two stages)

struct AdaptiveRing {
    double inRate, outRate, nominalStep;

    // SPSC ring (interleaved stereo)
    float ring[RING_CAP * 2];
    _Atomic uint64_t w, r;
    _Atomic uint32_t pushChunk;      // largest push seen
    _Atomic uint64_t pushDropped;
    _Atomic bool consumerActive;     // set on first pull; overflow before that is not a dropout
    // Last push: write position and time, published with a sequence lock.
    _Atomic uint32_t pushSeq;
    uint64_t pushW;
    double pushT;

    // Consumer state
    float hL[HIST_CAP], hR[HIST_CAP];
    uint32_t histLen;
    double pos;
    bool primed;
    double filtFill, filt1, integ, corr, target;
    uint32_t lastPull;
    float kernel[PHASES + 1][TAPS];

    // Stats (consumer writes, anyone reads)
    _Atomic uint64_t underruns, pullDropped;
    volatile double statFill, statTarget, statCorr;
    volatile bool statRunning;
};

static double besselI0(double x) {
    double sum = 1.0, term = 1.0, q = x * x / 4.0;
    for (int k = 1; k < 50; k++) {
        term *= q / ((double)k * (double)k);
        sum += term;
        if (term < 1e-12 * sum) break;
    }
    return sum;
}

static void buildKernel(AdaptiveRing *r) {
    double fc = 0.90 * fmin(1.0, r->outRate / r->inRate);   // cutoff, fraction of input Nyquist
    const double beta = 8.0;
    double i0b = besselI0(beta);
    for (int j = 0; j <= PHASES; j++) {
        double frac = (double)j / PHASES, sum = 0;
        double h[TAPS];
        for (int k = 0; k < TAPS; k++) {
            double x = (double)(k - (HALF - 1)) - frac;      // distance from tap to the output point
            double s = (x == 0) ? 1.0 : sin(M_PI * fc * x) / (M_PI * fc * x);
            double t = x / HALF;
            double win = (fabs(t) >= 1.0) ? 0.0 : besselI0(beta * sqrt(1.0 - t * t)) / i0b;
            h[k] = fc * s * win;
            sum += h[k];
        }
        for (int k = 0; k < TAPS; k++) r->kernel[j][k] = (float)(h[k] / sum);   // unity DC gain
    }
}

static void resetConsumer(AdaptiveRing *r) {
    memset(r->hL, 0, sizeof(float) * HALF);
    memset(r->hR, 0, sizeof(float) * HALF);
    r->histLen = HALF - 1;      // zero history so the first taps have data
    r->pos = HALF - 1;
    r->primed = false;
    r->integ = 0;
    r->corr = 0;
}

AdaptiveRing *AdaptiveRingCreate(double inRate, double outRate) {
    if (inRate <= 0 || outRate <= 0) return NULL;
    AdaptiveRing *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->inRate = inRate;
    r->outRate = outRate;
    r->nominalStep = inRate / outRate;
    buildKernel(r);
    resetConsumer(r);
    return r;
}

void AdaptiveRingDestroy(AdaptiveRing *r) { free(r); }

static void noteChunk(AdaptiveRing *r, uint32_t frames) {
    uint32_t cur = atomic_load_explicit(&r->pushChunk, memory_order_relaxed);
    if (frames > cur) atomic_store_explicit(&r->pushChunk, frames, memory_order_relaxed);
}

static void publishPush(AdaptiveRing *r, uint64_t w, double now) {
    uint32_t q = atomic_load_explicit(&r->pushSeq, memory_order_relaxed);
    atomic_store_explicit(&r->pushSeq, q + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    r->pushW = w;
    r->pushT = now;
    atomic_store_explicit(&r->pushSeq, q + 2, memory_order_release);
}

// Write position the producer would have reached by `now`, extrapolated from the
// last push at the nominal rate (at most 1.5 chunks ahead).
static double virtualWritePos(AdaptiveRing *r, double now, double chunk) {
    for (int tries = 0; tries < 4; tries++) {
        uint32_t q0 = atomic_load_explicit(&r->pushSeq, memory_order_acquire);
        if (q0 & 1) continue;
        uint64_t w = r->pushW;
        double t = r->pushT;
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&r->pushSeq, memory_order_relaxed) != q0) continue;
        double ahead = (now - t) * r->inRate;
        if (ahead < 0) ahead = 0;
        if (ahead > 1.5 * chunk) ahead = 1.5 * chunk;
        return (double)w + ahead;
    }
    return (double)atomic_load_explicit(&r->w, memory_order_acquire);
}

uint32_t AdaptiveRingPush(AdaptiveRing *r, const float *lr, uint32_t frames, double now) {
    noteChunk(r, frames);
    uint64_t w = atomic_load_explicit(&r->w, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&r->r, memory_order_acquire);
    uint32_t space = RING_CAP - (uint32_t)(w - rd);
    uint32_t n = frames < space ? frames : space;
    for (uint32_t i = 0; i < n; i++) {
        size_t k = ((w + i) & (RING_CAP - 1)) * 2;
        r->ring[k] = lr[2 * i];
        r->ring[k + 1] = lr[2 * i + 1];
    }
    if (n < frames && atomic_load_explicit(&r->consumerActive, memory_order_relaxed))
        atomic_fetch_add_explicit(&r->pushDropped, frames - n, memory_order_relaxed);
    atomic_store_explicit(&r->w, w + n, memory_order_release);
    publishPush(r, w + n, now);
    return n;
}

uint32_t AdaptiveRingPushSplit(AdaptiveRing *r, const float *l, const float *rc, uint32_t frames, double now) {
    noteChunk(r, frames);
    uint64_t w = atomic_load_explicit(&r->w, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&r->r, memory_order_acquire);
    uint32_t space = RING_CAP - (uint32_t)(w - rd);
    uint32_t n = frames < space ? frames : space;
    for (uint32_t i = 0; i < n; i++) {
        size_t k = ((w + i) & (RING_CAP - 1)) * 2;
        r->ring[k] = l[i];
        r->ring[k + 1] = rc[i];
    }
    if (n < frames && atomic_load_explicit(&r->consumerActive, memory_order_relaxed))
        atomic_fetch_add_explicit(&r->pushDropped, frames - n, memory_order_relaxed);
    atomic_store_explicit(&r->w, w + n, memory_order_release);
    publishPush(r, w + n, now);
    return n;
}

// Move up to `want` frames from the ring into the history buffer.
static void refill(AdaptiveRing *r, uint32_t want) {
    uint64_t rd = atomic_load_explicit(&r->r, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->w, memory_order_acquire);
    uint32_t avail = (uint32_t)(w - rd);
    uint32_t room = HIST_CAP - r->histLen;
    uint32_t n = want < avail ? want : avail;
    if (n > room) n = room;
    for (uint32_t i = 0; i < n; i++) {
        size_t k = ((rd + i) & (RING_CAP - 1)) * 2;
        r->hL[r->histLen + i] = r->ring[k];
        r->hR[r->histLen + i] = r->ring[k + 1];
    }
    r->histLen += n;
    atomic_store_explicit(&r->r, rd + n, memory_order_release);
}

bool AdaptiveRingPull(AdaptiveRing *r, float *outL, float *outR, uint32_t frames, double now) {
    double dt = (double)frames / r->outRate;
    atomic_store_explicit(&r->consumerActive, true, memory_order_relaxed);
    uint32_t chunk = atomic_load_explicit(&r->pushChunk, memory_order_relaxed);
    if (chunk < 64) chunk = 64;
    // Virtual fill must cover this pull plus one whole producer chunk (the actual
    // fill is up to a chunk lower just before a push), the taps and some jitter.
    r->target = frames * r->nominalStep + chunk + HALF + 1 + MARGIN_S * r->inRate;

    uint64_t rd = atomic_load_explicit(&r->r, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->w, memory_order_acquire);
    double avail = (double)(w - rd);
    double unread = (double)r->histLen - r->pos;
    double buffered = avail + unread;                                         // actual
    double vbuffered = virtualWritePos(r, now, chunk) - (double)rd + unread;  // smooth estimate

    if (!r->primed) {
        if (vbuffered < r->target) {
            memset(outL, 0, frames * sizeof(float));
            memset(outR, 0, frames * sizeof(float));
            r->statRunning = false;
            r->statFill = buffered;
            r->statTarget = r->target;
            return false;
        }
        // Start exactly on target: discard any excess that arrived while priming.
        if (vbuffered > r->target) {
            uint32_t drop = (uint32_t)fmin(avail, vbuffered - r->target);
            rd += drop; avail -= drop; buffered -= drop; vbuffered -= drop;
            atomic_store_explicit(&r->r, rd, memory_order_release);
        }
        r->primed = true;
        r->filtFill = r->filt1 = vbuffered;
        r->integ = 0;
    }

    // Overfill (e.g. the consumer stalled): drop the oldest ring frames back to target.
    double limit = r->target + 2.0 * chunk + 4096.0;
    if (buffered > limit) {
        uint32_t drop = (uint32_t)fmin(avail, buffered - r->target);
        atomic_store_explicit(&r->r, rd + drop, memory_order_release);
        atomic_fetch_add_explicit(&r->pullDropped, drop, memory_order_relaxed);
        buffered -= drop;
        vbuffered -= drop;
        r->filtFill = r->filt1 = vbuffered;
    }

    // PI controller: read faster when too full, slower when too empty.
    // Two cascaded one-pole filters: removes timing jitter from the fill
    // estimate before it reaches the rate (jitter there would be heard as FM).
    double alpha = dt / (FILL_TAU + dt);
    r->filt1 += alpha * (vbuffered - r->filt1);
    r->filtFill += alpha * (r->filt1 - r->filtFill);
    double err = (r->filtFill - r->target) / r->inRate;     // seconds
    double integ = r->integ + err * dt;
    double corr = KP * err + KI * integ;
    if (corr > MAX_CORR) corr = MAX_CORR;                 // saturated: hold the integral (anti-windup)
    else if (corr < -MAX_CORR) corr = -MAX_CORR;
    else r->integ = integ;
    r->corr = corr;
    double step = r->nominalStep * (1.0 + corr);

    // Make sure the history covers every tap this pull needs.
    uint32_t need = (uint32_t)floor(r->pos + (frames - 1) * step) + HALF + 1;
    if (need > HIST_CAP) need = HIST_CAP;
    if (r->histLen < need) refill(r, need - r->histLen + (uint32_t)(chunk));
    if (r->histLen < need) {
        memset(outL, 0, frames * sizeof(float));
        memset(outR, 0, frames * sizeof(float));
        atomic_fetch_add_explicit(&r->underruns, 1, memory_order_relaxed);
        resetConsumer(r);
        r->statRunning = false;
        return false;
    }

    double pos = r->pos;
    for (uint32_t i = 0; i < frames; i++) {
        int ip = (int)pos;
        double phase = (pos - ip) * PHASES;
        int ph = (int)phase;
        float pf = (float)(phase - ph);
        const float *k0 = r->kernel[ph], *k1 = r->kernel[ph + 1];
        const float *xl = &r->hL[ip - (HALF - 1)], *xr = &r->hR[ip - (HALF - 1)];
        float al = 0, ar = 0;
        for (int k = 0; k < TAPS; k++) {
            float c = k0[k] + pf * (k1[k] - k0[k]);
            al += c * xl[k];
            ar += c * xr[k];
        }
        outL[i] = al;
        outR[i] = ar;
        pos += step;
    }

    // Discard history that no future tap will need.
    int shift = (int)pos - (HALF - 1);
    if (shift > 0) {
        uint32_t keep = r->histLen - (uint32_t)shift;
        memmove(r->hL, r->hL + shift, keep * sizeof(float));
        memmove(r->hR, r->hR + shift, keep * sizeof(float));
        r->histLen = keep;
        pos -= shift;
    }
    r->pos = pos;

    r->statFill = r->filtFill;
    r->statTarget = r->target;
    r->statCorr = corr;
    r->statRunning = true;
    return true;
}

void AdaptiveRingGetStats(AdaptiveRing *r, AdaptiveRingStats *s) {
    s->underruns = atomic_load(&r->underruns);
    s->droppedFrames = atomic_load(&r->pullDropped) + atomic_load(&r->pushDropped);
    s->ratioPPM = r->statCorr * 1e6;
    s->fillFrames = r->statFill;
    s->targetFrames = r->statTarget;
    s->running = r->statRunning;
}
