import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  NativeEventEmitter,
  NativeModules,
  TurboModuleRegistry,
} from 'react-native';
import RNTPlayerVideoView from './PlayerVideoNativeComponent';

// - - - - - -

// Lazy module resolution. Under bridgeless newArch, the TurboModule proxy can be
// uninitialised at module-eval time (when index.tsx is loaded as part of the JS bundle);
// resolving eagerly returns null. Resolve on first method access instead — by then the
// proxy is ready. NativeModules fallback covers old-arch / interop paths.
let _moduleCache: any = null;
function resolveModule(): any {
  if (_moduleCache) return _moduleCache;
  _moduleCache =
    TurboModuleRegistry.get('StandaloneVideoPlayer') ??
    NativeModules.StandaloneVideoPlayer;
  return _moduleCache;
}

const StandaloneVideoPlayer = new Proxy(
  {},
  {
    get(_, prop: string) {
      const mod = resolveModule();
      if (mod == null) {
        throw new Error(
          `TurboModule 'StandaloneVideoPlayer' not registered. Rebuild the app natively after the lib's BaseReactPackage migration.`
        );
      }
      return mod[prop];
    },
  }
) as any;

type StandaloneVideoPlayerType = {
  newInstance(): void;

  load(
    instance: number,
    url: string,
    hls: boolean,
    loop: boolean,
    isSilent: boolean,
    initialTime: number,
  ): void;

  setMuted(instance:number, isMuted: boolean): void;
  getMuted(instance:number): Promise<boolean>

  seek(instance: number, position: number): void;

  // Pitch-preserving playback speed (1.0 = normal).
  setSpeed(instance: number, speed: number): void;

  seekForward(instance: number, time: number): void;

  seekRewind(instance: number, time: number): void;

  play(instance: number): void;

  pause(instance: number): void;

  stop(instance: number): void;

  // Releases the AVPlayerItem (cancels open URL session tasks + frees decoder slot).
  // Next load() re-attaches a fresh playerItem. Use when an instance is no longer
  // needed for some time — e.g., feed loses focus.
  unload(instance: number): void;

  getDuration(instance: number): Promise<number>;
  getProgress(instance: number): Promise<number>;

  clear(): void;

  // Android-only: force SurfaceFlinger to re-attach the SurfaceView's Layer to
  // the display tree. Workaround for a MIUI/Android compositor bug where, after
  // RDS open occludes the feed SurfaceView with an opaque layer, RDS close
  // doesn't re-signal the Layer needs compositing. ExoPlayer keeps decoding
  // frames into the Surface (rendered counter increments) but SurfaceFlinger
  // ignores them — last composited buffer stays frozen on screen.
  refreshCompositor(instance: number): void;
};

const PlayerVideoManager = StandaloneVideoPlayer as StandaloneVideoPlayerType;

//

enum PlayerStatus {
  new = 'new', //0,
  loading = 'loading', // 1,
  playing = 'playing', // 2,
  paused = 'paused', // 3,
  error = 'error', // 4,
  stopped = 'stopped', // 5,
  none = 'none', // 6
  finished = 'finished', // 6
}

//

var PlayerInstances = 0;

// used to distinguish which video is playing
var CurrentVideoId: (string | null)[] = [null, null, null];

//

// you have to call at least once before using any player!
function createStandalonePlayerVideoInstance() {
  PlayerInstances += 1;

  PlayerVideoManager.newInstance();

  return PlayerInstances - 1;
}

// Idempotent seeding — call once at app startup with the total number of
// slots you need. Keeps the JS-local PlayerInstances counter in sync with
// the native list so useVideoPlayer.load()'s grow-on-demand guard never
// fires behind the wrapper's back.
function ensureInstances(count: number) {
  while (PlayerInstances < count) {
    createStandalonePlayerVideoInstance();
  }
}

//

function clearPlayerVideo() {
  if (PlayerVideoManager && PlayerVideoManager.clear) {
    [0, 1, 2].forEach((id) => {
      const isPlayerPlayingOrPaused =
        PlayerInfo.lastStatus[id] === PlayerStatus.playing ||
        PlayerInfo.lastStatus[id] === PlayerStatus.paused;

      if (isPlayerPlayingOrPaused) {
        eventEmitter.emit('PlayerStatusChanged', {
          instance: id,
          status: 5,
        });

        CurrentVideoId[id] = null;

        PlayerVideoManager.stop(id);
      }
    });
  }
}

//

function getVideoDuration(playerInstance = 0): Promise<number> {
  return new Promise((resolve) => {
    if (!PlayerVideoManager.getDuration) {
      console.warn('getDuration not implemented');
      resolve(0);
    }

    PlayerVideoManager.getDuration(playerInstance)
      .then((val) => resolve(val || 0))
      .catch(() => resolve(0));
  });
}

//

function getMuted(playerInstance = 0): Promise<boolean> {
  return new Promise((resolve) => {
    if (!PlayerVideoManager.getMuted) {
      console.warn('getMuted not implemented');
      resolve(false);
    }

    PlayerVideoManager.getMuted(playerInstance)
      .then((val) => resolve(val || false))
      .catch(() => resolve(false));
  });
}
//

function getVideoProgress(playerInstance = 0): Promise<number> {
  return new Promise((resolve) => {
    if (!PlayerVideoManager.getProgress) {
      console.warn('getProgress not implemented');
      resolve(0);
    }

    PlayerVideoManager.getProgress(playerInstance)
      .then((val) => resolve(val || 0))
      .catch(() => resolve(0));
  });
}

//

export function useMuted(playerInstance = 0) {
  const [isMuted, setIsMuted] = useState(false);

  const setMuted = useCallback((isMuted: boolean) => {
    PlayerVideoManager.setMuted(playerInstance, isMuted);
  }, [playerInstance]);

   useEffect(() => {
    const subscription = eventEmitter.addListener(
      'PlayerMuteChanged',
      (event) => {
        if (event.instance === playerInstance) {
          setIsMuted(event.isMuted);
        }
      }
    );

    return () => subscription.remove();
  }, [playerInstance]);

  useEffect(() => {
    getMuted(playerInstance).then(setIsMuted);
  }, [playerInstance]);

  return {isMuted,setMuted};
}

//

function useVideoPlayer(playerInstance = 0) {
  const play = useCallback(() => {
    PlayerVideoManager.play(playerInstance);
  }, [playerInstance]);

  const pause = useCallback(() => {
    PlayerVideoManager.pause(playerInstance);
  }, [playerInstance]);

  const stop = useCallback(() => {
    // emit here for faster loop (dont wait from native)
    eventEmitter.emit('PlayerStatusChanged', {
      instance: playerInstance,
      status: 5,
    });

    CurrentVideoId[playerInstance] = null;

    PlayerVideoManager.stop(playerInstance);
  }, [playerInstance]);

  const load = useCallback(
    (
      url: string,
      autoplay: boolean = true,
      id: string | null = null,
      isHls = true,
      loop = false,
      isSilent = false,
      initialTime = 0,
    ) => {
      if (playerInstance >= PlayerInstances) {
        createStandalonePlayerVideoInstance();
      }

      // notify current video
      if (CurrentVideoId[playerInstance]) {
        eventEmitter.emit('PlayerStatusChanged', {
          instance: playerInstance,
          status: 5, // stopped
        });
      }

      CurrentVideoId[playerInstance] = id;

      // emit here for faster loop (dont wait from native)
      eventEmitter.emit('PlayerStatusChanged', {
        instance: playerInstance,
        status: 1, // loading
      });

      if (autoplay) {
        // TODO: handle autoplay
      }

      PlayerVideoManager.load(playerInstance, url, isHls, loop, isSilent, initialTime);
    },
    [playerInstance]
  );

  const seek = useCallback(
    (pos: number) => {
      PlayerVideoManager.seek(playerInstance, pos);
    },
    [playerInstance]
  );

  const setSpeed = useCallback(
    (speed: number) => {
      PlayerVideoManager.setSpeed(playerInstance, speed);
    },
    [playerInstance]
  );

  const seekForward = useCallback(
    (time: number) => {
      PlayerVideoManager.seekForward(playerInstance, time);
    },
    [playerInstance]
  );

  const seekRewind = useCallback(
    (time: number) => {
      PlayerVideoManager.seekRewind(playerInstance, time);
    },
    [playerInstance]
  );

  const getCurrentVideoId = useCallback(() => {
    // not the best way to return global var here...
    return CurrentVideoId[playerInstance];
  }, [playerInstance]);

  return useMemo(
    () => ({
      play,
      pause,
      stop,
      load,
      seek,
      setSpeed,
      seekForward,
      seekRewind,
      getCurrentVideoId,
    }),
    [getCurrentVideoId, load, pause, play, seek, setSpeed, seekForward, seekRewind, stop]
  );
}

//
// Event Hooks
//

const eventEmitter = new NativeEventEmitter(StandaloneVideoPlayer);

const PlayerInfo = {
  // for each player instance
  // TODO: make it dynamic for more players...
  lastStatus: [
    PlayerStatus.none,
    PlayerStatus.none,
    PlayerStatus.none,
    PlayerStatus.none,
    PlayerStatus.none,
  ],
};

// Keep PlayerInfo.lastStatus always up-to-date, even without hook subscribers
eventEmitter.addListener('PlayerStatusChanged', (data) => {
  if (data.instance != null && data.instance < PlayerInfo.lastStatus.length) {
    PlayerInfo.lastStatus[data.instance] = createStatus(data.status);
  }
});

// Synchronous read of the last known status — for handlers/effects that need the
// status without subscribing (a usePlayerVideoStatus subscription re-renders the
// caller on every status transition).
function getPlayerStatus(playerInstance = 0): PlayerStatus {
  return PlayerInfo.lastStatus[playerInstance];
}

function usePlayerVideoStatus(playerInstance = 0, recordingId?: string) {
  const [status, setStatus] = useState(PlayerInfo.lastStatus[playerInstance]);

  useEffect(() => {
    // Tombstone: RN's emit() snapshots the listener Set at start of dispatch,
    // so a listener removed mid-cycle (or via a follow-up emit racing with
    // cleanup) still fires from the snapshot. Without this guard, an old
    // closure's setStatus runs against the (stable) state slot AFTER deps
    // changed, flipping PlayerBar to a stale status from the prev instance.
    let alive = true;

    // Reseed on instance/id change. ExoPlayer dedupes setStatus on equal state,
    // so play() against an already-playing preloaded instance emits no event
    // and the hook's local state would otherwise stay stale.
    if (!recordingId || recordingId === CurrentVideoId[playerInstance]) {
      setStatus(PlayerInfo.lastStatus[playerInstance]);
    }

    const subscription = eventEmitter.addListener(
      'PlayerStatusChanged',
      (data) => {
        if (!alive) return;
        if (data.instance === playerInstance) {
          if (!recordingId || recordingId === CurrentVideoId[playerInstance]) {
            const next = createStatus(data.status);
            PlayerInfo.lastStatus[playerInstance] = next;
            setStatus(next);
          }
        }
      }
    );

    return () => {
      alive = false;
      subscription.remove();
    };
  }, [playerInstance, recordingId]);

  const forceLoadingStatus = () => {
    setStatus(PlayerStatus.loading);
  };

  return {
    status,
    forceLoadingStatus,
  };
}

//

function usePlayerVideoProgress(playerInstance = 0) {
  const [progress, setProgress] = useState(0);
  const [duration, setDuration] = useState(0);

  useEffect(() => {
    const subscription = eventEmitter.addListener(
      'PlayerProgressChanged',
      (data) => {
        if (data.instance === playerInstance) {
          setDuration(data.duration);
          setProgress(data.progress);
        }
      }
    );

    return () => subscription.remove();
  }, [playerInstance]);

  useEffect(() => {
    getVideoDuration(playerInstance).then(setDuration);
    getVideoProgress(playerInstance).then(setProgress);
  }, [playerInstance]);

  return {
    progress,
    duration: duration,
  };
}

//

// Subscribes to end-of-playthrough events from native. `willRestart = true`
// when the player is about to loop (native will seek-to-zero+play); `false`
// when it's the final end (non-loop stop). JS consumers use the flag to
// decide whether to restart per-playthrough counters.
function usePlayerPlaybackEnd(
  playerInstance: number,
  callback: (willRestart: boolean) => void
) {
  useEffect(() => {
    const subscription = eventEmitter.addListener(
      'PlayerPlaybackEnded',
      (data) => {
        if (data.instance === playerInstance) {
          callback(!!data.willRestart);
        }
      }
    );

    return () => subscription.remove();
  }, [playerInstance, callback]);
}

//
//
//

function createStatus(status: number): PlayerStatus {
  switch (status) {
    case 0:
      return PlayerStatus.new;
    case 1:
      return PlayerStatus.loading;
    case 2:
      return PlayerStatus.playing;
    case 3:
      return PlayerStatus.paused;
    case 4:
      return PlayerStatus.error;
    case 5:
      return PlayerStatus.stopped;
    case 6:
      return PlayerStatus.none;
    case 7:
      return PlayerStatus.finished;
  }

  return PlayerStatus.none;
}

// - - - - - -
// Video View
// - - - - - -

// RNTPlayerVideoView is imported above from PlayerVideoNativeComponent.ts (codegen Fabric
// component spec). Under newArch this returns a Fabric host component; under old-arch
// codegenNativeComponent falls back to requireNativeComponent internally.

//

interface PlayerViewProps {
  // if true this view will be presenting video from Player
  isBoundToPlayer?: boolean;

  // you can use multiple instances of player (now supported only on ioS)
  playerInstance?: number;

  // any other prop
  // TODO: use React's view's props...
  [key: string]: any;
}

//

function usePlayerReadyForDisplay(playerInstance = 0, recordingId?: string) {
  const [isReadyForDisplay, setIsReadyForDisplay] = useState(false);

  useEffect(() => {
    setIsReadyForDisplay(false);
    // Events are instance-keyed (no recording id) → cross-check CurrentVideoId so a pooled
    // instance's stale ready/status for a prior recording doesn't poison this one.
    const onReady = (data: { instance: number }) => {
      if (data.instance === playerInstance && CurrentVideoId[playerInstance] === recordingId) {
        setIsReadyForDisplay(true);
      }
    };
    // Instance now holds a different recording (evict/reload) → this one isn't displayed; reset
    // so a scroll-back re-masks until its fresh first frame.
    const onStatus = (data: { instance: number }) => {
      if (data.instance === playerInstance && CurrentVideoId[playerInstance] !== recordingId) {
        setIsReadyForDisplay(false);
      }
    };
    const readySub = eventEmitter.addListener('PlayerReadyForDisplay', onReady);
    const statusSub = eventEmitter.addListener('PlayerStatusChanged', onStatus);

    return () => {
      readySub.remove();
      statusSub.remove();
    };
  }, [playerInstance, recordingId]);

  return isReadyForDisplay;
}

//

const PlayerVideoView: React.FunctionComponent<PlayerViewProps> = ({
  isBoundToPlayer = false,
  playerInstance = -1,
  ...rest
}) => {
  return (
    <RNTPlayerVideoView
      isBoundToPlayer={isBoundToPlayer}
      playerInstance={playerInstance}
      {...rest}
    />
  );
};

//
//
//

export {
  PlayerVideoView,
  PlayerStatus,
  PlayerVideoManager,
  clearPlayerVideo,
  ensureInstances,
  getVideoDuration,
  getVideoProgress,
  useVideoPlayer,
  usePlayerVideoStatus,
  getPlayerStatus,
  usePlayerVideoProgress,
  usePlayerReadyForDisplay,
  usePlayerPlaybackEnd,
};
