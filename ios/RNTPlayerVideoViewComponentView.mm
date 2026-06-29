#import "RNTPlayerVideoViewComponentView.h"

// Codegen output for codegenConfig name `RNStandaloneVideoPlayerSpec`.
// BUILD-VERIFY: the exact umbrella path is generated under
// build/generated/ios/react/renderer/components/RNStandaloneVideoPlayerSpec/.
#import <react/renderer/components/RNStandaloneVideoPlayerSpec/ComponentDescriptors.h>
#import <react/renderer/components/RNStandaloneVideoPlayerSpec/EventEmitters.h>
#import <react/renderer/components/RNStandaloneVideoPlayerSpec/Props.h>
#import <react/renderer/components/RNStandaloneVideoPlayerSpec/RCTComponentViewHelpers.h>

#import <React/RCTConversions.h>

// Swift umbrella header. BUILD-VERIFY: CocoaPods derives the module name from the pod
// name → `react_native_standalone_video_player-Swift.h`. If the pod's module_name is
// overridden, adjust this import.
#import "react_native_standalone_video_player-Swift.h"

using namespace facebook::react;

@interface RNTPlayerVideoViewComponentView () <RCTComponentViewProtocol>
@end

@implementation RNTPlayerVideoViewComponentView {
  PlayerVideoView *_playerView;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<RNTPlayerVideoViewComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const RNTPlayerVideoViewProps>();
    _props = defaultProps;

    _playerView = [[PlayerVideoView alloc] initWithFrame:self.bounds];
    self.contentView = _playerView;
  }
  return self;
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &newViewProps = *std::static_pointer_cast<const RNTPlayerVideoViewProps>(props);

  // Apply playerInstance BEFORE isBoundToPlayer: PlayerVideoView's didSet binds against
  // the current playerInstance the moment isBoundToPlayer flips true.
  if (oldProps == nullptr) {
    _playerView.playerInstance = newViewProps.playerInstance;
    _playerView.isBoundToPlayer = newViewProps.isBoundToPlayer;
  } else {
    const auto &oldViewProps = *std::static_pointer_cast<const RNTPlayerVideoViewProps>(oldProps);
    if (oldViewProps.playerInstance != newViewProps.playerInstance) {
      _playerView.playerInstance = newViewProps.playerInstance;
    }
    if (oldViewProps.isBoundToPlayer != newViewProps.isBoundToPlayer) {
      _playerView.isBoundToPlayer = newViewProps.isBoundToPlayer;
    }
  }

  [super updateProps:props oldProps:oldProps];
}

// Fabric pools and reuses component views. Without this, the hosted PlayerVideoView keeps
// its previous cell's bound instance + stale AVPlayerLayer frame, and since updateProps
// only re-applies props that differ from the recycle-reset defaults, a new cell whose
// playerInstance equals the default never rebinds → wrong/stale video (stuck) or an
// instant reveal of the carried-over frame (blink). Reset to the prop-default state.
- (void)prepareForRecycle
{
  [_playerView resetForRecycle];
  [super prepareForRecycle];
}

@end

// Maps component name "RNTPlayerVideoView" → this class for the generated
// RCTThirdPartyFabricComponentsProvider. The function name must be
// <ComponentName>Cls per codegen convention.
Class<RCTComponentViewProtocol> RNTPlayerVideoViewCls(void)
{
  return RNTPlayerVideoViewComponentView.class;
}
