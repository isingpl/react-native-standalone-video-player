@file:OptIn(androidx.media3.common.util.UnstableApi::class)

package com.reactnativestandalonevideoplayer

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.common.VideoSize
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

class PlayerVideo(private val context: Context) {

  private var status: PlayerVideoStatus = PlayerVideoStatus.none

  private var progressHandler: Handler? = null
  private var progressRunnable: Runnable? = null
  private var muted = false

  private val PROGRESS_UPDATE_TIME: Long = 1000

  // Pitch-preserving playback speed (1.0 = normal). ExoPlayer is recreated per loadVideo(), so this
  // is held on the PlayerVideo instance and re-applied to each fresh player after prepare().
  private var desiredSpeed: Float = 1f

  // Tighter buffer window (10/20/1/2.5s vs default 50/50/2.5/5s) for short-form
  // feed across 3 instances. Declared before `player` — Kotlin inits fields in
  // declaration order and `buildPlayer()` reads `loadControl`.
  private val loadControl: DefaultLoadControl = DefaultLoadControl.Builder()
    .setBufferDurationsMs(
      /* minBufferMs = */ 10_000,
      /* maxBufferMs = */ 20_000,
      /* bufferForPlaybackMs = */ 1_000,
      /* bufferForPlaybackAfterRebufferMs = */ 2_500
    )
    .build()

  // Created fresh per buildPlayer() (player is recreated each load). Held so
  // setMuted can toggle audio-track decoding on the live instance.
  private var trackSelector: DefaultTrackSelector? = null

  // Mutable so loadVideo can release + recreate the underlying ExoPlayer.
  // ExoPlayer 2.19.0 retains MediaCodec decoders across setMediaSource + prepare
  // calls; the pool reuse pattern caused ~21 MB of GPU-side memory to leak per
  // load (observed +382 MB PSS over a short feed-scroll session). Release on
  // every load is the guaranteed way to free all owned resources (codecs,
  // DataSource threads, HlsMediaSource internals, renderer caches).
  var player: ExoPlayer = buildPlayer()
    private set

  private fun buildPlayer(): ExoPlayer {
    aliveCount.incrementAndGet()
    totalBuilt.incrementAndGet()
    // Skip audio decode while muted (idle/preloaded feed instances). Re-enabled by
    // setMuted/loadVideo when the video becomes audible. (No video-resolution cap:
    // the feed HLS serves a single 1024×576 AVC rendition with no ABR ladder, so a
    // setMaxVideoSize/Bitrate ceiling has nothing to select below — it was inert.)
    val selector = DefaultTrackSelector(context).apply {
      setParameters(
        buildUponParameters()
          .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, muted)
      )
    }
    trackSelector = selector
    return ExoPlayer.Builder(context)
      .setLoadControl(loadControl)
      .setTrackSelector(selector)
      .build()
      .apply { volume = 1f }
  }

  private fun applyAudioDisabled(disabled: Boolean) {
    val selector = trackSelector ?: return
    selector.setParameters(
      selector.buildUponParameters().setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, disabled)
    )
  }

  // Fires after the internal ExoPlayer is swapped so the bound MyPlayerView
  // can rebind its TextureView surface to the fresh instance before playback
  // begins. Single-slot — at most one MyPlayerView binds to each pool instance
  // at a time; setup() registers, onDropViewInstance unregisters.
  var playerReplaced: ((newPlayer: ExoPlayer) -> Unit)? = null

  var autoplay: Boolean = true

  var statusChanged: ((status: PlayerVideoStatus) -> Unit)? = null

  var progressChanged: ((progress: Double, duration: Double) -> Unit)? = null

  var videoSizeChanged: ((width: Int, height: Int) -> Unit)? = null

  var muteChanged: ((isMuted: Boolean) -> Unit)? = null

  var readyForDisplayChanged: (() -> Unit)? = null
  // Separate slot for the view-attached first-frame callback (used by MyPlayerView's
  // alpha fade-in). Kept distinct from `readyForDisplayChanged` so the JS-event emitter
  // installed by StandaloneVideoPlayer.load() and the per-view alpha closure don't
  // overwrite each other — both fire from onRenderedFirstFrame.
  var viewReadyForDisplayCallback: (() -> Unit)? = null
  var hasRenderedFirstFrame: Boolean = false

  // Fires on end-of-playthrough. `willRestart = true` on loop wrap (native
  // auto-transition with REPEAT_MODE_ALL); `false` on non-loop final end.
  // JS-side play-confirm tracker uses this to send a confirm and decide
  // whether to restart the listen-time counter for the next loop.
  var playbackEndReached: ((willRestart: Boolean) -> Unit)? = null

  private var playerListener: Player.Listener? = null

  var currentStatus: PlayerVideoStatus
    get() = status
    set(value) {}

  var isPlaying: Boolean
    get() = status == PlayerVideoStatus.playing
    set(value) {}

  var isLoaded: Boolean
    get() = status == PlayerVideoStatus.playing || status == PlayerVideoStatus.paused || status == PlayerVideoStatus.loading
    set(value) {}

  var isLoading: Boolean
    get() = status == PlayerVideoStatus.loading
    set(value) {}

  var volume: Float
    get() = player.volume
    set(value) { player.volume = value }

  var duration: Double
    get() {
      if (player.duration == C.TIME_UNSET) {
        return 0.0
      }
      val dur = player.duration.toDouble()
      return dur
    }
    set(_) {}

  var position: Double
    get() = player.currentPosition.toDouble()
    set(_) {}

  var progress: Double
    get() = if (player.duration > 0) player.currentPosition.toDouble() / player.duration.toDouble() else 0.0
    set(_) {}

  fun loadVideo(url: String, isHls: Boolean, loop: Boolean, initialTime: Int, isSilent: Boolean = false) {
    val oldPlayer = player
    // Detach the surface from the old player BEFORE swap. Forces MediaCodec to
    // drain its output BufferQueue back to the SurfaceTexture pool synchronously.
    // Without this, rapid load() calls during fast feed scroll pile 14-20 pending
    // frames per slot in the shared SurfaceTexture (observed via
    // GraphicBufferAllocator on 2026-05-22), starving SurfaceFlinger's free-
    // buffer pool and blocking RenderThread's dequeueBuffer 20-30 ms per frame.
    oldPlayer.clearVideoSurface()
    player = buildPlayer()
    playerReplaced?.invoke(player)
    oldPlayer.release()
    aliveCount.decrementAndGet()
    totalReleased.incrementAndGet()
    // Trim idle HTTP connections held by the shared OkHttp pool. Each idle
    // connection can retain a multi-MB response-body buffer for up to the
    // keep-alive window. evictAll forces immediate cleanup instead of waiting.
    //
    // Dispatched off the main thread because evictAll() synchronously closes
    // SSL sockets (network I/O) — StrictMode raises NetworkOnMainThreadException
    // otherwise. OkHttp's own dispatcher executor is reused to avoid spawning
    // a fresh thread per loadVideo call.
    exoHttpClient.dispatcher.executorService.execute {
      exoHttpClient.connectionPool.evictAll()
    }
    playerListener = null
    hasRenderedFirstFrame = false
    // Do NOT null viewReadyForDisplayCallback here — awaitFirstFrame on the
    // currently-bound MyPlayerView has already set it to a closure capturing
    // the view's alpha fade-in. Nulling it would (a) break first-video
    // rendering (callback never fires, view stays at alpha=0) and (b) not
    // help stale-closure cleanup anyway, because onDropViewInstance now
    // clears this slot per-view-drop.

    // UA identifies the app on every ExoPlayer HTTP request (manifest, chunklist,
    // segments). DefaultHttpDataSource.Factory().setUserAgent() applies to all
    // HTTP fetches going through this data source.
    val versionName = try {
      context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""
    } catch (_: Exception) { "" }
    val userAgent = "${context.packageName}/$versionName"
    val httpDataSourceFactory = OkHttpDataSource.Factory(exoHttpClient)
      .setUserAgent(userAgent)
    val dataSourceFactory = DefaultDataSource.Factory(context, httpDataSourceFactory)
    // Disk-cache wrapper: REPEAT_MODE_ALL loop wraps re-prepare the MediaPeriod and
    // re-read the whole stream — measured 70-100 KB/s sustained wifi RX on an idle
    // looping feed video (~360 MB/h, radio never idles → heat). With the cache the
    // re-read hits disk. Also serves feed scroll-backs and RDS reopens.
    val cacheDataSourceFactory = CacheDataSource.Factory()
      .setCache(VideoCache.get(context))
      .setUpstreamDataSourceFactory(dataSourceFactory)
      .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

    val mediaItem = MediaItem.fromUri(Uri.parse(url))
    val mediaSource = if (isHls) {
      HlsMediaSource.Factory(cacheDataSourceFactory).createMediaSource(mediaItem)
    } else {
      ProgressiveMediaSource.Factory(cacheDataSourceFactory).createMediaSource(mediaItem)
    }

    // Apply mute state BEFORE prepare()/playWhenReady so a freshly loaded video
    // never produces a split-second of audible playback when the user has muted.
    muted = isSilent
    player.volume = if (isSilent) 0f else 1f
    // buildPlayer() above seeded the selector from the prior `muted`; resync to
    // this load's mute state before prepare so audio isn't decoded when silent.
    applyAudioDisabled(isSilent)
    muteChanged?.invoke(isSilent)

    player.setMediaSource(mediaSource, initialTime.toLong())
    player.prepare()

    player.playWhenReady = autoplay
    player.repeatMode = if (loop) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
    // Re-apply the chosen speed to the freshly built player (PlaybackParameters with pitch left at
    // 1.0 → ExoPlayer time-stretches, preserving pitch).
    if (desiredSpeed != 1f) {
      player.playbackParameters = PlaybackParameters(desiredSpeed)
    }

    setStatus(PlayerVideoStatus.new)

    playerListener = object : Player.Listener {
      override fun onPlaybackStateChanged(playbackState: Int) {
        when (playbackState) {
          Player.STATE_IDLE -> setStatus(PlayerVideoStatus.none)
          Player.STATE_BUFFERING -> setStatus(PlayerVideoStatus.loading)
          Player.STATE_READY -> setStatus(if (player.playWhenReady) PlayerVideoStatus.playing else PlayerVideoStatus.paused)
          Player.STATE_ENDED -> {
            playbackEndReached?.invoke(false)
            setStatus(PlayerVideoStatus.finished)
            stopProgressTimer()
          }
        }
      }

      override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
        if (player.playbackState == Player.STATE_READY) {
          setStatus(if (playWhenReady) PlayerVideoStatus.playing else PlayerVideoStatus.paused)
        }
      }

      override fun onPositionDiscontinuity(
        oldPosition: Player.PositionInfo,
        newPosition: Player.PositionInfo,
        reason: Int
      ) {
        // REPEAT_MODE_ALL wraps produce DISCONTINUITY_REASON_AUTO_TRANSITION.
        // Each wrap = one completed playthrough → emit end-of-playthrough.
        if (reason == Player.DISCONTINUITY_REASON_AUTO_TRANSITION) {
          playbackEndReached?.invoke(true)
        }
      }

      override fun onVideoSizeChanged(videoSize: VideoSize) {
        super.onVideoSizeChanged(videoSize)
        videoSizeChanged?.invoke(videoSize.width, videoSize.height)
      }

      override fun onRenderedFirstFrame() {
        hasRenderedFirstFrame = true
        readyForDisplayChanged?.invoke()      // JS event — installed by StandaloneVideoPlayer.load()
        viewReadyForDisplayCallback?.invoke() // alpha fade — installed by MyPlayerView.awaitFirstFrame()
      }
    }
    player.addListener(playerListener!!)

    startProgressTimer()
  }

  fun play() {
    if (status == PlayerVideoStatus.finished) {
      seek(0.0)
    }
    player.play()
    startProgressTimer()
  }

  fun pause() {
    player.pause()
    stopProgressTimer()
  }

  // Pitch-preserving playback speed (1.0 = normal). Applied to the live player and stored so
  // loadVideo() re-applies it to the next (recreated) player. Pitch left at 1.0 → ExoPlayer
  // time-stretches instead of resampling.
  fun setSpeed(speed: Double) {
    desiredSpeed = speed.toFloat()
    player.playbackParameters = PlaybackParameters(desiredSpeed)
  }

  fun stop() {
    player.stop()
    setStatus(PlayerVideoStatus.stopped)
    stopProgressTimer()
  }

  fun setMuted(isMuted: Boolean) {
    muted = isMuted
    if (player != null) {
      player.volume = if (isMuted) 0f else 1f
    }
    // Toggle audio decode live: unmute re-selects the audio track (ExoPlayer
    // resumes decoding seamlessly), mute drops it.
    applyAudioDisabled(isMuted)
    muteChanged?.invoke(isMuted)
  }


  fun isMuted(): Boolean {
    return muted
  }


  fun seek(progress: Double) {
    player.seekTo((duration * progress).toLong())
  }

  fun seekForward(time: Double) {
    player.seekTo((position + time*1000).toLong())
  }

  fun seekRewind(time: Double) {
    player.seekTo((position - time * 1000).toLong())
  }

  fun release() {
    player.release()
    aliveCount.decrementAndGet()
    totalReleased.incrementAndGet()
  }

  private fun setStatus(newStatus: PlayerVideoStatus) {
    if (status == newStatus) return
    status = newStatus
    statusChanged?.invoke(status)
    if (status == PlayerVideoStatus.stopped || status == PlayerVideoStatus.none || status == PlayerVideoStatus.error) {
      stopProgressTimer()
    }
  }

  private fun startProgressTimer() {
    // Cancel currently-tracked runnable on the current handler before we
    // reassign the fields. Load callsites that don't pause first (preloadNext,
    // autoplay effect, active-change) would otherwise strand the previous
    // runnable, and because its body posts via the instance field it would
    // migrate onto the new handler and tick forever alongside the new one.
    stopProgressTimer()

    // Capture handler in a local val so the runnable reposts to its own
    // handler, not whatever progressHandler has been reassigned to later.
    val handler = Handler(Looper.getMainLooper())
    val runnable = object : Runnable {
      override fun run() {
        progressChanged?.invoke(progress, duration)
        handler.postDelayed(this, PROGRESS_UPDATE_TIME)
      }
    }
    progressHandler = handler
    progressRunnable = runnable
    handler.postDelayed(runnable, 0)
  }

  private fun stopProgressTimer() {
    progressRunnable?.let {
      progressHandler?.removeCallbacks(it)
    }
  }

  companion object {
    var instances: MutableList<PlayerVideo> = mutableListOf()

    // Diagnostic counters: track ExoPlayer churn (build/release per feed scroll, etc.)
    val aliveCount = java.util.concurrent.atomic.AtomicInteger(0)
    val totalBuilt = java.util.concurrent.atomic.AtomicInteger(0)
    val totalReleased = java.util.concurrent.atomic.AtomicInteger(0)

    // Shared OkHttp client for ExoPlayer HTTP. Bounded ConnectionPool (vs
    // OkHttp's default 5 idle × 5 min) prevents response-body buffers from
    // piling up across rapid video swaps during feed scroll. evictAll() is
    // called from loadVideo after oldPlayer.release() to actively trim idle
    // connections that would otherwise linger for minutes.
    val exoHttpClient: OkHttpClient = OkHttpClient.Builder()
      .connectionPool(ConnectionPool(3, 30L, TimeUnit.SECONDS))
      .build()
  }
}

enum class PlayerVideoStatus(val value: Int) {
  new(0),
  loading(1),
  playing(2),
  paused(3),
  error(4),
  stopped(5),
  none(6),
  finished(7)
}

fun printPlayerStatus(status: PlayerVideoStatus): String {
  return status.name
}
