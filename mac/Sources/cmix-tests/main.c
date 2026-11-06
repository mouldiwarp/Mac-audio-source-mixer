// Offline tests for the C engine. Run: swift run cmix-tests
#include "AdaptiveRing.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int failures = 0;
void runFxTests(void);
#define CHECK(c, ...) do { printf((c) ? "ok   " : "FAIL "); printf(__VA_ARGS__); printf("\n"); if (!(c)) failures++; } while (0)

// Simulates a producer and a consumer on independent clocks.
// inRate/outRate are nominal; ppm is how fast the producer's real clock runs.
// jitterMs: each callback runs up to this late (uniform random), as real IO threads do.
static double jitter(double ms) { return ms * 1e-3 * ((double)rand() / RAND_MAX); }

static void drift_case_j(const char *name, double inRate, double outRate, double ppm,
                         uint32_t inChunk, uint32_t outChunk, double seconds, double jitterMs) {
    AdaptiveRing *r = AdaptiveRingCreate(inRate, outRate);
    const double f0 = 1000.0;
    double trueInRate = inRate * (1.0 + ppm * 1e-6);
    double tIn = 0, tOut = 0;
    uint64_t nIn = 0;
    float *buf = malloc(sizeof(float) * 2 * 8192);
    float *oL = malloc(sizeof(float) * 8192), *oR = malloc(sizeof(float) * 8192);
    uint64_t warmUnder = 0, warmDrop = 0;
    // last second of output, for the quality check
    size_t capN = (size_t)outRate, capPos = 0;
    float *cap = malloc(sizeof(float) * capN);
    bool warm = false;

    while (tOut < seconds) {
        if (tIn <= tOut) {
            for (uint32_t i = 0; i < inChunk; i++) {
                float s = (float)(0.5 * sin(2 * M_PI * f0 * (double)(nIn + i) / inRate));
                buf[2 * i] = s; buf[2 * i + 1] = -s;
            }
            AdaptiveRingPush(r, buf, inChunk, tIn + jitter(jitterMs));
            nIn += inChunk;
            tIn += inChunk / trueInRate;
        } else {
            AdaptiveRingPull(r, oL, oR, outChunk, tOut + jitter(jitterMs));
            tOut += outChunk / outRate;
            if (!warm && tOut > 20.0) {
                AdaptiveRingStats s; AdaptiveRingGetStats(r, &s);
                warmUnder = s.underruns; warmDrop = s.droppedFrames; warm = true;
            }
            if (tOut > seconds - 1.0)
                for (uint32_t i = 0; i < outChunk && capPos < capN; i++) cap[capPos++] = oL[i];
        }
    }
    AdaptiveRingStats s; AdaptiveRingGetStats(r, &s);

    // Quality: least-squares sine fit over a 0.25 s window, searching the
    // frequency near the expected output frequency, then SNR of the residual.
    size_t win = (size_t)(outRate / 4);
    double fExp = f0 * (1.0 + ppm * 1e-6), bestSnr = -1e9, bestAmp = 0;
    for (double df = -0.2; df <= 0.2; df += 0.002) {
        double f = fExp + df, scc = 0, sss = 0, scs = 0, syc = 0, sys = 0;
        for (size_t i = 0; i < win; i++) {
            double ph = 2 * M_PI * f * i / outRate, c = cos(ph), sn = sin(ph);
            scc += c * c; sss += sn * sn; scs += c * sn; syc += cap[i] * c; sys += cap[i] * sn;
        }
        double det = scc * sss - scs * scs;
        double a = (syc * sss - sys * scs) / det, b = (sys * scc - syc * scs) / det;
        double sig = 0, res = 0;
        for (size_t i = 0; i < win; i++) {
            double ph = 2 * M_PI * f * i / outRate, fit = a * cos(ph) + b * sin(ph);
            sig += fit * fit; res += (cap[i] - fit) * (cap[i] - fit);
        }
        double snr = 10 * log10(sig / (res + 1e-30));
        if (snr > bestSnr) { bestSnr = snr; bestAmp = sqrt(a * a + b * b); }
    }
    double snr = bestSnr, amp = bestAmp;

    printf("-- %s: in %.0f Hz (%+.0f ppm, chunk %u) -> out %.0f Hz (chunk %u), %.0f s, jitter %.1f ms\n",
           name, inRate, ppm, inChunk, outRate, outChunk, seconds, jitterMs);
    CHECK(s.underruns - warmUnder == 0, "no underruns after warm-up (total %llu)", s.underruns);
    CHECK(s.droppedFrames - warmDrop == 0, "no drops after warm-up (total %llu)", s.droppedFrames);
    CHECK(fabs(s.ratioPPM - ppm) < 25, "controller tracks drift: %.1f ppm (expected %.0f)", s.ratioPPM, ppm);
    CHECK(fabs(s.fillFrames - s.targetFrames) < 64, "fill %.0f near target %.0f frames", s.fillFrames, s.targetFrames);
    // Without timing jitter the resampler itself must be clean (>70 dB). With
    // jitter, residual rate noise limits SNR; the real engine passes HAL buffer
    // timestamps, which follow the device clock and jitter far less than 0.5 ms.
    double minSnr = jitterMs >= 1.0 ? 55 : jitterMs > 0 ? 65 : 70;
    CHECK(snr > minSnr, "output SNR %.1f dB (pass mark %.0f)", snr, minSnr);
    CHECK(fabs(amp - 0.5) < 0.005, "amplitude %.4f (0.5 expected)", amp);
    AdaptiveRingDestroy(r);
    free(buf); free(oL); free(oR); free(cap);
}

static void drift_case(const char *name, double inRate, double outRate, double ppm,
                       uint32_t inChunk, uint32_t outChunk, double seconds) {
    drift_case_j(name, inRate, outRate, ppm, inChunk, outChunk, seconds, 0);
}

int main(int argc, char **argv) {
    srand(1);
    runFxTests();
    void runRingTests(void); runRingTests();
    void runLoudnessTests(void); runLoudnessTests();
    if (argc > 1 && strcmp(argv[1], "fx") == 0) {   // voice chain only (fast)
        printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
        return failures ? 1 : 0;
    }
    drift_case("44.1k USB mic, fast clock", 44100, 48000, +200, 512, 256, 120);
    drift_case("48k webcam, slow clock", 48000, 48000, -150, 480, 256, 120);
    drift_case("96k interface", 96000, 48000, +80, 1024, 256, 120);
    drift_case("mix to 44.1k headphones", 48000, 44100, -300, 256, 512, 120);
    drift_case("Bluetooth-sized buffers", 48000, 48000, +500, 2048, 256, 120);
    drift_case_j("scheduling jitter", 48000, 48000, +100, 256, 256, 120, 1.0);
    drift_case_j("one hour, USB mic", 44100, 48000, -250, 512, 256, 3600, 0.5);
    printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
