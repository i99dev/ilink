package com.i99dev.ilink.daemon

import android.content.Context
import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Daemon health watchdog.
 *
 * The daemon is a long-running app_process spawned over ADB at app
 * boot via [AdbBootstrap]. It can die mid-session for a number of
 * reasons: the framework killed it (low-memory), an unhandled
 * exception in a stale code path, ADB connection severed (cable
 * unplugged on dev devices), the host's auto service rebooted, etc.
 *
 * When the daemon dies:
 *   - In-app push subscriptions stay registered with the framework,
 *     so push frames continue arriving (they bypass the daemon).
 *   - But the daemon TCP socket goes dead — every `setInt` call
 *     from the app fails with `disconnected`.
 *   - And if the registry tries to refresh values from the daemon
 *     (e.g., bulk seed at boot), that also fails.
 *
 * The watchdog detects this via two signals:
 *   1. A periodic ping (every [PING_INTERVAL_MS]); 3 consecutive
 *      ping failures = "daemon is gone".
 *   2. ADB-bridge connectivity tripped to false.
 *
 * Recovery: invoke [AdbShellBridge.ensureDaemon], which sweeps any
 * orphan helpers and re-spawns the daemon over loopback ADB, then
 * waits for it to bind. (This used to call `AdbBootstrap.retry`, which
 * only re-runs the permission GRANT commands over direct ADB and never
 * spawns the daemon — so a dead daemon stayed dead until something else
 * happened to call ensureDaemon. That was the "can't reach car" that
 * survived the re-bind + single-instance fixes.) Backoff between
 * retries to avoid a spawn-storm if the ADB bridge itself is down.
 *
 * Lifetime: started by [com.i99dev.ilink.car.AutoFeatureService]
 * on construct; runs forever until [stop]. Single thread,
 * negligible CPU (one ping per 30 s + occasional retry).
 */
class DaemonWatchdog(private val context: Context) {

    private var executor: ScheduledExecutorService? = null

    /** Consecutive ping failures since the last success. Reset to 0
     *  on every successful ping. Triggers retry at [FAILURES_TO_RECOVER]. */
    private val pingFailures = AtomicInteger(0)

    /** ms-since-epoch of the last retry attempt. Used to enforce
     *  the backoff window. 0 = never retried this session. */
    private val lastRetryAtMs = AtomicLong(0L)

    /** Current backoff window in ms. Doubles after each retry that
     *  doesn't restore the daemon, capped at [BACKOFF_MAX_MS].
     *  Resets to [BACKOFF_INITIAL_MS] on a successful ping after a
     *  retry. */
    private val backoffMs = AtomicLong(BACKOFF_INITIAL_MS)

    /** Lifetime counters for the diagnostic stats op (or any future
     *  health screen). */
    private val pingsTotal = AtomicLong(0L)
    private val pingsOk = AtomicLong(0L)
    private val retriesAttempted = AtomicLong(0L)
    private val retriesSucceeded = AtomicLong(0L)

    /** True between a retry actually running and the next ping that
     *  verifies recovery. Lets [onPingSuccess] attribute a recovery to the
     *  retry that drove it (bumping [retriesSucceeded]) instead of a
     *  transient hiccup that self-healed without a retry. */
    private val retryPending = AtomicBoolean(false)

    /** Start the periodic health check. Idempotent — second call
     *  returns the existing executor; no double-thread risk. */
    fun start() {
        if (executor != null) return
        executor = Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "daemon-watchdog").apply { isDaemon = true }
        }
        executor?.scheduleWithFixedDelay(
            ::tick,
            PING_INTERVAL_MS,
            PING_INTERVAL_MS,
            TimeUnit.MILLISECONDS,
        )
        Log.w(TAG, "watchdog started (interval=${PING_INTERVAL_MS}ms)")
    }

    /** Stop the watchdog. Caller is responsible for life-cycling
     *  (e.g. on app shutdown). */
    fun stop() {
        executor?.shutdownNow()
        executor = null
    }

    /** Snapshot of watchdog state for diagnostics surfaces. */
    fun stats(): Map<String, Any?> = mapOf(
        "pingsTotal" to pingsTotal.get(),
        "pingsOk" to pingsOk.get(),
        "consecutiveFailures" to pingFailures.get(),
        "retriesAttempted" to retriesAttempted.get(),
        "retriesSucceeded" to retriesSucceeded.get(),
        "currentBackoffMs" to backoffMs.get(),
        "lastRetryAtMs" to lastRetryAtMs.get(),
    )

    private fun tick() {
        try {
            val client = AdbShellBridge.daemonClient()
            pingsTotal.incrementAndGet()
            val ok = client.isConnected() && client.ping(timeoutMs = PING_TIMEOUT_MS)
            if (ok) {
                onPingSuccess()
                return
            }
            val failures = pingFailures.incrementAndGet()
            Log.w(TAG, "ping failed (consecutive=$failures)")
            if (failures >= FAILURES_TO_RECOVER) {
                maybeRetry()
            }
        } catch (t: Throwable) {
            // Defensive — a watchdog crash shouldn't take down the
            // app. Treat as a ping failure.
            Log.w(TAG, "tick threw: ${t.javaClass.simpleName}: ${t.message}")
            val failures = pingFailures.incrementAndGet()
            if (failures >= FAILURES_TO_RECOVER) maybeRetry()
        }
    }

    private fun onPingSuccess() {
        pingsOk.incrementAndGet()
        if (pingFailures.get() > 0) {
            Log.w(TAG, "daemon recovered after ${pingFailures.get()} failed pings")
            pingFailures.set(0)
            backoffMs.set(BACKOFF_INITIAL_MS)
            // Attribute the recovery to a retry only if one actually ran
            // (retryPending) — a transient hiccup that self-healed without
            // a retry must not count as a retry success.
            if (retryPending.getAndSet(false)) retriesSucceeded.incrementAndGet()
        }
    }

    private fun maybeRetry() {
        val now = System.currentTimeMillis()
        val sinceLast = now - lastRetryAtMs.get()
        val window = backoffMs.get()
        if (sinceLast < window) {
            // Inside backoff window — wait. Don't reset failure
            // counter; it'll trigger again at the next tick.
            return
        }
        lastRetryAtMs.set(now)
        retriesAttempted.incrementAndGet()
        Log.w(TAG, "daemon silent — respawning via ensureDaemon (backoff=${window}ms)")
        // ensureDaemon sweeps orphans + re-spawns the daemon + waits for the
        // bind; it can take a few seconds. The executor schedule keeps ticks
        // waiting, which is fine — no point pinging until the respawn settles.
        try {
            val ok = AdbShellBridge.ensureDaemon(maxAttempts = 2)
            Log.w(TAG, "ensureDaemon recovery → $ok")
            // A true here means the client reconnected to a freshly-spawned
            // daemon. Mark a retry pending; [onPingSuccess] bumps
            // retriesSucceeded when the next ping confirms it's serving.
            retryPending.set(true)
        } catch (t: Throwable) {
            Log.w(TAG, "ensureDaemon recovery threw: ${t.javaClass.simpleName}: ${t.message}")
        }
        // Either way, double the backoff for the next attempt. Reset
        // to initial happens in [onPingSuccess] when the daemon
        // actually recovers.
        backoffMs.set(minOf(window * 2, BACKOFF_MAX_MS))
    }

    companion object {
        private const val TAG = "DaemonWatchdog"

        /** How often to ping. 10 s keeps a dead daemon's "can't reach car"
         *  window short (worst case ~20 s from death to respawn at
         *  FAILURES_TO_RECOVER=2) while a single 1-frame TCP ping every 10 s
         *  is still negligible CPU. */
        private const val PING_INTERVAL_MS = 10_000L

        /** Per-ping timeout. The daemon's ping handler returns in
         *  ~5 ms on a healthy bus; 1 s is generous slack for ADB
         *  hiccups while still bounding the watchdog's response time. */
        private const val PING_TIMEOUT_MS = 1_000L

        /** N consecutive ping failures before triggering a respawn.
         *  Two rides out a single dropped TCP packet while still
         *  recovering fast (~20 s at PING_INTERVAL_MS=10 s). */
        private const val FAILURES_TO_RECOVER = 2

        /** Initial backoff window after the first respawn attempt. */
        private const val BACKOFF_INITIAL_MS = 10_000L

        /** Cap the backoff at 5 minutes — beyond that the user has
         *  bigger problems than watchdog response time, and we
         *  don't want to silently give up. */
        private const val BACKOFF_MAX_MS = 5 * 60_000L
    }
}
