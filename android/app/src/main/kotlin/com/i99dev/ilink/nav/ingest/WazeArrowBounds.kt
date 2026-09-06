package com.i99dev.ilink.nav.ingest

import android.os.SystemClock

/**
 * Live on-screen crop of Waze's maneuver-arrow node (its `:id/navBarDirection`
 * bounds), published by [com.i99dev.ilink.input.RemoteControlAccessibilityService]
 * (which holds the live window root) and read each frame by [WazeArrowCaptureService]
 * (which holds the mirrored pixels). This is the seam between the two — the a11y
 * service can't read pixels (the ROM blocks the a11y screenshot API) and the capture
 * service can't read the node tree, so the crop rectangle crosses here.
 *
 * Stored as ints (not an Android Rect) so the crop math stays pure + host-testable.
 * Time-bounded so a crop isn't run against a stale rect after Waze leaves the
 * foreground. Mirrors the reference's shared arrow-bounds singleton.
 */
object WazeArrowBounds {

    /** A crop rectangle in display-pixel coordinates. */
    data class Crop(val left: Int, val top: Int, val width: Int, val height: Int)

    @Volatile private var crop: Crop? = null
    @Volatile private var atMs: Long = 0L

    /** Publish the arrow node's on-screen bounds (from the a11y poll/event while
     *  Waze is foreground). Degenerate / oversized rects are ignored. */
    fun update(left: Int, top: Int, width: Int, height: Int) {
        if (width in 1..4096 && height in 1..4096) {
            crop = Crop(left, top, width, height)
            atMs = SystemClock.elapsedRealtime()
        }
    }

    /** Fresh arrow crop within [maxAgeMs], or null (the capture loop skips the frame).
     *  Crop is an immutable value — no defensive copy needed. */
    fun latest(maxAgeMs: Long = 2_000L): Crop? {
        val c = crop ?: return null
        return if (SystemClock.elapsedRealtime() - atMs <= maxAgeMs) c else null
    }

    fun clear() {
        crop = null
        atMs = 0L
    }
}
