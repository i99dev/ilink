package com.i99dev.ilink.nav.ingest

import android.os.SystemClock
import com.i99dev.ilink.nav.domain.NavLane

/**
 * Latest Waze lane guidance from the capture pipeline (segment + classify of the
 * `:id/laneGuidanceView` row) — the lane twin of [WazeArrowBus]. The Waze a11y
 * source reads it and attaches it to the emitted frame; the SOME/IP codec already
 * serializes [NavLane]. Time-bounded so a stale lane row doesn't linger.
 */
object WazeLaneBus {
    @Volatile private var lane: NavLane? = null
    @Volatile private var atMs: Long = 0L

    fun update(value: NavLane?) {
        lane = value
        atMs = SystemClock.elapsedRealtime()
    }

    /** The fresh lane within [maxAgeMs], or null. */
    fun latest(maxAgeMs: Long = 4_000L): NavLane? {
        val l = lane ?: return null
        return if (SystemClock.elapsedRealtime() - atMs <= maxAgeMs) l else null
    }

    fun clear() {
        lane = null
        atMs = 0L
    }
}
