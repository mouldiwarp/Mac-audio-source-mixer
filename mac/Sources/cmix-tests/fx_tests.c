// Offline tests for the voice chain (spec/features/voice-dsp.md, Acceptance 1-2).
#include "VoiceFx.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern int failures;
#define CHECK(c, ...) do { printf((c) ? "ok   " : "FAIL "); printf(__VA_ARGS__); printf("\n"); if (!(c)) failures++; } while (0)

#define FS 48000.0
#define BLK 256
// Sample counts are whole blocks.
#define NS(sec) (((size_t)((sec) * FS) / BLK) * BLK)

static float frand(void) { return 2.0f * (float)rand() / (float)RAND_MAX - 1.0f; }

// Least-squares amplitude of a sine at hz over x[0..n).
static double fitAmp(const float *x, size_t n, double hz, double *residualRms) {
    double ss = 0, cc = 0, sc = 0, xs = 0, xc = 0;
    for (size_t i = 0; i < n; i++) {
        double s = sin(2 * M_PI * hz * i / FS), c = cos(2 * M_PI * hz * i / FS);
        ss += s * s; cc += c * c; sc += s * c; xs += x[i] * s; xc += x[i] * c;
    }
    double det = ss * cc - sc * sc, a = (xs * cc - xc * sc) / det, b = (xc * ss - xs * sc) / det;
    if (residualRms) {
        double e = 0;
        for (size_t i = 0; i < n; i++) {
            double d = x[i] - a * sin(2 * M_PI * hz * i / FS) - b * cos(2 * M_PI * hz * i / FS);
            e += d * d;
        }
        *residualRms = sqrt(e / n);
    }
    return sqrt(a * a + b * b);
}

// Runs a sine of amplitude amp through the chain's pre (or post) stage and
// returns the output gain in dB, measured over the last 0.25 s of 1 s.
static double sineGainDB(const FxParams *p, double hz, double amp, bool post) {
    FxChain *c = FxChainCreate(FS);
    FxChainSetParams(c, p);
    size_t n = NS(1);
    float *l = malloc(n * sizeof(float)), *r = malloc(n * sizeof(float));
    for (size_t i = 0; i < n; i++) l[i] = r[i] = (float)(amp * sin(2 * M_PI * hz * i / FS));
    for (size_t i = 0; i < n; i += BLK) {
        if (post) FxChainProcessPost(c, l + i, r + i, BLK); else FxChainProcessPre(c, l + i, r + i, BLK);
    }
    size_t tail = n / 4;
    double a = fitAmp(l + n - tail, tail, hz, NULL);
    free(l); free(r); FxChainDestroy(c);
    return 20 * log10(a / amp);
}

static void testEq(void) {
    printf("-- 3-band EQ\n");
    FxParams p; FxParamsDefault(&p);
    p.eq3.on = true; p.eq3.lowDB = 6; p.eq3.midDB = 0; p.eq3.highDB = 0;
    double g = sineGainDB(&p, 25, 0.25, false);
    CHECK(fabs(g - 6) < 0.3, "low shelf +6 dB: %.2f dB at 25 Hz", g);
    g = sineGainDB(&p, 5000, 0.25, false);
    CHECK(fabs(g) < 0.1, "low shelf leaves 5 kHz alone: %.2f dB", g);
    p.eq3.lowDB = 0; p.eq3.midDB = -9;
    g = sineGainDB(&p, 1000, 0.25, false);
    CHECK(fabs(g + 9) < 0.05, "mid -9 dB: %.2f dB at 1 kHz", g);
    p.eq3.midDB = 0; p.eq3.highDB = 12;
    g = sineGainDB(&p, 20000, 0.25, false);
    CHECK(fabs(g - 12) < 0.5, "high shelf +12 dB: %.2f dB at 20 kHz", g);
    p.eq3.highDB = 0;
    g = sineGainDB(&p, 1000, 0.25, false);
    CHECK(fabs(g) < 0.01, "flat EQ is transparent: %.3f dB", g);

    printf("-- parametric EQ\n");
    FxParamsDefault(&p);
    p.peq.on = true;
    p.peq.band[3] = (FxPeqBand){ true, FX_PEQ_PEAK, 3000, 9, 2 };
    g = sineGainDB(&p, 3000, 0.25, false);
    CHECK(fabs(g - 9) < 0.05, "peak +9 dB at 3 kHz: %.2f dB", g);
    g = sineGainDB(&p, 300, 0.25, false);
    CHECK(fabs(g) < 0.2, "peak leaves 300 Hz alone: %.2f dB", g);
    FxParamsDefault(&p);
    p.peq.on = true;
    p.peq.band[0] = (FxPeqBand){ true, FX_PEQ_HIGHPASS, 80, 0, (float)M_SQRT1_2 };
    g = sineGainDB(&p, 80, 0.25, false);
    CHECK(fabs(g + 3.01) < 0.1, "high-pass 80 Hz is -3 dB at 80 Hz: %.2f dB", g);
    g = sineGainDB(&p, 20, 0.25, false);
    CHECK(g < -23, "high-pass removes 20 Hz: %.1f dB", g);
    g = sineGainDB(&p, 1000, 0.25, false);
    CHECK(fabs(g) < 0.05, "high-pass passes 1 kHz: %.2f dB", g);
    p.peq.band[0] = (FxPeqBand){ true, FX_PEQ_LOWPASS, 8000, 0, (float)M_SQRT1_2 };
    g = sineGainDB(&p, 16000, 0.25, false);
    CHECK(g < -10, "low-pass 8 kHz cuts 16 kHz: %.1f dB", g);
    p.peq.band[0].on = false;
    g = sineGainDB(&p, 1000, 0.25, false);
    CHECK(fabs(g) < 1e-4, "bands off: transparent (%.5f dB)", g);
}

static void testGate(void) {
    printf("-- gate\n");
    FxParams p; FxParamsDefault(&p);
    p.gate.on = true; p.gate.thresholdDB = -40; p.gate.rangeDB = 40;
    double g = sineGainDB(&p, 440, 0.001, false);   // -60 dBFS
    CHECK(fabs(g + 40) < 0.5, "below threshold: attenuated %.1f dB (range 40)", g);
    g = sineGainDB(&p, 440, 0.1, false);            // -20 dBFS
    CHECK(fabs(g) < 0.05, "above threshold: %.2f dB (unity)", g);

    // Timing: burst of tone then silence-level tone; gate closes after hold+release.
    FxChain *c = FxChainCreate(FS);
    p.gate.holdMs = 80; p.gate.releaseMs = 50;
    FxChainSetParams(c, &p);
    size_t n = NS(1);
    float *l = calloc(n, sizeof(float)), *r = calloc(n, sizeof(float));
    for (size_t i = 0; i < n; i++) {
        double a = i < n / 2 ? 0.1 : 0.003;   // -20 dBFS then -50 dBFS
        l[i] = r[i] = (float)(a * sin(2 * M_PI * 440 * i / FS));
    }
    bool openMid = false, closedEnd = false;
    for (size_t i = 0; i < n; i += BLK) {
        FxChainProcessPre(c, l + i, r + i, BLK);
        FxMeters m; FxChainGetMeters(c, &m);
        if (i < n / 2 && i + BLK >= n / 2) openMid = m.gateOpen;
        if (i + BLK == n) closedEnd = !m.gateOpen;
    }
    // 30 ms after the drop: still in hold, so unattenuated.
    double aHold = fitAmp(l + n / 2 + 960, 480, 440, NULL);
    double aEnd = fitAmp(l + n - 4800, 4800, 440, NULL);
    CHECK(openMid && closedEnd, "indicator: open during speech, closed after");
    CHECK(fabs(20 * log10(aHold / 0.003)) < 0.5, "hold keeps the gate open 30 ms after the drop (%.1f dB)", 20 * log10(aHold / 0.003));
    CHECK(20 * log10(aEnd / 0.003) < -39, "closed after hold + release (%.1f dB)", 20 * log10(aEnd / 0.003));
    free(l); free(r); FxChainDestroy(c);
}

static void testComp(void) {
    printf("-- compressor\n");
    FxComp k = { true, -20, 4, 0, 10, 150, 0 };
    CHECK(fabsf(FxCompStaticCurve(&k, -30) + 30) < 1e-4, "static: below threshold is unity");
    CHECK(fabsf(FxCompStaticCurve(&k, -10) + 17.5f) < 1e-4, "static: -10 in -> -17.5 out at 4:1, T -20");
    k.kneeDB = 6;
    float a = FxCompStaticCurve(&k, -23.0f), b = FxCompStaticCurve(&k, -17.0f);
    CHECK(fabsf(a + 23) < 1e-4 && fabsf(b - (-20 + 3.0f / 4)) < 1e-4, "static: soft knee joins both segments (%.3f, %.3f)", a, b);
    bool mono = true;
    for (float x = -40; x < 0; x += 0.1f)
        if (FxCompStaticCurve(&k, x + 0.1f) < FxCompStaticCurve(&k, x)) mono = false;
    CHECK(mono, "static: curve is monotonic");

    // Dynamic: a square wave has a constant level, so the output settles on the curve.
    FxParams p; FxParamsDefault(&p);
    p.comp = (FxComp){ true, -20, 4, 0, 5, 50, 6 };
    FxChain *c = FxChainCreate(FS);
    FxChainSetParams(c, &p);
    size_t n = NS(1);
    float *l = malloc(n * sizeof(float)), *r = malloc(n * sizeof(float));
    float amp = powf(10, -10 / 20.0f);
    for (size_t i = 0; i < n; i++) l[i] = r[i] = ((i / 48) & 1) ? amp : -amp;   // 500 Hz square
    float gr = 0, in = -120;
    for (size_t i = 0; i < n; i += BLK) {
        FxChainProcessPre(c, l + i, r + i, BLK);
        FxMeters m; FxChainGetMeters(c, &m);
        gr = m.compGainReductionDB; in = m.compInputDB;
    }
    float out = 20 * log10f(fabsf(l[n - 1]));
    CHECK(fabsf(out - (-17.5f + 6)) < 0.05f, "square at -10 dBFS -> %.2f dBFS (expected -11.5 with +6 make-up)", out);
    CHECK(fabsf(gr - 7.5f) < 0.05f && fabsf(in + 10) < 0.05f, "meters: input %.2f dB, reduction %.2f dB", in, gr);
    free(l); free(r); FxChainDestroy(c);
}

static void testLimiter(void) {
    printf("-- limiter\n");
    FxParams p; FxParamsDefault(&p);
    p.limiter = (FxLimiter){ true, -1, 50 };
    FxChain *c = FxChainCreate(FS);
    FxChainSetParams(c, &p);
    size_t n = NS(10);
    float *l = malloc(n * sizeof(float)), *r = malloc(n * sizeof(float));
    srand(7);
    // Speech-like bursts with random transients up to +12 dBFS.
    for (size_t i = 0; i < n; i++) {
        double env = 0.5 + 0.5 * sin(2 * M_PI * 3 * i / FS);
        float spike = (rand() % 2000 == 0) ? 4.0f * frand() : 0;
        l[i] = (float)(1.6 * env * sin(2 * M_PI * 220 * i / FS)) + 0.05f * frand() + spike;
        r[i] = (float)(1.2 * env * sin(2 * M_PI * 330 * i / FS)) + 0.05f * frand() - spike;
    }
    float maxOut = 0, maxGr = 0;
    for (size_t i = 0; i < n; i += BLK) {
        FxChainProcessPost(c, l + i, r + i, BLK);
        for (size_t j = i; j < i + BLK; j++) maxOut = fmaxf(maxOut, fmaxf(fabsf(l[j]), fabsf(r[j])));
        FxMeters m; FxChainGetMeters(c, &m);
        maxGr = fmaxf(maxGr, m.limiterGainReductionDB);
    }
    float ceil = powf(10, -1 / 20.0f);
    CHECK(maxOut <= ceil, "10 s with +12 dBFS transients: peak %.5f <= ceiling %.5f", maxOut, ceil);
    CHECK(maxGr > 11, "meter shows gain reduction (max %.1f dB)", maxGr);
    FxChainDestroy(c);

    // Below the ceiling: unchanged apart from the 1.5 ms delay.
    c = FxChainCreate(FS);
    FxChainSetParams(c, &p);
    n = NS(1);
    float *x = malloc(n * sizeof(float));
    for (size_t i = 0; i < n; i++) x[i] = l[i] = r[i] = 0.5f * frand();
    for (size_t i = 0; i < n; i += BLK) FxChainProcessPost(c, l + i, r + i, BLK);
    int d = -1;
    for (int k = 0; k < 200 && d < 0; k++) {
        double e = 0;
        for (size_t i = 1000; i < 2000; i++) e += fabs(l[i] - x[i - k]);
        if (e < 1e-3) d = k;
    }
    CHECK(d == 71, "quiet signal passes unchanged, delayed %d samples (1.5 ms = 71)", d);
    free(x); free(l); free(r); FxChainDestroy(c);
}

static void testDenoise(void) {
    printf("-- denoiser\n");
    FxParams p; FxParamsDefault(&p);
    p.denoise = (FxDenoise){ true, 1.0f };
    FxChain *c = FxChainCreate(FS);
    FxChainSetParams(c, &p);
    size_t n = NS(4);
    float *l = malloc(n * sizeof(float)), *r = malloc(n * sizeof(float));
    srand(3);
    const double hz = 1000, amp = 0.1;   // -20 dBFS tone bursts in -40 dBFS white noise
    double noiseRms = 0.01;
    const size_t period = (size_t)(0.5 * FS), on = (size_t)(0.3 * FS), lat = 512;
    for (size_t i = 0; i < n; i++) {
        float t = (i % period) < on ? (float)(amp * sin(2 * M_PI * hz * i / FS)) : 0.0f;
        l[i] = t + (float)(noiseRms * sqrt(3.0)) * frand();
        r[i] = t + (float)(noiseRms * sqrt(3.0)) * frand();
    }
    for (size_t i = 0; i < n; i += BLK) FxChainProcessPre(c, l + i, r + i, BLK);
    // Last full period: tone over 50-250 ms of the burst, noise over the gap.
    size_t p0 = (n / period - 2) * period + lat;   // a period that ends inside the buffer
    size_t ts = p0 + (size_t)(0.05 * FS), tn = (size_t)(0.2 * FS);
    // fitAmp assumes phase 0 at x[0]; amplitude is phase-independent.
    double a = fitAmp(l + ts, tn, hz, NULL);
    size_t ns = p0 + on + (size_t)(0.05 * FS), nn = (size_t)(0.14 * FS);
    double e0 = 0;
    for (size_t i = ns; i < ns + nn; i++) e0 += (double)l[i] * l[i];
    double toneDB = 20 * log10(a / amp), redDB = 20 * log10(noiseRms / sqrt(e0 / nn));
    CHECK(fabs(toneDB) < 1.0, "speech-like tone bursts kept: %.2f dB", toneDB);
    CHECK(redDB > 12, "noise between bursts reduced by %.1f dB (amount 100%%)", redDB);
    size_t tail = NS(1);

    // Noise only, amount 50 %: about half the maximum reduction.
    FxChainDestroy(c);
    p.denoise.amount = 0.5f;
    c = FxChainCreate(FS);
    FxChainSetParams(c, &p);
    for (size_t i = 0; i < n; i++) { l[i] = (float)(noiseRms * sqrt(3.0)) * frand(); r[i] = (float)(noiseRms * sqrt(3.0)) * frand(); }
    for (size_t i = 0; i < n; i += BLK) FxChainProcessPre(c, l + i, r + i, BLK);
    double e = 0;
    for (size_t i = n - tail; i < n; i++) e += (double)l[i] * l[i];
    double red = 20 * log10(noiseRms / sqrt(e / tail));
    CHECK(red > 9 && red < 15, "amount 50%%: steady noise reduced by %.1f dB (limit 12)", red);
    free(l); free(r); FxChainDestroy(c);
}

static void testCpu(void) {
    printf("-- CPU\n");
    FxParams p; FxParamsDefault(&p);
    p.denoise.on = true; p.gate.on = true; p.eq3.on = true; p.eq3.lowDB = 3; p.eq3.midDB = -2; p.eq3.highDB = 2;
    p.peq.on = true;
    for (int b = 0; b < FX_PEQ_BANDS; b++) { p.peq.band[b].on = true; p.peq.band[b].gainDB = 2; }
    p.comp.on = true; p.limiter.on = true;
    FxChain *c[8];
    for (int i = 0; i < 8; i++) { c[i] = FxChainCreate(FS); FxChainSetParams(c[i], &p); }
    float l[BLK], r[BLK];
    const double seconds = 20;
    size_t blocks = (size_t)(seconds * FS / BLK);
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (size_t b = 0; b < blocks; b++)
        for (int i = 0; i < 8; i++) {
            for (int j = 0; j < BLK; j++) { l[j] = 0.3f * frand(); r[j] = 0.3f * frand(); }
            FxChainProcessPre(c[i], l, r, BLK);
            FxChainProcessPost(c[i], l, r, BLK);
        }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double spent = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
    CHECK(spent / seconds < 0.10, "8 strips, every block on: %.2f%% of one core (limit 10%%)", 100 * spent / seconds);
    for (int i = 0; i < 8; i++) FxChainDestroy(c[i]);
}

static void testLiveChange(void) {
    printf("-- live parameter changes\n");
    FxParams p; FxParamsDefault(&p);
    FxChain *c = FxChainCreate(FS);
    float l[BLK], r[BLK];
    bool finite = true;
    srand(11);
    for (int b = 0; b < 4000; b++) {
        if (b % 7 == 0) {
            p.gate.on = rand() & 1; p.comp.on = rand() & 1; p.eq3.on = rand() & 1; p.peq.on = rand() & 1;
            p.limiter.on = rand() & 1; p.denoise.on = rand() & 1;
            p.eq3.midDB = 12 * frand(); p.comp.ratio = 1 + 19 * fabsf(frand());
            p.peq.band[b % 6].on = true; p.peq.band[b % 6].type = rand() % 5;
            p.peq.band[b % 6].freq = 20 + 19980 * fabsf(frand()); p.peq.band[b % 6].q = 0.1f + 9.9f * fabsf(frand());
            FxChainSetParams(c, &p);
        }
        for (int j = 0; j < BLK; j++) { l[j] = 0.5f * frand(); r[j] = 0.5f * frand(); }
        FxChainProcessPre(c, l, r, BLK);
        FxChainProcessPost(c, l, r, BLK);
        for (int j = 0; j < BLK; j++) if (!isfinite(l[j]) || !isfinite(r[j]) || fabsf(l[j]) > 100) finite = false;
    }
    CHECK(finite, "random parameter changes for 21 s: output stays finite and bounded");
    FxChainDestroy(c);
}

void runFxTests(void) {
    testEq();
    testGate();
    testComp();
    testLimiter();
    testDenoise();
    testCpu();
    testLiveChange();
}
