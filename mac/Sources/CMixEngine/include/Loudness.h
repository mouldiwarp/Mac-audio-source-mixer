// Loudness measurement per ITU-R BS.1770 (spec/features/plugins-and-balance.md §2).
#ifndef LOUDNESS_H
#define LOUDNESS_H

#include <stdatomic.h>
#include <stdint.h>

#define LOUD_BLOCK_FRAMES 4800    // 100 ms at 48 kHz
#define LOUD_RING_BLOCKS 600      // 60 s history

typedef struct {
    double z[2][2][2];            // [stage][channel][state]
    double acc;                   // K-weighted sum of squares (both channels) in the current block
    uint32_t n;
    float ring[LOUD_RING_BLOCKS]; // mean square per 100 ms block
    _Atomic uint64_t blocks;      // blocks completed so far
} LoudnessMeter;

void LoudnessReset(LoudnessMeter *m);
// Audio thread, 48 kHz stereo.
void LoudnessProcess(LoudnessMeter *m, const float *l, const float *r, uint32_t n);
// Control thread: copies up to max of the newest blocks (oldest first); returns
// the count. *total receives the number of blocks completed so far.
uint32_t LoudnessBlocks(LoudnessMeter *m, float *out, uint32_t max, uint64_t since, uint64_t *total);
// Gated integrated loudness (LUFS) of consecutive 100 ms mean-square blocks.
// Returns -INFINITY if nothing passes the absolute gate.
double LoudnessIntegrated(const float *blockMS, uint32_t n);

#endif
