// Mixer implementation. See include/Mixer.h and spec/features/mixer.md.

#include "Mixer.h"
#include "AdaptiveRing.h"
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAXF        4096u
#define MIX_RATE    48000.0
#define FEED_CH     6

static double gTicksToSec = 0;

static double hostSeconds(UInt64 ticks) { return (double)ticks * gTicksToSec; }
static double nowSeconds(void) { return hostSeconds(mach_absolute_time()); }

static void setErr(char *err, size_t n, const char *fmt, OSStatus st) {
    if (err && n) snprintf(err, n, fmt, (int)st);
}

static float dbToLin(float dB) { return dB <= -60.0f ? 0.0f : powf(10.0f, dB / 20.0f); }

// ---- Device helpers -------------------------------------------------------------

static double deviceRate(AudioObjectID dev) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 r = 0; UInt32 sz = sizeof r;
    AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &r);
    return r;
}

static void setBufferFrames(AudioObjectID dev, UInt32 frames) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof frames, &frames);
}

typedef struct { int buf; int off; int stride; } ChanLoc;

// Finds where 1-based channel `ch` lives in the device's IOProc buffer list for
// `scope`, and checks that every stream carries 32-bit float samples.
static OSStatus locateChannel(AudioObjectID dev, AudioObjectPropertyScope scope, UInt32 ch, ChanLoc *out,
                              char *err, size_t errLen) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    OSStatus st = AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &sz);
    if (st || sz == 0) { setErr(err, errLen, "device has no streams in this direction (%d)", st); return st ? st : -1; }
    AudioBufferList *abl = malloc(sz);
    st = AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, abl);
    if (st) { free(abl); setErr(err, errLen, "read stream configuration failed (%d)", st); return st; }
    UInt32 base = 0;
    bool found = false;
    for (UInt32 b = 0; b < abl->mNumberBuffers; b++) {
        UInt32 n = abl->mBuffers[b].mNumberChannels;
        if (ch >= base + 1 && ch <= base + n) {
            out->buf = (int)b; out->off = (int)(ch - base - 1); out->stride = (int)n;
            found = true;
            break;
        }
        base += n;
    }
    free(abl);
    if (!found) { setErr(err, errLen, "channel out of range (%d)", (OSStatus)ch); return -1; }

    // Format check on the streams of this scope.
    AudioObjectPropertyAddress sa = { kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyDataSize(dev, &sa, 0, NULL, &sz) == noErr && sz > 0) {
        UInt32 count = sz / sizeof(AudioObjectID);
        AudioObjectID *streams = malloc(sz);
        AudioObjectGetPropertyData(dev, &sa, 0, NULL, &sz, streams);
        for (UInt32 i = 0; i < count; i++) {
            AudioObjectPropertyAddress fa = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            AudioStreamBasicDescription f; UInt32 fs = sizeof f;
            if (AudioObjectGetPropertyData(streams[i], &fa, 0, NULL, &fs, &f) == noErr) {
                if (f.mFormatID != kAudioFormatLinearPCM || !(f.mFormatFlags & kAudioFormatFlagIsFloat) || f.mBitsPerChannel != 32) {
                    free(streams);
                    setErr(err, errLen, "device stream is not 32-bit float (%d)", -1);
                    return -1;
                }
            }
        }
        free(streams);
    }
    return noErr;
}

// ---- Sources (strip inputs) -----------------------------------------------------

typedef enum { SRC_DEVICE, SRC_TONE } SourceKind;

typedef struct Source {
    SourceKind kind;
    AudioObjectID dev;
    AudioDeviceIOProcID proc;
    ChanLoc a, b;
    double rate;
    AdaptiveRing *ring;
    double phase, inc;            // tone
    float sl[MAXF], sr[MAXF];     // producer scratch
} Source;

static OSStatus sourceIOProc(AudioObjectID dev, const AudioTimeStamp *inNow, const AudioBufferList *in,
                             const AudioTimeStamp *inTime, AudioBufferList *out, const AudioTimeStamp *outTime,
                             void *ctx) {
    (void)dev; (void)out; (void)outTime;
    Source *s = ctx;
    if (!in || (UInt32)s->a.buf >= in->mNumberBuffers || (UInt32)s->b.buf >= in->mNumberBuffers) return noErr;
    const AudioBuffer *ba = &in->mBuffers[s->a.buf], *bb = &in->mBuffers[s->b.buf];
    if (!ba->mData || !bb->mData) return noErr;
    UInt32 frames = ba->mDataByteSize / (4u * (UInt32)s->a.stride);
    if (frames > MAXF) frames = MAXF;
    const float *pa = ba->mData, *pb = bb->mData;
    for (UInt32 i = 0; i < frames; i++) {
        s->sl[i] = pa[i * s->a.stride + s->a.off];
        s->sr[i] = pb[i * s->b.stride + s->b.off];
    }
    // Stamp = when these frames became available (this callback), which is what
    // the ring's fill estimate extrapolates from.
    (void)inTime;
    AdaptiveRingPushSplit(s->ring, s->sl, s->sr, frames, hostSeconds(inNow->mHostTime));
    return noErr;
}

static void sourceDestroy(Source *s) {
    if (!s) return;
    if (s->kind == SRC_DEVICE && s->proc) {
        AudioDeviceStop(s->dev, s->proc);
        AudioDeviceDestroyIOProcID(s->dev, s->proc);
    }
    if (s->ring) AdaptiveRingDestroy(s->ring);
    free(s);
}

// ---- Sinks (A-bus outputs) -----------------------------------------------------

typedef struct Sink {
    AudioObjectID dev;
    AudioDeviceIOProcID proc;
    ChanLoc a, b;
    double rate;
    AdaptiveRing *ring;           // 48 kHz mix -> device rate
    float sl[MAXF], sr[MAXF];
} Sink;

static OSStatus sinkIOProc(AudioObjectID dev, const AudioTimeStamp *inNow, const AudioBufferList *in,
                           const AudioTimeStamp *inTime, AudioBufferList *out, const AudioTimeStamp *outTime,
                           void *ctx) {
    (void)dev; (void)in; (void)inTime; (void)outTime;
    Sink *k = ctx;
    if (!out || (UInt32)k->a.buf >= out->mNumberBuffers || (UInt32)k->b.buf >= out->mNumberBuffers) return noErr;
    AudioBuffer *ba = &out->mBuffers[k->a.buf], *bb = &out->mBuffers[k->b.buf];
    if (!ba->mData || !bb->mData) return noErr;
    UInt32 frames = ba->mDataByteSize / (4u * (UInt32)k->a.stride);
    if (frames > MAXF) return noErr;
    AdaptiveRingPull(k->ring, k->sl, k->sr, frames, hostSeconds(inNow->mHostTime));
    float *pa = ba->mData, *pb = bb->mData;
    for (UInt32 i = 0; i < frames; i++) {
        pa[i * k->a.stride + k->a.off] += k->sl[i];
        pb[i * k->b.stride + k->b.off] += k->sr[i];
    }
    return noErr;
}

static void sinkDestroy(Sink *k) {
    if (!k) return;
    if (k->proc) {
        AudioDeviceStop(k->dev, k->proc);
        AudioDeviceDestroyIOProcID(k->dev, k->proc);
    }
    if (k->ring) AdaptiveRingDestroy(k->ring);
    free(k);
}

// ---- Mixer ----------------------------------------------------------------------

typedef struct {
    _Atomic(Source *) src;
    _Atomic float gainDB, pan;
    _Atomic bool mono, mute, solo;
    _Atomic uint32_t assign;      // bit per bus
    FxChain *fx;
    // real-time state
    float curG, curPL, curPR;
    // stats
    _Atomic uint32_t peakL, peakR; // float bits
} Strip;

typedef struct {
    _Atomic float gainDB;
    _Atomic bool mute;
    _Atomic(Sink *) sink;         // A buses only
    FxChain *fx;
    float curGain;
    _Atomic uint32_t peakL, peakR;
} Bus;

struct Mixer {
    AudioObjectID feed;
    AudioDeviceIOProcID proc;
    uint32_t bufferFrames;
    bool started;
    Strip strip[MIXER_MAX_STRIPS];
    Bus bus[MIXER_NUM_BUSES];
    float acc[MIXER_NUM_BUSES][2][MAXF];
    float sl[MAXF], sr[MAXF];
    _Atomic uint64_t cycles;
    _Atomic uint32_t lastFrames;
    volatile double load;
};

static void peakStore(_Atomic uint32_t *slot, float v) {
    uint32_t cur = atomic_load_explicit(slot, memory_order_relaxed);
    float f; memcpy(&f, &cur, 4);
    if (v > f) { memcpy(&cur, &v, 4); atomic_store_explicit(slot, cur, memory_order_relaxed); }
}
static float peakTake(_Atomic uint32_t *slot) {
    uint32_t v = atomic_exchange(slot, 0);
    float f; memcpy(&f, &v, 4);
    return f;
}

static inline float softClip(float x) {
    const float t = 0.8f;
    float ax = fabsf(x);
    if (ax <= t) return x;
    float y = t + (1.0f - t) * tanhf((ax - t) / (1.0f - t));
    return x < 0 ? -y : y;
}

static void panGains(float pan, float *gl, float *gr) {
    // Constant-power law, compensated to unity at centre and capped at unity.
    double th = (pan + 1.0) * M_PI / 4.0;
    *gl = (float)fmin(1.0, M_SQRT2 * cos(th));
    *gr = (float)fmin(1.0, M_SQRT2 * sin(th));
}

static OSStatus masterIOProc(AudioObjectID dev, const AudioTimeStamp *inNow, const AudioBufferList *in,
                             const AudioTimeStamp *inTime, AudioBufferList *out, const AudioTimeStamp *outTime,
                             void *ctx) {
    (void)dev; (void)in; (void)inTime; (void)outTime;
    Mixer *m = ctx;
    UInt64 t0 = mach_absolute_time();
    if (!out || out->mNumberBuffers < 1 || out->mBuffers[0].mNumberChannels != FEED_CH) return noErr;
    float *feed = out->mBuffers[0].mData;
    UInt32 frames = out->mBuffers[0].mDataByteSize / (4u * FEED_CH);
    if (frames > MAXF || !feed) return noErr;
    double now = hostSeconds(inNow->mHostTime);
    float inv = 1.0f / (float)frames;

    for (int b = 0; b < MIXER_NUM_BUSES; b++) {
        memset(m->acc[b][0], 0, frames * sizeof(float));
        memset(m->acc[b][1], 0, frames * sizeof(float));
    }
    bool anySolo = false;
    for (int s = 0; s < MIXER_MAX_STRIPS; s++)
        if (atomic_load_explicit(&m->strip[s].solo, memory_order_relaxed) &&
            atomic_load_explicit(&m->strip[s].src, memory_order_relaxed)) anySolo = true;

    for (int s = 0; s < MIXER_MAX_STRIPS; s++) {
        Strip *st = &m->strip[s];
        Source *src = atomic_load_explicit(&st->src, memory_order_acquire);
        if (!src) continue;
        if (src->kind == SRC_TONE) {
            for (UInt32 i = 0; i < frames; i++) {
                float v = (float)(0.25 * sin(src->phase));
                m->sl[i] = v; m->sr[i] = v;
                src->phase += src->inc;
                if (src->phase > 2 * M_PI) src->phase -= 2 * M_PI;
            }
        } else {
            AdaptiveRingPull(src->ring, m->sl, m->sr, frames, now);
        }
        if (atomic_load_explicit(&st->mono, memory_order_relaxed))
            for (UInt32 i = 0; i < frames; i++) m->sl[i] = m->sr[i] = 0.5f * (m->sl[i] + m->sr[i]);

        // source -> mono -> voice chain -> fader -> limiter -> pan (spec/features/voice-dsp.md)
        FxChainProcessPre(st->fx, m->sl, m->sr, frames);
        bool silent = atomic_load_explicit(&st->mute, memory_order_relaxed) ||
                      (anySolo && !atomic_load_explicit(&st->solo, memory_order_relaxed));
        float tg = silent ? 0.0f : dbToLin(atomic_load_explicit(&st->gainDB, memory_order_relaxed));
        float dg = (tg - st->curG) * inv, g = st->curG;     // ramp over this cycle
        for (UInt32 i = 0; i < frames; i++) { g += dg; m->sl[i] *= g; m->sr[i] *= g; }
        st->curG = tg;
        FxChainProcessPost(st->fx, m->sl, m->sr, frames);
        float tl, tr;
        panGains(atomic_load_explicit(&st->pan, memory_order_relaxed), &tl, &tr);
        float dl = (tl - st->curPL) * inv, dr = (tr - st->curPR) * inv;
        float gl = st->curPL, gr = st->curPR, mxl = 0, mxr = 0;
        for (UInt32 i = 0; i < frames; i++) {
            gl += dl; gr += dr;
            m->sl[i] *= gl; m->sr[i] *= gr;
            float al = fabsf(m->sl[i]), ar = fabsf(m->sr[i]);
            if (al > mxl) mxl = al;
            if (ar > mxr) mxr = ar;
        }
        st->curPL = tl; st->curPR = tr;
        peakStore(&st->peakL, mxl);
        peakStore(&st->peakR, mxr);

        uint32_t assign = atomic_load_explicit(&st->assign, memory_order_relaxed);
        for (int b = 0; b < MIXER_NUM_BUSES; b++) {
            if (!(assign & (1u << b))) continue;
            float *al = m->acc[b][0], *ar = m->acc[b][1];
            for (UInt32 i = 0; i < frames; i++) { al[i] += m->sl[i]; ar[i] += m->sr[i]; }
        }
    }

    for (int b = 0; b < MIXER_NUM_BUSES; b++) {
        Bus *bs = &m->bus[b];
        float target = atomic_load_explicit(&bs->mute, memory_order_relaxed) ? 0.0f
                     : dbToLin(atomic_load_explicit(&bs->gainDB, memory_order_relaxed));
        float g = bs->curGain, dg = (target - g) * inv, mxl = 0, mxr = 0;
        float *al = m->acc[b][0], *ar = m->acc[b][1];
        // bus sum -> EQ -> gain -> limiter -> mode -> soft clip
        FxChainProcessPre(bs->fx, al, ar, frames);
        for (UInt32 i = 0; i < frames; i++) { g += dg; al[i] *= g; ar[i] *= g; }
        FxChainProcessPost(bs->fx, al, ar, frames);
        for (UInt32 i = 0; i < frames; i++) {
            al[i] = softClip(al[i]);
            ar[i] = softClip(ar[i]);
            float x = fabsf(al[i]), y = fabsf(ar[i]);
            if (x > mxl) mxl = x;
            if (y > mxr) mxr = y;
        }
        bs->curGain = target;
        peakStore(&bs->peakL, mxl);
        peakStore(&bs->peakR, mxr);

        if (b >= MIXER_BUS_B1) {
            int c = (b - MIXER_BUS_B1) * 2;
            for (UInt32 i = 0; i < frames; i++) {
                feed[i * FEED_CH + c] = al[i];
                feed[i * FEED_CH + c + 1] = ar[i];
            }
        } else {
            Sink *k = atomic_load_explicit(&bs->sink, memory_order_acquire);
            if (k) AdaptiveRingPushSplit(k->ring, al, ar, frames, now);
        }
    }

    atomic_store_explicit(&m->lastFrames, frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&m->cycles, 1, memory_order_release);
    double spent = hostSeconds(mach_absolute_time() - t0);
    m->load = 0.95 * m->load + 0.05 * (spent / (frames / MIX_RATE));
    return noErr;
}

// Waits until the master callback has finished any cycle that might still be
// using an object that was just unpublished.
static void waitForCycle(Mixer *m) {
    if (!m->started) return;
    uint64_t c0 = atomic_load(&m->cycles);
    for (int i = 0; i < 200 && atomic_load(&m->cycles) < c0 + 2; i++) usleep(1000);
}

static void MixerFreeChains(Mixer *m) {
    for (int s = 0; s < MIXER_MAX_STRIPS; s++) { FxChainDestroy(m->strip[s].fx); m->strip[s].fx = NULL; }
    for (int b = 0; b < MIXER_NUM_BUSES; b++) { FxChainDestroy(m->bus[b].fx); m->bus[b].fx = NULL; }
}

Mixer *MixerCreate(AudioObjectID feed, uint32_t bufferFrames, char *err, size_t errLen) {
    if (gTicksToSec == 0) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        gTicksToSec = (double)tb.numer / (double)tb.denom * 1e-9;
    }
    Mixer *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->feed = feed;
    m->bufferFrames = bufferFrames ? bufferFrames : 256;
    for (int s = 0; s < MIXER_MAX_STRIPS; s++) {
        atomic_init(&m->strip[s].gainDB, 0.0f);
        atomic_init(&m->strip[s].pan, 0.0f);
        atomic_init(&m->strip[s].assign, 1u << MIXER_BUS_B1);
        m->strip[s].fx = FxChainCreate(MIX_RATE);
        m->strip[s].curPL = m->strip[s].curPR = 1.0f;
    }
    for (int b = 0; b < MIXER_NUM_BUSES; b++) {
        atomic_init(&m->bus[b].gainDB, 0.0f);
        m->bus[b].curGain = 1.0f;
        m->bus[b].fx = FxChainCreate(MIX_RATE);
    }
    for (int s = 0; s < MIXER_MAX_STRIPS; s++) if (!m->strip[s].fx) { setErr(err, errLen, "out of memory (%d)", -1); MixerFreeChains(m); free(m); return NULL; }
    for (int b = 0; b < MIXER_NUM_BUSES; b++) if (!m->bus[b].fx) { setErr(err, errLen, "out of memory (%d)", -1); MixerFreeChains(m); free(m); return NULL; }

    if (deviceRate(feed) != MIX_RATE) { setErr(err, errLen, "feed device is not at 48 kHz (%d)", -1); MixerFreeChains(m); free(m); return NULL; }
    setBufferFrames(feed, m->bufferFrames);
    OSStatus st = AudioDeviceCreateIOProcID(feed, masterIOProc, m, &m->proc);
    if (st) { setErr(err, errLen, "create feed IOProc failed (%d)", st); MixerFreeChains(m); free(m); return NULL; }
    return m;
}

OSStatus MixerStart(Mixer *m) {
    OSStatus st = AudioDeviceStart(m->feed, m->proc);
    if (st == noErr) m->started = true;
    return st;
}

void MixerStop(Mixer *m) {
    if (m->started) AudioDeviceStop(m->feed, m->proc);
    m->started = false;
}

void MixerDestroy(Mixer *m) {
    if (!m) return;
    MixerStop(m);
    AudioDeviceDestroyIOProcID(m->feed, m->proc);
    for (int s = 0; s < MIXER_MAX_STRIPS; s++) sourceDestroy(atomic_exchange(&m->strip[s].src, NULL));
    for (int b = 0; b < MIXER_NUM_HW_BUSES; b++) sinkDestroy(atomic_exchange(&m->bus[b].sink, NULL));
    MixerFreeChains(m);
    free(m);
}

static bool validStrip(int s) { return s >= 0 && s < MIXER_MAX_STRIPS; }
static bool validBus(int b) { return b >= 0 && b < MIXER_NUM_BUSES; }

void MixerStripDetach(Mixer *m, int s) {
    if (!validStrip(s)) return;
    Source *old = atomic_exchange(&m->strip[s].src, NULL);
    if (!old) return;
    waitForCycle(m);
    sourceDestroy(old);
}

OSStatus MixerStripAttachDevice(Mixer *m, int s, AudioObjectID dev, uint32_t chA, uint32_t chB, char *err, size_t errLen) {
    if (!validStrip(s)) { setErr(err, errLen, "bad strip index (%d)", s); return -1; }
    Source *src = calloc(1, sizeof *src);
    if (!src) return -1;
    src->kind = SRC_DEVICE;
    src->dev = dev;
    src->rate = deviceRate(dev);
    OSStatus st;
    if (src->rate <= 0) { free(src); setErr(err, errLen, "cannot read device sample rate (%d)", -1); return -1; }
    if ((st = locateChannel(dev, kAudioObjectPropertyScopeInput, chA, &src->a, err, errLen)) ||
        (st = locateChannel(dev, kAudioObjectPropertyScopeInput, chB, &src->b, err, errLen))) { free(src); return st; }
    src->ring = AdaptiveRingCreate(src->rate, MIX_RATE);
    setBufferFrames(dev, m->bufferFrames);
    if ((st = AudioDeviceCreateIOProcID(dev, sourceIOProc, src, &src->proc))) {
        sourceDestroy(src); setErr(err, errLen, "create input IOProc failed (%d)", st); return st;
    }
    if ((st = AudioDeviceStart(dev, src->proc))) {
        sourceDestroy(src); setErr(err, errLen, "start input device failed (%d)", st); return st;
    }
    MixerStripDetach(m, s);
    atomic_store_explicit(&m->strip[s].src, src, memory_order_release);
    return noErr;
}

void MixerStripAttachTone(Mixer *m, int s, double hz) {
    if (!validStrip(s)) return;
    Source *src = calloc(1, sizeof *src);
    if (!src) return;
    src->kind = SRC_TONE;
    src->inc = 2 * M_PI * hz / MIX_RATE;
    MixerStripDetach(m, s);
    atomic_store_explicit(&m->strip[s].src, src, memory_order_release);
}

void MixerStripSetGainDB(Mixer *m, int s, float dB) { if (validStrip(s)) atomic_store(&m->strip[s].gainDB, fmaxf(-60.0f, fminf(12.0f, dB))); }
void MixerStripSetPan(Mixer *m, int s, float p)     { if (validStrip(s)) atomic_store(&m->strip[s].pan, fmaxf(-1.0f, fminf(1.0f, p))); }
void MixerStripSetMono(Mixer *m, int s, bool on)    { if (validStrip(s)) atomic_store(&m->strip[s].mono, on); }
void MixerStripSetMute(Mixer *m, int s, bool on)    { if (validStrip(s)) atomic_store(&m->strip[s].mute, on); }
void MixerStripSetSolo(Mixer *m, int s, bool on)    { if (validStrip(s)) atomic_store(&m->strip[s].solo, on); }
void MixerStripSetAssign(Mixer *m, int s, int b, bool on) {
    if (!validStrip(s) || !validBus(b)) return;
    if (on) atomic_fetch_or(&m->strip[s].assign, 1u << b);
    else atomic_fetch_and(&m->strip[s].assign, ~(1u << b));
}
void MixerStripSetFx(Mixer *m, int s, const FxParams *p) { if (validStrip(s) && p) FxChainSetParams(m->strip[s].fx, p); }
void MixerBusSetFx(Mixer *m, int b, const FxParams *p) {
    if (!validBus(b) || !p) return;
    FxParams q = *p;   // buses use EQ, limiter and mode only
    q.denoise.on = q.gate.on = q.eq3.on = q.comp.on = false;
    FxChainSetParams(m->bus[b].fx, &q);
}
void MixerBusSetGainDB(Mixer *m, int b, float dB) { if (validBus(b)) atomic_store(&m->bus[b].gainDB, fmaxf(-60.0f, fminf(12.0f, dB))); }
void MixerBusSetMute(Mixer *m, int b, bool on)    { if (validBus(b)) atomic_store(&m->bus[b].mute, on); }

OSStatus MixerBusSetDevice(Mixer *m, int b, AudioObjectID dev, char *err, size_t errLen) {
    if (b < 0 || b >= MIXER_NUM_HW_BUSES) { setErr(err, errLen, "only A buses have a device (%d)", b); return -1; }
    Sink *old = atomic_exchange(&m->bus[b].sink, NULL);
    if (old) { waitForCycle(m); sinkDestroy(old); }
    if (dev == 0 || dev == kAudioObjectUnknown) return noErr;

    Sink *k = calloc(1, sizeof *k);
    if (!k) return -1;
    k->dev = dev;
    k->rate = deviceRate(dev);
    OSStatus st;
    if (k->rate <= 0) { free(k); setErr(err, errLen, "cannot read device sample rate (%d)", -1); return -1; }
    if ((st = locateChannel(dev, kAudioObjectPropertyScopeOutput, 1, &k->a, err, errLen)) ||
        (st = locateChannel(dev, kAudioObjectPropertyScopeOutput, 2, &k->b, err, errLen))) {
        // Mono output device: send both sides to channel 1.
        if ((st = locateChannel(dev, kAudioObjectPropertyScopeOutput, 1, &k->a, err, errLen))) { free(k); return st; }
        k->b = k->a;
    }
    k->ring = AdaptiveRingCreate(MIX_RATE, k->rate);
    setBufferFrames(dev, m->bufferFrames);
    if ((st = AudioDeviceCreateIOProcID(dev, sinkIOProc, k, &k->proc))) {
        sinkDestroy(k); setErr(err, errLen, "create output IOProc failed (%d)", st); return st;
    }
    if ((st = AudioDeviceStart(dev, k->proc))) {
        sinkDestroy(k); setErr(err, errLen, "start output device failed (%d)", st); return st;
    }
    atomic_store_explicit(&m->bus[b].sink, k, memory_order_release);
    return noErr;
}

static void ringStats(AdaptiveRing *r, MixerChannelStats *c) {
    AdaptiveRingStats s;
    AdaptiveRingGetStats(r, &s);
    c->underruns = s.underruns;
    c->droppedFrames = s.droppedFrames;
    c->ratioPPM = s.ratioPPM;
    c->running = s.running;
}

void MixerGetStats(Mixer *m, MixerStats *out) {
    memset(out, 0, sizeof *out);
    for (int s = 0; s < MIXER_MAX_STRIPS; s++) {
        MixerChannelStats *c = &out->strip[s];
        c->peakL = peakTake(&m->strip[s].peakL);
        c->peakR = peakTake(&m->strip[s].peakR);
        FxChainGetMeters(m->strip[s].fx, &c->fx);
        Source *src = atomic_load(&m->strip[s].src);
        c->attached = src != NULL;
        if (src && src->ring) ringStats(src->ring, c);
        else if (src) c->running = true;
    }
    for (int b = 0; b < MIXER_NUM_BUSES; b++) {
        MixerChannelStats *c = &out->bus[b];
        c->peakL = peakTake(&m->bus[b].peakL);
        c->peakR = peakTake(&m->bus[b].peakR);
        FxChainGetMeters(m->bus[b].fx, &c->fx);
        if (b < MIXER_NUM_HW_BUSES) {
            Sink *k = atomic_load(&m->bus[b].sink);
            c->attached = k != NULL;
            if (k) ringStats(k->ring, c);
        } else {
            c->attached = true;
            c->running = m->started;
        }
    }
    out->cycles = atomic_load(&m->cycles);
    out->bufferFrames = atomic_load(&m->lastFrames);
    out->load = m->load;
}
