#import <Foundation/Foundation.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE(StandaloneVideoPlayer, RCTEventEmitter)

RCT_EXTERN_METHOD(newInstance);

RCT_EXTERN_METHOD(load: (NSInteger)instance withUrl: (NSString*)url withHls: (BOOL)isHls withLoop: (BOOL)loop withSilent: (BOOL)silent);

RCT_EXTERN_METHOD(seek: (NSInteger)instance toPosition: (nonnull double*)position);

RCT_EXTERN_METHOD(seekForward: (NSInteger)instance withTime: (nonnull double*)time);

RCT_EXTERN_METHOD(seekRewind: (NSInteger)instance withTime: (nonnull double*)time);

RCT_EXTERN_METHOD(setVolume: (NSInteger)instance volume: (float)volume)

RCT_EXTERN_METHOD(play: (NSInteger)instance);

RCT_EXTERN_METHOD(pause: (NSInteger)instance);

RCT_EXTERN_METHOD(stop: (NSInteger)instance);

RCT_EXTERN_METHOD(getDuration: (NSInteger)instance
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject);

RCT_EXTERN_METHOD(clear);


@end
