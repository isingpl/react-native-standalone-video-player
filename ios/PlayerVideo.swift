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
  
  private var timeObserver: Any?
  
  private var observersAdded = false
  private var timer: Timer?
  private var timerAdded = false
  
  private var shouldLoop = true

  private let DEBUG = false

  // we could have one AVPlayer and multiple items
  let player: AVPlayer = AVPlayer()
  
  //
  // Public
  //
  
  @objc
  var duration: Double {
    if let duration = player.currentItem?.asset.duration {
        return duration.seconds
    }

    return 0.0
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
  
  //
    
    private let TAG = "PLAAAYER"
    
    private func log(_ text: String) {
        if(!DEBUG) {return}

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = dateFormatter.string(from: Date())
        
        print("\(TAG) [\(timestamp)] \(text)")
    }
  
  @objc
  func load(url: String) {
      log("load url: \(url)")

    // Configure AVAudioSession to play sound even in silent mode
    do {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try AVAudioSession.sharedInstance().setActive(true)
    } catch {
        log("Failed to set AVAudioSession category: \(error.localizedDescription)")
    }

    shouldPlay = autoplay
    
    guard let videoUrl = URL(string: url) else {
      setStatus(.error)
        
      return
    }
    
    let asset = AVAsset(url: videoUrl)
    
    let playerItem = AVPlayerItem(asset: asset)
    
    player.replaceCurrentItem(with: playerItem)
    
    setStatus(.new)
    
    addObservers()
  }
  
  @objc
  func play() {
      log("play")
    
    player.play()
      
    shouldPlay = true
    
    setStatus(.playing)
  }
  
  @objc
  func pause() {
      log("pause")
    
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
      log("stop")
    
    player.pause()
    
    shouldPlay = false
    
    seekToZero()
    
    setStatus(.stoped)
    
    progressChanged?(0, duration)
    
    removeObservers()
  }
  
  // 0 <= position <= 1.0
  @objc
  func seekTo(position: Double) {
      log("SEEEEK TO = \(position)")
    
    let progress = min(1.0, max(0.0, position))
    
    guard let currentItem = player.currentItem else { return }
    
    self.isSeeking = true
    
    progressChanged?(progress, duration)
    
    if progress == 0.0 {
        seekToZero()

        // set progress 0
    } else {
        let time = CMTime(seconds: progress * currentItem.asset.duration.seconds, preferredTimescale: currentItem.asset.duration.timescale)
      
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { [weak self] (finished) in
          
            self?.log("SEEEEK TO = \(position), finished=\(finished)")

          if finished == false {
            // seek started
          } else {
            self?.didSeek(progress: progress)
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
      log("NEW STATUS = \(newStatus.print())")
    
    self.status = newStatus
    
    statusChanged?(status)
  }
  
  private func addObservers() {
      log("videoPlayer addObservers")
    guard let playerItem = player.currentItem else { return }
      
    playerItem.addObserver(self, forKeyPath: "status", options: [], context: nil)
    playerItem.addObserver(self, forKeyPath: "playbackBufferEmpty", options: [], context: nil)
    playerItem.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: [], context: nil)
      
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
        timerAdded = false
    }

    
    private func handleTick(time: CMTime) {
        guard self.status == .playing else {return}

          self.log("interval run")
        let currentTime = time.seconds
        let progress = currentTime / (self.duration != 0.0 ? self.duration : 1.0)

        if (!self.isSeeking) {
          self.progressChanged?(progress, self.duration)
        }
        
        if (progress >= 0.99) {
          if (self.shouldLoop) {
            self.log("video playback end")
            self.seekToZero()
            self.play()
          } else {
            self.stop()
          }
        }
    }
  
  private func removeObservers() {
    guard let playerItem = player.currentItem else { return }
    
    log("remove observers")
      
    guard observersAdded else { return } // dont remove when not added
    
    playerItem.removeObserver(self, forKeyPath: "status")
    playerItem.removeObserver(self, forKeyPath: "playbackBufferEmpty")
    playerItem.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
    
    stopTimer()
    
    observersAdded = false
  }
  
  //
  //
  //
  
  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
      
    guard let asset = object as? AVPlayerItem, let keyPath = keyPath else { return }
    
    guard asset == player.currentItem else { return }
        
      log("OBSERVER keyPath=\(keyPath), status=\(asset.status.rawValue), isPlaybackLikelyToKeepUp=\(asset.isPlaybackLikelyToKeepUp)")
        
    if (keyPath == "status") {
        switch (asset.status) {
        case .failed:
            
            setStatus(.error)
            
            break
            
        // this may be called also when binding to view (I dont know why)..
        case .readyToPlay:
            
            if (shouldPlay) {
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
      log("buffering = \(isBuffering), status=\(status.print())")
      
    if (isBuffering) {
      if (status != .stoped && status != .error && status != .none) {
        setStatus(.loading)
      }
    } else {
      setStatus(shouldPlay ? .playing : .paused)
    }
  }
  
  //
  
  fileprivate func seekToZero() {
    log("videoPlayer seekToZero")
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


