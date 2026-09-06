package com.i99dev.ilink.nav.logic

/**
 * Anti-flicker road-name retention — ported from the reference's `utils/RoadNameCache`.
 * A nav app's road node occasionally reads blank for a single frame (the view is
 * mid-update between maneuvers); without retention that empty string would blank
 * the cluster's road line for a beat. This keeps the last non-blank name for a
 * short window so a momentary blank doesn't blink it.
 *
 * Pure + host-testable (caller passes `nowMs`); reset on source switch / disarm.
 */
class RoadNameCache(private val retainMs: Long = 1_000L) {

    private var last: String = ""
    private var atMs: Long = 0L

    /**
     * The road name to actually use: the [incoming] one when non-blank (also
     * refreshing the cache), else the retained name while still within [retainMs],
     * else blank.
     */
    fun resolve(incoming: String, nowMs: Long): String {
        if (incoming.isNotBlank()) {
            last = incoming
            atMs = nowMs
            return incoming
        }
        return if (last.isNotBlank() && nowMs - atMs <= retainMs) last else ""
    }

    fun reset() {
        last = ""
        atMs = 0L
    }
}
