#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioHardwareBase.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <map>
#include <mutex>
#include <string>

// This HAL plug-in publishes a virtual stereo output device and applies per-client gain
// during kAudioServerPlugInIOOperationMixOutput. A production driver also needs an IPC
// transport to a helper/app that drains the mixed ring buffer and writes it to the
// selected hardware output. The Swift app uses Apple's process taps for that transport
// on macOS 14.2+.

namespace {

constexpr AudioObjectID kObjectPlugIn = kAudioObjectPlugInObject;
constexpr AudioObjectID kObjectDevice = 2;
constexpr AudioObjectID kObjectStream = 3;
constexpr Float64 kSampleRate = 48000.0;
constexpr UInt32 kChannels = 2;
constexpr UInt32 kBytesPerFrame = sizeof(float) * kChannels;
constexpr AudioObjectPropertySelector kAppMixerPropertyBundleGains = 'amgn';

AudioServerPlugInHostRef gHost = nullptr;
std::mutex gStateMutex;
std::map<UInt32, std::string> gClientBundles;
std::map<std::string, float> gBundleGains;
UInt64 gSampleTime = 0;
UInt64 gSeed = 1;
UInt32 gRefCount = 1;

CFStringRef CopyString(const char* value) {
    return CFStringCreateWithCString(kCFAllocatorDefault, value, kCFStringEncodingUTF8);
}

bool IsDevice(AudioObjectID objectID) {
    return objectID == kObjectDevice;
}

bool IsStream(AudioObjectID objectID) {
    return objectID == kObjectStream;
}

float GainForClient(UInt32 clientID) {
    std::lock_guard<std::mutex> lock(gStateMutex);
    auto bundle = gClientBundles.find(clientID);
    if (bundle == gClientBundles.end()) {
        return 1.0f;
    }
    auto gain = gBundleGains.find(bundle->second);
    return gain == gBundleGains.end() ? 1.0f : gain->second;
}

void ApplyGain(void* buffer, UInt32 frames, float gain) {
    if (buffer == nullptr || gain == 1.0f) {
        return;
    }
    float* samples = static_cast<float*>(buffer);
    for (UInt32 i = 0; i < frames * kChannels; ++i) {
        samples[i] *= gain;
    }
}

HRESULT QueryInterface(void*, REFIID uuid, LPVOID* outInterface);
ULONG AddRef(void*);
ULONG Release(void*);
OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef host);
OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
OSStatus IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
OSStatus GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
OSStatus SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

AudioServerPlugInDriverInterface gInterface = {
    nullptr,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation
};

AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;

HRESULT QueryInterface(void*, REFIID uuid, LPVOID* outInterface) {
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(nullptr, uuid);
    Boolean isDriver = CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    Boolean isIUnknown = CFEqual(requested, IUnknownUUID);
    CFRelease(requested);
    if (!isDriver && !isIUnknown) {
        *outInterface = nullptr;
        return E_NOINTERFACE;
    }
    AddRef(nullptr);
    *outInterface = &gInterfacePtr;
    return S_OK;
}

ULONG AddRef(void*) {
    return ++gRefCount;
}

ULONG Release(void*) {
    return --gRefCount;
}

OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef host) {
    gHost = host;
    return noErr;
}

OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID* outDeviceObjectID) {
    if (outDeviceObjectID != nullptr) {
        *outDeviceObjectID = kObjectDevice;
    }
    return noErr;
}

OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID) { return noErr; }

OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo* client) {
    if (client == nullptr) { return noErr; }
    std::lock_guard<std::mutex> lock(gStateMutex);
    if (client->mBundleID != nullptr) {
        char buffer[1024] = {};
        CFStringGetCString(client->mBundleID, buffer, sizeof(buffer), kCFStringEncodingUTF8);
        gClientBundles[client->mClientID] = buffer;
    } else {
        gClientBundles[client->mClientID] = "pid." + std::to_string(client->mProcessID);
    }
    return noErr;
}

OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo* client) {
    if (client == nullptr) { return noErr; }
    std::lock_guard<std::mutex> lock(gStateMutex);
    gClientBundles.erase(client->mClientID);
    return noErr;
}

OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*) { return noErr; }
OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*) { return noErr; }

Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID objectID, pid_t, const AudioObjectPropertyAddress* address) {
    if (address == nullptr) { return false; }
    switch (address->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyCustomPropertyInfoList:
            return true;
        case kAppMixerPropertyBundleGains:
            return IsDevice(objectID);
        case kAudioPlugInPropertyDeviceList:
            return objectID == kObjectPlugIn;
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyStreamConfiguration:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyBufferFrameSizeRange:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return IsDevice(objectID);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyTerminalType:
            return IsStream(objectID);
        default:
            return false;
    }
}

OSStatus IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress* address, Boolean* outIsSettable) {
    if (outIsSettable == nullptr || address == nullptr) { return kAudioHardwareBadPropertySizeError; }
    *outIsSettable = address->mSelector == kAudioDevicePropertyBufferFrameSize || address->mSelector == kAppMixerPropertyBundleGains;
    return noErr;
}

OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t pid, const AudioObjectPropertyAddress* address, UInt32 qualifierSize, const void* qualifier, UInt32* outSize) {
    if (outSize == nullptr || address == nullptr) { return kAudioHardwareBadPropertySizeError; }
    switch (address->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outSize = sizeof(CFStringRef);
            return noErr;
        case kAudioPlugInPropertyDeviceList:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            *outSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyClass:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyTerminalType:
            *outSize = sizeof(UInt32);
            return noErr;
        case kAudioObjectPropertyCustomPropertyInfoList:
            *outSize = sizeof(AudioServerPlugInCustomPropertyInfo);
            return noErr;
        case kAppMixerPropertyBundleGains:
            *outSize = sizeof(CFPropertyListRef);
            return noErr;
        case kAudioDevicePropertyNominalSampleRate:
            *outSize = sizeof(Float64);
            return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyBufferFrameSizeRange:
            *outSize = sizeof(AudioValueRange);
            return noErr;
        case kAudioDevicePropertyStreamConfiguration:
            *outSize = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
            return noErr;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outSize = sizeof(AudioStreamBasicDescription);
            return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outSize = sizeof(AudioStreamRangedDescription);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

AudioStreamBasicDescription StreamFormat() {
    AudioStreamBasicDescription format = {};
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = kBytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kBytesPerFrame;
    format.mChannelsPerFrame = kChannels;
    format.mBitsPerChannel = 32;
    return format;
}

OSStatus GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID objectID, pid_t, const AudioObjectPropertyAddress* address, UInt32, const void*, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (address == nullptr || outDataSize == nullptr || outData == nullptr) { return kAudioHardwareBadPropertySizeError; }
    switch (address->mSelector) {
        case kAudioObjectPropertyName: {
            CFStringRef value = CopyString(IsDevice(objectID) ? "AppMixer Virtual Output" : "AppMixer HAL Plug-In");
            *static_cast<CFStringRef*>(outData) = value;
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        }
        case kAudioObjectPropertyManufacturer: {
            *static_cast<CFStringRef*>(outData) = CopyString("Clarity");
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        }
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID: {
            *static_cast<CFStringRef*>(outData) = CopyString("com.clarity.appmixer.virtual-output");
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        }
        case kAudioPlugInPropertyDeviceList:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            *static_cast<AudioObjectID*>(outData) = address->mSelector == kAudioDevicePropertyStreams ? kObjectStream : kObjectDevice;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyClass:
            *static_cast<AudioClassID*>(outData) = IsDevice(objectID) ? kAudioDeviceClassID : IsStream(objectID) ? kAudioStreamClassID : kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo info = {};
            info.mSelector = kAppMixerPropertyBundleGains;
            info.mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
            info.mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
            *static_cast<AudioServerPlugInCustomPropertyInfo*>(outData) = info;
            *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
            return noErr;
        }
        case kAppMixerPropertyBundleGains: {
            CFMutableDictionaryRef dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            {
                std::lock_guard<std::mutex> lock(gStateMutex);
                for (const auto& entry : gBundleGains) {
                    CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, entry.first.c_str(), kCFStringEncodingUTF8);
                    CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &entry.second);
                    CFDictionarySetValue(dict, key, value);
                    CFRelease(key);
                    CFRelease(value);
                }
            }
            *static_cast<CFPropertyListRef*>(outData) = dict;
            *outDataSize = sizeof(CFPropertyListRef);
            return noErr;
        }
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
            *static_cast<UInt32*>(outData) = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            *static_cast<UInt32*>(outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyBufferFrameSize:
            *static_cast<UInt32*>(outData) = 512;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyTransportType:
            *static_cast<UInt32*>(outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *static_cast<UInt32*>(outData) = 512;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyNominalSampleRate:
            *static_cast<Float64*>(outData) = kSampleRate;
            *outDataSize = sizeof(Float64);
            return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyBufferFrameSizeRange: {
            AudioValueRange range = { kSampleRate, kSampleRate };
            if (address->mSelector == kAudioDevicePropertyBufferFrameSizeRange) {
                range.mMinimum = 128;
                range.mMaximum = 2048;
            }
            *static_cast<AudioValueRange*>(outData) = range;
            *outDataSize = sizeof(AudioValueRange);
            return noErr;
        }
        case kAudioDevicePropertyStreamConfiguration: {
            if (inDataSize < offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer)) {
                return kAudioHardwareBadPropertySizeError;
            }
            AudioBufferList* list = static_cast<AudioBufferList*>(outData);
            list->mNumberBuffers = 1;
            list->mBuffers[0].mNumberChannels = kChannels;
            list->mBuffers[0].mDataByteSize = 0;
            list->mBuffers[0].mData = nullptr;
            *outDataSize = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
            return noErr;
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *static_cast<AudioStreamBasicDescription*>(outData) = StreamFormat();
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription desc = {};
            desc.mFormat = StreamFormat();
            desc.mSampleRateRange.mMinimum = kSampleRate;
            desc.mSampleRateRange.mMaximum = kSampleRate;
            *static_cast<AudioStreamRangedDescription*>(outData) = desc;
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return noErr;
        }
        case kAudioStreamPropertyDirection:
            *static_cast<UInt32*>(outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyStartingChannel:
            *static_cast<UInt32*>(outData) = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyTerminalType:
            *static_cast<UInt32*>(outData) = kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress* address, UInt32, const void*, UInt32 inDataSize, const void* inData) {
    if (address == nullptr) {
        return kAudioHardwareUnknownPropertyError;
    }
    if (address->mSelector == kAudioDevicePropertyBufferFrameSize) {
        return noErr;
    }
    if (address->mSelector == kAppMixerPropertyBundleGains) {
        if (inDataSize != sizeof(CFPropertyListRef) || inData == nullptr) {
            return kAudioHardwareBadPropertySizeError;
        }
        CFDictionaryRef dict = *static_cast<CFDictionaryRef const*>(inData);
        if (dict == nullptr || CFGetTypeID(dict) != CFDictionaryGetTypeID()) {
            return kAudioHardwareIllegalOperationError;
        }
        std::lock_guard<std::mutex> lock(gStateMutex);
        gBundleGains.clear();
        CFIndex count = CFDictionaryGetCount(dict);
        std::vector<const void*> keys(count);
        std::vector<const void*> values(count);
        CFDictionaryGetKeysAndValues(dict, keys.data(), values.data());
        for (CFIndex i = 0; i < count; ++i) {
            if (CFGetTypeID(keys[i]) != CFStringGetTypeID() || CFGetTypeID(values[i]) != CFNumberGetTypeID()) {
                continue;
            }
            char key[1024] = {};
            float value = 1.0f;
            CFStringGetCString(static_cast<CFStringRef>(keys[i]), key, sizeof(key), kCFStringEncodingUTF8);
            CFNumberGetValue(static_cast<CFNumberRef>(values[i]), kCFNumberFloatType, &value);
            gBundleGains[key] = value;
        }
        return noErr;
    }
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32) { return noErr; }
OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32) { return noErr; }

OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    if (outSampleTime == nullptr || outHostTime == nullptr || outSeed == nullptr) { return kAudioHardwareBadPropertySizeError; }
    gSampleTime += 512;
    *outSampleTime = static_cast<Float64>(gSampleTime);
    *outHostTime = mach_absolute_time();
    *outSeed = gSeed;
    return noErr;
}

OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    if (outWillDo == nullptr || outWillDoInPlace == nullptr) { return kAudioHardwareBadPropertySizeError; }
    *outWillDo = operationID == kAudioServerPlugInIOOperationMixOutput || operationID == kAudioServerPlugInIOOperationProcessMix;
    *outWillDoInPlace = true;
    return noErr;
}

OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*) { return noErr; }

OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32 clientID, UInt32 operationID, UInt32 frameCount, const AudioServerPlugInIOCycleInfo*, void* ioMainBuffer, void*) {
    if (operationID == kAudioServerPlugInIOOperationMixOutput || operationID == kAudioServerPlugInIOOperationProcessMix) {
        ApplyGain(ioMainBuffer, frameCount, GainForClient(clientID));
    }
    return noErr;
}

OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*) { return noErr; }

} // namespace

extern "C" void* AudioServerPlugInMain(CFAllocatorRef, CFUUIDRef requestedTypeUUID) {
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return &gInterfacePtr;
    }
    return nullptr;
}
