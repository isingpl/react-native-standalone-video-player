@file:OptIn(androidx.media3.common.util.UnstableApi::class)

package com.reactnativestandalonevideoplayer


import android.content.Context
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.util.AttributeSet
import android.view.LayoutInflater
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.RNTPlayerVideoViewManagerDelegate
import com.facebook.react.viewmanagers.RNTPlayerVideoViewManagerInterface
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView


class MyPlayerView : PlayerView {
  constructor(context: Context) : super(context)
  constructor(context: Context, attrs: AttributeSet?) : super(context, attrs)
  constructor(context: Context, attrs: AttributeSet?, defStyleAttr: Int) : super(context, attrs, defStyleAttr)


  var playerInstance: Int = -1
  var isBound: Boolean = false
  private var hasRenderedFirstFrame: Boolean = false

  // Video size tracked here so we can apply a center-crop Matrix transform to the
  // underlying TextureView. AspectRatioFrameLayout's RESIZE_MODE_ZOOM does not work
  // inside React Native because Yoga overrides the layout's onMeasure result and
  // forces the contentFrame back to the JS-cell dimensions, leaving no surface for
  // cropping. Applying a Matrix on the TextureView is independent of layout passes.
  private var videoW = 0
  private var videoH = 0
  private var videoPixelRatio = 1f
  private var videoUnappliedRotation = 0
  internal var attachedPlayer: Player? = null
    private set

  // Tracks video metrics so applyContentTransform can do center-crop on the TextureView
  // (resize_mode="fill" in XML stretches; the Matrix does the aspect-preserving crop).
  // Listener is intentionally minimal — extra overrides (onPlaybackStateChanged, etc.)
  // were added during freeze debug and removed because their Log.d calls on the player
  // looper were piling up during rapid tab-switch view churn.
  private val aspectListener = object : Player.Listener {
    override fun onVideoSizeChanged(videoSize: VideoSize) {
      videoW = videoSize.width
      videoH = videoSize.height
      videoPixelRatio = videoSize.pixelWidthHeightRatio
      videoUnappliedRotation = videoSize.unappliedRotationDegrees
      applyContentTransform()
    }
  }

  override fun setPlayer(player: Player?) {
    attachedPlayer?.removeListener(aspectListener)
    super.setPlayer(player)
    attachedPlayer = player
    if (player != null) {
      player.addListener(aspectListener)
      val vs = player.videoSize
      videoW = vs.width
      videoH = vs.height
      videoPixelRatio = vs.pixelWidthHeightRatio
      videoUnappliedRotation = vs.unappliedRotationDegrees
    } else {
      videoW = 0
      videoH = 0
      hasRenderedFirstFrame = false
    }
    applyContentTransform()
  }

  // Force-unbind without clearing the player's output Surface.
  //
  // The standard force-unbind path (prior.setPlayer(null)) is needed to remove listener
  // subscriptions so the dropped view's aspectListener/analyticsListener don't leak.
  // BUT calling setPlayer(null) on PlayerView also calls player.clearVideoSurfaceView(),
  // which forces ExoPlayer to switch MediaCodec.setOutputSurface() to a placeholder/null
  // surface. Then the *new* view's setPlayer(player) schedules setVideoSurfaceView(newSV)
  // which waits for surfaceCreated, then issues another MediaCodec.setOutputSurface(new).
  // The clear → wait → set sequence opens a window where MediaCodec's BufferQueue
  // producer/consumer can desync — frames decode and `renderedOutputBufferCount`
  // increments, but SurfaceFlinger never composites them. User sees a frozen frame
  // on the new view while audio + karaoke continue.
  //
  // This method removes listeners + marks unbound but leaves attachedPlayer's surface
  // alone. The new view's PlayerView.setPlayer(player) will call setVideoSurfaceView(newSV)
  // which transitions MediaCodec's output surface directly from old → new, no clear gap.
  fun unbindPreserveSurface() {
    attachedPlayer?.removeListener(aspectListener)
    attachedPlayer = null
    isBound = false
    hasRenderedFirstFrame = false
  }

  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    applyContentTransform()
  }

  private fun applyContentTransform() {
    val surface = videoSurfaceView ?: return
    val viewW = width.toFloat()
    val viewH = height.toFloat()
    if (viewW <= 0f || viewH <= 0f || videoW <= 0 || videoH <= 0) return

    // Account for non-square pixels and 90/270 rotation (mirrors PlayerView.updateAspectRatio).
    var videoAspect = (videoW * videoPixelRatio) / videoH
    if (videoUnappliedRotation == 90 || videoUnappliedRotation == 270) {
      videoAspect = 1f / videoAspect
    }
    val viewAspect = viewW / viewH

    val sx: Float
    val sy: Float
    if (videoAspect > viewAspect) {
      // Video is wider than the cell — filling the cell would squeeze it horizontally.
      // Scale X up so the video keeps its aspect; horizontal overflow is cropped at the
      // cell boundary by the JS wrapper's overflow:hidden.
      sx = videoAspect / viewAspect
      sy = 1f
    } else {
      sx = 1f
      sy = viewAspect / videoAspect
    }

    when (surface) {
      is TextureView -> {
        val matrix = Matrix()
        matrix.setScale(sx, sy, viewW / 2f, viewH / 2f)
        surface.setTransform(matrix)
        surface.invalidate()
      }
      // SurfaceView has no setTransform; scale the view itself (the parent FrameLayout clips the
      // overflow) for the same aspect-preserving center-crop the TextureView Matrix gave. Without
      // this, resize_mode="fill" just stretches the video to the (often square) cell.
      is SurfaceView -> {
        surface.pivotX = surface.width / 2f
        surface.pivotY = surface.height / 2f
        surface.scaleX = sx
        surface.scaleY = sy
      }
    }
  }

  // Recover from a frozen video state after rapid Surface swap. Two distinct hypotheses
  // covered here:
  //
  // (1) MediaCodec.setOutputSurface() raced with old-surface destruction during the
  //     view swap (force-unbind on RDS close): MediaCodec keeps decoding but its output
  //     surface reference is stale. `renderedOutputBufferCount` increments because
  //     releaseOutputBuffer returns OK against the stale ref. Fix: re-bind player to
  //     surface → forces a fresh MediaCodec.setOutputSurface call.
  //
  // (2) SurfaceFlinger Layer detached from display tree (compositor bug). Fix:
  //     INVISIBLE→VISIBLE toggle wakes the Layer.
  //
  // Guarded by hasRenderedFirstFrame so we don't disturb a view still in initial bind —
  // the JS hook fires on RDS close, and the new feed view may not have had its first
  // frame yet. Toggling visibility on a SurfaceView mid-init can destroy/recreate the
  // Surface and race ExoPlayer's setOutputSurface call → makes things worse.
  fun refreshCompositor() {
    val sv = videoSurfaceView as? android.view.SurfaceView ?: return
    val p = attachedPlayer ?: return
    if (!hasRenderedFirstFrame) return
    // (1) Re-bind player to surface — forces MediaCodec.setOutputSurface call.
    p.clearVideoSurfaceView(sv)
    p.setVideoSurfaceView(sv)
    // (2) Visibility toggle — Layer state-change for SurfaceFlinger.
    sv.visibility = View.INVISIBLE
    Handler(Looper.getMainLooper()).post {
      sv.visibility = View.VISIBLE
    }
  }

  fun awaitFirstFrame() {
    if (playerInstance < 0 || playerInstance >= PlayerVideo.instances.size) return

    val playerVideo = PlayerVideo.instances[playerInstance]

    // SurfaceView path would need a different masking strategy (parent alpha may not
    // gate SurfaceFlinger Layers reliably across Android versions); current XML uses
    // texture_view so the alpha=0 fade-in works as the cover-image → video transition.
    val isSurfaceView = videoSurfaceView is android.view.SurfaceView
    if (!isSurfaceView) {
      alpha = 0f
    }
    // Use the dedicated view-callback slot so we don't clobber the JS-event emitter
    // installed by StandaloneVideoPlayer.load() (which is what `usePlayerReadyForDisplay`
    // depends on). Both callbacks are invoked from PlayerVideo.onRenderedFirstFrame.
    //
    // WeakReference so a dropped MyPlayerView can GC even if the callback slot
    // isn't explicitly nulled. Critical: RN can mount a new view BEFORE dropping
    // the old one on the same playerInstance (feed→details→feed), so nulling in
    // onDropViewInstance could wipe out a fresh callback the new view just set.
    // Weak ref avoids that race AND prevents the ~20 MB-per-view retain leak.
    val weakSelf = java.lang.ref.WeakReference(this)
    playerVideo.viewReadyForDisplayCallback = {
      Handler(Looper.getMainLooper()).post {
        val self = weakSelf.get() ?: return@post
        // The view pool keeps dropped views strongly referenced, so the weak ref no
        // longer dies on drop — gate on isBound so a stale closure can't animate a
        // pooled (or recycled-into-another-cell) view.
        if (!self.isBound) return@post
        self.hasRenderedFirstFrame = true
        if (self.alpha < 1f) self.animate().alpha(1f).setDuration(150).start()
      }
    }
  }

  // Return the view to a freshly-inflated state so the pool can hand it to the next
  // mount. Anything awaitFirstFrame/applyContentTransform/setPlayer touched must be
  // reset here — a recycled view with stale alpha/scale/video-size is exactly the
  // "stale native state" class of bug the iOS Fabric recycling fix dealt with.
  fun resetForPool() {
    animate().cancel()
    alpha = 1f
    isBound = false
    playerInstance = -1
    hasRenderedFirstFrame = false
    videoW = 0
    videoH = 0
    videoPixelRatio = 1f
    videoUnappliedRotation = 0
    (videoSurfaceView as? SurfaceView)?.let {
      it.scaleX = 1f
      it.scaleY = 1f
    }
    (videoSurfaceView as? TextureView)?.setTransform(null)
  }
}

//

@ReactModule(name = PlayerContainerView.NAME)
class PlayerContainerView : SimpleViewManager<MyPlayerView>(),
  RNTPlayerVideoViewManagerInterface<MyPlayerView> {

  // Fabric delegate forwards setProperty(view, name, value) calls from the
  // codegen-generated ShadowNode/Props path to the typed methods below.
  // Old-arch builds skip the delegate and reach the @ReactProp setters directly,
  // so we keep both surfaces wired (the @ReactProp annotations are no-ops under
  // Fabric but stay for interop / dev-mode reload safety).
  private val delegate: RNTPlayerVideoViewManagerDelegate<MyPlayerView, PlayerContainerView> =
    RNTPlayerVideoViewManagerDelegate(this)

  override fun getDelegate(): ViewManagerDelegate<MyPlayerView> = delegate

  override fun getName() = NAME

  @ReactProp(name = "isBoundToPlayer")
  override fun setIsBoundToPlayer(view: MyPlayerView, value: Boolean) {
    view.isBound = value
    setup(view)
  }

  @ReactProp(name = "playerInstance")
  override fun setPlayerInstance(view: MyPlayerView, value: Int) {
    view.playerInstance = value
    setup(view)
  }

  private fun setup(view: MyPlayerView) {
    if (view.playerInstance < 0 || view.playerInstance >= PlayerVideo.instances.size) {
      return
    }

    // Singleton-bind per playerInstance. When the JS tree re-renders to swap which
    // MyPlayerView is bound (feed cell ↔ RDS MainRecordingPlayer), React unmount of
    // the prior view sometimes doesn't propagate to native onDropViewInstance under
    // Fabric — the old MyPlayerView lingers with aspectListener still subscribed AND
    // its TextureView still referenced by ExoPlayer (whichever setPlayer ran last
    // wins). Force-unbind the prior view here so listeners are removed deterministically.
    val prior = activeBoundViews[view.playerInstance]
    activeBoundViews[view.playerInstance] = view

    val playerVideo = PlayerVideo.instances[view.playerInstance]
    val currentPlayer = if (view.isBound) playerVideo.player else null
    // Bind the NEW view first so the player's output surface transitions directly old→new
    // (setVideoSurfaceView) with no clear→wait→set gap.
    view.player = currentPlayer

    view.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FILL

    // Now release the prior view. ROOT LEAK FIX: unbindPreserveSurface() removed only our
    // aspectListener and deliberately skipped super.setPlayer(null) to dodge the surface-clear
    // race — but super.setPlayer(null) is what removes media3 PlayerView's + PlayerControlView's
    // OWN internal listeners from the pooled, app-lifetime ExoPlayer. Skipping it left every
    // prior MyPlayerView (plus its whole inflated PlayerControlView subtree) retained by the
    // player → ~80 leaked Views per RDS open/close (heap-confirmed). Because the new view above
    // already took the surface, prior.setPlayer(null)'s clearVideoSurfaceView(priorSV) is now a
    // no-op (player is on the new surface) yet it DOES drop those internal listeners → no leak,
    // no race. If the new view isn't displaying this player (not bound), keep the old
    // surface-preserving partial unbind.
    if (prior != null && prior !== view && prior.attachedPlayer != null) {
      if (currentPlayer != null && view.isBound) {
        prior.player = null
      } else {
        prior.unbindPreserveSurface()
      }
    }

    if (view.isBound && currentPlayer != null) {
      view.awaitFirstFrame()
    }

    // loadVideo releases the underlying ExoPlayer and swaps in a fresh one to
    // prevent MediaCodec accumulation. When that happens, rebind the view's
    // surface to the new player so rendering continues without a dead reference.
    // WeakReference mirrors awaitFirstFrame — dropped views GC via weak ref
    // rather than explicit null-on-drop (which would race with fresh views
    // binding to the same instance).
    val weakView = java.lang.ref.WeakReference(view)
    playerVideo.playerReplaced = { newPlayer ->
      val v = weakView.get()
      if (v != null && v.isBound) v.player = newPlayer
    }
  }

  //

  override fun onDropViewInstance(view: MyPlayerView) {
    view.isBound = false

    // Remove from singleton map if still pointing here.
    if (view.playerInstance >= 0 && activeBoundViews[view.playerInstance] === view) {
      activeBoundViews.remove(view.playerInstance)
    }

    // Clear the playerReplaced callback set by this view's setup. The next view to
    // bind to this instance will install its own callback in setup().
    if (view.playerInstance in PlayerVideo.instances.indices) {
      PlayerVideo.instances[view.playerInstance].playerReplaced = null
    }

    // If this view was already unbound via setup() force-unbind, the player has moved
    // to a new MyPlayerView and we MUST NOT call super.setPlayer(null) here — that
    // would call player.clearVideoSurfaceView(oldSV). If the player's current video
    // output is the new view's SurfaceView, the clear is a no-op (mismatch). But if
    // the drop fires before the new view's surfaceCreated callback, ExoPlayer's
    // pending setVideoSurfaceView(newSV) is still on the old SurfaceView — the clear
    // forces MediaCodec.setOutputSurface to a dummy, racing the new view's bind.
    // Leaving PlayerView's internal player reference dangling is a one-frame leak
    // (cleared on GC once RN finishes view recycle).
    if (view.attachedPlayer != null) {
      view.player = null
    }

    // Pool the view so the next mount (every RDS open inflates a fresh MyPlayerView —
    // 14-25ms of synchronous UI-thread inflate landing inside the open-slide frames)
    // reuses it instead. Only pool a FULLY detached view: if PlayerView's internal
    // player ref is still set (unbindPreserveSurface path — clearing it here risks the
    // documented MediaCodec surface-clear freeze race), let the view GC as before.
    if (view.player == null && viewPool.size < POOL_MAX) {
      (view.parent as? android.view.ViewGroup)?.removeView(view)
      view.resetForPool()
      viewPool.addLast(view)
      android.util.Log.d("asd_ViewPool", "pooled (size=${viewPool.size})")
    } else {
      android.util.Log.d("asd_ViewPool", "discarded (player=${view.player != null}, size=${viewPool.size})")
    }
    super.onDropViewInstance(view)
  }

  override fun createViewInstance(reactContext: ThemedReactContext): MyPlayerView {
    // Reuse a pooled view when its context matches the current React instance
    // (a Metro reload creates a new ReactContext — pooled views from the old one
    // would retain it, so discard the pool on mismatch).
    while (viewPool.isNotEmpty()) {
      val pooled = viewPool.removeFirst()
      if (pooled.context === reactContext) {
        android.util.Log.d("asd_ViewPool", "reuse (size=${viewPool.size})")
        return pooled
      }
    }
    android.util.Log.d("asd_ViewPool", "inflate")
    return inflateView(reactContext)
  }

  private fun inflateView(reactContext: ThemedReactContext): MyPlayerView {
    val playerView = LayoutInflater.from(reactContext)
      .inflate(R.layout.my_player_view, null) as MyPlayerView

    playerView.useController = false
    playerView.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FILL
    playerView.player = null

    // Mark the TextureView as non-opaque so it actually honors `alpha` set on its
    // ancestors (the alpha-fade in MyPlayerView.awaitFirstFrame). With the default
    // opaque=true, TextureView uses an optimized compositing path that can ignore
    // ancestor alpha and leak the uninitialized texture buffer (solid black) through
    // a parent that is logically alpha=0 — this is the intermittent black blink the
    // user sees when switching from the details player to the feed item.
    (playerView.videoSurfaceView as? TextureView)?.isOpaque = false

    return playerView
  }

  companion object {
    const val NAME = "RNTPlayerVideoView"

    // Singleton map: which MyPlayerView is the active bound view per playerInstance.
    // Used by setup() to force-unbind a prior view that JS removed from the tree but
    // whose native onDropViewInstance hasn't fired yet (Fabric unmount race).
    val activeBoundViews: MutableMap<Int, MyPlayerView> = mutableMapOf()

    // Recycled MyPlayerViews (XML inflate is 14-25ms on the UI thread; every RDS
    // open used to pay it mid-slide). Main-thread only — Fabric create/drop both
    // run on the UI thread.
    private const val POOL_MAX = 3
    val viewPool: ArrayDeque<MyPlayerView> = ArrayDeque()
  }
}
