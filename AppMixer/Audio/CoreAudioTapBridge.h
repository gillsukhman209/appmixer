#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMCoreAudioTapMixer : NSObject

@property (nonatomic, readonly) BOOL running;
@property (nonatomic) float masterVolume;
@property (nonatomic, readonly) NSString *diagnosticSummary;

- (BOOL)startWithOutputDeviceID:(AudioObjectID)outputDeviceID error:(NSError **)error;
- (void)stop;
- (BOOL)setOutputDeviceID:(AudioObjectID)outputDeviceID error:(NSError **)error;
- (BOOL)setOutputDeviceID:(AudioObjectID)outputDeviceID
      forBundleIdentifier:(NSString *)bundleIdentifier
                    error:(NSError **)error;
- (BOOL)upsertProcessTapWithProcessObjectID:(AudioObjectID)processObjectID
                                        pid:(pid_t)pid
                           bundleIdentifier:(NSString *)bundleIdentifier
                                     volume:(float)volume
                                      muted:(BOOL)muted
                             outputDeviceID:(AudioObjectID)outputDeviceID
                                      error:(NSError **)error;
- (void)removeMissingBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers;
- (void)setVolume:(float)volume forBundleIdentifier:(NSString *)bundleIdentifier;
- (void)setMuted:(BOOL)muted forBundleIdentifier:(NSString *)bundleIdentifier;

@end

NS_ASSUME_NONNULL_END
