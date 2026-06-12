#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <ReactCommon/RCTTurboModule.h>

// Codegen JSI spec for codegenConfig name `RNStandaloneVideoPlayerSpec`.
// BUILD-VERIFY: generated under build/generated/ios/RNStandaloneVideoPlayerSpec/.
#import <RNStandaloneVideoPlayerSpec/RNStandaloneVideoPlayerSpec.h>

// Exposes the Swift `StandaloneVideoPlayer` (RCTEventEmitter subclass) methods to ObjC.
// The TurboModule glue below provides the C++ JSI binding so the module loads on the
// new architecture (RN 0.85 removed the legacy module-interop layer).
@interface RCT_EXTERN_MODULE(StandaloneVideoPlayer, RCTEventEmitter)

RCT_EXTERN_METHOD(newInstance)
RCT_EXTERN_METHOD(load:(NSInteger)instance url:(NSString *)url isHls:(BOOL)isHls loop:(BOOL)loop isSilent:(BOOL)silent initialTime:(NSInteger)initialTime)
RCT_EXTERN_METHOD(seek:(NSInteger)instance position:(double)position)
RCT_EXTERN_METHOD(seekForward:(NSInteger)instance time:(double)time)
RCT_EXTERN_METHOD(seekRewind:(NSInteger)instance time:(double)time)
RCT_EXTERN_METHOD(setMuted:(NSInteger)instance isMuted:(BOOL)isMuted)
RCT_EXTERN_METHOD(getMuted:(NSInteger)instance resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(play:(NSInteger)instance)
RCT_EXTERN_METHOD(pause:(NSInteger)instance)
RCT_EXTERN_METHOD(stop:(NSInteger)instance)
RCT_EXTERN_METHOD(unload:(NSInteger)instance)
RCT_EXTERN_METHOD(refreshCompositor:(NSInteger)instance)
RCT_EXTERN_METHOD(clear)
RCT_EXTERN_METHOD(getDuration:(NSInteger)instance resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(getProgress:(NSInteger)instance resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)

// RCTEventEmitter requires these to satisfy the NativeEventEmitter contract; the Swift
// base class implements them.
RCT_EXTERN_METHOD(addListener:(NSString *)eventName)
RCT_EXTERN_METHOD(removeListeners:(double)count)

@end

// TurboModule conformance: hand the runtime the generated C++ JSI binding. RN looks up
// `getTurboModule:` on the module class when registering on the new architecture.
@interface StandaloneVideoPlayer (RCTTurboModule) <RCTTurboModule>
@end

@implementation StandaloneVideoPlayer (RCTTurboModule)

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeStandaloneVideoPlayerSpecJSI>(params);
}

@end
