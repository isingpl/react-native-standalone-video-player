//
//  PlayerVideo.swift
//  PlayerVideo
//
//  Created by Ufos on 08/02/2020.
//  Copyright © 2020 panowiepro. All rights reserved.
//

import Foundation
import AVKit
import AVFoundation

//
// HLS video player
//

class PlayerVideo: NSObject {
  
  @objc
  static func newInstance() -> Int {
    let instance = PlayerVideo()
    
    instances.append(instance)
    
    return instances.count
  }
  
  @objc
  static var instances: [PlayerVideo] = []
  
  @objc
  static func clear() {
    instances.forEach { (player) in
      player.stop()
    }
    
    instances.removeAll()
  }
  
  //
  // Private
  //
  
  private var url: String = ""
  private var status: PlayerVideoStatus = .none

  private var shouldPlay = true

  private var isSeeking = false

  // Pitch-preserving playback speed (1.0 = normal). player.play() and seek reset rate to 1.0, so the
  // chosen rate is re-asserted after each (see applyDesiredRate). Pitch is held constant via the
  // playerItem's audioTimePitchAlgorithm (.spectral), set in load().
  private var desiredRate: Float = 1.0

  // Async-loaded asset duration. Reading AVAsset.duration synchronously while it
  // hasn't loaded blocks ALL asset property loads on the device (Apple warning:
  // "Asset property 'duration' accessed synchronously..."). Under bad network
  // this freezes every player. We load asynchronously and read the cache.
  private var cachedDuration: Double = 0

  // Watchdog. AVPlayer's internal retry on persistent socket RST is unbounded —
  // status stays .unknown indefinitely, JS never sees .error, UI shows spinner
  // forever. After this many seconds without reaching readyToPlay, we give up.
  private static let LOAD_TIMEOUT_SECONDS: TimeInterval = 15
  private var loadTimeoutTimer: Timer?

  // One-shot guard so `handleTick` doesn't re-fire `playbackEndReached`
  // while the async seek-to-zero is still in flight after a loop wrap.
  private var endReachedFired = false
  // Seek queued by load() — performed when AVPlayerItem reaches .readyToPlay,
  // before play() resumes. Direct AVPlayer.seek calls made before status==.readyToPlay
  // are unreliable (no-op or silently fail).
  private var pendingInitialSeekSeconds: Double? = nil

  // True from the moment an initial (media_start_time) seek is requested until it
  // actually lands. PlayerVideoView reads this to hold its reveal (alpha 0→1) so the
  // first visible frame is the offset frame, not frame 0 that then jumps. The status
  // transition to playing/paused is held the same way (see buffering()).
  var isInitialSeekPending = false
  // Fired once when the initial seek completes; PlayerVideoView assigns this to gate
  // its reveal. Cleared after firing and on each load().
  var onInitialSeekCompleted: (() -> Void)? = nil

  // The single AVPlayerLayer currently displaying this instance's player. An AVPlayer
  // renders to only one layer reliably; if two PlayerVideoViews (e.g. a recycled view
  // that didn't detach + the new active cell) both attach this player, one shows nothing.
  // Each bind claims ownership here and detaches the previous layer.
  weak var boundDisplayLayer: AVPlayerLayer? = nil

  private var timeObserver: Any?

  private var observersAdded = false
  private var timer: Timer?
  private var timerAdded = false
  
  private var shouldLoop = true

  // we could have one AVPlayer and multiple items
  let player: AVPlayer = {
    let avPlayer = AVPlayer()
    // Start playback as soon as the item is ready instead of waiting to build a stall-free
    // buffer — lowers time-to-first-frame. Trade-off: more risk of mid-playback stalls on poor
    // networks (AVPlayer no longer self-paces playback rate).
    avPlayer.automaticallyWaitsToMinimizeStalling = false
    return avPlayer
  }()
  
  //
  // Public
  //
  
  @objc
  var duration: Double {
    return cachedDuration
  }
  
  @objc
  var position: Double {
    if let position = player.currentItem?.currentTime().seconds {
      return position
    }

    return 0.0
  }
  
  @objc
  var progress: Double {
    if (duration > 0) {
      return position / duration
    }

    return 0.0
  }
  
  
  @objc
  var statusChanged: ((_ newStatus: PlayerVideoStatus) -> ())?
  
  @objc
  var progressChanged: ((_ newProgress: Double, _ duration: Double) -> ())?
  
  @objc
  var muteChanged: ((Bool) -> Void)?
  
  @objc
  var statusChanged2: (() -> ())?

  // Fires on end-of-playthrough. `willRestart = true` on loop wrap (JS-layer
  // loop in handleTick calls seekToZero+play); `false` on non-loop final stop.
  // JS-side play-confirm tracker uses this to send a confirm and decide
  // whether to restart the listen-time counter for the next loop.
  @objc
  var playbackEndReached: ((Bool) -> Void)?
  
  @objc
  var autoplay: Bool = true {
    didSet {
      shouldPlay = autoplay
    }
  }

  @objc
  var shouldRecordingLoop: Bool = true {
    didSet {
        shouldLoop = shouldRecordingLoop
    }
  }
  
  @objc
  var currentStatus: PlayerVideoStatus {
    return status
  }
  
  @objc
  var isPlaying: Bool {
    return status == .playing
  }
  
  @objc
  func load(url: String) {
    // Configure AVAudioSession to play sound even in silent mode
    do {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try AVAudioSession.sharedInstance().setActive(true)
    } catch {}

    // Tear down observers bound to the previous AVPlayerItem before we attach a new one.
    // Prevents stacked KVO + NC closures retaining stale items across pool reuse.
    removeObservers()

    shouldPlay = autoplay
    endReachedFired = false
    cachedDuration = 0
    // Reset stale pending seek from a prior load() whose item may not have reached
    // .readyToPlay before being replaced. StandaloneVideoPlayer.load() will set this
    // again after calling us, if JS passed an initialTime.
    pendingInitialSeekSeconds = nil
    isInitialSeekPending = false
    onInitialSeekCompleted = nil

    guard let videoUrl = URL(string: url) else {
      setStatus(.error)

      return
    }
    
    let bundleId = Bundle.main.bundleIdentifier ?? "com.ising.app"
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let userAgent = "\(bundleId)/\(version)"

    // iOS 16+ exposes AVURLAssetHTTPUserAgentKey — a PUBLIC, Apple-blessed way to
    // set UA on every HLS request (master playlist + chunklists + segments).
    // iOS < 16: no public header API. URL from JS already carries `ua=` in query
    // (appended in parseRecording.ts if backend didn't sign with it), so default
    // AVAsset is enough for CDN-side identification.
    let asset: AVAsset
    if #available(iOS 16.0, *) {
      asset = AVURLAsset(url: videoUrl, options: [
        AVURLAssetHTTPUserAgentKey: userAgent
      ])
    } else {
      asset = AVAsset(url: videoUrl)
    }

    let playerItem = AVPlayerItem(asset: asset)
    // Cap forward buffer; default auto-tunes to ~30s per instance.
    // Lowered 20→8→2: paired with automaticallyWaitsToMinimizeStalling=false, keep the
    // ahead-buffer small so the first frame shows sooner.
    playerItem.preferredForwardBufferDuration = 2
    // Time-stretch so changing playback rate (setSpeed) keeps pitch constant. .spectral is the
    // highest-quality algorithm — right for a music backing track (vs .timeDomain for speech).
    playerItem.audioTimePitchAlgorithm = .spectral

    // Async duration load — prevents the sync AVAsset.duration access that blocks
    // device-wide media services under poor network. Cache only if asset still bound.
    asset.loadValuesAsynchronously(forKeys: ["duration"]) { [weak self] in
      guard let self = self else { return }
      var error: NSError?
      let status = asset.statusOfValue(forKey: "duration", error: &error)
      guard status == .loaded else { return }
      let dur = asset.duration.seconds
      DispatchQueue.main.async {
        // Only cache if this asset is still the current one (not replaced mid-load)
        if let item = self.player.currentItem, item.asset === asset {
          self.cachedDuration = dur.isFinite ? dur : 0
        }
      }
    }

    // nil the existing item first so AVPlayer drops its decoder binding before
    // attaching the new one — without this, the old item lingers until passive ARC.
    player.replaceCurrentItem(with: nil)
    player.replaceCurrentItem(with: playerItem)

    setStatus(.new)

    addObservers()

    // Start fail-fast watchdog
    loadTimeoutTimer?.invalidate()
    loadTimeoutTimer = Timer.scheduledTimer(withTimeInterval: PlayerVideo.LOAD_TIMEOUT_SECONDS, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      // If we already reached playing/paused, ignore (success). Otherwise abort.
      if self.status != .playing && self.status != .paused {
        self.setStatus(.error)
        self.player.replaceCurrentItem(with: nil)  // cancels in-flight URL session tasks
        self.removeObservers()
      }
    }
  }
  
  @objc
  func play() {
    // After a non-loop end the player was stop()'d, which tore down the KVO/time/end observers and
    // left endReachedFired set. A replay arrives as play() (no reload), so re-arm end detection here
    // — otherwise the second playthrough never detects its end (status stays .playing, the JS clock
    // runs past duration). Guarded on observersAdded so a normal mid-song resume doesn't re-register.
    if !observersAdded, player.currentItem != nil {
      endReachedFired = false
      addObservers()
    }

    player.play()

    shouldPlay = true

    applyDesiredRate()

    setStatus(.playing)
  }

  // player.play() (and seek-resume) set rate to 1.0; re-assert the chosen speed after them.
  private func applyDesiredRate() {
    if desiredRate != 1.0 {
      player.rate = desiredRate
    }
  }

  // Pitch-preserving playback speed. Applied live if currently playing; otherwise stored and applied
  // by the next play()/seek-resume. Pitch is held by the item's audioTimePitchAlgorithm (load()).
  @objc
  func setSpeed(_ speed: Double) {
    desiredRate = Float(speed)
    if status == .playing {
      player.rate = desiredRate
    }
  }

  @objc
  func pause() {
    player.pause()

    shouldPlay = false

    setStatus(.paused)
  }
  
  @objc
  func setMuted(isMuted: Bool) {
    player.isMuted = isMuted
    muteChanged?(isMuted)
  }

  @objc
  func getMuted() -> Bool {
      return player.isMuted
  }
  
  @objc
  func stop() {
    loadTimeoutTimer?.invalidate()
    loadTimeoutTimer = nil

    player.pause()

    shouldPlay = false

    seekToZero()

    setStatus(.stoped)

    progressChanged?(0, duration)

    removeObservers()
  }

  // Fully release the playerItem (cancels open URL session tasks + frees decoder slot).
  // Use when an instance is no longer needed for some time (e.g., feed loses focus).
  // Next call to load() re-attaches a fresh playerItem.
  // (Named `unload` to avoid clashing with NSObject's `release` selector.)
  @objc
  func unload() {
    loadTimeoutTimer?.invalidate()
    loadTimeoutTimer = nil
    player.pause()
    shouldPlay = false
    removeObservers()
    player.replaceCurrentItem(with: nil)
    cachedDuration = 0
    setStatus(.none)
  }
  
  // Initial seek to an absolute time in seconds. Used by the load() path to honor
  // JS-side `initialTime` (media_start_time * 1000).
  //
  // Direct AVPlayer.seek before AVPlayerItem.status == .readyToPlay is unreliable
  // — it can no-op or silently fail. So we stash the value and let the KVO observer
  // perform the seek on the .readyToPlay transition, BEFORE play() resumes.
  // If the item is already ready (rare for fresh load, common for re-load of same
  // url), seek immediately and skip the pending path.
  @objc
  func seekToSeconds(seconds: Double) {
    let clamped = max(0, seconds)
    isInitialSeekPending = true
    if player.currentItem?.status == .readyToPlay {
      let time = CMTime(seconds: clamped, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
      // Tolerant initial seek: snap to the first keyframe at/after the target instead of
      // decoding to the exact frame. An exact (.zero/.zero) seek to a deep media_start_time
      // on HLS costs seconds (fetch segment + decode the whole GOP) and sits in the reveal
      // critical path. A ~2s keyframe snap is cosmetic for a feed start point — lyrics
      // follow the player's actual position, so they stay in sync.
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600)) { [weak self] _ in
        // Hop to main: completeInitialSeek() fires PlayerVideoView's one-shot reveal
        // callback, and the view reads isInitialSeekPending / sets that callback on the
        // main queue. AVPlayer calls this handler on an arbitrary queue, so without the
        // hop the two interleave and the reveal callback can be assigned AFTER it already
        // fired → never called → video stays hidden behind the cover (intermittent,
        // only when media_start_time>0 so the seek gate is engaged).
        DispatchQueue.main.async { self?.completeInitialSeek() }
      }
      pendingInitialSeekSeconds = nil
    } else {
      pendingInitialSeekSeconds = clamped
    }
  }

  // Marks the initial (media_start_time) seek as landed and notifies PlayerVideoView
  // so it reveals the offset frame instead of frame 0. One-shot.
  private func completeInitialSeek() {
    isInitialSeekPending = false
    let cb = onInitialSeekCompleted
    onInitialSeekCompleted = nil
    cb?()
  }

  // 0 <= position <= 1.0
  @objc
  func seekTo(position: Double) {
    let progress = min(1.0, max(0.0, position))

    guard player.currentItem != nil else { return }

    self.isSeeking = true
    
    progressChanged?(progress, duration)
    
    if progress == 0.0 {
        seekToZero()

        // set progress 0
    } else {
        // cachedDuration avoids sync asset.duration access; fixed nanosecond timescale is fine here
        let time = CMTime(seconds: progress * cachedDuration, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

        // Non-zero toleranceAfter: a zero-tolerance EXACT seek on HLS (paired with
        // automaticallyWaitsToMinimizeStalling=false) stalls the player into an empty buffer after a
        // forward scrub — video/audio freeze with no recovery, and progress stops. A small tolerance
        // lands reliably (matches seekToSeconds).
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600), completionHandler: { [weak self] (finished) in
          guard let self = self else { return }
          // Always clear isSeeking (even on finished==false). Otherwise handleTick's `!isSeeking`
          // gate stays shut and progress never resumes. Mirrors the 2026-04-21 loop-wrap fix.
          self.didSeek(progress: progress)
          // Force a progress update — AVPlayer's periodic time observer may not fire promptly after a seek.
          self.progressChanged?(progress, self.duration)
          // Re-assert play AFTER the seek lands so resume doesn't race the in-flight seek.
          if self.shouldPlay {
            self.player.play()
            self.applyDesiredRate()
          }
        })
    }
  }
  
  //
  
  @objc
  func seekForward(time: Double) {
    if (duration > 0) {
      seekTo(position: (position + time) / duration)
    }
  }
  
  
  @objc
  func seekRewind(time: Double) {
    if (duration > 0) {
      seekTo(position: (position - time) / duration)
    }
  }
  
  
  //
  // Private
  //
  
  deinit {
    stop()
  }
  
  
  //
  
  private func didSeek(progress: Double) {
    isSeeking = false
    
    if (status != .loading) {
      setStatus(shouldPlay ? .playing : .paused)
    }
  }
  
  private func setStatus(_ newStatus: PlayerVideoStatus) {
      guard newStatus != status else { return }
    self.status = newStatus

    statusChanged?(status)
  }
  
  private func addObservers() {
    guard let playerItem = player.currentItem else { return }

    playerItem.addObserver(self, forKeyPath: "status", options: [], context: nil)
    playerItem.addObserver(self, forKeyPath: "playbackBufferEmpty", options: [], context: nil)
    playerItem.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: [], context: nil)

    // Canonical end-of-play signal. The periodic time observer (handleTick) only fires while the
    // player is playing and on ~1s boundaries, so AVPlayer auto-pausing at true end can leave the
    // last observed progress below the 0.99 threshold — the end is then never detected and status
    // stays .playing forever (clock free-runs past duration). This notification fires exactly once
    // at true end regardless of tick cadence; handleEndReached() dedupes against handleTick.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(playerItemDidReachEnd(_:)),
      name: .AVPlayerItemDidPlayToEndTime,
      object: playerItem
    )

      observersAdded = true

      if(!timerAdded){
          startTimeObserver()
      }
  }
    
    private func startTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: Int32(NSEC_PER_SEC))
        
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: nil, using: handleTick)
        timerAdded = true
    }

    private func stopTimer() {
        guard let _timeObserver = timeObserver  else {return}

        player.removeTimeObserver(_timeObserver)
        timeObserver = nil
        timerAdded = false
    }

    
    private func handleTick(time: CMTime) {
        guard self.status == .playing else {return}

        let currentTime = time.seconds
        let progress = currentTime / (self.duration != 0.0 ? self.duration : 1.0)

        if (!self.isSeeking) {
          self.progressChanged?(progress, self.duration)
        }

        if (progress >= 0.99) {
          self.handleEndReached()
        }
    }

  // True end-of-play notification — fires once when the item plays to its end, even if the periodic
  // observer never observed progress >= 0.99 (it stops ticking the moment AVPlayer auto-pauses at
  // end). Routed through the same handler as the handleTick 0.99 path; endReachedFired dedupes.
  @objc private func playerItemDidReachEnd(_ notification: Notification) {
    guard let item = notification.object as? AVPlayerItem, item == player.currentItem else { return }
    handleEndReached()
  }

  // End-of-playthrough: loop wrap (seek-to-zero + play) or final stop, fired at most once per
  // playthrough. endReachedFired guards against the handleTick 0.99 pre-empt and the end
  // notification both firing for the same end.
  private func handleEndReached() {
    guard !endReachedFired else { return }
    endReachedFired = true
    if (shouldLoop) {
      // Fire end-of-playthrough BEFORE seek+play so JS event handler
      // runs first and can send playConfirm for the completed loop.
      playbackEndReached?(true)
      isSeeking = true
      let zero = CMTime(seconds: 0.0, preferredTimescale: 1)
      let dur = duration
      player.seek(to: zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
        self?.isSeeking = false
        self?.endReachedFired = false
        // Force UI progress update — periodic observer may not fire promptly
        // after seek completion if AVPlayer auto-paused at end-of-media.
        self?.progressChanged?(0.0, dur)
      }
      play()
    } else {
      playbackEndReached?(false)
      stop()
    }
  }
  
  private func removeObservers() {
    if observersAdded, let playerItem = player.currentItem {
      playerItem.removeObserver(self, forKeyPath: "status")
      playerItem.removeObserver(self, forKeyPath: "playbackBufferEmpty")
      playerItem.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
      observersAdded = false
    }

    NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)

    stopTimer()
  }
  
  //
  //
  //
  
  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
      
    guard let asset = object as? AVPlayerItem, let keyPath = keyPath else { return }
    
    guard asset == player.currentItem else { return }
        
    if (keyPath == "status") {
        switch (asset.status) {
        case .failed:

            setStatus(.error)

            break
            
        // this may be called also when binding to view (I dont know why)..
        case .readyToPlay:

            // Successful load — cancel watchdog
            loadTimeoutTimer?.invalidate()
            loadTimeoutTimer = nil

            // If a pending initial seek was queued by load() (media_start_time),
            // perform it now BEFORE play(), so playback starts at the right offset
            // instead of from 0.
            if let pendingSeek = pendingInitialSeekSeconds {
                pendingInitialSeekSeconds = nil
                let time = CMTime(seconds: pendingSeek, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                // Tolerant initial seek — snap to nearest keyframe at/after target (see seekToSeconds).
                // Exact deep-offset HLS seeks cost seconds and block the reveal.
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600)) { [weak self] _ in
                    // Main-hop so completeInitialSeek() (which fires PlayerVideoView's one-shot
                    // reveal callback) is serialized with the view's main-thread reveal gate —
                    // otherwise the callback is set after it already fired and the video stays
                    // stuck behind the cover. play()/pause() stay inside the hop so they run
                    // after isInitialSeekPending is cleared (buffering() gates status on it).
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.completeInitialSeek()
                        if self.shouldPlay {
                            self.play()
                        } else {
                            self.pause()
                        }
                    }
                }
            } else if (shouldPlay) {
                play()
            } else {
                pause()
            }

            break
            
        case .unknown:
            // wtf should we do now??
            break
            
        @unknown default:
            // wtf should we do now??
            break
        }
    } else {
        if (keyPath == "playbackBufferEmpty") {
          if (asset.isPlaybackBufferEmpty) {
            if asset.isPlaybackLikelyToKeepUp == true || asset.status == .readyToPlay {
              self.buffering(isBuffering: false)
            } else {
              self.buffering(isBuffering: true)
            }
          }
        } else if (keyPath == "playbackLikelyToKeepUp") {
          if asset.isPlaybackLikelyToKeepUp == true {
            self.buffering(isBuffering: false)
          } else {
            if (asset.status != .readyToPlay) {
              self.buffering(isBuffering: true)
            }
          }
        }
    }
  }
  
  //
  
  private func buffering(isBuffering: Bool) {
    if (isBuffering) {
      if (status != .stoped && status != .error && status != .none) {
        setStatus(.loading)
      }
    } else {
      // Hold the playing/paused transition until the initial seek lands, so neither
      // the status nor any JS reveal keyed on it flips to playing at frame 0.
      if isInitialSeekPending { return }
      setStatus(shouldPlay ? .playing : .paused)
    }
  }

  //

  fileprivate func seekToZero() {
    let time = CMTime(seconds: 0.0, preferredTimescale: 1)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
  }

}

//

public typealias VoidClosure = (() -> Void)?

//

@objc
enum PlayerVideoStatus: Int {
  
  // for initial setup
  case new = 0
  
  case loading = 1
  
  case playing = 2
  
  case paused = 3
  
  case error = 4
  
  case stoped = 5
  
  // no video loaded or loading
  case none = 6
  
  
  func print() -> String {
    switch(self) {
    case .new: return "new"
    case .loading: return "loading"
    case .playing: return "playing"
    case .paused: return "paused"
    case .error: return "error"
    case .stoped: return "stoped"
    case .none: return "none"
      
    default: return ""
    }
  }
}


