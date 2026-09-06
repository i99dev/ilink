package com.i99dev.ilink.car

import android.content.Context
import android.util.Log
import com.i99dev.ilink.helper.BydPushDevice
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * In-process BYD push subscription manager.
 *
 * Verified empirically on DiLink 5.1 (12 May 2026): the BYD framework
 * dispatches `AbsBYDAutoDevice.onPostEvent` callbacks ONLY to instances
 * constructed with a bound Application context. The shell-UID
 * [com.i99dev.ilink.helper.DashDaemon] uses
 * `ActivityThread.getSystemContext()` and the framework refuses to
 * dispatch to it (`pushFramesReceived` stays at 0 across active subs
 * with confirmed-live keys). Registering [BydPushDevice] from inside the
 * app's process — where `getApplicationContext()` returns a real
 * Application context — is the only path that actually delivers push.
 *
 * Architectural split confirmed by today's hardware test:
 *   - `set` → must stay shell-UID daemon (system write permission)
 *   - `get` → either daemon or in-app works
 *   - `push` → must be in-app (framework context-binds dispatch)
 *
 * Construct one of these per [AutoFeatureService] (one process, one
 * push subscription per device-type). Lifetime is the service's:
 * device instances are held as strong references for the same reason
 * the daemon holds them — the framework registers via constructor
 * side-effect and dropping the ref silently unsubscribes.
 */
class InAppPushManager(context: Context) {

    companion object {
        private const val TAG = "InAppPush"

        // Mirror DashDaemon.WARM_DT — same set of device-types we want
        // push registration for. Kept duplicated rather than centralized
        // because the daemon's WARM_DT may diverge in the future (e.g.
        // shell-only enableDevice for write-side dts), and conflating
        // the two surfaces would mask the divergence.
        private val WARM_DT = intArrayOf(
            1000, // AC
            1001, // BODY (instrument cluster + tires + battery stats)
            1023, // SETTING / SENSOR
            1038, // GEAR
            1040, // WHEEL
            1041, // DOORLOCK
            1045, // TIRE
        )
    }

    /** Application context — explicitly NOT the bare context the caller
     *  passed in, so we don't leak a possibly-Activity context to the
     *  framework's long-lived device registry. */
    private val appContext: Context = context.applicationContext

    /** Strong references to every successfully-registered BydPushDevice.
     *  GC-pinning is load-bearing — the framework registers via
     *  constructor side-effect and dropping a ref silently unsubscribes
     *  us from further onPostEvent dispatches for that device-type. */
    private val devices = mutableListOf<BydPushDevice>()

    /** dt -> device, for O(1) typed-read lookup. Populated alongside
     *  [devices] in [init]; never mutated after. */
    private val deviceByDt = HashMap<Int, BydPushDevice>()

    /** Per-dt registration outcome. Surfaced via [stats] so a failure on
     *  one device-type is observable without grepping logcat. */
    private val perDtStatus = LinkedHashMap<Int, Boolean>()

    /** Lifetime push frames received across all device-types. The
     *  smoking-gun metric: zero with `available=true` means the
     *  framework registered us but never dispatched. */
    private val framesReceived = AtomicLong(0L)

    /** (dt, key) → list of (Int) -> Unit callbacks. Composite key avoids
     *  a nested map allocation on the hot dispatch path. */
    private val subs = ConcurrentHashMap<Long, MutableList<(Int) -> Unit>>()

    @Volatile
    var available: Boolean = false
        private set

    /** Single sink shared across every per-dt device. Routing happens
     *  here once per push frame — O(1) lookup into the (dt,key) sub
     *  index, then linear over the (typically 1) callback list. */
    private val sink = BydPushDevice.PushSink { dt, key, value ->
        framesReceived.incrementAndGet()
        val composite = compositeKey(dt, key)
        val list = subs[composite] ?: return@PushSink
        // Snapshot the callback list under lock so a concurrent
        // unsubscribe can't NPE us mid-iteration. The list itself
        // grows/shrinks rarely (once per backfill), so the cost is
        // immaterial vs the dispatch frequency.
        val snapshot = synchronized(list) { list.toList() }
        for (cb in snapshot) {
            try {
                cb(value)
            } catch (t: Throwable) {
                Log.w(TAG, "push sub callback threw: ${t.message}")
            }
        }
    }

    /**
     * Construct one BydPushDevice per WARM_DT against the application
     * context. Idempotent — second call returns the cached `available`.
     *
     * Returns true iff at least one device-type registered. Failures
     * are logged with the actual exception class+message so an operator
     * can tell the difference between (a) framework class not on this
     * ROM, (b) AbstractMethodError from missing override (the
     * `getType()` bug we hit at first), and (c) per-dt permission /
     * state refusals.
     */
    fun init(): Boolean {
        if (available) return true
        if (devices.isNotEmpty()) return false  // attempted, all-failed
        // Log.w (not Log.i) to survive proguard-android-optimize stripping
        // in release builds. Log.i is allowed-by-default but custom rules
        // may strip it — Log.w is universally retained.
        Log.w(TAG, "init begin (appContext=${appContext.javaClass.simpleName})")
        try {
            for (dt in WARM_DT) {
                try {
                    val dev = BydPushDevice(appContext, dt, sink)
                    devices.add(dev)
                    deviceByDt[dt] = dev
                    perDtStatus[dt] = true
                } catch (t: Throwable) {
                    perDtStatus[dt] = false
                    val cause = unwrap(t)
                    Log.w(
                        TAG,
                        "BydPushDevice(dt=$dt) failed: " +
                            "${cause.javaClass.name}: ${cause.message}",
                    )
                }
            }
            available = devices.isNotEmpty()
            Log.w(
                TAG,
                "init done: available=$available " +
                    "(${devices.size}/${WARM_DT.size} devices) " +
                    "status=$perDtStatus",
            )
        } catch (t: Throwable) {
            // Catch ALL — stripped-ROM throws NoClassDefFoundError on
            // first AbsBYDAutoDevice reference, but also catches any
            // unforeseen surprise (security exception, framework
            // initializer error, etc.) so we never crash the app on a
            // best-effort optimization.
            available = false
            for (dt in WARM_DT) perDtStatus[dt] = false
            Log.w(TAG, "init failed (outer catch): ${t.javaClass.name}: ${t.message}")
        }
        return available
    }

    /**
     * Subscribe to push for a specific (dt, key). The returned
     * canceller MUST be invoked to unsubscribe (idempotent — second
     * call is a no-op). Subscribing the same callback twice will
     * fire it twice per push.
     *
     * Note: there is no daemon hop for in-app push, so no `subId`
     * round-trip and no per-sub TCP cost.
     */
    fun subscribe(dt: Int, key: Int, onValue: (Int) -> Unit): () -> Unit {
        val composite = compositeKey(dt, key)
        val list = subs.getOrPut(composite) { mutableListOf() }
        synchronized(list) { list.add(onValue) }
        return {
            synchronized(list) { list.remove(onValue) }
        }
    }

    /**
     * Synchronous read via the per-device instance — Dudu's pattern.
     * Routes through the same dispatcher that fires push events,
     * which means the value is the framework's currently-cached one
     * (the live value the framework would also have pushed). The
     * SystemService route (`autoMgr.getInt(dt, key)`) bypasses that
     * dispatcher and on DiLink 5.1 returns stale data for push-fed
     * signals — verified empirically: speed via autoMgr stayed at 0
     * while super.get on the device instance returned the moving
     * value. Use this instead of daemon `get` whenever in-app push
     * is available.
     *
     * Returns [Int.MIN_VALUE] when the device-type isn't registered
     * (caller falls back to daemon get) or when the framework
     * threw on the call.
     */
    fun getInt(dt: Int, key: Int): Int {
        val dev = deviceByDt[dt] ?: return Int.MIN_VALUE
        return dev.getInt(key)
    }

    /** Bulk read across many keys for the same device-type — Phase 3
     *  pattern. One framework hop instead of N. */
    fun getIntArray(dt: Int, keys: IntArray): IntArray? {
        val dev = deviceByDt[dt] ?: return null
        return dev.getIntArray(keys)
    }

    /** Synchronous double read. Returns [Double.NaN] on failure. */
    fun getDouble(dt: Int, key: Int): Double {
        val dev = deviceByDt[dt] ?: return Double.NaN
        return dev.getDouble(key)
    }

    /** Synchronous bytes read. Returns null on failure. */
    fun getBuffer(dt: Int, key: Int): ByteArray? {
        val dev = deviceByDt[dt] ?: return null
        return dev.getBuffer(key)
    }

    /** Snapshot of the in-app push pipeline state. Mirrors the daemon's
     *  `stats` op — let the same operator dashboard query both. */
    fun stats(): Map<String, Any?> = mapOf(
        "available" to available,
        "devicesRegistered" to perDtStatus,
        "framesReceived" to framesReceived.get(),
        "subKeysActive" to subs.size,
    )

    private fun compositeKey(dt: Int, key: Int): Long =
        (dt.toLong() shl 32) or (key.toLong() and 0xFFFFFFFFL)

    private fun unwrap(t: Throwable): Throwable {
        var c: Throwable = t
        while (c.cause != null && c.cause !== c) c = c.cause!!
        return c
    }
}
