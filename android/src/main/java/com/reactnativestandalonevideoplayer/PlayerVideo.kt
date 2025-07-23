package com.reactnativestandalonevideoplayer

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.MediaItem
import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.source.ProgressiveMediaSource
import com.google.android.exoplayer2.source.hls.HlsMediaSource
import com.google.android.exoplayer2.upstream.DefaultDataSource
import com.google.android.exoplayer2.video.VideoSize

class PlayerVideo(private val context: Context) {

  private var status: PlayerVideoStatus = PlayerVideoStatus.none

  private var progressHandler: Handler? = null
  private var progressRunnable: Runnable? = null

  private val PROGRESS_UPDATE_TIME: Long = 1000

  val player: ExoPlayer = ExoPlayer.Builder(context).setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING).build()

  var autoplay: Boolean = true

  var statusChanged: ((status: PlayerVideoStatus) -> Unit)? = null

  var progressChanged: ((progress: Double, duration: Double) -> Unit)? = null

  var videoSizeChanged: ((width: Int, height: Int) -> Unit)? = null

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
        Log.d("PlayerVideo", "DURRRRR: TIME_UNSET")
        return 0.0
      }
      val dur = player.duration.toDouble()
      Log.d("PlayerVideo", "DURRRRR: $dur")
      return dur
    }
    set(_) {}

  var position: Double
    get() = player.currentPosition.toDouble()
    set(_) {}

  var progress: Double
    get() = if (player.duration > 0) player.currentPosition.toDouble() / player.duration.toDouble() else 0.0
    set(_) {}

  fun loadVideo(url: String, isHls: Boolean, loop: Boolean) {
    Log.d("PlayerVideo", "load = $url")

    val dataSourceFactory = DefaultDataSource.Factory(context)

    val mediaItem = MediaItem.fromUri(Uri.parse(url))
    val mediaSource = if (isHls) {
      HlsMediaSource.Factory(dataSourceFactory).createMediaSource(mediaItem)
    } else {
      ProgressiveMediaSource.Factory(dataSourceFactory).createMediaSource(mediaItem)
    }

    player.setMediaSource(mediaSource)
    player.prepare()

    player.playWhenReady = autoplay
    player.repeatMode = if (loop) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF

    setStatus(PlayerVideoStatus.new)

    player.addListener(object : Player.Listener {
      override fun onPlayerStateChanged(playWhenReady: Boolean, playbackState: Int) {
        Log.d("PlayerVideo", "onPlaybackStateChanged = $playbackState")
        when (playbackState) {
          Player.STATE_IDLE -> setStatus(PlayerVideoStatus.none)
          Player.STATE_BUFFERING -> setStatus(PlayerVideoStatus.loading)
          Player.STATE_READY -> setStatus(if (player.playWhenReady) PlayerVideoStatus.playing else PlayerVideoStatus.paused)
          Player.STATE_ENDED -> {
            setStatus(PlayerVideoStatus.finished)
            stopProgressTimer()
          }
        }
      }

      override fun onVideoSizeChanged(videoSize: VideoSize) {
        super.onVideoSizeChanged(videoSize)
        Log.d("PlayerVideo", "onVideoSizeChanged width=${videoSize.width}, height=${videoSize.height}")
        videoSizeChanged?.invoke(videoSize.width, videoSize.height)
      }
    })

    startProgressTimer()
  }

  fun play() {
    Log.d("PlayerVideo", "play")
    if (status == PlayerVideoStatus.finished) {
      seek(0.0)
    }
    player.play()
    startProgressTimer()
  }

  fun pause() {
    Log.d("PlayerVideo", "pause")
    player.pause()
    stopProgressTimer()
  }

  fun stop() {
    Log.d("PlayerVideo", "stop")
    player.stop()
    setStatus(PlayerVideoStatus.stopped)
    stopProgressTimer()
  }

  fun seek(progress: Double) {
    Log.d("PlayerVideo", "seek: $progress")
    player.seekTo((duration * progress).toLong())
  }

  fun seekForward(time: Double) {
    Log.d("PlayerVideo", "Seek forward position=$position, by=${time*1000}")
    player.seekTo((position + time*1000).toLong())
  }

  fun seekRewind(time: Double) {
    Log.d("PlayerVideo", "Seek rewind position=$position, by=${time*1000}")
    player.seekTo((position - time * 1000).toLong())
  }

  fun release() {
    player.release()
  }

  private fun setStatus(newStatus: PlayerVideoStatus) {
    status = newStatus
    Log.d("PlayerVideo", "NEW status = $status")
    statusChanged?.invoke(status)
    if (status == PlayerVideoStatus.stopped || status == PlayerVideoStatus.none || status == PlayerVideoStatus.error) {
      stopProgressTimer()
    }
  }

  private fun startProgressTimer() {
    progressHandler = Handler(Looper.getMainLooper())
    progressRunnable = object : Runnable {
      override fun run() {
        progressChanged?.invoke(progress, duration)
        progressHandler?.postDelayed(this, PROGRESS_UPDATE_TIME)
      }
    }
    progressRunnable?.let {
      progressHandler?.postDelayed(it, 0)
    }
  }

  private fun stopProgressTimer() {
    progressRunnable?.let {
      progressHandler?.removeCallbacks(it)
    }
  }

  companion object {
    var instances: MutableList<PlayerVideo> = mutableListOf()
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
