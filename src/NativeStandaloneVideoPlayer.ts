import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

// TurboModule spec for the standalone video player. Codegen reads this at build time
// to generate the Java/ObjC interface the native impl must conform to. Method signatures
// must match the legacy module (StandaloneVideoPlayer.kt) so swapping is transparent.
//
// Stage 1a (current): spec exists + JS imports via TurboModuleRegistry. Native impl is
// still the legacy ReactContextBaseJavaModule — works via newArch interop layer.
// Stage 1b: rewrite native impl to extend the codegen-generated NativeStandaloneVideoPlayerSpec.
export interface Spec extends TurboModule {
  newInstance(): void;
  load(
    instance: number,
    url: string,
    isHls: boolean,
    loop: boolean,
    isSilent: boolean,
    initialTime: number
  ): void;
  play(instance: number): void;
  pause(instance: number): void;
  stop(instance: number): void;
  seek(instance: number, position: number): void;
  // Pitch-preserving playback speed (1.0 = normal). iOS: AVPlayer.rate +
  // audioTimePitchAlgorithm; Android: ExoPlayer PlaybackParameters(speed) (pitch fixed at 1.0).
  setSpeed(instance: number, speed: number): void;
  seekForward(instance: number, time: number): void;
  seekRewind(instance: number, time: number): void;
  setMuted(instance: number, isMuted: boolean): void;
  getMuted(instance: number): Promise<boolean>;
  getDuration(instance: number): Promise<number>;
  getProgress(instance: number): Promise<number>;
  clear(): void;
  unload(instance: number): void;
  refreshCompositor(instance: number): void;
  // Required by NativeEventEmitter on the JS side. Codegen surfaces these as no-ops
  // when emit-from-JS isn't needed — keeps Spec compatible with addListener-style usage.
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('StandaloneVideoPlayer');
