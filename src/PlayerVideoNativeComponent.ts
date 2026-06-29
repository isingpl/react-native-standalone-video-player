import type { ViewProps } from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
import type { Int32 } from 'react-native/Libraries/Types/CodegenTypes';

// Fabric component spec for the standalone video player view. Pairs with the TurboModule
// in NativeStandaloneVideoPlayer.ts — the module owns the ExoPlayer instances, the view
// just binds to a slot and renders the surface.
export interface NativeProps extends ViewProps {
  isBoundToPlayer?: boolean;
  playerInstance?: Int32;
}

export default codegenNativeComponent<NativeProps>('RNTPlayerVideoView');
