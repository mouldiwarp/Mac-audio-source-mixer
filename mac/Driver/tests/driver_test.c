// In-process test of MixdeckDriver: loads the built bundle with dlopen and drives
// it the way the HAL does. Nothing is installed. Run: make test
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

static int failures = 0;
#define CHECK(c, msg) do { if (c) printf("ok   %s\n", msg); else { printf("FAIL %s\n", msg); failures++; } } while (0)

static AudioServerPlugInDriverRef drv;
static AudioServerPlugInDriverInterface *I;

enum { FEED = 2, MIC1 = 4, MIC2 = 6, MIC3 = 8 };
static void cycle(AudioObjectID dev, UInt32 op, double t, float *buf, UInt32 frames) {
    AudioServerPlugInIOCycleInfo ci; memset(&ci, 0, sizeof ci);
    ci.mInputTime.mSampleTime = t; ci.mOutputTime.mSampleTime = t;
    I->DoIOOperation(drv, dev, dev + 1, 0, op, frames, &ci, buf, NULL);
}
// Feed: channel pair k (0..2) gets value v*(k+1), so the mics can be told apart.
static void feed(double t, float v, UInt32 n) {
    float b[256 * 6]; for (UInt32 f = 0; f < n; f++) for (int c = 0; c < 6; c++) b[f * 6 + c] = v * (float)(c / 2 + 1);
    cycle(FEED, kAudioServerPlugInIOOperationWriteMix, t, b, n);
}
static float readmic(AudioObjectID mic, double t, UInt32 n) {
    float b[256 * 2]; cycle(mic, kAudioServerPlugInIOOperationReadInput, t, b, n);
    float s = 0; for (UInt32 i = 0; i < n * 2; i++) s += fabsf(b[i]); return s;
}
static float readsum(double t, UInt32 n) { return readmic(MIC1, t, n); }

static CFStringRef getstr(AudioObjectID o, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, 0 };
    CFStringRef s = NULL; UInt32 sz = 0;
    I->GetPropertyData(drv, o, 0, &a, 0, NULL, sizeof s, &sz, &s);
    return s;
}
static UInt32 getu32(AudioObjectID o, AudioObjectPropertySelector sel, AudioObjectPropertyScope sc) {
    AudioObjectPropertyAddress a = { sel, sc, 0 }; UInt32 v = 99, sz = 0;
    I->GetPropertyData(drv, o, 0, &a, 0, NULL, sizeof v, &sz, &v); return v;
}
static UInt32 getsize(AudioObjectID o, AudioObjectPropertySelector sel, AudioObjectPropertyScope sc) {
    AudioObjectPropertyAddress a = { sel, sc, 0 }; UInt32 sz = 0;
    I->GetPropertyDataSize(drv, o, 0, &a, 0, NULL, &sz); return sz;
}

int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
    void *(*create)(CFAllocatorRef, CFUUIDRef) = dlsym(h, "MixdeckDriverCreate");
    drv = create(NULL, kAudioServerPlugInTypeUUID); I = *drv;
    AudioServerPlugInHostInterface dummyHost; memset(&dummyHost, 0, sizeof dummyHost);
    CHECK(I->Initialize(drv, &dummyHost) == 0, "Initialize");

    CHECK(CFEqual(getstr(MIC1, kAudioObjectPropertyName), CFSTR("Mixer B1")), "mic 1 name");
    CHECK(CFEqual(getstr(MIC2, kAudioObjectPropertyName), CFSTR("Mixer B2")), "mic 2 name");
    CHECK(CFEqual(getstr(MIC3, kAudioObjectPropertyName), CFSTR("Mixer B3")), "mic 3 name");
    CHECK(CFEqual(getstr(FEED, kAudioObjectPropertyName), CFSTR("Mixdeck Feed")), "feed device name");
    CHECK(CFEqual(getstr(MIC3, kAudioDevicePropertyDeviceUID), CFSTR("MixerB3_Input_UID")), "mic 3 UID");
    CHECK(getu32(MIC1, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 0, "mics visible");
    CHECK(getu32(FEED, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 1, "feed hidden");
    CHECK(getu32(FEED, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0, "feed not default-capable");
    CHECK(getsize(1, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal) == 16, "plug-in lists 4 devices");
    CHECK(getsize(MIC2, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput) == 4, "mic has 1 input stream");
    CHECK(getsize(MIC2, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput) == 0, "mic has 0 output streams");
    CHECK(getsize(FEED, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput) == 4, "feed has 1 output stream");
    CHECK(getu32(MIC2 + 1, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 1, "mic stream direction=input");
    CHECK(getu32(FEED + 1, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 0, "feed stream direction=output");
    {
        AudioObjectPropertyAddress fa = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, 0 };
        AudioStreamBasicDescription f; UInt32 fs = 0;
        I->GetPropertyData(drv, FEED + 1, 0, &fa, 0, NULL, sizeof f, &fs, &f);
        CHECK(f.mChannelsPerFrame == 6, "feed stream is 6 channels");
        I->GetPropertyData(drv, MIC3 + 1, 0, &fa, 0, NULL, sizeof f, &fs, &f);
        CHECK(f.mChannelsPerFrame == 2, "mic stream is 2 channels");
    }

    AudioObjectPropertyAddress tr = { kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, 0 };
    CFStringRef uid = CFSTR("Mixdeck_Feed_UID"); AudioObjectID dev = 0; UInt32 sz = 0;
    I->GetPropertyData(drv, 1, 0, &tr, sizeof uid, &uid, sizeof dev, &sz, &dev);
    CHECK(dev == FEED, "translate feed UID");
    uid = CFSTR("MixerB2_Input_UID");
    I->GetPropertyData(drv, 1, 0, &tr, sizeof uid, &uid, sizeof dev, &sz, &dev);
    CHECK(dev == MIC2, "translate mic 2 UID");

    AudioObjectPropertyAddress sr = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0 };
    Float64 r48 = 48000, r44 = 44100;
    CHECK(I->SetPropertyData(drv, MIC1, 0, &sr, 0, NULL, sizeof r48, &r48) == 0, "set 48 kHz accepted");
    CHECK(I->SetPropertyData(drv, MIC1, 0, &sr, 0, NULL, sizeof r44, &r44) != 0, "set 44.1 kHz refused");

    CHECK(readsum(1000, 256) == 0, "silence before any write");
    feed(10000, 0.5f, 256);
    CHECK(fabsf(readsum(10000, 256) - 0.5f * 512) < 1e-3, "loopback: written frames read back");
    CHECK(fabsf(readmic(MIC2, 10000, 256) - 1.0f * 512) < 1e-3, "mic 2 carries feed channels 3-4 only");
    CHECK(fabsf(readmic(MIC3, 10000, 256) - 1.5f * 512) < 1e-3, "mic 3 carries feed channels 5-6 only");
    CHECK(readsum(10256, 256) == 0, "frames after write end read as silence (app stopped)");
    feed(10000 + 70000, 0.25f, 256);   // writer restarts after a gap longer than the ring
    CHECK(readsum(10000 + 65536, 256) == 0, "gap after restart is silent, no stale replay");
    CHECK(fabsf(readsum(80000, 256) - 0.25f * 512) < 1e-3, "new audio after restart");
    feed(80256 + 100, 0.1f, 256);       // short gap of 100 frames
    CHECK(readsum(80256, 100) == 0, "short gap zeroed");

    printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
