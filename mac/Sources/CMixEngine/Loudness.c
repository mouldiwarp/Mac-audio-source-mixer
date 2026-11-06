// See include/Loudness.h. K-weighting coefficients for 48 kHz from ITU-R BS.1770.
#include "Loudness.h"
#include <math.h>
#include <stdatomic.h>
#include <string.h>

static const double KB[2][3] = { { 1.53512485958697, -2.69169618940638, 1.19839281085285 }, { 1.0, -2.0, 1.0 } };
static const double KA[2][2] = { { -1.69065929318241, 0.73248077421585 }, { -1.99004745483398, 0.99007225036621 } };

void LoudnessReset(LoudnessMeter *m) {
    memset(m->z, 0, sizeof m->z);
    m->acc = 0; m->n = 0;
}

static inline double kstage(double x, int s, double *z) {
    double y = KB[s][0] * x + z[0];
    z[0] = KB[s][1] * x - KA[s][0] * y + z[1];
    z[1] = KB[s][2] * x - KA[s][1] * y;
    return y;
}

void LoudnessProcess(LoudnessMeter *m, const float *l, const float *r, uint32_t n) {
    const float *ch[2] = { l, r };
    for (uint32_t i = 0; i < n; i++) {
        double sum = 0;
        for (int c = 0; c < 2; c++) {
            double y = kstage(kstage(ch[c][i], 0, m->z[0][c]), 1, m->z[1][c]);
            sum += y * y;
        }
        m->acc += sum;
        if (++m->n == LOUD_BLOCK_FRAMES) {
            uint64_t b = atomic_load_explicit(&m->blocks, memory_order_relaxed);
            m->ring[b % LOUD_RING_BLOCKS] = (float)(m->acc / LOUD_BLOCK_FRAMES);
            atomic_store_explicit(&m->blocks, b + 1, memory_order_release);
            m->acc = 0; m->n = 0;
            for (int s = 0; s < 2; s++) for (int c = 0; c < 2; c++)
                for (int k = 0; k < 2; k++) if (fabs(m->z[s][c][k]) < 1e-25) m->z[s][c][k] = 0;
        }
    }
}

uint32_t LoudnessBlocks(LoudnessMeter *m, float *out, uint32_t max, uint64_t since, uint64_t *total) {
    uint64_t t = atomic_load_explicit(&m->blocks, memory_order_acquire);
    if (total) *total = t;
    uint64_t first = since < t ? since : t;
    if (t - first > LOUD_RING_BLOCKS - 1) first = t - (LOUD_RING_BLOCKS - 1);   // keep clear of the block being written
    if (t - first > max) first = t - max;
    uint32_t n = (uint32_t)(t - first);
    for (uint32_t i = 0; i < n; i++) out[i] = m->ring[(first + i) % LOUD_RING_BLOCKS];
    return n;
}

double LoudnessIntegrated(const float *ms, uint32_t n) {
    if (n < 4) return -INFINITY;
    // 400 ms gating blocks with 75 % overlap = 4 consecutive 100 ms blocks.
    uint32_t g = n - 3;
    double sumAbs = 0; uint32_t cntAbs = 0;
    const double absMS = pow(10.0, (-70.0 + 0.691) / 10.0);
    for (uint32_t i = 0; i < g; i++) {
        double z = (ms[i] + ms[i + 1] + ms[i + 2] + ms[i + 3]) / 4.0;
        if (z > absMS) { sumAbs += z; cntAbs++; }
    }
    if (cntAbs == 0) return -INFINITY;
    double relMS = (sumAbs / cntAbs) * pow(10.0, -10.0 / 10.0);
    double sum = 0; uint32_t cnt = 0;
    for (uint32_t i = 0; i < g; i++) {
        double z = (ms[i] + ms[i + 1] + ms[i + 2] + ms[i + 3]) / 4.0;
        if (z > absMS && z > relMS) { sum += z; cnt++; }
    }
    if (cnt == 0) return -INFINITY;
    return -0.691 + 10.0 * log10(sum / cnt);
}
