import Foundation

@objc(StandaloneVideoPlayer)
class StandaloneVideoPlayer: RCTEventEmitter {

    // Module binds AVPlayer instances + sets PlayerVideoView.onReadyForDisplay in init —
    // all main-thread work. Required on the new architecture to avoid the background-init warning.
    @objc override static func requiresMainQueueSetup() -> Bool {
        return true
    }

    override func supportedEvents() -> [String]! {
        return ["PlayerStatusChanged", "PlayerProgressChanged", "PlayerMuteChanged", "PlayerReadyForDisplay", "PlayerPlaybackEnded"]
    }

    override init() {
        super.init()

        PlayerVideoView.onReadyForDisplay = { [weak self] instance in
            self?.sendEvent(withName: "PlayerReadyForDisplay", body: ["instance": instance])
        }
    }


    //

    @objc(newInstance)
    func newInstance() -> Void {
        _=PlayerVideo.newInstance()
    }

    //
  
    @objc(setMuted:isMuted:)
    func setMuted(instance: Int, isMuted: Bool) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else { return }
        let player = PlayerVideo.instances[instance]

        player.setMuted(isMuted: isMuted)

        if player.muteChanged == nil {
            player.muteChanged = { isMuted in
                self.sendEvent(withName: "PlayerMuteChanged", body: [
                    "isMuted": isMuted,
                    "instance": instance
                ])
            }
        }
    }

  //
  
    @objc(getMuted:resolve:reject:)
    func getMuted(instance: Int, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else {
            resolve(0)
            return
        }
        
        let isMuted = PlayerVideo.instances[instance].player.isMuted
        resolve(isMuted)
    }

    //

    @objc(load:url:isHls:loop:isSilent:initialTime:)
    func load(instance: Int, url: String, isHls hls: Bool, loop: Bool, isSilent silent: Bool, initialTime: Int) -> Void {
        guard instance >= 0 && instance < PlayerVideo.instances.count else { return }

        let player = PlayerVideo.instances[instance]
        player.shouldRecordingLoop = loop

        player.statusChanged = { status in
            self.sendEvent(withName: "PlayerStatusChanged", body: ["status" : status.rawValue, "instance": instance])
        }

        player.progressChanged = { progress, duration in
            self.sendEvent(withName: "PlayerProgressChanged", body: ["progress" : progress, "duration" : duration, "instance": instance])
        }

        player.playbackEndReached = { willRestart in
            self.sendEvent(withName: "PlayerPlaybackEnded", body: [
                "instance": instance,
                "willRestart": willRestart
            ])
        }

        player.load(url: url)
        // Apply initial seek from JS (media_start_time * 1000). Mirrors Android's
        // load() which honors initialTime. AVPlayer queues this seek against the
        // freshly-attached item, so duration doesn't need to be resolved yet.
        if initialTime > 0 {
            player.seekToSeconds(seconds: Double(initialTime) / 1000.0)
        }
        // Honor the `silent` flag — mirrors Android (StandaloneVideoPlayer.kt sets
        // volume = 0f when isSilent). Without this, preloaded next-item recordings
        // load with full volume and play audibly alongside the active feed item;
        // they also keep playing when the app goes to background because they're
        // not bound to a SingleVideoPlayer view and so have no AppState pause handler.
        // Calling setMuted with `silent` (rather than only when true) also correctly
        // unmutes a previously-silent instance when it is re-loaded as the active item.
        player.setMuted(isMuted: silent)
    }
    
    //
    @objc(seek:position:)
    func seek(instance: Int, position: Double) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else { return }

        PlayerVideo.instances[instance].seekTo(position: position)
    }

    //

    @objc(setSpeed:speed:)
    func setSpeed(instance: Int, speed: Double) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else { return }

        PlayerVideo.instances[instance].setSpeed(speed)
    }
    
    //
    
    @objc(seekForward:time:)
    func seekForward(instance: Int, time: Double) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else { return }
        
        PlayerVideo.instances[instance].seekForward(time: time)
    }
    
    //
    
    @objc(seekRewind:time:)
    func seekRewind(instance: Int, time: Double) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else { return }
        
        PlayerVideo.instances[instance].seekRewind(time: time)
    }
    
    //
    
    @objc(play:)
    func play(instance: Int) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else { return }
        
        PlayerVideo.instances[instance].play()
    }
    
    //
    
    @objc(pause:)
    func pause(instance: Int) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else { return }
        
        PlayerVideo.instances[instance].pause()
    }
    
    
    //
    
    @objc(stop:)
    func stop(instance: Int) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else { return }

        PlayerVideo.instances[instance].stop()
    }

    //

    @objc(unload:)
    func unload(instance: Int) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else { return }

        PlayerVideo.instances[instance].unload()
    }

    // No-op on iOS — Android-only workaround for SurfaceFlinger Layer-detach bug.
    // Method must exist on both platforms because the TurboModule spec is shared.
    @objc(refreshCompositor:)
    func refreshCompositor(instance: Int) {}
    
    //
    
    @objc(clear)
    func clear() {
        PlayerVideo.clear()
    }
    
    //
    
    @objc(getDuration:resolve:reject:)
    func getDuration(instance: Int, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else {
          resolve(0)
          return
        }
        
        let duration = PlayerVideo.instances[instance].duration
        resolve(duration)
    }

    //

    @objc(getProgress:resolve:reject:)
    func getProgress(instance: Int, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        guard instance >= 0 && instance < PlayerVideo.instances.count else {
            resolve(0)
            return
        }

        let progress = PlayerVideo.instances[instance].progress
        resolve(progress)
    }

}
