//
//  PlayerVideoView.swift
//  iSing
//
//  Created by Ufos on 08/02/2020.
//  Copyright © 2020 Facebook. All rights reserved.
//

import UIKit
import AVKit
import AVFoundation


@objc(PlayerVideoView)
public class PlayerVideoView: UIView {

  @objc
  public var isBoundToPlayer: Bool = false {
    didSet {
      if (isBoundToPlayer) {
        bindPlayer(playerInstance: self.playerInstance)
      } else {
        unbindPlayer()
      }
    }
  }

  @objc
  public var playerInstance: Int = 0 {
    didSet {
      if (isBoundToPlayer) {
        bindPlayer(playerInstance: self.playerInstance)
      } else {
        unbindPlayer()
      }
    }
  }

  //

  private var videoPlayerLayer: AVPlayerLayer = AVPlayerLayer()
  private var pendingPlayerInstance: Int? = nil
  private var readyForDisplayObservation: NSKeyValueObservation? = nil
  private var statusObservation: NSKeyValueObservation? = nil
  private var currentItemObservation: NSKeyValueObservation? = nil
  // Reveal is driven by an idempotent attemptReveal() re-checked on every trigger
  // (item-ready, seek-completed, isReadyForDisplay) plus a short polling watchdog —
  // so a single missed KVO/callback (TOCTOU on isReadyForDisplay, or a shared
  // onInitialSeekCompleted slot overwritten by a second view bound to the same
  // instance) can't leave the video stuck behind the cover.
  private var didReveal = false
  private var revealWatchdog: Timer? = nil
  private var watchdogTicks = 0

  static var onReadyForDisplay: ((Int) -> Void)? = nil

  public override init(frame: CGRect) {
      super.init(frame: frame)

      initialize()
  }

  public required init?(coder: NSCoder) {
      super.init(coder: coder)

      initialize()
  }

  private func initialize() {
      backgroundColor = .clear
      alpha = 0
      clipsToBounds = true

      configureLayer()
  }

  private func configureLayer() {
      videoPlayerLayer.videoGravity = .resizeAspectFill

      videoPlayerLayer.contentsScale = UIScreen.main.scale

      videoPlayerLayer.actions = [
          "bounds": NSNull(),
          "position": NSNull(),
          "frame": NSNull(),
          "contents": NSNull(),
      ]
  }

  // Fabric recycles RNTPlayerVideoViewComponentView's hosted PlayerVideoView for a new
  // cell. Without a full reset the Swift view keeps its old playerInstance + bound player
  // + the prior recording's frame on a sticky-isReadyForDisplay layer — and because
  // updateProps only re-applies props that differ from the recycle-reset defaults, a new
  // cell whose playerInstance equals the default (0) never rebinds → wrong/stale content
  // (stuck) or an instant reveal of the carried-over frame (blink). Reset everything to
  // the prop-default state and swap in a FRESH layer (isReadyForDisplay back to false).
  @objc
  public func resetForRecycle() {
      isBoundToPlayer = false   // didSet -> unbindPlayer(): player=nil, observers/watchdog off
      playerInstance = 0
      pendingPlayerInstance = nil

      videoPlayerLayer.removeFromSuperlayer()
      videoPlayerLayer.player = nil
      videoPlayerLayer = AVPlayerLayer()
      configureLayer()

      didReveal = false
      alpha = 0
  }

  private func syncLayerFrame() {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      videoPlayerLayer.frame = bounds
      CATransaction.commit()
  }

  //

  public override var frame: CGRect {
      didSet {
          syncLayerFrame()
      }
  }

  public override var bounds: CGRect {
      didSet {
          syncLayerFrame()
      }
  }

  open override func layoutSubviews() {
      super.layoutSubviews()

      if layer.sublayers == nil || !layer.sublayers!.contains(videoPlayerLayer) {
          layer.addSublayer(videoPlayerLayer)
      }

      syncLayerFrame()

      // If binding was deferred because bounds were zero, apply it now
      if let pending = pendingPlayerInstance, !bounds.isEmpty {
          pendingPlayerInstance = nil
          bindPlayer(playerInstance: pending)
      }
  }

  //

  func bindPlayer(playerInstance: Int) {
    if (playerInstance < PlayerVideo.instances.count && playerInstance >= 0) {
      let player = PlayerVideo.instances[playerInstance].player

      // Defer binding until we have a non-zero layout
      if bounds.isEmpty {
        pendingPlayerInstance = playerInstance
        if layer.sublayers == nil || !layer.sublayers!.contains(videoPlayerLayer) {
          layer.addSublayer(videoPlayerLayer)
        }
        return
      }

      pendingPlayerInstance = nil
      if layer.sublayers == nil || !layer.sublayers!.contains(videoPlayerLayer) {
        layer.addSublayer(videoPlayerLayer)
      }
      videoPlayerLayer.frame = bounds

      // Claim sole display ownership of this instance's player: detach whatever layer
      // was attached before (a stale recycled view, or the previous active cell) so the
      // AVPlayer renders into OUR layer, not theirs.
      let owner = PlayerVideo.instances[playerInstance]
      if owner.boundDisplayLayer !== videoPlayerLayer {
        owner.boundDisplayLayer?.player = nil
        owner.boundDisplayLayer = videoPlayerLayer
      }
      videoPlayerLayer.player = player

      // Watch AVPlayer.currentItem swaps. Without this, after the first reveal alpha=1
      // sticks; reusing the slot for a new URL leaves the layer showing the previous
      // video's last frame until the new item renders. AVPlayerLayer.isReadyForDisplay
      // is sticky-true after the first frame, so we can't rely on it for re-reveals.
      currentItemObservation?.invalidate()
      currentItemObservation = player.observe(\.currentItem, options: [.new, .initial]) { [weak self] player, _ in
        DispatchQueue.main.async {
          self?.handleCurrentItemChanged(item: player.currentItem)
        }
      }
    }
  }

  // Reset visibility on each new playerItem and reveal once it's ready.
  private func handleCurrentItemChanged(item: AVPlayerItem?) {
    statusObservation?.invalidate()
    statusObservation = nil
    readyForDisplayObservation?.invalidate()
    readyForDisplayObservation = nil
    stopRevealWatchdog()

    // Hide stale frame from previous playerItem; cover behind shows through
    didReveal = false
    alpha = 0

    guard let item = item else { return }

    if item.status == .readyToPlay {
      beginReveal()
    } else {
      statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        if item.status == .readyToPlay {
          DispatchQueue.main.async { self?.beginReveal() }
        }
      }
    }
  }

  // Item is ready. Wire the seek-completion trigger, arm the watchdog, then evaluate.
  // Reveal is gated on: initial (media_start_time) seek landed AND the layer rendered
  // its first frame — otherwise we'd flash frame 0 then jump to the offset.
  private func beginReveal() {
    statusObservation?.invalidate()
    statusObservation = nil

    if playerInstance >= 0, playerInstance < PlayerVideo.instances.count {
      let owner = PlayerVideo.instances[playerInstance]
      if owner.isInitialSeekPending {
        // Trigger only — attemptReveal re-reads the gate, so a missed/overwritten
        // callback can't strand the reveal (the watchdog also re-evaluates).
        owner.onInitialSeekCompleted = { [weak self] in
          DispatchQueue.main.async { self?.attemptReveal() }
        }
      }
    }

    startRevealWatchdog()
    attemptReveal()
  }

  // Idempotent: safe to call from any trigger (item-ready, seek-completed,
  // isReadyForDisplay KVO, watchdog). Reveals only when both gates pass.
  private func attemptReveal() {
    if didReveal { stopRevealWatchdog(); return }

    if playerInstance >= 0, playerInstance < PlayerVideo.instances.count {
      if PlayerVideo.instances[playerInstance].isInitialSeekPending { return }
    }

    guard videoPlayerLayer.isReadyForDisplay else {
      if readyForDisplayObservation == nil {
        readyForDisplayObservation = videoPlayerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
          guard change.newValue == true else { return }
          DispatchQueue.main.async { self?.attemptReveal() }
        }
      }
      return
    }

    animateReveal()
  }

  private func animateReveal() {
    if didReveal { return }
    didReveal = true
    readyForDisplayObservation?.invalidate()
    readyForDisplayObservation = nil
    stopRevealWatchdog()
    UIView.animate(withDuration: 0.15) { self.alpha = 1 }
    PlayerVideoView.onReadyForDisplay?(playerInstance)
  }

  // Backstop: poll the reveal gates for ~2s (20 × 100ms). Catches any trigger that was
  // missed (KVO TOCTOU, overwritten one-shot callback). Stops on reveal or timeout.
  private func startRevealWatchdog() {
    stopRevealWatchdog()
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
      guard let self = self else { timer.invalidate(); return }
      if self.didReveal { self.stopRevealWatchdog(); return }
      self.watchdogTicks += 1
      if self.watchdogTicks > 20 { self.stopRevealWatchdog(); return }
      self.attemptReveal()
    }
    // .common so it still fires while the feed is mid-scroll (default mode is paused
    // during UIScrollView tracking).
    RunLoop.main.add(timer, forMode: .common)
    revealWatchdog = timer
  }

  private func stopRevealWatchdog() {
    revealWatchdog?.invalidate()
    revealWatchdog = nil
    watchdogTicks = 0
  }

  func unbindPlayer() {
    pendingPlayerInstance = nil
    stopRevealWatchdog()
    didReveal = false
    statusObservation?.invalidate()
    statusObservation = nil
    currentItemObservation?.invalidate()
    currentItemObservation = nil
    readyForDisplayObservation?.invalidate()
    readyForDisplayObservation = nil
    // Release display ownership if we held it, so a stale weak ref can't block the next bind.
    if playerInstance >= 0, playerInstance < PlayerVideo.instances.count {
      let owner = PlayerVideo.instances[playerInstance]
      if owner.boundDisplayLayer === videoPlayerLayer {
        owner.boundDisplayLayer = nil
      }
    }
    videoPlayerLayer.player = nil
  }


}