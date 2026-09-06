package com.i99dev.ilink.nav.controller

import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import com.i99dev.ilink.nav.NavHudOptions
import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavSourceId
import com.i99dev.ilink.nav.logic.HudFailSafe
import com.i99dev.ilink.nav.logic.NavGuidanceCoalescer
import com.i99dev.ilink.nav.logic.NavTextNormalizer
import com.i99dev.ilink.nav.logic.RoadNameCache
import com.i99dev.ilink.nav.transport.HudTransport

/**
 * The single orchestration point. Runs every push on ONE dedicated `nav-hud`
 * thread (single-producer → the tested [NavGuidanceCoalescer] / [HudFailSafe]
 * stay lock-free), never on the Flutter main thread or a binder callback.
 *
 * ## Wide-car "drive all" model
 * BYD trims with an IDENTICAL `ro.vehicle.type` can read DIFFERENT cluster
 * protocols (e.g. Leopard 8 reads SOME/IP RoadInfo; a code40d-376 Di5.1 trim reads
 * the instrument HAL / CAN-FID), so picking one transport by static detection is
 * fundamentally undecidable. Instead — like the reference, which always drives the BYD
 * HAL + SOME/IP + the Amap broadcast together — we push every frame to ALL
 * AVAILABLE transports at once. The cluster renders from whichever channel it
 * subscribes to and ignores the rest; a failing channel is swallowed, never
 * demotes the others. [NavHudOptions.clusterProtocol] lets the user force a single
 * protocol (`someip`/`canfid`) for diagnosis; default `auto` = all available.
 *
 * Responsibilities: select the active transport SET (availability ∩ override),
 * drive the [HudFailSafe] keyframe machine + the [NavGuidanceCoalescer], keepalive
 * re-push between sparse frames, and clear the cluster when the source ends.
 *
 * The pure decisions are unit-tested in NavCoreTest; this class is the Android glue.
 */
class HudController(
    private val transports: List<HudTransport>,
    /** Always-on additive sinks (e.g. the BYD Amap broadcast) driven on every push
     *  regardless of the protocol override; each self-gates and swallows its errors. */
    private val auxTransports: List<HudTransport> = emptyList(),
    private val tickIntervalMs: Long = 1_000L,
    bucketMeters: Int = 50,
) {
    private val coalescer = NavGuidanceCoalescer(bucketMeters)
    private val failSafe = HudFailSafe()
    private val roadCache = RoadNameCache()

    private var counter = 0
    private var lastSource: NavSourceId? = null
    // The current guidance, re-pushed every tick (keepalive) so the BYD cluster
    // — which auto-hides guidance after a few seconds of no fresh event — keeps
    // showing it between sparse source frames. Cleared only on disarm or a long
    // abandonment (nav genuinely ended), NOT on the short per-source TTL.
    @Volatile private var lastFrame: NavGuidance? = null
    @Volatile private var lastSourceFrameMs = 0L
    // The PRIOR same-source frame's (distance, time). Lets tick() extrapolate the
    // distance DOWN at the rate the source last moved, so the cluster counts down
    // smoothly between sparse source frames instead of jumping (a backgrounded
    // Google Maps posts its nav notification only every ~6-8s, in ~100m steps).
    @Volatile private var prevDist: Int? = null
    @Volatile private var prevMs = 0L

    // Latest-wins burst handling (anti-lag): a frame that arrives while one is
    // still being processed REPLACES the queued one.
    @Volatile private var pending: Pair<NavGuidance, Long>? = null
    @Volatile private var draining = false
    @Volatile private var sourceGoneAtMs = 0L

    // Every transport we're currently driving (availability ∩ user override).
    @Volatile private var activeTransports: List<HudTransport> = emptyList()
    @Volatile private var armed = false
    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    /** Live state for the diagnostics/status surface. */
    val isArmed: Boolean get() = armed

    /** Names of the transports actually being driven ("SOME_IP+CAN_FID"), or null. */
    val activeTransportName: String?
        get() = activeTransports.takeIf { it.isNotEmpty() }?.joinToString("+") { it.name }

    /** Is ANY active transport actually linked (e.g. SOME/IP bound)? The M0 signal. */
    val activeConnected: Boolean
        get() = activeTransports.any { runCatching { it.connected() }.getOrDefault(false) }

    /** Pushes that reached at least one transport (so the UI can show data flows). */
    @Volatile var pushedFrames: Int = 0
        private set

    /** Begin driving the cluster. Selects the transport SET + starts the stale-tick. */
    fun arm() {
        if (armed) return
        val t = HandlerThread("nav-hud").also { it.start() }
        thread = t
        handler = Handler(t.looper)
        armed = true
        post {
            selectTransports()
            auxTransports.forEach { runCatching { it.start() } }
            scheduleTick()
        }
    }

    /** Stop driving, clear the cluster, tear down the transports + thread. */
    fun disarm() {
        if (!armed) return
        armed = false
        val h = handler
        val t = thread
        h?.post {
            activeTransports.forEach { runCatching { it.clear(); it.stop() } }
            auxTransports.forEach { runCatching { it.clear(); it.stop() } }
            activeTransports = emptyList()
            coalescer.reset(); failSafe.reset(); roadCache.reset(); lastSource = null
            h.removeCallbacksAndMessages(null)
            t?.quitSafely()
        }
        thread = null; handler = null
    }

    /** Feed the arbiter's winning frame + that source's freshness TTL (latest-wins). */
    fun submit(winning: NavGuidance, sourceTtlMs: Long) {
        if (!armed) return
        pending = winning to sourceTtlMs
        post { drain() }
    }

    /** Called by the registry when a source signals it ended (notification removed). */
    fun onSourceGone(id: NavSourceId) {
        if (!armed) return
        post { if (id == lastSource) sourceGoneAtMs = now() }
    }

    // --- nav-hud thread only below ---

    private fun drain() {
        if (draining) return
        draining = true
        try {
            while (true) {
                val (frame, ttl) = pending ?: break
                pending = null
                onFrame(frame, ttl)
            }
        } finally {
            draining = false
            if (pending != null) post { drain() }
        }
    }

    private fun onFrame(frame: NavGuidance, ttlMs: Long) {
        // Re-select if we somehow have nothing (e.g. armed before a transport
        // became available). Aux sinks still fire even with no primary.
        if (activeTransports.isEmpty()) selectTransports()

        val switched = lastSource != null && lastSource != frame.source
        if (switched) { coalescer.reset(); roadCache.reset(); prevDist = null }
        lastSource = frame.source

        val action = failSafe.onFrame(now(), ttlMs)
        val keyframe = switched || action == HudFailSafe.Action.PUSH_KEYFRAME
        // Suppress an out-of-range icon (parser glitch) → 0 sentinel; retain the last
        // non-blank road for a beat (anti-flicker); then normalize text ONCE here so
        // every transport + the keepalive share one clean, pre-folded frame.
        val iconSafe = if (frame.hasDrawableIcon) frame else frame.copy(maneuverIcon = 0)
        val retained = iconSafe.copy(roadName = roadCache.resolve(iconSafe.roadName, now()))
        val safe = NavTextNormalizer.apply(retained, NavHudOptions.transliterate)
        // Anchor the prior same-source frame so tick() can extrapolate distance down
        // (reset above on a source switch, so a rate never carries across apps).
        if (!switched) { prevDist = lastFrame?.distanceMeters; prevMs = lastSourceFrameMs }
        lastFrame = safe // keepalive re-push + extrapolation anchor
        lastSourceFrameMs = now()
        if (!switched) sourceGoneAtMs = 0L
        val toPush = coalescer.next(safe, keyframe) ?: return
        pushFrame(toPush)
    }

    /** Fan one frame out to EVERY active transport + every aux sink. A transport
     *  that throws (bind dropped, daemon not up yet) is swallowed and keeps getting
     *  later frames — so it recovers on its own without dropping the others. */
    private fun pushFrame(frame: NavGuidance) {
        counter = (counter + 1) and 0xFF
        var anyOk = false
        for (t in activeTransports) {
            if (runCatching { t.push(frame, counter) }.isSuccess) anyOk = true
        }
        for (aux in auxTransports) runCatching { aux.push(frame, counter) }
        if (anyOk) pushedFrames++
    }

    private fun tick() {
        if (!armed) return
        val f = lastFrame
        if (f != null && activeTransports.isNotEmpty()) {
            val now = now()
            // PRIMARY clear: the driving source signalled it ended + the grace
            // elapsed. BACKSTOP: no fresh source frame for a long time (crash, no
            // removal signal). The 1s keepalive paints between these.
            val goneExpired = sourceGoneAtMs != 0L && now - sourceGoneAtMs > SOURCE_GONE_GRACE_MS
            val abandoned = now - lastSourceFrameMs > ABANDON_MS
            if (goneExpired || abandoned) {
                activeTransports.forEach { runCatching { it.clear() } }
                auxTransports.forEach { runCatching { it.clear() } }
                coalescer.reset()
                roadCache.reset()
                failSafe.onStop()
                lastFrame = null
                sourceGoneAtMs = 0L
            } else {
                pushFrame(extrapolate(f, now))
            }
        }
        scheduleTick()
    }

    /** Between sparse source frames, count the distance DOWN at the rate the source
     *  itself last moved (its prior two same-source frames), so the cluster ticks
     *  smoothly instead of jumping when a backgrounded app posts slowly. HARD-RESYNCS
     *  to the real value on every source frame (submit overwrites the anchor).
     *  Safeguards: only downward, never < 0, never > the real value; freeze when the
     *  source didn't advance (stopped) or distance went UP (reroute); inert until a
     *  second same-source frame establishes a rate. */
    private fun extrapolate(f: NavGuidance, now: Long): NavGuidance {
        val cur = f.distanceMeters ?: return f
        val p = prevDist ?: return f
        val dt = lastSourceFrameMs - prevMs
        if (dt <= 0L) return f
        val drop = p - cur
        if (drop <= 0) return f
        val est = (cur - drop.toDouble() / dt * (now - lastSourceFrameMs)).toInt()
        val clamped = est.coerceIn(0, cur)
        return if (clamped != cur) f.copy(distanceMeters = clamped) else f
    }

    /** Pick the transport SET to drive: every transport that is available AND
     *  allowed by the user's protocol override, then start each. */
    private fun selectTransports() {
        val sel = transports.filter {
            protocolAllows(it) && runCatching { it.isAvailable() }.getOrDefault(false)
        }
        activeTransports = sel
        if (sel.isEmpty()) {
            Log.w(TAG, "no HUD transport available (protocol=${NavHudOptions.clusterProtocol})")
            return
        }
        sel.forEach { t ->
            runCatching { t.start() }
                .onFailure { Log.w(TAG, "start ${t.name} failed: ${it.message}") }
        }
        Log.i(TAG, "HUD transports = ${sel.joinToString { it.name }}")
    }

    /** Honour the user's protocol override: `someip`/`canfid` force a single
     *  channel; anything else (default `auto`) drives all available. */
    private fun protocolAllows(t: HudTransport): Boolean = when (NavHudOptions.clusterProtocol) {
        "someip" -> t.name == "SOME_IP"
        "canfid" -> t.name == "CAN_FID"
        else -> true
    }

    private fun post(r: () -> Unit) {
        val h = handler
        if (h != null) h.post(r) else r()
    }

    private fun scheduleTick() {
        handler?.postDelayed({ tick() }, tickIntervalMs)
    }

    private fun now() = SystemClock.elapsedRealtime()

    fun dispose() = disarm()

    companion object {
        private const val TAG = "HudController"

        /** Backstop only: no fresh source frame for this long ⇒ clear. */
        private const val ABANDON_MS = 45_000L

        /** Grace after the driving source's notification is removed before clearing. */
        private const val SOURCE_GONE_GRACE_MS = 12_000L
    }
}
