package com.i99dev.ilink.nav.ingest

import android.os.SystemClock

/**
 * Latest Waze maneuver code from the arrow-capture pipeline
 * ([com.i99dev.ilink.nav.ingest.WazeArrowCaptureService]). The Waze a11y
 * source reads it as its maneuver (Waze renders the arrow as a bitmap, so it
 * can't come from text). Time-bounded so a stale arrow doesn't linger.
 */
object WazeArrowBus {
    @Volatile private var code: Int = 0
    @Volatile private var atMs: Long = 0L

    fun update(maneuverCode: Int) {
        code = maneuverCode
        atMs = SystemClock.elapsedRealtime()
    }

    /** The fresh arrow code (1..49) within [maxAgeMs], or null. */
    fun latest(maxAgeMs: Long = 4_000L): Int? {
        val c = code
        return if (c in 1..49 && SystemClock.elapsedRealtime() - atMs <= maxAgeMs) c else null
    }
}
