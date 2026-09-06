package com.i99dev.ilink.nav.ingest

import android.os.SystemClock

/**
 * Live on-screen crop of Waze's lane-guidance row (`:id/laneGuidanceView` bounds),
 * published by the a11y service (which holds the window root) and read each frame by
 * the capture side (which holds the pixels) — the lane-row twin of [WazeArrowBounds].
 * Stored as ints (pure crop math) and time-bounded so a stale rect isn't cropped
 * after Waze leaves the foreground / the lane row disappears.
 */
object WazeLaneBounds {

    data class Crop(val left: Int, val top: Int, val width: Int, val height: Int)

    @Volatile private var crop: Crop? = null
    @Volatile private var atMs: Long = 0L

    /** Publish the lane-row bounds. Degenerate / oversized rects are ignored. The
     *  lane row is wide + short; allow a generous width. */
    fun update(left: Int, top: Int, width: Int, height: Int) {
        if (width in 1..8192 && height in 1..4096) {
            crop = Crop(left, top, width, height)
            atMs = SystemClock.elapsedRealtime()
        }
    }

    /** Fresh lane-row crop within [maxAgeMs], or null (the capture loop skips it). */
    fun latest(maxAgeMs: Long = 2_000L): Crop? {
        val c = crop ?: return null
        return if (SystemClock.elapsedRealtime() - atMs <= maxAgeMs) c else null
    }

    fun clear() {
        crop = null
        atMs = 0L
    }
}
