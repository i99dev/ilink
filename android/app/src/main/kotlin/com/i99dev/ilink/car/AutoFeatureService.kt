package com.i99dev.ilink.car

import android.content.Context
import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** Polling cadence tier for a [StatusKey]. The Dart-side
 *  `CarStateController` runs three timers — one per tier — so direct
 *  user-action keys (HOT) get fresh values every second while slow-moving
 *  telemetry (COLD) keeps the existing 10 s budget. Mapping happens by
 *  label string so the encrypted [CarTableSource] doesn't need a proto
 *  change to opt in. */
enum class StatusTier { HOT, WARM, COLD }

object StatusTiers {
    // Direct user actions where UI lag is most visible — door
    // sensors, lock state, lights, road speed.
    private val HOT_LABELS = setOf(
        "door_lock", "door_lf", "door_rf", "door_lr", "door_rr",
        "trunk", "speed_kmh",
        "headlight", "low_beam", "high_beam",
    )

    // Climate + secondary lighting — change less often than doors,
    // more often than range/mode.
    private val WARM_LABELS = setOf(
        "ac_power", "ac_fan", "ac_wind_mode", "ac_cycle",
        "ac_target_temp", "ac_cabin_temp",
        "front_fog", "rear_fog",
    )

    fun tierOf(label: String): StatusTier = when {
        label in HOT_LABELS -> StatusTier.HOT
        label in WARM_LABELS -> StatusTier.WARM
        else -> StatusTier.COLD
    }

    fun filter(plan: List<StatusKey>, tier: StatusTier): List<StatusKey> =
        plan.filter { tierOf(it.label) == tier }
}

// Thin facade over UnitDispatcher + AdbShellBridge. Fast path goes through
// the long-running DashDaemon (~5-10 ms per call); slow path spawns a
// unit DEX via adb shell when a command needs byd_airconditioning or
// multi-step state (fragrance, atmos, find-car).
class AutoFeatureService(context: Context) {
    /** Application context for filesystem + manager lookups across the
     *  service's lifetime. Stored explicitly because [context] is just
     *  a constructor param and not accessible from member methods. */
    private val appContext: Context = context.applicationContext

    /** In-process BYD push registration. Subscriptions go directly
     *  here (no daemon hop, no TCP) when in-app push is available;
     *  otherwise the legacy daemon poll path carries the load (the
     *  daemon retains its sub-poller for exactly this reason). */
    private val inAppPush = InAppPushManager(context)

    /** Auto-discovery engine. Built on a background thread the first
     *  time a consumer needs it — typically during the first readStatus
     *  tick. See [AutoCarRegistry] for how it derives the live feature
     *  list directly from the framework catalog. */
    val registry = AutoCarRegistry(context, inAppPush)

    /** Daemon health watchdog — periodic ping + auto-retry on
     *  silence. Runs forever; AutoFeatureService outlives the app's
     *  visible lifecycle, so a single instance suffices. */
    val watchdog = com.i99dev.ilink.daemon.DaemonWatchdog(context)

    init {
        AdbShellBridge.init(context)
        // Initialize in-app push registration eagerly. The framework
        // dispatches push only to instances constructed in a process
        // with a bound Application context — which is us, the app —
        // not the shell-UID daemon (verified empirically 12 May 2026
        // on DiLink 5.1: daemon-side registration succeeded but the
        // framework never invoked onPostEvent). See InAppPushManager
        // for the architectural rationale.
        inAppPush.init()
        // No runtime brute-force scan. The framework catalog is shipped
        // as a static asset (`assets/byd/catalog.tsv`, source-of-truth
        // `.secrets/byd/catalog.tsv`) — every name we'd ever discover is
        // already there. Live values arrive lazily as widgets watch
        // names through the SDK's daemon-poll subscribe path.
        //
        // The legacy 2-3 s registry.build() probe used to populate the
        // Auto Registry diagnostic screen up-front; that screen now
        // reads from `BydAutoFeatureIdsCatalog` + the SDK's hot cache,
        // so an on-demand probe per-tab tap is plenty.

        // Start the daemon health watchdog. Pings every 30 s; auto-
        // retries via AdbBootstrap on prolonged silence. See
        // [DaemonWatchdog] for the recovery state machine.
        watchdog.start()
    }


    fun runAction(actionId: String, args: Map<String, Any?>): Map<String, Any?> =
        UnitDispatcher.runAction(actionId, args)

    fun runUnit(unitId: String, args: List<String>): Map<String, Any?> =
        UnitDispatcher.runUnit(unitId, args)

    fun knownActions(): List<String> = UnitDispatcher.knownActions()
    fun knownUnits(): List<String> = UnitDispatcher.knownUnits()

    /**
     * Auto-discovered live feature snapshot — the entire registry
     * of catalog entries this car currently exposes through the
     * BYD framework. Keys are FULL catalog names
     * (`Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT`,
     * `Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE`, …); values are
     * the most-recent live integer.
     *
     * Returns empty until [AutoCarRegistry.build] finishes (~3-5 sec
     * after app start; runs on a background thread). Returns the
     * live-fresh state thereafter — values mutate via the registry's
     * push subscriptions, no Binder calls per access.
     *
     * Use this for "all features" UIs / SDK consumers that want the
     * raw catalog. The textproto-curated [readStatus] surface
     * remains for label-keyed access.
     */
    fun allFeaturesAuto(): Map<String, Int> {
        if (!registry.built) return emptyMap()
        val out = LinkedHashMap<String, Int>(registry.all().size)
        for (rec in registry.all()) out[rec.name] = rec.value
        return out
    }

    /** Diagnostic stats for the auto-discovery engine. Surfaced via
     *  the daemon's `stats` op equivalent on the app side — useful
     *  for the diagnostics screen. */
    fun registryStats(): Map<String, Any?> = registry.stats() + mapOf(
        // Process-wide framework push-frame counter from BydPushDevice.
        // EXPECTED to stay 0 on app UID — IBYDAutoListener dispatch is
        // restricted to system-signed BYD processes. Kept as a tripwire:
        // if it ever flips non-zero we've gained framework dispatch
        // (e.g. via privileged install) and could short-circuit the
        // daemon poll path.
        "frameworkPushFramesReceived" to com.i99dev.ilink.helper.BydPushDevice.framesReceived(),
        "sdkPushSubscribedNames" to sdkPushCancellers.size,
    )

    /** Watchdog stats — pings sent / OK, recovery attempts /
     *  successes, current backoff. Lets a diagnostic screen show
     *  daemon-health history at a glance. */
    fun watchdogStats(): Map<String, Any?> = watchdog.stats()

    /**
     * The FULL framework catalog — every feature BYD's framework
     * knows about (~21k entries on DiLink5.1+, varies slightly by ROM).
     * Stable across boots on the same ROM. Same set on every BYD
     * trim that ships the same DiLink version.
     *
     * This is the SDK's universal-BYD-knowledge surface: widget /
     * mini-app builders code against ANY catalog name; the runtime
     * tells them per-name whether it's live on the current car
     * (via [allFeaturesAuto] which is the per-trim subset).
     *
     * Returned as a flat `name → int` map, identical shape to
     * [allFeaturesAuto] so the Dart side can union them.
     */
    fun allKnownFeatures(): Map<String, Int> =
        BydAutoFeatureIdsCatalog.byName

    /**
     * Read a single feature's current value by catalog name.
     *
     * Used by the SDK's watch() fallback when the registry's hot
     * snapshot doesn't have a recent value for a name (typical for
     * state-change-only signals like doors that don't push until
     * the state changes — and the registry's brute-force probe
     * returned a sentinel at boot).
     *
     * Strategy:
     *   1. If the registry has the name (push-fed entry), return
     *      the freshest live read via daemon.get(dt, key) — the
     *      registry knows the right dt.
     *   2. Else, look up int via BydAutoFeatureIdsCatalog and probe
     *      WARM_DT until something returns non-sentinel. Slower but
     *      handles names absent from the registry.
     *
     * Returns null when the name doesn't resolve OR all probes
     * return sentinels.
     */
    fun getValueByName(name: String): Int? {
        // Fast path — registry knows the dt.
        val rec = registry.get(name)
        if (rec != null) {
            val v = readDaemonInt(rec.dt, rec.key)
            if (v != null && v !in WATCH_SENTINELS) return v
        }

        // Fallback — resolve via the framework catalog + try each
        // WARM_DT. Stops on the first non-sentinel.
        val key = BydAutoFeatureIdsCatalog.resolve(name) ?: return null
        for (dt in WARM_DT_FALLBACK) {
            val v = readDaemonInt(dt, key)
            if (v != null && v !in WATCH_SENTINELS) return v
        }
        return null
    }

    /**
     * Bulk variant — fetch many features in a single daemon round-
     * trip via the Phase 3 grouped getIntArray path.
     *
     * SDK calls this when N widgets watch N features for the first
     * time and the registry doesn't have any of them — the alternative
     * is N sequential daemon calls which serialise on the IPC.
     *
     * Strategy:
     *   1. For each name, look up (dt, key) — registry first, then
     *      framework catalog with a default dt guess.
     *   2. Group by dt; one getIntArray per group (Phase 3 path).
     *   3. Return name → value map; absent entries mean unresolved
     *      OR all-sentinel response.
     *
     * Single round-trip per dt group. ~7 dts × ~5ms per group on
     * Leopard = ~35ms total even for hundreds of names; vs ~5ms
     * each = N×5ms for the per-name fallback.
     */
    fun getValuesByName(names: List<String>): Map<String, Int> {
        if (names.isEmpty()) return emptyMap()
        // Single-host-call batch: N daemon getInt calls in a tight
        // loop, no MethodChannel marshalling between them. Same N×5ms
        // total daemon cost as the per-name path, but the Dart side
        // only pays ONE MethodChannel round-trip — so for 16 widgets
        // each watching ~5 features at boot we go from 80 channel
        // hops to 1.
        //
        // (Earlier attempt used AdbShellBridge.fastBatchGet for true
        // batching at the daemon layer; it hung — pursued in a
        // follow-up. Sequential getInt is correct + bounded.)
        val out = HashMap<String, Int>(names.size)
        for (name in names) {
            // Per-name try/catch so ONE bad name (socket reset on
            // the underlying readDaemonInt, registry-resolve throw,
            // sentinel-NPE inside the framework catalog) can't poison
            // the whole batch. Before this wrap, a single throw
            // unwound the for-loop, propagated through
            // CarChannel.setMethodCallHandler's outer try/catch as a
            // PlatformException, and the Dart SDK's bulk-call wrap
            // (BydClient._reseedWarmSet) swallowed everything — the
            // hot cache stayed empty for the WHOLE warm set, every
            // dashboard tile + miniapp render showed nulls, and the
            // 60 s periodic re-seed kept failing the same way each
            // tick. Reported by a user on 2026-05-15.
            try {
                val v = getValueByName(name) ?: continue
                out[name] = v
            } catch (t: Throwable) {
                Log.w(TAG, "getValuesByName: skipped $name (${t.javaClass.simpleName}: ${t.message})")
            }
        }
        return out
    }

    /**
     * Registry-free push subscription. Resolves [name] via the
     * framework catalog, probes WARM_DT once to find the live
     * device-type, and registers a daemon-side poll subscription
     * that forwards value changes to [sdkPushOnChange].
     *
     * Idempotent — second call for the same name is a no-op.
     *
     * Why daemon, not in-app: BYD's `IBYDAutoListener.registerListener`
     * silently rejects unprivileged-UID callers — verified empirically
     * 12 May 2026 on Leopard 8. Only system-signed `com.byd.*` PIDs
     * (acservice / car.server / gpsinfo) actually receive `onPostEvent`.
     * No wiring change in our app process can fix that. The daemon's
     * 200ms poll-and-diff loop ([DashDaemon.pollSubs]) is the only
     * push channel that delivers hot signals to our UID.
     *
     * The dashboard's SDK seed calls this for every name in its warm
     * set so live updates flow without depending on push from the
     * framework. ~22 hot subs at 200ms cadence = ~22 binder hops per
     * tick = comfortably inside the daemon's poll budget.
     */
    fun subscribePushByName(name: String): Boolean {
        if (sdkPushCancellers.containsKey(name)) return true
        val key = BydAutoFeatureIdsCatalog.resolve(name) ?: return false
        // Resolve dt ONCE: registry hint first, else probe WARM_DT
        // until daemon getInt returns a non-sentinel. ~5ms per probe;
        // worst-case 7×5ms = 35ms one-time per name. Cached implicitly
        // by the daemon-side subscription itself.
        val dt = resolveLiveDt(name, key) ?: return false
        val client = AdbShellBridge.daemonClient()
        if (!client.isConnected()) {
            // Daemon may have been killed by force-stop / reinstall.
            // Spawn-on-demand here so the warm-set seed doesn't fail
            // silently on the first launch after an update.
            AdbShellBridge.ensureDaemon()
            if (!client.isConnected()) return false
        }
        val periodMs = cadenceFor(name)
        val subId = client.subscribe(dt, key, periodMs) { evt ->
            val raw = evt.opt("value") as? Number ?: return@subscribe
            val v = raw.toInt()
            if (v in WATCH_SENTINELS) return@subscribe
            try { sdkPushOnChange?.invoke(name, v) } catch (_: Throwable) {}
        } ?: return false
        sdkPushCancellers[name] = { try { client.unsubscribe(subId) } catch (_: Throwable) {} }
        return true
    }

    /**
     * Per-name poll cadence in milliseconds. Picked by name prefix —
     * driver-visible motion stays at 200 ms, slow-changing values move
     * to 500 ms / 2 s so a 100-name watcher (gate probe) doesn't drive
     * 100 binder hops per 200 ms tick for cabin temp + SOC that change
     * once a minute.
     *
     * The daemon's grouped poller honours these; 22 hot subs across
     * 4 dts becomes 4 binder hops/tick instead of 22, and a 2 s sub
     * skips 9 of 10 ticks.
     */
    private fun cadenceFor(name: String): Int {
        // Speed + gear + wheel — driver-visible motion. The dashboard
        // tile that shows "0 km/h → 5 km/h" needs sub-half-second
        // refresh or it looks frozen.
        if (name.startsWith("Statistic.STATISTIC_SPEED")) return 200
        if (name.startsWith("Statistic.STATISTIC_GEAR")) return 200
        if (name.startsWith("Wheel.")) return 200
        if (name.startsWith("Gearbox.")) return 200

        // Closures + lights — user-perceivable but step-change, not
        // continuous. 500 ms is the sweet spot: door open → tile
        // updates within half a second; the rest of the tick budget
        // goes to actually-changing signals.
        if (name.startsWith("Door.")) return 500
        if (name.startsWith("Bodywork.")) return 500
        if (name.startsWith("Light.")) return 500

        // Settings + AC + SOC + range — change in steps of seconds or
        // minutes. 2 s polling cuts binder churn 10× for these without
        // any visible UX change.
        if (name.startsWith("Setting.")) return 2_000
        if (name.startsWith("Ac.")) return 2_000
        if (name.startsWith("Statistic.STATISTIC_SOC")) return 2_000
        if (name.startsWith("Statistic.STATISTIC_FUEL")) return 2_000
        if (name.startsWith("Statistic.STATISTIC_ELEC_DRIVING")) return 2_000

        // Default — keep the legacy 200 ms cadence for anything not
        // explicitly slowed. New / unknown names err on the responsive
        // side; if a tile screams about excess polling, slow it here.
        return 200
    }

    /** In-memory cache of resolved (name -> dt) pairs. Populated on
     *  first subscribe and persisted to disk via [persistDtMap] so a
     *  warm restart can skip the per-name 7-DT probe entirely.
     *  Loaded once at construct time from [dtMapFile]. */
    private val nameToDt = ConcurrentHashMap<String, Int>()
    private val dtMapFile: java.io.File by lazy {
        java.io.File(appContext.filesDir, "byd_name_to_dt.json")
    }

    init {
        runCatching {
            val f = dtMapFile
            if (f.exists()) {
                val obj = org.json.JSONObject(f.readText())
                val it = obj.keys()
                while (it.hasNext()) {
                    val k = it.next() as String
                    nameToDt[k] = obj.getInt(k)
                }
            }
        }
    }

    /** Resolve which device-type a name lives on. Order:
     *    (1) persistent (name -> dt) cache hit  — zero binder cost
     *    (2) registry hint                       — zero binder cost
     *    (3) probe each WARM_DT via daemon getInt (~5 ms × ≤7 dts)
     *  Returns null when the name doesn't resolve on any WARM_DT — the
     *  caller skips push registration for that name. */
    private fun resolveLiveDt(name: String, key: Int): Int? {
        nameToDt[name]?.let { return it }
        registry.get(name)?.dt?.let {
            nameToDt[name] = it
            schedulePersist()
            return it
        }
        for (dt in WARM_DT_FALLBACK) {
            val v = readDaemonInt(dt, key) ?: continue
            if (v !in WATCH_SENTINELS) {
                nameToDt[name] = dt
                schedulePersist()
                return dt
            }
        }
        return null
    }

    /** Coalesces frequent persist calls into one disk write. The map
     *  grows monotonically (~176 names max), so a 500 ms debounce keeps
     *  burst-subscribe scenarios (gate probe open) at one write total. */
    private val persistPending = AtomicBoolean(false)
    private fun schedulePersist() {
        if (!persistPending.compareAndSet(false, true)) return
        Thread({
            try {
                Thread.sleep(500L)
                persistDtMap()
            } finally {
                persistPending.set(false)
            }
        }, "byd-dt-persist").apply { isDaemon = true }.start()
    }

    private fun persistDtMap() {
        val obj = org.json.JSONObject()
        for ((k, v) in nameToDt) obj.put(k, v)
        runCatching { dtMapFile.writeText(obj.toString()) }
    }

    /** Bulk variant — subscribes every name in [names] in one call.
     *  Returns the set of names whose subscription succeeded.
     *
     *  Pre-resolves every name's device-type using bulk
     *  `daemon.getIntArray(dt, keys[])` calls — ONE binder hop per
     *  WARM_DT instead of N×7 hops per name. After the bulk probe,
     *  each per-name subscribe is constant-time (cache hit on
     *  [nameToDt]).
     *
     *  Cost: 7 batched probes upfront (~350 ms for 176 names) vs the
     *  legacy ~6 s sequential per-name path. Identical correctness —
     *  same WARM_DT_FALLBACK iteration, same sentinel filter. */
    fun subscribePushByNames(names: List<String>): List<String> {
        if (names.isEmpty()) return emptyList()
        bulkResolveDts(names)
        val ok = ArrayList<String>(names.size)
        for (n in names) if (subscribePushByName(n)) ok.add(n)
        return ok
    }

    /** Pre-warm [nameToDt] for [names] using bulk daemon reads. Uses
     *  one [DashDaemonClient.getIntArray] call per WARM_DT, in order;
     *  short-circuits as soon as every name is resolved. Failures
     *  (daemon down, dt rejected) leave names unresolved — the
     *  per-name [resolveLiveDt] fallback picks up the slack on the
     *  subscribe call itself. */
    private fun bulkResolveDts(names: List<String>) {
        val client = AdbShellBridge.daemonClient()
        if (!client.isConnected()) {
            AdbShellBridge.ensureDaemon()
            if (!client.isConnected()) return
        }
        // Filter to names we don't already have a dt for AND that
        // resolve in the catalog.
        data class Pending(val name: String, val key: Int)
        val pending = ArrayList<Pending>(names.size)
        for (n in names) {
            if (nameToDt.containsKey(n)) continue
            val k = BydAutoFeatureIdsCatalog.resolve(n) ?: continue
            pending.add(Pending(n, k))
        }
        if (pending.isEmpty()) return
        val unresolved = LinkedHashSet<Pending>(pending)

        for (dt in WARM_DT_FALLBACK) {
            if (unresolved.isEmpty()) break
            val snapshot = unresolved.toList()
            val keys = snapshot.map { it.key }
            val resp = try {
                client.getIntArray(dt, keys)
            } catch (_: Throwable) {
                continue
            }
            val arr = resp.optJSONArray("values") ?: continue
            if (arr.length() != snapshot.size) continue
            for ((i, p) in snapshot.withIndex()) {
                val v = arr.optInt(i, Int.MIN_VALUE)
                if (v != Int.MIN_VALUE && v !in WATCH_SENTINELS) {
                    nameToDt[p.name] = dt
                    unresolved.remove(p)
                }
            }
        }
        // One persist after the whole bulk pass — saves N writes.
        if (pending.size != unresolved.size) schedulePersist()
    }

    /** Active SDK push subscriptions — cancellers keyed by name. */
    private val sdkPushCancellers = HashMap<String, () -> Unit>()

    /** Forward callback set by [CarChannel] (multiplexed with the
     *  registry's onChange into the same EventChannel sink). */
    var sdkPushOnChange: ((String, Int) -> Unit)? = null

    /** Daemon getInt returns a JSONObject `{value: <int>}` or
     *  `{error: <str>}`; unwrap to nullable Int. */
    private fun readDaemonInt(dt: Int, key: Int): Int? {
        val client = AdbShellBridge.daemonClient()
        if (!client.isConnected()) return null
        return try {
            val resp = client.getInt(dt, key)
            if (resp.has("error")) null else resp.optInt("value", Int.MIN_VALUE)
                .takeIf { it != Int.MIN_VALUE }
        } catch (_: Throwable) {
            null
        }
    }

    // (WARM_DT_FALLBACK + WATCH_SENTINELS moved into the existing
    // companion object below — Kotlin allows only one companion
    // per class.)

    /**
     * Label → catalog-name map for the textproto's status_keys block.
     * The Dart side uses this once at SDK construct to bridge legacy
     * label-keyed consumers (carGateProvider, dashboard widgets) onto
     * the universal catalog-name-keyed [AutoCarRegistry] / store.
     *
     * Pulled from the active CarTableSource so it picks up textproto
     * updates automatically. Stable across the app's lifetime once
     * the encrypted asset is loaded.
     */
    fun labelToCatalog(): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        // statusKeys() returns StatusKey objects with the raw catalog
        // INTEGER (post-resolution). To recover the NAME we reverse-
        // lookup in the framework catalog — same int → same name as
        // the textproto's feature_name field. This avoids extending
        // StatusKey just to plumb a name field through.
        val intToName = BydAutoFeatureIdsCatalog.byName
            .entries.associate { it.value to it.key }
        for (sk in UnitDispatcher.statusKeys()) {
            val name = intToName[sk.key] ?: continue
            out[sk.label] = name
        }
        return out
    }

    /** Phase-9 plumbing: expose the active CarTableSource so the
     *  ContentProvider reader (CarStatusProviderSource) can share the
     *  same encrypted-asset rotation as the dispatcher.
     *  See UnitDispatcher.tableSource() for the volatility contract. */
    fun tableSource(): CarTableSource = UnitDispatcher.tableSource()


    companion object {
        private const val TAG = "AutoFeatureService"

        // Device-types probed by getValueByName when the registry doesn't
        // know a feature's dt (probe each until non-sentinel). Aliases
        // [DeviceTypes.WARM] (the single source of truth) so it can't drift.
        val WARM_DT_FALLBACK = DeviceTypes.WARM
        // Sentinel set used by getValueByName to reject framework
        // "no data" responses from the per-feature fallback fetch.
        // (See SENTINEL_VALUES below for the full set used by the
        // legacy readStatus path.)
        val WATCH_SENTINELS = setOf(-10011, -10013, -10006, -10005, -10001, 65535)

        // Throttle the per-key failure log so a chronically-failing key
        // surfaces in logs without flooding them. 10 ticks ≈ 10 s on the
        // HOT tier; ~30 s WARM; ~100 s COLD.
        private const val LOG_EVERY_N_FAILURES = 10

        // BYDAutoManager sentinels meaning "value not available right now"
        // (typically the underlying CAN signal hasn't been published — car
        // parked / not in READY mode). The daemon returns these as a
        // successful response, but caching them poisons the LKV: a real
        // value that arrives later would have to fight a stale -10011 in
        // the cache, and the UI would see the sentinel propagate as a
        // valid number until Dart's range checks reject it. Treat them
        // as failures here so the cache stays clean and the UI's `--`
        // correctly means "we don't have a real reading yet."
        //
        // Catalog of observed BYD framework sentinels:
        //   -10011 = "feature key not bound / not supported on this trim"
        //   -10006 = "value not initialized yet (CAN signal hasn't fired)"
        //   -10005 = "permission denied for current process UID"
        //   -10001 = "framework still booting"
        //    65535 = uint16 -1 / "no data"
        //   Int.MIN_VALUE = our InAppPushManager.getInt sentinel for
        //                   "device-type not registered" (couldn't even
        //                   reach the framework)
        private val SENTINEL_VALUES = setOf(
            -10011, // feature key not bound / not supported on this trim
            -10013, // statistics-class signal not yet computed
            -10006, // value not initialized yet (CAN signal hasn't fired)
            -10005, // permission denied for current process UID
            -10001, // framework still booting
            65535,  // uint16 -1 / "no data"
            Int.MIN_VALUE, // InAppPushManager: device-type not registered
        )

        private fun isSentinel(v: Any?): Boolean =
            v is Number && v.toInt() in SENTINEL_VALUES
    }
}
