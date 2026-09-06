package com.i99dev.ilink.nav.ingest

import android.os.SystemClock
import java.util.concurrent.ConcurrentHashMap

/**
 * Latest maneuver code per nav-app package, derived from that app's ONGOING
 * notification (title / large-icon arrow) by
 * [com.i99dev.ilink.nav.logic.NavManeuverExtractor].
 *
 * This is the single authority for the turn direction. The accessibility sources
 * read it (via their maneuverProvider) instead of classifying their own view-id
 * text — on these apps that text doesn't carry the direction (the cue node is a
 * street, the arrow is a bitmap or a non-phrase content-description), so a11y
 * classification defaults and paints the wrong arrow. The notification carries
 * the real maneuver, so we make it the source of truth and keep a11y for
 * distance / road / ETA only.
 *
 * Process-local, lock-free, O(1) read. Time-bounded so a stale maneuver from a
 * notification that stopped updating doesn't linger past its app's freshness
 * window. Mirrors [WazeArrowBus] but keyed by package (one entry per nav app).
 */
object NavManeuverBus {

    private data class Stamped(val code: Int, val atMs: Long, val expiresAtMs: Long = Long.MAX_VALUE)

    private val byPackage = ConcurrentHashMap<String, Stamped>()

    /** Publish the maneuver derived from [pkg]'s latest notification. Codes
     *  outside 1..49 are ignored (a non-maneuver must never overwrite a good
     *  code — the caller already maps "couldn't decide" to null/no-call). */
    fun set(pkg: String, maneuverCode: Int) {
        if (maneuverCode in 1..49) {
            byPackage[pkg] = Stamped(maneuverCode, SystemClock.elapsedRealtime())
        }
    }

    /** The fresh maneuver (1..49) for [pkg] within [maxAgeMs], or null when
     *  absent or stale. Callers pass the source's arbiter TTL so the maneuver is
     *  exactly as fresh as the frame it decorates, and fall back to STRAIGHT (as
     *  before) when this is null. */
    fun latest(pkg: String, maxAgeMs: Long = 8_000L): Int? {
        val s = byPackage[pkg] ?: return null
        val now = SystemClock.elapsedRealtime()
        if (now >= s.expiresAtMs) return null // soft-clear deadline passed
        return if (now - s.atMs <= maxAgeMs) s.code else null
    }

    /** Hard clear (immediate). */
    fun clear(pkg: String) {
        byPackage.remove(pkg)
    }

    /** Soft clear: keep serving the last maneuver for [graceMs] (so an a11y window
     *  still on-screen during the source-gone grace reads the correct arrow, not a
     *  defaulted one — e.g. the arrival arrow while decelerating), then stop. Matches
     *  the controller's source-gone grace. No-op if the package has no maneuver. */
    fun clearAfter(pkg: String, graceMs: Long) {
        val s = byPackage[pkg] ?: return
        byPackage[pkg] = s.copy(expiresAtMs = SystemClock.elapsedRealtime() + graceMs)
    }
}
