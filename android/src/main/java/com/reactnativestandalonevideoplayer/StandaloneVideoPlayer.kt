package com.reactnativestandalonevideoplayer


import android.os.Handler
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.Arguments
import com.facebook.react.module.annotations.ReactModule

// TurboModule impl. Extends codegen-generated abstract class (NativeStandaloneVideoPlayerSpec)
// produced from src/NativeStandaloneVideoPlayer.ts at build time. Method signatures must
// match the spec (TS `number` → Java `double`; cast inside bodies to existing Int/Long shapes).
@ReactModule(name = StandaloneVideoPlayer.NAME)
class StandaloneVideoPlayer(val context: ReactApplicationContext) : NativeStandaloneVideoPlayerSpec(context), LifecycleEventListener {

  init {
    context.addLifecycleEventListener(this)
    // Seeding is now JS-driven (see ensureInstances in src/index.tsx). Keeping
    // a newInstance() here added a "hidden" slot 0 that the JS-local counter
    // didn't know about, so the wrapper's load() guard would always spawn
    // duplicate natives on first use of each slot.
  }

  //
  // LifecycleEventListener
  //
  override fun onHostResume() {
  }

  override fun onHostPause() {
    for (instance in PlayerVideo.instances) {
      instance.pause()
    }
  }

  override fun onHostDestroy() {
    Handler(context.mainLooper).post {
      for (instance in PlayerVideo.instances) {
        instance.stop()
        instance.release()
      }
    }
  }

  // Fires on RN bridge teardown (dev fast refresh, prod bridge rebuild).
  // Without this, the companion-object instances list survived the old module
  // and the next init re-seeded on top, growing the list unboundedly.
  override fun invalidate() {
    super.invalidate()
    Handler(context.mainLooper).post {
      for (instance in PlayerVideo.instances) {
        instance.stop()
        instance.release()
      }
      PlayerVideo.instances.clear()
    }
  }

  //
  // TurboModule methods (match generated abstract signatures — all numerics as double)
  //

  override fun newInstance() {
    Handler(context.mainLooper).post {
      val instance = PlayerVideo(context)
      PlayerVideo.instances.add(instance)
    }
  }

  override fun load(instance: Double, url: String, isHls: Boolean, loop: Boolean, isSilent: Boolean, initialTime: Double) {
    val idx = instance.toInt()
    val startMs = initialTime.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      return
    }

    Handler(context.mainLooper).post {
      PlayerVideo.instances[idx].statusChanged = { status ->
        val map = Arguments.createMap()
        map.putInt("status", status.value)
        map.putInt("instance", idx)

        context.emitDeviceEvent("PlayerStatusChanged", map)
      }

      PlayerVideo.instances[idx].progressChanged = { progress, duration ->
        val map = Arguments.createMap()
        map.putDouble("progress", progress)
        map.putDouble("duration", duration / 1000)
        map.putInt("instance", idx)

        context.emitDeviceEvent("PlayerProgressChanged", map)
      }

      PlayerVideo.instances[idx].readyForDisplayChanged = {
        val map = Arguments.createMap()
        map.putInt("instance", idx)

        context.emitDeviceEvent("PlayerReadyForDisplay", map)
      }

      PlayerVideo.instances[idx].playbackEndReached = { willRestart ->
        val map = Arguments.createMap()
        map.putInt("instance", idx)
        map.putBoolean("willRestart", willRestart)

        context.emitDeviceEvent("PlayerPlaybackEnded", map)
      }

      PlayerVideo.instances[idx].loadVideo(url, isHls, loop, startMs, isSilent)
    }
  }

  override fun stop(instance: Double) {
    val idx = instance.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      return
    }

    Handler(context.mainLooper).post {
      PlayerVideo.instances[idx].stop()

      PlayerVideo.instances[idx].statusChanged = null
    }
  }

  override fun play(instance: Double) {
    val idx = instance.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      return
    }

    Handler(context.mainLooper).post {
      PlayerVideo.instances[idx].play()
    }
  }

  override fun pause(instance: Double) {
    val idx = instance.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      return
    }

    Handler(context.mainLooper).post {
      PlayerVideo.instances[idx].pause()
    }
  }

  override fun seek(instance: Double, position: Double) {
    val idx = instance.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      return
    }

    Handler(context.mainLooper).post {
      PlayerVideo.instances[idx].seek(position)
    }
  }

  override fun setSpeed(instance: Double, speed: Double) {
    val idx = instance.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      return
    }

    Handler(context.mainLooper).post {
      PlayerVideo.instances[idx].setSpeed(speed)
    }
  }

  override fun seekForward(instance: Double, time: Double) {
    val idx = instance.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      return
    }

    Handler(context.mainLooper).post {
      PlayerVideo.instances[idx].seekForward(time)
    }
  }

  override fun seekRewind(instance: Double, time: Double) {
    val idx = instance.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      return
    }

    Handler(context.mainLooper).post {
      PlayerVideo.instances[idx].seekRewind(time)
    }
  }

  override fun setMuted(instance: Double, isMuted: Boolean) {
    val idx = instance.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      return
    }

    Handler(context.mainLooper).post {
      PlayerVideo.instances[idx].muteChanged = { muted ->
        val map = Arguments.createMap()
        map.putInt("instance", idx)
        map.putBoolean("isMuted", muted)

        context.emitDeviceEvent("PlayerMuteChanged", map)
      }

      PlayerVideo.instances[idx].setMuted(isMuted)
    }
  }

  override fun getMuted(instance: Double, promise: Promise) {
    val idx = instance.toInt()
    if (idx in 0 until PlayerVideo.instances.size) {
      PlayerVideo.instances[idx].isMuted()
      val isMuted: Boolean = PlayerVideo.instances[idx].isMuted()
      promise.resolve(isMuted)
    } else {
      promise.resolve(false)
    }
  }

  override fun getDuration(instance: Double, promise: Promise) {
    val idx = instance.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      promise.resolve(0)
      return
    }

    Handler(context.mainLooper).post {
      val duration = PlayerVideo.instances[idx].duration / 1000
      promise.resolve(duration)
    }
  }

  override fun getProgress(instance: Double, promise: Promise) {
    val idx = instance.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      promise.resolve(0)
      return
    }

    Handler(context.mainLooper).post {
      val duration = PlayerVideo.instances[idx].progress
      promise.resolve(duration)
    }
  }

  override fun clear() {
    Handler(context.mainLooper).post {
      for (instance in PlayerVideo.instances) {
        instance.stop()
        instance.release()
      }
      PlayerVideo.instances.clear()
    }
  }

  // Android compositor refresh — see PlayerContainerView.MyPlayerView.refreshCompositor
  // for the why. Looked up via the activeBoundViews singleton because the bound view
  // is what owns the SurfaceView that needs the visibility toggle.
  override fun refreshCompositor(instance: Double) {
    val idx = instance.toInt()
    Handler(context.mainLooper).post {
      PlayerContainerView.activeBoundViews[idx]?.refreshCompositor()
    }
  }

  override fun unload(instance: Double) {
    val idx = instance.toInt()
    if (idx < 0 || idx >= PlayerVideo.instances.size) {
      return
    }
    Handler(context.mainLooper).post {
      PlayerVideo.instances[idx].stop()
      PlayerVideo.instances[idx].release()
    }
  }

  // Required by codegen spec — NativeEventEmitter compatibility. Events still emit via
  // RCTDeviceEventEmitter (see load() above); these are placeholders so addListener-style
  // JS subscriptions don't throw.
  override fun addListener(eventName: String) {
    // no-op
  }

  override fun removeListeners(count: Double) {
    // no-op
  }

  companion object {
    const val NAME = "StandaloneVideoPlayer"
  }
}
