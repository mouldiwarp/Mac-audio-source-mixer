// VirtualMixerTest: minimal AudioServerPlugIn spike.
// One stereo input device at 48 kHz that outputs silence. Written from scratch
// against Apple's public AudioServerPlugIn.h. Purpose: check whether coreaudiod
// loads this bundle when it is only ad-hoc signed.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>

enum { kPlugInObj = 1, kDeviceObj = 2, kStreamObj = 3 };
#define kSampleRate 48000.0
#define kChannels 2
#define kBufferFrames 512

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static ULONG gRefCount = 1;
static UInt32 gIORunCount = 0;
static UInt64 gAnchorTicks = 0;
static double gTicksPerFrame = 1.0;

// Log with: log show --last 10m --predicate 'subsystem == "local.spike.virtualmixertest"'
static os_log_t Log(void) {
    static os_log_t l = NULL;
    if (!l) l = os_log_create("local.spike.virtualmixertest", "driver");
    return l;
}
#define FCC(x) (char)((x)>>24), (char)((x)>>16), (char)((x)>>8), (char)(x)

// ---- COM-style plumbing ----------------------------------------------------

static HRESULT VM_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG VM_AddRef(void *inDriver);
static ULONG VM_Release(void *inDriver);
static OSStatus VM_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus VM_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus VM_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus VM_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus VM_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus VM_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus VM_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean VM_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus VM_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus VM_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus VM_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus VM_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus VM_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus VM_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus VM_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus VM_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus VM_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus VM_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus VM_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    VM_QueryInterface,
    VM_AddRef,
    VM_Release,
    VM_Initialize,
    VM_CreateDevice,
    VM_DestroyDevice,
    VM_AddDeviceClient,
    VM_RemoveDeviceClient,
    VM_PerformDeviceConfigurationChange,
    VM_AbortDeviceConfigurationChange,
    VM_HasProperty,
    VM_IsPropertySettable,
    VM_GetPropertyDataSize,
    VM_GetPropertyData,
    VM_SetPropertyData,
    VM_StartIO,
    VM_StopIO,
    VM_GetZeroTimeStamp,
    VM_WillDoIOOperation,
    VM_BeginIOOperation,
    VM_DoIOOperation,
    VM_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// Factory: named in Info.plist under CFPlugInFactories.
__attribute__((visibility("default")))
void *VirtualMixerTestCreate(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    (void)allocator;
    os_log(Log(), "factory called");
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}

static HRESULT VM_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    (void)inDriver;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    CFUUIDRef iunknown = CFUUIDGetConstantUUIDWithBytes(NULL, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(req, kAudioServerPlugInDriverInterfaceUUID) || CFEqual(req, iunknown)) {
        *outInterface = gDriverRef;
        VM_AddRef(inDriver);
        result = S_OK;
    } else {
        *outInterface = NULL;
    }
    CFRelease(req);
    return result;
}

static ULONG VM_AddRef(void *inDriver) { (void)inDriver; return ++gRefCount; }
static ULONG VM_Release(void *inDriver) { (void)inDriver; return --gRefCount; }

static OSStatus VM_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    (void)inDriver;
    os_log(Log(), "Initialize");
    gHost = inHost;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double ticksPerSecond = 1e9 * (double)tb.denom / (double)tb.numer;
    gTicksPerFrame = ticksPerSecond / kSampleRate;
    gAnchorTicks = mach_absolute_time();
    return kAudioHardwareNoError;
}

static OSStatus VM_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *out) {
    (void)d; (void)desc; (void)ci; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus VM_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus VM_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) {
    (void)d; (void)id; (void)ci; return kAudioHardwareNoError;
}
static OSStatus VM_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) {
    (void)d; (void)id; (void)ci; return kAudioHardwareNoError;
}
static OSStatus VM_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void *i) {
    (void)d; (void)id; (void)a; (void)i; return kAudioHardwareNoError;
}
static OSStatus VM_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void *i) {
    (void)d; (void)id; (void)a; (void)i; return kAudioHardwareNoError;
}

// ---- Properties -------------------------------------------------------------

static AudioStreamBasicDescription MakeFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = 4 * kChannels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4 * kChannels;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

// Shared getter. With out == NULL it only reports the size. Returns
// kAudioHardwareUnknownPropertyError for selectors this object does not have.
static OSStatus GetProp(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 inSize, UInt32 *outSize, void *out) {
    AudioObjectID stream[1] = { kStreamObj };
    AudioObjectID device[1] = { kDeviceObj };
    bool inputScope = (a->mScope == kAudioObjectPropertyScopeInput || a->mScope == kAudioObjectPropertyScopeGlobal);

#define RET_VAL(T, v) do { \
        *outSize = sizeof(T); \
        if (out) { if (inSize < sizeof(T)) return kAudioHardwareBadPropertySizeError; *(T *)out = (v); } \
        return kAudioHardwareNoError; } while (0)
#define RET_ARR(T, arr, n) do { \
        *outSize = (UInt32)((n) * sizeof(T)); \
        if (out) { if (inSize < (n) * sizeof(T)) return kAudioHardwareBadPropertySizeError; memcpy(out, arr, (n) * sizeof(T)); } \
        return kAudioHardwareNoError; } while (0)

    if (a->mSelector == kAudioObjectPropertyCustomPropertyInfoList &&
        (obj == kPlugInObj || obj == kDeviceObj || obj == kStreamObj)) {
        *outSize = 0; // no custom properties
        return kAudioHardwareNoError;
    }

    switch (obj) {
    case kPlugInObj:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RET_VAL(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     RET_VAL(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:     RET_VAL(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RET_VAL(CFStringRef, CFSTR("Mixer Test"));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: RET_ARR(AudioObjectID, device, 1);
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList: RET_ARR(AudioObjectID, device, 0);
        case kAudioPlugInPropertyResourceBundle: RET_VAL(CFStringRef, CFSTR(""));
        case kAudioPlugInPropertyTranslateUIDToDevice: RET_VAL(AudioObjectID, kDeviceObj); // qualifier checked in VM_GetPropertyData
        default: break;
        }
        break;

    case kDeviceObj:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RET_VAL(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     RET_VAL(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:     RET_VAL(AudioObjectID, kPlugInObj);
        case kAudioObjectPropertyName:      RET_VAL(CFStringRef, CFSTR("Mixer Test Mic"));
        case kAudioObjectPropertyManufacturer: RET_VAL(CFStringRef, CFSTR("Mixer Test"));
        case kAudioObjectPropertyOwnedObjects: RET_ARR(AudioObjectID, stream, inputScope ? 1 : 0);
        case kAudioDevicePropertyDeviceUID: RET_VAL(CFStringRef, CFSTR("MixerTest_Mic_UID"));
        case kAudioDevicePropertyModelUID:  RET_VAL(CFStringRef, CFSTR("MixerTest_Model"));
        case kAudioDevicePropertyTransportType: RET_VAL(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: RET_ARR(AudioObjectID, device, 1);
        case kAudioDevicePropertyClockDomain: RET_VAL(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RET_VAL(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: RET_VAL(UInt32, gIORunCount > 0 ? 1 : 0);
        case kAudioDevicePropertyDeviceIsRunningSomewhere: RET_VAL(UInt32, gIORunCount > 0 ? 1 : 0);
        case kAudioDevicePropertyIsHidden: RET_VAL(UInt32, 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RET_VAL(UInt32, 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RET_VAL(UInt32, 1);
        case kAudioDevicePropertyLatency: RET_VAL(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RET_VAL(UInt32, 0);
        case kAudioDevicePropertyStreams: RET_ARR(AudioObjectID, stream, inputScope ? 1 : 0);
        case kAudioDevicePropertyNominalSampleRate: RET_VAL(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            RET_VAL(AudioValueRange, r);
        }
        case kAudioDevicePropertyBufferFrameSize: RET_VAL(UInt32, kBufferFrames);
        case kAudioDevicePropertyBufferFrameSizeRange: {
            AudioValueRange r = { 16, 4096 };
            RET_VAL(AudioValueRange, r);
        }
        case kAudioDevicePropertyZeroTimeStampPeriod: RET_VAL(UInt32, kBufferFrames);
        case kAudioObjectPropertyControlList: RET_ARR(AudioObjectID, device, 0);
        case kAudioDevicePropertyClockIsStable: RET_VAL(UInt32, 1);
        case kAudioDevicePropertyClockAlgorithm: RET_VAL(UInt32, kAudioDeviceClockAlgorithmSimpleIIR);
        case kAudioDevicePropertyPreferredChannelsForStereo: { UInt32 ch[2] = {1, 2}; RET_ARR(UInt32, ch, 2); }
        case kAudioDevicePropertyStreamConfiguration: {
            if (!inputScope) {
                *outSize = offsetof(AudioBufferList, mBuffers);
                if (out) { if (inSize < *outSize) return kAudioHardwareBadPropertySizeError; ((AudioBufferList *)out)->mNumberBuffers = 0; }
                return kAudioHardwareNoError;
            }
            *outSize = sizeof(AudioBufferList);
            if (out) {
                if (inSize < sizeof(AudioBufferList)) return kAudioHardwareBadPropertySizeError;
                AudioBufferList *abl = (AudioBufferList *)out;
                abl->mNumberBuffers = 1;
                abl->mBuffers[0].mNumberChannels = kChannels;
                abl->mBuffers[0].mDataByteSize = 0;
                abl->mBuffers[0].mData = NULL;
            }
            return kAudioHardwareNoError;
        }
        default: break;
        }
        break;

    case kStreamObj:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RET_VAL(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     RET_VAL(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:     RET_VAL(AudioObjectID, kDeviceObj);
        case kAudioStreamPropertyDirection: RET_VAL(UInt32, 1); // 1 = input
        case kAudioStreamPropertyStartingChannel: RET_VAL(UInt32, 1);
        case kAudioStreamPropertyLatency: RET_VAL(UInt32, 0);
        case kAudioStreamPropertyIsActive: RET_VAL(UInt32, 1);
        case kAudioStreamPropertyTerminalType: RET_VAL(UInt32, kAudioStreamTerminalTypeMicrophone);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription f = MakeFormat();
            RET_VAL(AudioStreamBasicDescription, f);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription rd;
            memset(&rd, 0, sizeof rd);
            rd.mFormat = MakeFormat();
            rd.mSampleRateRange.mMinimum = kSampleRate;
            rd.mSampleRateRange.mMaximum = kSampleRate;
            RET_ARR(AudioStreamRangedDescription, &rd, 1);
        }
        default: break;
        }
        break;

    default:
        return kAudioHardwareBadObjectError;
    }
    if (out) os_log(Log(), "unsupported property obj=%u sel=%c%c%c%c scope=%c%c%c%c", obj, FCC(a->mSelector), FCC(a->mScope));
    return kAudioHardwareUnknownPropertyError;
#undef RET_VAL
#undef RET_ARR
}

static Boolean VM_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)d; (void)pid;
    UInt32 size = 0;
    return GetProp(obj, a, 0, &size, NULL) == kAudioHardwareNoError;
}

static OSStatus VM_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *outIsSettable) {
    (void)d; (void)obj; (void)pid; (void)a;
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static OSStatus VM_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *outSize) {
    (void)d; (void)pid; (void)qs; (void)q;
    OSStatus st = GetProp(obj, a, 0, outSize, NULL);
    if (st != kAudioHardwareNoError) os_log(Log(), "GetPropertyDataSize failed obj=%u sel=%c%c%c%c scope=%c%c%c%c status=%d", obj, FCC(a->mSelector), FCC(a->mScope), (int)st);
    return st;
}

static OSStatus VM_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 inSize, UInt32 *outSize, void *outData) {
    (void)d; (void)pid;
    if (obj == kPlugInObj && a->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) {
        if (inSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
        CFStringRef uid = (q && qs >= sizeof(CFStringRef)) ? *(const CFStringRef *)q : NULL;
        *(AudioObjectID *)outData = (uid && CFEqual(uid, CFSTR("MixerTest_Mic_UID"))) ? kDeviceObj : kAudioObjectUnknown;
        *outSize = sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    OSStatus st = GetProp(obj, a, inSize, outSize, outData);
    if (st != kAudioHardwareNoError) os_log(Log(), "GetPropertyData failed obj=%u sel=%c%c%c%c status=%d", obj, FCC(a->mSelector), (int)st);
    return st;
}

static OSStatus VM_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 inSize, const void *data) {
    (void)d; (void)obj; (void)pid; (void)a; (void)qs; (void)q; (void)inSize; (void)data;
    return kAudioHardwareUnsupportedOperationError;
}

// ---- IO ----------------------------------------------------------------------

static OSStatus VM_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID) {
    (void)d; (void)id; (void)clientID;
    pthread_mutex_lock(&gLock);
    gIORunCount++;
    pthread_mutex_unlock(&gLock);
    return kAudioHardwareNoError;
}

static OSStatus VM_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID) {
    (void)d; (void)id; (void)clientID;
    pthread_mutex_lock(&gLock);
    if (gIORunCount > 0) gIORunCount--;
    pthread_mutex_unlock(&gLock);
    return kAudioHardwareNoError;
}

static OSStatus VM_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)d; (void)id; (void)clientID;
    UInt64 now = mach_absolute_time();
    UInt64 period = (UInt64)(kBufferFrames * gTicksPerFrame);
    UInt64 n = (now - gAnchorTicks) / period;
    *outHostTime = gAnchorTicks + n * period;
    *outSampleTime = (Float64)(n * kBufferFrames);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus VM_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID, UInt32 op, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)d; (void)id; (void)clientID;
    *outWillDo = (op == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus VM_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) {
    (void)d; (void)id; (void)clientID; (void)op; (void)frames; (void)ci;
    return kAudioHardwareNoError;
}

static OSStatus VM_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 clientID, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci, void *mainBuffer, void *secondaryBuffer) {
    (void)d; (void)dev; (void)stream; (void)clientID; (void)ci; (void)secondaryBuffer;
    if (op == kAudioServerPlugInIOOperationReadInput && mainBuffer) {
        memset(mainBuffer, 0, (size_t)frames * kChannels * sizeof(Float32)); // silence
    }
    return kAudioHardwareNoError;
}

static OSStatus VM_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) {
    (void)d; (void)id; (void)clientID; (void)op; (void)frames; (void)ci;
    return kAudioHardwareNoError;
}
