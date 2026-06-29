#import <React/RCTViewComponentView.h>

NS_ASSUME_NONNULL_BEGIN

// Fabric component view for `RNTPlayerVideoView` (see src/PlayerVideoNativeComponent.ts).
// Replaces the legacy `RNTPlayerVideoViewManager` (RCTViewManager) — that path is gone
// in RN 0.85 (no component-view interop). Hosts the existing Swift `PlayerVideoView`
// (AVPlayerLayer + reveal-gating) as its contentView and forwards the two props.
@interface RNTPlayerVideoViewComponentView : RCTViewComponentView
@end

NS_ASSUME_NONNULL_END
