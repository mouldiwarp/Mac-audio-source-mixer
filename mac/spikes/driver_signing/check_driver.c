// In-process check: load the driver binary and query its properties.
// Does not install anything or touch coreaudiod.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: check_driver <binary>\n"); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    void *(*create)(CFAllocatorRef, CFUUIDRef) = dlsym(h, "VirtualMixerTestCreate");
    if (!create) { fprintf(stderr, "no factory symbol\n"); return 1; }
    AudioServerPlugInDriverRef drv = create(kCFAllocatorDefault, kAudioServerPlugInTypeUUID);
    if (!drv) { fprintf(stderr, "factory returned NULL\n"); return 1; }
    AudioServerPlugInDriverInterface *i = *drv;
    if (i->Initialize(drv, NULL) != kAudioHardwareNoError) { fprintf(stderr, "Initialize failed\n"); return 1; }

    AudioObjectPropertyAddress name = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef s = NULL; UInt32 sz = 0;
    OSStatus st = i->GetPropertyDataSize(drv, 2, 0, &name, 0, NULL, &sz);
    st = i->GetPropertyData(drv, 2, 0, &name, 0, NULL, sizeof s, &sz, &s);
    char buf[128] = {0};
    if (st == 0 && s) CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    printf("device name: %s (status %d)\n", buf, (int)st);

    AudioObjectPropertyAddress rate = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 r = 0; sz = 0;
    st = i->GetPropertyData(drv, 2, 0, &rate, 0, NULL, sizeof r, &sz, &r);
    printf("nominal rate: %.0f (status %d)\n", r, (int)st);

    AudioObjectPropertyAddress fmt = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioStreamBasicDescription f; memset(&f, 0, sizeof f);
    st = i->GetPropertyData(drv, 3, 0, &fmt, 0, NULL, sizeof f, &sz, &f);
    printf("stream format: %.0f Hz, %u ch, float=%d (status %d)\n", f.mSampleRate, f.mChannelsPerFrame, (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0, (int)st);
    return 0;
}
