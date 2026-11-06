// MixdeckDriver: AudioServerPlugIn loopback for the virtual buses.
//
//   "Mixdeck Feed" (hidden, 6-ch output) --ring--> "Mixer B1" (ch 1-2)
//                                                  "Mixer B2" (ch 3-4)
//                                                  "Mixer B3" (ch 5-6)
//
// Spec: spec/features/virtual-devices.md. Written from Apple's public
// AudioServerPlugIn.h; no third-party code.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

// ---- Object model -----------------------------------------------------------

enum {
    kObjPlugIn     = kAudioObjectPlugInObject, // 1
    kObjFeedDevice = 2,
    kObjFeedStream = 3,
    kObjMic1       = 4,                        // mic n: device 4+2(n-1), stream 5+2(n-1)
};
#define kNumMics         3
#define kMicChannels     2
#define kFeedChannels    (kNumMics * kMicChannels)

#define kSampleRate      48000.0
#define kRingFrames      65536u            // power of two, ~1.37 s
#define kZeroTSPeriod    16384u            // frames between zero timestamps
#define kClockDomain     0x4D584231u       // 'MXB1': both devices share one clock

#define kFeedUID  "Mixdeck_Feed_UID"
static const char *kMicUIDs[kNumMics]  = { "MixerB1_Input_UID", "MixerB2_Input_UID", "MixerB3_Input_UID" };
static const char *kMicNames[kNumMics] = { "Mixer B1", "Mixer B2", "Mixer B3" };

static AudioServerPlugInHostRef gHost = NULL;
static ULONG gRefCount = 1;
static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRunCount[1 + kNumMics];    // [0] feed, [n] mic n

static UInt64 gAnchorTicks = 0;
static double gTicksPerFrame = 1.0;

// Ring indexed by absolute sample time. gWriteEnd is one past the last frame
// written by the feed device. Frames at or after gWriteEnd, or older than
// gWriteEnd - kRingFrames, read as silence.
static float gRing[kRingFrames * kFeedChannels];
static _Atomic int64_t gWriteEnd = INT64_MIN;

static os_log_t Log(void) {
    static os_log_t l = NULL;
    if (!l) l = os_log_create("local.mixdeck.driver", "driver");
    return l;
}
#define FCC(x) (char)((x) >> 24), (char)((x) >> 16), (char)((x) >> 8), (char)(x)

static bool IsMicDevice(AudioObjectID o) { return o >= kObjMic1 && o < kObjMic1 + 2 * kNumMics && (o - kObjMic1) % 2 == 0; }
static bool IsMicStream(AudioObjectID o) { return o > kObjMic1 && o <= kObjMic1 + 2 * kNumMics && (o - kObjMic1) % 2 == 1; }
static int MicIndex(AudioObjectID o) { return (int)(o - kObjMic1) / 2; }           // device or stream -> 0..2
static bool IsDevice(AudioObjectID o) { return o == kObjFeedDevice || IsMicDevice(o); }
static bool IsStream(AudioObjectID o) { return o == kObjFeedStream || IsMicStream(o); }
static int DevIndex(AudioObjectID o) { return o == kObjFeedDevice ? 0 : 1 + MicIndex(o); }
static CFStringRef CFS(const char *c) { return CFStringCreateWithCString(NULL, c, kCFStringEncodingUTF8); }

// ---- Interface table --------------------------------------------------------

static HRESULT  MD_QueryInterface(void *, REFIID, LPVOID *);
static ULONG    MD_AddRef(void *);
static ULONG    MD_Release(void *);
static OSStatus MD_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus MD_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *);
static OSStatus MD_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus MD_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus MD_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus MD_PerformConfigChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static OSStatus MD_AbortConfigChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static Boolean  MD_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *);
static OSStatus MD_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, Boolean *);
static OSStatus MD_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus MD_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, UInt32 *, void *);
static OSStatus MD_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);
static OSStatus MD_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus MD_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus MD_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *, UInt64 *, UInt64 *);
static OSStatus MD_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean *, Boolean *);
static OSStatus MD_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);
static OSStatus MD_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *, void *, void *);
static OSStatus MD_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, MD_QueryInterface, MD_AddRef, MD_Release,
    MD_Initialize, MD_CreateDevice, MD_DestroyDevice,
    MD_AddDeviceClient, MD_RemoveDeviceClient,
    MD_PerformConfigChange, MD_AbortConfigChange,
    MD_HasProperty, MD_IsPropertySettable, MD_GetPropertyDataSize,
    MD_GetPropertyData, MD_SetPropertyData,
    MD_StartIO, MD_StopIO, MD_GetZeroTimeStamp,
    MD_WillDoIOOperation, MD_BeginIOOperation, MD_DoIOOperation, MD_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

__attribute__((visibility("default")))
void *MixdeckDriverCreate(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    (void)allocator;
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}

static HRESULT MD_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *out) {
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    CFUUIDRef iunknown = CFUUIDGetConstantUUIDWithBytes(NULL, 0, 0, 0, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46);
    HRESULT r = E_NOINTERFACE;
    *out = NULL;
    if (CFEqual(req, kAudioServerPlugInDriverInterfaceUUID) || CFEqual(req, iunknown)) {
        MD_AddRef(inDriver);
        *out = gDriverRef;
        r = S_OK;
    }
    CFRelease(req);
    return r;
}
static ULONG MD_AddRef(void *d) { (void)d; return ++gRefCount; }
static ULONG MD_Release(void *d) { (void)d; return gRefCount > 0 ? --gRefCount : 0; }

static OSStatus MD_Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    (void)d;
    gHost = host;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gTicksPerFrame = (1e9 * (double)tb.denom / (double)tb.numer) / kSampleRate;
    gAnchorTicks = mach_absolute_time();
    memset(gRing, 0, sizeof gRing);
    os_log(Log(), "Initialize: Mixdeck Feed + Mixer B1..B%d", kNumMics);
    return kAudioHardwareNoError;
}

static OSStatus MD_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *out) {
    (void)d; (void)desc; (void)ci; (void)out; return kAudioHardwareUnsupportedOperationError;
}
static OSStatus MD_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) {
    (void)d; (void)o; return kAudioHardwareUnsupportedOperationError;
}
static OSStatus MD_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *ci) {
    (void)d; (void)o; (void)ci; return kAudioHardwareNoError;
}
static OSStatus MD_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *ci) {
    (void)d; (void)o; (void)ci; return kAudioHardwareNoError;
}
static OSStatus MD_PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) {
    (void)d; (void)o; (void)a; (void)i; return kAudioHardwareNoError;
}
static OSStatus MD_AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) {
    (void)d; (void)o; (void)a; (void)i; return kAudioHardwareNoError;
}

// ---- Properties -------------------------------------------------------------

static AudioStreamBasicDescription Format(UInt32 kChannels) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = f.mBytesPerFrame = 4 * kChannels;
    f.mFramesPerPacket = 1;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

// One getter for both size and data. out == NULL: size only.
static OSStatus GetProp(AudioObjectID obj, const AudioObjectPropertyAddress *a,
                        UInt32 qSize, const void *q, UInt32 inSize, UInt32 *outSize, void *out) {
#define RET_VAL(T, v) do { *outSize = sizeof(T); \
        if (out) { if (inSize < sizeof(T)) return kAudioHardwareBadPropertySizeError; *(T *)out = (v); } \
        return kAudioHardwareNoError; } while (0)
#define RET_ARR(T, arr, n) do { UInt32 _n = (UInt32)(n); *outSize = _n * (UInt32)sizeof(T); \
        if (out) { UInt32 _fit = inSize / (UInt32)sizeof(T); if (_fit < _n) _n = _fit; \
                   if (_n) memcpy(out, arr, _n * sizeof(T)); *outSize = _n * (UInt32)sizeof(T); } \
        return kAudioHardwareNoError; } while (0)

    AudioObjectID devices[1 + kNumMics] = { kObjFeedDevice, kObjMic1, kObjMic1 + 2, kObjMic1 + 4 };
    AudioObjectID none[1] = { 0 };

    // No custom properties anywhere.
    if (a->mSelector == kAudioObjectPropertyCustomPropertyInfoList &&
        (obj == kObjPlugIn || IsDevice(obj) || IsStream(obj))) {
        *outSize = 0;
        return kAudioHardwareNoError;
    }

    if (obj == kObjPlugIn) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:  RET_VAL(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:      RET_VAL(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:      RET_VAL(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RET_VAL(CFStringRef, CFSTR("Mixdeck"));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: RET_ARR(AudioObjectID, devices, 1 + kNumMics);
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList: RET_ARR(AudioObjectID, none, 0);
        case kAudioPlugInPropertyResourceBundle: RET_VAL(CFStringRef, CFSTR(""));
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID r = kAudioObjectUnknown;
            CFStringRef uid = (q && qSize >= sizeof(CFStringRef)) ? *(const CFStringRef *)q : NULL;
            if (uid && CFEqual(uid, CFSTR(kFeedUID))) r = kObjFeedDevice;
            for (int m = 0; m < kNumMics && uid; m++) {
                CFStringRef u = CFS(kMicUIDs[m]);
                if (CFEqual(uid, u)) r = kObjMic1 + 2 * m;
                CFRelease(u);
            }
            RET_VAL(AudioObjectID, r);
        }
        default: break;
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (IsDevice(obj)) {
        bool isIn = IsMicDevice(obj);
        int m = isIn ? MicIndex(obj) : 0;
        UInt32 kChannels = isIn ? kMicChannels : kFeedChannels;
        AudioObjectID stream[1] = { obj + 1 };
        AudioObjectPropertyScope myScope = isIn ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
        bool scopeHasStream = (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == myScope);
        UInt32 running = gRunCount[DevIndex(obj)] > 0;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:  RET_VAL(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:      RET_VAL(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:      RET_VAL(AudioObjectID, kObjPlugIn);
        case kAudioObjectPropertyName:       RET_VAL(CFStringRef, isIn ? CFS(kMicNames[m]) : CFSTR("Mixdeck Feed"));
        case kAudioObjectPropertyManufacturer: RET_VAL(CFStringRef, CFSTR("Mixdeck"));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:    RET_ARR(AudioObjectID, stream, scopeHasStream ? 1 : 0);
        case kAudioObjectPropertyControlList: RET_ARR(AudioObjectID, none, 0);
        case kAudioDevicePropertyDeviceUID:  RET_VAL(CFStringRef, isIn ? CFS(kMicUIDs[m]) : CFSTR(kFeedUID));
        case kAudioDevicePropertyModelUID:   RET_VAL(CFStringRef, CFSTR("Mixdeck_Loopback_Model"));
        case kAudioDevicePropertyTransportType: RET_VAL(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: RET_ARR(AudioObjectID, devices, 1 + kNumMics);
        case kAudioDevicePropertyClockDomain: RET_VAL(UInt32, kClockDomain);
        case kAudioDevicePropertyClockIsStable: RET_VAL(UInt32, 1);
        case kAudioDevicePropertyClockAlgorithm: RET_VAL(UInt32, kAudioDeviceClockAlgorithmSimpleIIR);
        case kAudioDevicePropertyDeviceIsAlive: RET_VAL(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: RET_VAL(UInt32, running);
        case kAudioDevicePropertyIsHidden:   RET_VAL(UInt32, isIn ? 0 : 1);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RET_VAL(UInt32, isIn ? 1 : 0);
        case kAudioDevicePropertyPreferredChannelLayout: {
            AudioChannelLayout lay; memset(&lay, 0, sizeof lay);
            lay.mChannelLayoutTag = isIn ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | kFeedChannels;
            RET_VAL(AudioChannelLayout, lay);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RET_VAL(UInt32, 0);
        case kAudioDevicePropertyLatency:    RET_VAL(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RET_VAL(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: RET_VAL(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            RET_ARR(AudioValueRange, &r, 1);
        }
        case kAudioDevicePropertyZeroTimeStampPeriod: RET_VAL(UInt32, kZeroTSPeriod);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 ch[2] = { 1, 2 };
            RET_ARR(UInt32, ch, 2);
        }
        case kAudioDevicePropertyStreamConfiguration: {
            UInt32 n = scopeHasStream && a->mScope != kAudioObjectPropertyScopeGlobal ? 1 : 0;
            UInt32 need = (UInt32)(offsetof(AudioBufferList, mBuffers) + n * sizeof(AudioBuffer));
            *outSize = need;
            if (out) {
                if (inSize < need) return kAudioHardwareBadPropertySizeError;
                AudioBufferList *abl = (AudioBufferList *)out;
                abl->mNumberBuffers = n;
                if (n) {
                    abl->mBuffers[0].mNumberChannels = kChannels;
                    abl->mBuffers[0].mDataByteSize = 0;
                    abl->mBuffers[0].mData = NULL;
                }
            }
            return kAudioHardwareNoError;
        }
        default: break;
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (IsStream(obj)) {
        bool isIn = IsMicStream(obj);
        UInt32 kChannels = isIn ? kMicChannels : kFeedChannels;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:  RET_VAL(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:      RET_VAL(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:      RET_VAL(AudioObjectID, obj - 1);
        case kAudioObjectPropertyOwnedObjects: RET_ARR(AudioObjectID, none, 0);
        case kAudioStreamPropertyDirection:  RET_VAL(UInt32, isIn ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            RET_VAL(UInt32, isIn ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: RET_VAL(UInt32, 1);
        case kAudioStreamPropertyLatency:    RET_VAL(UInt32, 0);
        case kAudioStreamPropertyIsActive:   RET_VAL(UInt32, 1);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: RET_VAL(AudioStreamBasicDescription, Format(kChannels));
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription rd;
            memset(&rd, 0, sizeof rd);
            rd.mFormat = Format(kChannels);
            rd.mSampleRateRange.mMinimum = rd.mSampleRateRange.mMaximum = kSampleRate;
            RET_ARR(AudioStreamRangedDescription, &rd, 1);
        }
        default: break;
        }
        return kAudioHardwareUnknownPropertyError;
    }

    return kAudioHardwareBadObjectError;
#undef RET_VAL
#undef RET_ARR
}

static Boolean MD_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)d; (void)pid;
    UInt32 size = 0;
    return GetProp(obj, a, 0, NULL, 0, &size, NULL) == kAudioHardwareNoError;
}

static bool IsSettable(AudioObjectID obj, AudioObjectPropertySelector sel) {
    if (IsDevice(obj)) return sel == kAudioDevicePropertyNominalSampleRate;
    if (IsStream(obj)) return sel == kAudioStreamPropertyVirtualFormat || sel == kAudioStreamPropertyPhysicalFormat
                           || sel == kAudioStreamPropertyIsActive;
    return false;
}

static OSStatus MD_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *outSettable) {
    (void)d; (void)pid;
    if (!MD_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    *outSettable = IsSettable(obj, a->mSelector);
    return kAudioHardwareNoError;
}

static OSStatus MD_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *outSize) {
    (void)d; (void)pid;
    OSStatus st = GetProp(obj, a, qs, q, 0, outSize, NULL);
    if (st != kAudioHardwareNoError)
        os_log(Log(), "GetPropertyDataSize unsupported obj=%u sel=%c%c%c%c scope=%c%c%c%c", obj, FCC(a->mSelector), FCC(a->mScope));
    return st;
}

static OSStatus MD_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 inSize, UInt32 *outSize, void *out) {
    (void)d; (void)pid;
    OSStatus st = GetProp(obj, a, qs, q, inSize, outSize, out);
    if (st != kAudioHardwareNoError)
        os_log(Log(), "GetPropertyData failed obj=%u sel=%c%c%c%c status=%d", obj, FCC(a->mSelector), (int)st);
    return st;
}

static OSStatus MD_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 inSize, const void *data) {
    (void)d; (void)pid; (void)qs; (void)q;
    if (!IsSettable(obj, a->mSelector)) {
        os_log(Log(), "SetPropertyData refused obj=%u sel=%c%c%c%c", obj, FCC(a->mSelector));
        return kAudioHardwareUnknownPropertyError;
    }
    // Only the fixed format is accepted; setting it again is a no-op.
    if (a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return (*(const Float64 *)data == kSampleRate) ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    if (a->mSelector == kAudioStreamPropertyIsActive) return kAudioHardwareNoError;
    if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
    const AudioStreamBasicDescription *f = (const AudioStreamBasicDescription *)data;
    AudioStreamBasicDescription mine = Format(IsMicStream(obj) ? kMicChannels : kFeedChannels);
    bool same = f->mSampleRate == mine.mSampleRate && f->mFormatID == mine.mFormatID
             && f->mChannelsPerFrame == mine.mChannelsPerFrame && f->mBitsPerChannel == mine.mBitsPerChannel
             && (f->mFormatFlags & kAudioFormatFlagIsFloat);
    return same ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
}

// ---- IO -----------------------------------------------------------------------

static OSStatus MD_StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (!IsDevice(dev)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateLock);
    gRunCount[DevIndex(dev)]++;
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus MD_StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (!IsDevice(dev)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateLock);
    int i = DevIndex(dev);
    if (gRunCount[i] > 0) gRunCount[i]--;
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

// Both devices use the same anchor and period, so their sample times line up.
static OSStatus MD_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)d; (void)dev; (void)client;
    UInt64 now = mach_absolute_time();
    double periodTicks = kZeroTSPeriod * gTicksPerFrame;
    UInt64 n = (UInt64)((double)(now - gAnchorTicks) / periodTicks);
    *outHostTime = gAnchorTicks + (UInt64)((double)n * periodTicks);
    *outSampleTime = (Float64)(n * kZeroTSPeriod);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus MD_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, Boolean *outWillDo, Boolean *outInPlace) {
    (void)d; (void)client;
    *outWillDo = (IsMicDevice(dev) && op == kAudioServerPlugInIOOperationReadInput)
              || (dev == kObjFeedDevice && op == kAudioServerPlugInIOOperationWriteMix);
    *outInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus MD_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)ci; return kAudioHardwareNoError;
}
static OSStatus MD_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)ci; return kAudioHardwareNoError;
}

static void RingZero(int64_t start, int64_t end) {
    if (end - start > (int64_t)kRingFrames) start = end - kRingFrames;
    for (int64_t t = start; t < end; t++)
        memset(&gRing[((size_t)t & (kRingFrames - 1)) * kFeedChannels], 0, kFeedChannels * sizeof(float));
}

static void RingWrite(int64_t start, UInt32 frames, const float *src) {
    int64_t end = start + frames;
    int64_t prevEnd = atomic_load_explicit(&gWriteEnd, memory_order_relaxed);
    // A gap since the last write (the app was stopped): clear it so old audio is never replayed.
    if (prevEnd != INT64_MIN && start > prevEnd) RingZero(prevEnd, start);
    for (UInt32 f = 0; f < frames; f++)
        memcpy(&gRing[((size_t)(start + f) & (kRingFrames - 1)) * kFeedChannels], &src[f * kFeedChannels], kFeedChannels * sizeof(float));
    if (prevEnd == INT64_MIN || end > prevEnd)
        atomic_store_explicit(&gWriteEnd, end, memory_order_release);
}

static void RingRead(int mic, int64_t start, UInt32 frames, float *dst) {
    int64_t end = atomic_load_explicit(&gWriteEnd, memory_order_acquire);
    for (UInt32 f = 0; f < frames; f++) {
        int64_t t = start + f;
        bool valid = end != INT64_MIN && t < end && t >= end - (int64_t)kRingFrames;
        size_t i = ((size_t)t & (kRingFrames - 1)) * kFeedChannels + (size_t)mic * kMicChannels;
        dst[f * kMicChannels]     = valid ? gRing[i] : 0.0f;
        dst[f * kMicChannels + 1] = valid ? gRing[i + 1] : 0.0f;
    }
}

static OSStatus MD_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci, void *mainBuf, void *secondaryBuf) {
    (void)d; (void)stream; (void)client; (void)secondaryBuf;
    if (!mainBuf) return kAudioHardwareNoError;
    if (dev == kObjFeedDevice && op == kAudioServerPlugInIOOperationWriteMix) {
        RingWrite((int64_t)ci->mOutputTime.mSampleTime, frames, (const float *)mainBuf);
    } else if (IsMicDevice(dev) && op == kAudioServerPlugInIOOperationReadInput) {
        RingRead(MicIndex(dev), (int64_t)ci->mInputTime.mSampleTime, frames, (float *)mainBuf);
    }
    return kAudioHardwareNoError;
}
