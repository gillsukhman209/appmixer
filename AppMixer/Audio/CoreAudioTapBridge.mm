#import "CoreAudioTapBridge.h"

#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <atomic>
#import <mutex>
#import <vector>

static NSString *const AMTapErrorDomain = @"com.clarity.appmixer.tap";

static NSError *AMError(OSStatus status, NSString *message) {
    return [NSError errorWithDomain:AMTapErrorDomain
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (%d)", message, status]}];
}

static OSStatus CopyTapUID(AudioObjectID tapID, CFStringRef *outUID);

static NSString *AMKey(const char *key) {
    return [NSString stringWithUTF8String:key];
}

class AMFloatRingBuffer {
public:
    explicit AMFloatRingBuffer(size_t capacityFrames = 48000 * 4)
    : _capacityFrames(capacityFrames), _samples(capacityFrames * 2, 0.0f) {}

    void write(const AudioBufferList *input, UInt32 frameCount, float gain) {
        if (input == nullptr || frameCount == 0) { return; }
        _totalInputFrames += frameCount;
        if (gain <= 0.0f) { return; }
        std::lock_guard<std::mutex> lock(_mutex);

        for (UInt32 frame = 0; frame < frameCount; ++frame) {
            float left = 0.0f;
            float right = 0.0f;

            if (input->mNumberBuffers == 1 && input->mBuffers[0].mData != nullptr) {
                const float *samples = static_cast<const float *>(input->mBuffers[0].mData);
                UInt32 channels = input->mBuffers[0].mNumberChannels;
                left = samples[frame * channels] * gain;
                right = channels > 1 ? samples[(frame * channels) + 1] * gain : left;
            } else if (input->mNumberBuffers >= 2 &&
                       input->mBuffers[0].mData != nullptr &&
                       input->mBuffers[1].mData != nullptr) {
                const float *leftSamples = static_cast<const float *>(input->mBuffers[0].mData);
                const float *rightSamples = static_cast<const float *>(input->mBuffers[1].mData);
                left = leftSamples[frame] * gain;
                right = rightSamples[frame] * gain;
            }

            _samples[(_writeFrame * 2) % _samples.size()] = left;
            _samples[((_writeFrame * 2) + 1) % _samples.size()] = right;
            _writeFrame = (_writeFrame + 1) % _capacityFrames;
            if (_availableFrames < _capacityFrames) {
                ++_availableFrames;
            } else {
                _readFrame = (_readFrame + 1) % _capacityFrames;
            }
        }
    }

    void mixInto(AudioBufferList *output, UInt32 frameCount) {
        if (output == nullptr || frameCount == 0) { return; }
        std::lock_guard<std::mutex> lock(_mutex);

        for (UInt32 frame = 0; frame < frameCount && _availableFrames > 0; ++frame) {
            float left = _samples[(_readFrame * 2) % _samples.size()];
            float right = _samples[((_readFrame * 2) + 1) % _samples.size()];
            _readFrame = (_readFrame + 1) % _capacityFrames;
            --_availableFrames;

            if (output->mNumberBuffers == 1 && output->mBuffers[0].mData != nullptr) {
                float *samples = static_cast<float *>(output->mBuffers[0].mData);
                UInt32 channels = output->mBuffers[0].mNumberChannels;
                samples[frame * channels] += left;
                if (channels > 1) {
                    samples[(frame * channels) + 1] += right;
                }
            } else if (output->mNumberBuffers >= 2 &&
                       output->mBuffers[0].mData != nullptr &&
                       output->mBuffers[1].mData != nullptr) {
                static_cast<float *>(output->mBuffers[0].mData)[frame] += left;
                static_cast<float *>(output->mBuffers[1].mData)[frame] += right;
            }
        }
    }

    uint64_t totalInputFrames() const { return _totalInputFrames.load(); }

private:
    std::mutex _mutex;
    size_t _capacityFrames;
    std::vector<float> _samples;
    size_t _writeFrame = 0;
    size_t _readFrame = 0;
    size_t _availableFrames = 0;
    std::atomic<uint64_t> _totalInputFrames = 0;
};

@class AMCoreAudioTapMixer;

@interface AMProcessTap : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic) float volume;
@property (nonatomic) BOOL muted;
@property (nonatomic) AudioObjectID outputDeviceID;
@property (nonatomic, readonly) AMFloatRingBuffer *ringBuffer;
@property (nonatomic, readonly) NSString *diagnosticSummary;
- (instancetype)initWithProcessObjectID:(AudioObjectID)processObjectID
                                    pid:(pid_t)pid
                       bundleIdentifier:(NSString *)bundleIdentifier
                                  mixer:(AMCoreAudioTapMixer *)mixer;
- (BOOL)start:(NSError **)error;
- (void)stop;
@end

@interface AMOutputRenderer : NSObject
@property (nonatomic, readonly) AudioObjectID deviceID;
- (instancetype)initWithDeviceID:(AudioObjectID)deviceID mixer:(AMCoreAudioTapMixer *)mixer;
- (BOOL)start:(NSError **)error;
- (void)stop;
@end

@interface AMCoreAudioTapMixer ()
@property (nonatomic) BOOL running;
- (void)renderIntoBufferList:(AudioBufferList *)bufferList frameCount:(UInt32)frameCount outputDeviceID:(AudioObjectID)outputDeviceID;
@end

@implementation AMCoreAudioTapMixer {
    AudioObjectID _defaultOutputDeviceID;
    NSMutableDictionary<NSString *, AMProcessTap *> *_taps;
    NSMutableDictionary<NSNumber *, AMOutputRenderer *> *_renderers;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _taps = [NSMutableDictionary dictionary];
        _renderers = [NSMutableDictionary dictionary];
        _masterVolume = 1.0f;
    }
    return self;
}

- (BOOL)startWithOutputDeviceID:(AudioObjectID)outputDeviceID error:(NSError **)error {
    if (@available(macOS 14.2, *)) {
        if (_running) { return YES; }
        _defaultOutputDeviceID = outputDeviceID;
        if (![self ensureRendererForOutputDeviceID:outputDeviceID error:error]) {
            return NO;
        }
        _running = YES;
        return YES;
    } else {
        if (error) { *error = AMError(kAudioHardwareUnsupportedOperationError, @"Process taps require macOS 14.2 or later"); }
        return NO;
    }
}

- (void)stop {
    for (AMProcessTap *tap in _taps.allValues) {
        [tap stop];
    }
    [_taps removeAllObjects];

    for (AMOutputRenderer *renderer in _renderers.allValues) {
        [renderer stop];
    }
    [_renderers removeAllObjects];
    _running = NO;
}

- (BOOL)setOutputDeviceID:(AudioObjectID)outputDeviceID error:(NSError **)error {
    _defaultOutputDeviceID = outputDeviceID;
    if (_running && ![self ensureRendererForOutputDeviceID:outputDeviceID error:error]) { return NO; }
    return YES;
}

- (BOOL)setOutputDeviceID:(AudioObjectID)outputDeviceID
      forBundleIdentifier:(NSString *)bundleIdentifier
                    error:(NSError **)error {
    if (_running && ![self ensureRendererForOutputDeviceID:outputDeviceID error:error]) { return NO; }
    @synchronized (self) {
        AMProcessTap *tap = _taps[bundleIdentifier];
        if (tap == nil) { return YES; }
        tap.outputDeviceID = outputDeviceID;
    }
    return YES;
}

- (BOOL)upsertProcessTapWithProcessObjectID:(AudioObjectID)processObjectID
                                        pid:(pid_t)pid
                           bundleIdentifier:(NSString *)bundleIdentifier
                                     volume:(float)volume
                                      muted:(BOOL)muted
                             outputDeviceID:(AudioObjectID)outputDeviceID
                                      error:(NSError **)error {
    if (_running && ![self ensureRendererForOutputDeviceID:outputDeviceID error:error]) { return NO; }
    AMProcessTap *tap = nil;
    BOOL shouldStart = NO;
    @synchronized (self) {
        tap = _taps[bundleIdentifier];
        if (tap == nil) {
            tap = [[AMProcessTap alloc] initWithProcessObjectID:processObjectID pid:pid bundleIdentifier:bundleIdentifier mixer:self];
            _taps[bundleIdentifier] = tap;
            shouldStart = YES;
        }
        tap.volume = volume;
        tap.muted = muted;
        tap.outputDeviceID = outputDeviceID;
    }
    if (shouldStart) {
        BOOL started = [tap start:error];
        if (!started) {
            @synchronized (self) {
                if (_taps[bundleIdentifier] == tap) {
                    [_taps removeObjectForKey:bundleIdentifier];
                }
            }
        }
        return started;
    }
    return YES;
}

- (void)removeMissingBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers {
    NSSet *live = [NSSet setWithArray:bundleIdentifiers];
    NSMutableArray<AMProcessTap *> *stoppedTaps = [NSMutableArray array];
    @synchronized (self) {
        for (NSString *bundleID in _taps.allKeys) {
            if (![live containsObject:bundleID]) {
                [stoppedTaps addObject:_taps[bundleID]];
                [_taps removeObjectForKey:bundleID];
            }
        }
    }
    for (AMProcessTap *tap in stoppedTaps) {
        [tap stop];
    }
}

- (void)setVolume:(float)volume forBundleIdentifier:(NSString *)bundleIdentifier {
    @synchronized (self) {
        _taps[bundleIdentifier].volume = volume;
    }
}

- (void)setMuted:(BOOL)muted forBundleIdentifier:(NSString *)bundleIdentifier {
    @synchronized (self) {
        _taps[bundleIdentifier].muted = muted;
    }
}

- (BOOL)ensureRendererForOutputDeviceID:(AudioObjectID)outputDeviceID error:(NSError **)error {
    if (outputDeviceID == kAudioObjectUnknown) {
        if (error) { *error = AMError(kAudioHardwareBadObjectError, @"No output device selected"); }
        return NO;
    }
    NSNumber *key = @(outputDeviceID);
    if (_renderers[key] != nil) { return YES; }

    AMOutputRenderer *renderer = [[AMOutputRenderer alloc] initWithDeviceID:outputDeviceID mixer:self];
    if (![renderer start:error]) { return NO; }
    _renderers[key] = renderer;
    return YES;
}

- (NSString *)diagnosticSummary {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSArray<AMProcessTap *> *taps = nil;
    @synchronized (self) {
        taps = _taps.allValues;
    }
    for (AMProcessTap *tap in taps) {
        [parts addObject:tap.diagnosticSummary];
    }
    return parts.count == 0 ? @"No process taps are active." : [parts componentsJoinedByString:@"\n"];
}

- (void)renderIntoBufferList:(AudioBufferList *)bufferList frameCount:(UInt32)frameCount outputDeviceID:(AudioObjectID)outputDeviceID {
    if (bufferList == nullptr) { return; }
    for (UInt32 buffer = 0; buffer < bufferList->mNumberBuffers; ++buffer) {
        if (bufferList->mBuffers[buffer].mData != nullptr) {
            memset(bufferList->mBuffers[buffer].mData, 0, bufferList->mBuffers[buffer].mDataByteSize);
        }
    }

    NSArray<AMProcessTap *> *taps = nil;
    @synchronized (self) {
        taps = _taps.allValues;
    }
    for (AMProcessTap *tap in taps) {
        if (tap.outputDeviceID != outputDeviceID) { continue; }
        tap.ringBuffer->mixInto(bufferList, frameCount);
    }
}

@end

static OSStatus OutputRenderProc(void *inRefCon,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp,
                                 UInt32 inBusNumber,
                                 UInt32 inNumberFrames,
                                 AudioBufferList *ioData);

@implementation AMOutputRenderer {
    __weak AMCoreAudioTapMixer *_mixer;
    AudioUnit _outputUnit;
}

- (instancetype)initWithDeviceID:(AudioObjectID)deviceID mixer:(AMCoreAudioTapMixer *)mixer {
    self = [super init];
    if (self) {
        _deviceID = deviceID;
        _mixer = mixer;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)start:(NSError **)error {
    if (_outputUnit != nullptr) { return YES; }

    AudioComponentDescription description = {};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_HALOutput;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (component == nullptr) {
        if (error) { *error = AMError(kAudioHardwareUnspecifiedError, @"HAL output audio unit not found"); }
        return NO;
    }

    OSStatus status = AudioComponentInstanceNew(component, &_outputUnit);
    if (status != noErr) {
        if (error) { *error = AMError(status, @"Failed to create output audio unit"); }
        return NO;
    }

    UInt32 enable = 1;
    status = AudioUnitSetProperty(_outputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, sizeof(enable));
    if (status != noErr) {
        if (error) { *error = AMError(status, @"Failed to enable audio output"); }
        [self stop];
        return NO;
    }

    AudioObjectID mutableDeviceID = _deviceID;
    status = AudioUnitSetProperty(_outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, sizeof(mutableDeviceID));
    if (status != noErr) {
        if (error) { *error = AMError(status, @"Failed to select output device"); }
        [self stop];
        return NO;
    }

    AudioStreamBasicDescription format = {};
    format.mSampleRate = 48000.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = sizeof(float) * 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(float) * 2;
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 32;
    status = AudioUnitSetProperty(_outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
    if (status != noErr) {
        if (error) { *error = AMError(status, @"Failed to set output stream format"); }
        [self stop];
        return NO;
    }

    AURenderCallbackStruct callback = {};
    callback.inputProc = OutputRenderProc;
    callback.inputProcRefCon = (__bridge void *)self;
    status = AudioUnitSetProperty(_outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    if (status != noErr) {
        if (error) { *error = AMError(status, @"Failed to install render callback"); }
        [self stop];
        return NO;
    }

    status = AudioUnitInitialize(_outputUnit);
    if (status != noErr) {
        if (error) { *error = AMError(status, @"Failed to initialize output audio unit"); }
        [self stop];
        return NO;
    }

    status = AudioOutputUnitStart(_outputUnit);
    if (status != noErr) {
        if (error) { *error = AMError(status, @"Failed to start output audio unit"); }
        [self stop];
        return NO;
    }

    return YES;
}

- (void)stop {
    if (_outputUnit != nullptr) {
        AudioOutputUnitStop(_outputUnit);
        AudioUnitUninitialize(_outputUnit);
        AudioComponentInstanceDispose(_outputUnit);
        _outputUnit = nullptr;
    }
}

static OSStatus OutputRenderProc(void *inRefCon,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp,
                                 UInt32 inBusNumber,
                                 UInt32 inNumberFrames,
                                 AudioBufferList *ioData) {
    (void)ioActionFlags;
    (void)inTimeStamp;
    (void)inBusNumber;
    AMOutputRenderer *renderer = (__bridge AMOutputRenderer *)inRefCon;
    [renderer->_mixer renderIntoBufferList:ioData frameCount:inNumberFrames outputDeviceID:renderer.deviceID];
    return noErr;
}

@end

@implementation AMProcessTap {
    AudioObjectID _processObjectID;
    pid_t _pid;
    __weak AMCoreAudioTapMixer *_mixer;
    AudioObjectID _tapID;
    AudioObjectID _aggregateDeviceID;
    AudioDeviceIOProcID _ioProcID;
    NSUUID *_uuid;
    AMFloatRingBuffer *_ringBuffer;
    std::atomic<uint64_t> _callbacks;
    std::atomic<uint64_t> _bytes;
    std::atomic<uint32_t> _lastFrames;
}

- (instancetype)initWithProcessObjectID:(AudioObjectID)processObjectID
                                    pid:(pid_t)pid
                       bundleIdentifier:(NSString *)bundleIdentifier
                                  mixer:(AMCoreAudioTapMixer *)mixer {
    self = [super init];
    if (self) {
        _processObjectID = processObjectID;
        _pid = pid;
        _bundleIdentifier = [bundleIdentifier copy];
        _mixer = mixer;
        _tapID = kAudioObjectUnknown;
        _aggregateDeviceID = kAudioObjectUnknown;
        _uuid = [NSUUID UUID];
        _ringBuffer = new AMFloatRingBuffer();
        _callbacks.store(0);
        _bytes.store(0);
        _lastFrames.store(0);
        _volume = 1.0f;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    delete _ringBuffer;
}

- (BOOL)start:(NSError **)error {
    if (@available(macOS 14.2, *)) {
        CATapDescription *description = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[@(_processObjectID)]];
        description.name = [NSString stringWithFormat:@"AppMixer %@", _bundleIdentifier];
        description.UUID = _uuid;
        description.privateTap = YES;
        description.muteBehavior = CATapMutedWhenTapped;

        OSStatus status = AudioHardwareCreateProcessTap(description, &_tapID);
        if (status != noErr) {
            if (error) { *error = AMError(status, @"Failed to create process tap"); }
            return NO;
        }

        CFStringRef tapUID = nullptr;
        status = CopyTapUID(_tapID, &tapUID);
        if (status != noErr || tapUID == nullptr) {
            if (error) { *error = AMError(status, @"Failed to read process tap UID"); }
            [self stop];
            return NO;
        }

        NSDictionary *aggregate = @{
            AMKey(kAudioAggregateDeviceNameKey): [NSString stringWithFormat:@"AppMixer Tap %@", _bundleIdentifier],
            AMKey(kAudioAggregateDeviceUIDKey): [NSString stringWithFormat:@"com.clarity.appmixer.tap.%@", _uuid.UUIDString],
            AMKey(kAudioAggregateDeviceIsPrivateKey): @YES,
            AMKey(kAudioAggregateDeviceTapAutoStartKey): @YES,
            AMKey(kAudioAggregateDeviceTapListKey): @[
                @{ AMKey(kAudioSubTapUIDKey): (__bridge NSString *)tapUID }
            ]
        };

        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &_aggregateDeviceID);
        CFRelease(tapUID);
        if (status != noErr) {
            if (error) { *error = AMError(status, @"Failed to create private aggregate tap device"); }
            [self stop];
            return NO;
        }

        status = AudioDeviceCreateIOProcID(_aggregateDeviceID, TapIOProc, (__bridge void *)self, &_ioProcID);
        if (status != noErr) {
            if (error) { *error = AMError(status, @"Failed to create tap IOProc"); }
            [self stop];
            return NO;
        }

        status = AudioDeviceStart(_aggregateDeviceID, _ioProcID);
        if (status != noErr) {
            if (error) { *error = AMError(status, @"Failed to start process tap"); }
            [self stop];
            return NO;
        }
        return YES;
    } else {
        if (error) { *error = AMError(kAudioHardwareUnsupportedOperationError, @"Process taps require macOS 14.2 or later"); }
        return NO;
    }
}

- (void)stop {
    if (_aggregateDeviceID != kAudioObjectUnknown && _ioProcID != nullptr) {
        AudioDeviceStop(_aggregateDeviceID, _ioProcID);
        AudioDeviceDestroyIOProcID(_aggregateDeviceID, _ioProcID);
        _ioProcID = nullptr;
    }
    if (_aggregateDeviceID != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(_aggregateDeviceID);
        _aggregateDeviceID = kAudioObjectUnknown;
    }
    if (_tapID != kAudioObjectUnknown) {
        if (@available(macOS 14.2, *)) {
            AudioHardwareDestroyProcessTap(_tapID);
        }
        _tapID = kAudioObjectUnknown;
    }
}

- (NSString *)diagnosticSummary {
    return [NSString stringWithFormat:@"%@ callbacks=%llu lastFrames=%u inputFrames=%llu bytes=%llu",
            _bundleIdentifier,
            _callbacks.load(),
            _lastFrames.load(),
            _ringBuffer->totalInputFrames(),
            _bytes.load()];
}

static OSStatus CopyTapUID(AudioObjectID tapID, CFStringRef *outUID) {
    if (outUID == nullptr) { return kAudioHardwareBadPropertySizeError; }
    AudioObjectPropertyAddress address = {
        kAudioTapPropertyUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = UInt32(sizeof(CFStringRef));
    return AudioObjectGetPropertyData(tapID, &address, 0, nullptr, &size, outUID);
}

static OSStatus TapIOProc(AudioObjectID inDevice,
                          const AudioTimeStamp *inNow,
                          const AudioBufferList *inInputData,
                          const AudioTimeStamp *inInputTime,
                          AudioBufferList *outOutputData,
                          const AudioTimeStamp *inOutputTime,
                          void *inClientData) {
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)outOutputData;
    (void)inOutputTime;

    AMProcessTap *tap = (__bridge AMProcessTap *)inClientData;
    AMCoreAudioTapMixer *mixer = tap->_mixer;
    float gain = tap.muted ? 0.0f : tap.volume * mixer.masterVolume;

    UInt32 frames = 0;
    if (inInputData != nullptr && inInputData->mNumberBuffers > 0 && inInputData->mBuffers[0].mDataByteSize > 0) {
        UInt32 channels = MAX(inInputData->mBuffers[0].mNumberChannels, 1);
        frames = inInputData->mBuffers[0].mDataByteSize / (sizeof(float) * channels);
        UInt64 bytes = 0;
        for (UInt32 bufferIndex = 0; bufferIndex < inInputData->mNumberBuffers; ++bufferIndex) {
            bytes += inInputData->mBuffers[bufferIndex].mDataByteSize;
        }
        tap->_bytes += bytes;
    }
    tap->_callbacks++;
    tap->_lastFrames = frames;
    tap.ringBuffer->write(inInputData, frames, gain);
    return noErr;
}

@end
