package com.i99dev.ilink.nav.ingest

/**
 * The *decisions* the a11y nav read makes, extracted from the service so they can be
 * host-tested. Nothing here touches an [android.accessibilityservice.AccessibilityService],
 * an [android.view.accessibility.AccessibilityNodeInfo] or any other Android type — the
 * service keeps the I/O, this keeps the policy.
 *
 * Three decisions live here:
 *
 *  1. [isNavEvent] — the CHEAP GATE. Events from packages no nav source registered cost a
 *     single set lookup and nothing else. This is a perf guard and must stay one.
 *  2. [rootMatches] — never hand a source a tree that belongs to a different app. The
 *     service used to dispatch `rootInActiveWindow` under the *event's* package name, so a
 *     backgrounded map's event dispatched the FOREGROUND app's tree. That read finds no
 *     view-ids (they are prefixed with the map's package) and yields no frame, but it still
 *     consumes [A11yNavSource]'s 200 ms self-throttle — so a wrong-tree read at event
 *     cadence can throttle out the 600 ms poll's *correct* background read. That is an
 *     ingest-starvation mechanism, and this predicate closes it.
 *  3. [ScanGate] — the COST GATE in front of the all-displays window enumeration.
 *
 * ### Why the cost gate exists (the throttle-position finding)
 *
 * [A11yNavSource]'s 200 ms throttle is enforced *inside* `onWindow` — i.e. AFTER the root
 * has been fetched. It therefore bounds node-tree PARSING, not the window-enumeration IPC.
 * The reference implementation places its own 200 ms per-app throttle BEFORE it calls the
 * ladder, so the enumeration itself is what it rate-limits. To run the ladder from the
 * event path at all we need an equivalent gate in the same position, which is this one.
 */
object NavA11yReadPolicy {

    /**
     * Minimum interval between two all-displays window enumerations, from any caller.
     * Matches the reference's per-app read cadence. Shared by the event path and the
     * 600 ms poll so the two cannot double-scan.
     */
    const val SCAN_MIN_INTERVAL_MS = 200L

    /** Upper bound on the parent walk from an event's source node to its tree root.
     *  A malformed/looping tree must not spin the a11y thread. */
    const val MAX_PARENT_WALK = 64

    /**
     * The cheap gate: is this event worth spending any node-tree work on?
     *
     * True only when at least one nav source is armed AND the event's own package is one
     * it scrapes. Events from every other app cost exactly this call. Mirrors the
     * reference, which likewise routes an event to a handler only when the event's package
     * is the selected nav app's — it never runs the ladder for a foreign package.
     */
    fun isNavEvent(pkg: String?, active: Set<String>): Boolean =
        pkg != null && active.isNotEmpty() && pkg in active

    /**
     * May a tree owned by [rootPkg] be dispatched as [pkg]'s window? Only when they are the
     * same app. Both must be present; an unknown owner is not a match.
     */
    fun rootMatches(rootPkg: String?, pkg: String?): Boolean =
        rootPkg != null && pkg != null && rootPkg == pkg

    /**
     * Rate limiter for the expensive all-displays enumeration. Deliberately positioned in
     * FRONT of the read (see the class doc) rather than behind it.
     *
     * Monotonic-clock caller ([android.os.SystemClock.elapsedRealtime] in production); the
     * clock is passed in so this is testable without one.
     */
    class ScanGate(private val minIntervalMs: Long = SCAN_MIN_INTERVAL_MS) {

        @Volatile
        private var lastMs: Long = Long.MIN_VALUE

        /** True (and arms the next interval) when a scan is allowed at [nowMs]. */
        fun allow(nowMs: Long): Boolean {
            val last = lastMs
            // First call always passes. Guard the subtraction against a clock that went
            // backwards (or the Long.MIN_VALUE sentinel) rather than overflowing into a
            // permanent deny.
            if (last != Long.MIN_VALUE && nowMs >= last && nowMs - last < minIntervalMs) return false
            lastMs = nowMs
            return true
        }
    }
}
