// See include/StereoRing.h.
#include "StereoRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct StereoRing {
    uint32_t cap;                 // power of two
    float *l, *r;
    _Atomic uint64_t w, rd;       // monotonically increasing frame counters
    _Atomic uint64_t dropped;
    _Atomic bool paused, flush;
};

StereoRing *StereoRingCreate(uint32_t want) {
    StereoRing *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    uint32_t cap = 1024;
    while (cap < want && cap < (1u << 28)) cap <<= 1;
    r->cap = cap;
    r->l = calloc(cap, sizeof(float));
    r->r = calloc(cap, sizeof(float));
    if (!r->l || !r->r) { StereoRingDestroy(r); return NULL; }
    return r;
}

void StereoRingDestroy(StereoRing *r) {
    if (!r) return;
    free(r->l); free(r->r); free(r);
}

uint32_t StereoRingAvailable(StereoRing *r) {
    return (uint32_t)(atomic_load_explicit(&r->w, memory_order_acquire) - atomic_load_explicit(&r->rd, memory_order_acquire));
}
uint32_t StereoRingSpace(StereoRing *r) { return r->cap - StereoRingAvailable(r); }
uint64_t StereoRingDropped(StereoRing *r) { return atomic_load_explicit(&r->dropped, memory_order_relaxed); }

uint32_t StereoRingWrite(StereoRing *r, const float *l, const float *rr, uint32_t n) {
    uint64_t w = atomic_load_explicit(&r->w, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&r->rd, memory_order_acquire);
    uint32_t space = r->cap - (uint32_t)(w - rd);
    uint32_t m = n < space ? n : space;
    uint32_t mask = r->cap - 1;
    for (uint32_t i = 0; i < m; i++) {
        uint32_t k = (uint32_t)(w + i) & mask;
        r->l[k] = l[i]; r->r[k] = rr[i];
    }
    atomic_store_explicit(&r->w, w + m, memory_order_release);
    if (m < n) atomic_fetch_add_explicit(&r->dropped, n - m, memory_order_relaxed);
    return m;
}

uint32_t StereoRingRead(StereoRing *r, float *l, float *rr, uint32_t n) {
    uint64_t rd = atomic_load_explicit(&r->rd, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->w, memory_order_acquire);
    uint32_t avail = (uint32_t)(w - rd);
    uint32_t m = n < avail ? n : avail;
    uint32_t mask = r->cap - 1;
    for (uint32_t i = 0; i < m; i++) {
        uint32_t k = (uint32_t)(rd + i) & mask;
        l[i] = r->l[k]; rr[i] = r->r[k];
    }
    atomic_store_explicit(&r->rd, rd + m, memory_order_release);
    return m;
}

void StereoRingTrim(StereoRing *r, uint32_t keep) {
    uint64_t rd = atomic_load_explicit(&r->rd, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->w, memory_order_acquire);
    if (w - rd > keep) atomic_store_explicit(&r->rd, w - keep, memory_order_release);
}

uint64_t StereoRingWriteCount(StereoRing *r) { return atomic_load_explicit(&r->w, memory_order_acquire); }

void StereoRingTrimTo(StereoRing *r, uint64_t index) {
    uint64_t rd = atomic_load_explicit(&r->rd, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->w, memory_order_acquire);
    if (index > w) index = w;
    if (index > rd) atomic_store_explicit(&r->rd, index, memory_order_release);
}

void StereoRingSetPaused(StereoRing *r, bool p) { atomic_store(&r->paused, p); }
bool StereoRingPaused(StereoRing *r) { return atomic_load(&r->paused); }
void StereoRingRequestFlush(StereoRing *r) { atomic_store(&r->flush, true); }
bool StereoRingFlushPending(StereoRing *r) { return atomic_load(&r->flush); }

uint32_t StereoRingPull(StereoRing *r, float *l, float *rr, uint32_t n) {
    if (atomic_load_explicit(&r->flush, memory_order_acquire)) {
        atomic_store_explicit(&r->rd, atomic_load_explicit(&r->w, memory_order_acquire), memory_order_release);
        atomic_store_explicit(&r->flush, false, memory_order_release);
    }
    uint32_t got = 0;
    if (!atomic_load_explicit(&r->paused, memory_order_relaxed)) got = StereoRingRead(r, l, rr, n);
    if (got < n) { memset(l + got, 0, (n - got) * sizeof(float)); memset(rr + got, 0, (n - got) * sizeof(float)); }
    return got;
}
