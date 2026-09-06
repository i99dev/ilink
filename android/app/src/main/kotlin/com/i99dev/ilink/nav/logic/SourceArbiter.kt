package com.i99dev.ilink.nav.logic

import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavSourceId

/**
 * THE single point that decides which nav app drives the cluster. Pure — no
 * per-app or per-car table baked in: the priority order and the per-source
 * staleness TTLs are injected, so adding a nav app never edits this file.
 *
 * Rules (mirrors the reference's single-app pick, generalised):
 *  1. Active set = candidates whose frame is fresher than that source's TTL.
 *  2. Winner = the pinned source if it is active; else the active source with
 *     the most recent *drawable* (distance >= 0) frame; ties broken by the
 *     injected [priority] order.
 */
object SourceArbiter {

    /** Per-source freshness windows (ms). Ground truth: GMaps a11y 5s, Yandex
     *  icon 10s, Waze 40s expiry. Injected, not hard-wired into the arbiter. */
    val DEFAULT_TTL_MS: Map<NavSourceId, Long> = mapOf(
        NavSourceId.GOOGLE_MAPS to 5_000L,
        NavSourceId.YANDEX to 10_000L,
        NavSourceId.WAZE to 40_000L,
        NavSourceId.AMAP to 10_000L,
    )

    val DEFAULT_PRIORITY: List<NavSourceId> = listOf(
        NavSourceId.WAZE, NavSourceId.GOOGLE_MAPS, NavSourceId.YANDEX, NavSourceId.AMAP,
    )

    data class Candidate(val frame: NavGuidance, val lastFrameMs: Long)

    /**
     * @param candidates latest frame + its arrival time per source
     * @param nowMs current clock
     * @param pinned user-pinned source, or null
     * @return the winning frame, or null if nothing is active/drawable
     */
    fun arbitrate(
        candidates: Map<NavSourceId, Candidate>,
        nowMs: Long,
        pinned: NavSourceId? = null,
        ttlMs: Map<NavSourceId, Long> = DEFAULT_TTL_MS,
        priority: List<NavSourceId> = DEFAULT_PRIORITY,
    ): NavGuidance? {
        val active = candidates.filterValues { c ->
            val ttl = ttlMs[c.frame.source] ?: 10_000L
            (nowMs - c.lastFrameMs) <= ttl && c.frame.isDrawable
        }
        if (active.isEmpty()) return null

        pinned?.let { p -> active[p]?.let { return it.frame } }

        // most-recent drawable; ties → injected priority (lower index wins)
        return active.values
            .sortedWith(
                compareByDescending<Candidate> { it.lastFrameMs }
                    .thenBy { priority.indexOf(it.frame.source).let { i -> if (i < 0) Int.MAX_VALUE else i } },
            )
            .first().frame
    }
}
