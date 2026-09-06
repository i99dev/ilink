package com.i99dev.ilink.nav.ingest

import android.os.SystemClock
import com.i99dev.ilink.nav.controller.HudController
import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavSourceId
import com.i99dev.ilink.nav.logic.SourceArbiter
import java.util.concurrent.ConcurrentHashMap

/**
 * Holds the [NavSource]s, arbitrates on every emitted frame (the tested
 * [SourceArbiter]), and feeds the winner to the [HudController]. THE place the
 * per-app TTLs and the user pin live.
 *
 * Frames are keyed by their OWN [NavGuidance.source] (set by each source from
 * [NavAppRegistry]), so a single multi-app source (the notification listener)
 * can drive many apps at once. TTLs come from [NavAppRegistry].
 */
class NavSourceRegistry(
    private val sources: List<NavSource>,
    private val controller: HudController,
    /** THE single position read in the nav stack — stamped onto every frame here
     *  so no [NavSource] has to know about location. Defaults to "no position",
     *  which reproduces today's behaviour exactly (and keeps tests Android-free). */
    private val location: NavLocationCache? = null,
) {
    private val latest = ConcurrentHashMap<NavSourceId, SourceArbiter.Candidate>()

    @Volatile var pinned: NavSourceId? = null

    /** Which app is driving + what — for the diagnostics surface. Re-arbitrated
     *  LIVE on read so it respects each source's staleness TTL: once every source
     *  goes stale (all maps closed) this returns null and the panel shows
     *  "Waiting…" instead of sticking on the last app forever. (A stored field
     *  was only updated on a fresh winner, so a closed app never cleared.) */
    val lastWinner: NavGuidance?
        get() = SourceArbiter.arbitrate(
            candidates = latest,
            nowMs = now(),
            pinned = pinned,
            ttlMs = NavAppRegistry.TTL_MS.ifEmpty { SourceArbiter.DEFAULT_TTL_MS },
        )

    fun start() {
        controller.arm()
        sources.forEach { s ->
            s.start(
                onFrame = { frame -> onFrame(frame) },
                onGone = { id -> controller.onSourceGone(id) },
            )
        }
    }

    fun stop() {
        sources.forEach { runCatching { it.stop() } }
        controller.disarm()
        location?.reset()
        latest.clear()
        NavActiveApp.clear()
    }

    private fun onFrame(raw: NavGuidance) {
        // Ingest boundary: stamp position ONCE, here. Throttled+permission-checked
        // inside the cache; null (no fix / no permission) leaves the frame untouched.
        val frame = raw.withPosition(location?.current())
        val id = frame.source
        latest[id] = SourceArbiter.Candidate(frame, now())
        val winner = SourceArbiter.arbitrate(
            candidates = latest,
            nowMs = now(),
            pinned = pinned,
            ttlMs = NavAppRegistry.TTL_MS.ifEmpty { SourceArbiter.DEFAULT_TTL_MS },
        ) ?: return
        // Publish which "rich" (a11y-scraped) app is currently driving the cluster.
        // STALE-COMMENT FIX: this used to read "so the a11y service can keep it
        // rendering on a keepalive VirtualDisplay (Workstream B, gated)". That
        // VirtualDisplay — and the `am start --display` relocation behind it — was
        // deleted in `e9835e25` because it ping-ponged single-task maps on-car. It is
        // not coming back; background reads are now passive (NavA11yDispatcher's
        // all-displays scan reads windows that already exist).
        // NavActiveApp therefore currently has NO reader. Kept as a cheap volatile
        // holder rather than deleted in this fix's blast radius; deleting it is a
        // separate, safe cleanup.
        NavActiveApp.set(winner.source)
        controller.submit(winner, NavAppRegistry.TTL_MS[winner.source] ?: 10_000L)
    }

    private fun now() = SystemClock.elapsedRealtime()
}
