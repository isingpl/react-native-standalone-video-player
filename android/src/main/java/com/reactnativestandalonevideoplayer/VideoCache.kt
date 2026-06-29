package com.reactnativestandalonevideoplayer

import android.content.Context
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File

// Process-wide singleton — SimpleCache throws if two instances open the same directory,
// and all three player instances share it. Disk LRU so a looping feed video replays from
// disk instead of re-streaming (REPEAT_MODE_ALL wraps create a fresh MediaPeriod, so the
// in-memory back buffer can never serve a loop); also serves scroll-backs and RDS reopens.
object VideoCache {
  private const val MAX_BYTES = 256L * 1024 * 1024

  @Volatile private var instance: SimpleCache? = null

  fun get(context: Context): SimpleCache =
    instance ?: synchronized(this) {
      instance ?: SimpleCache(
        File(context.cacheDir, "feed-video-cache"),
        LeastRecentlyUsedCacheEvictor(MAX_BYTES),
        StandaloneDatabaseProvider(context)
      ).also { instance = it }
    }
}
