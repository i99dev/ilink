package com.i99dev.ilink.car

import android.content.Context
import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Auto-discovery engine — works on ANY BYD trim with zero curation.
 *
 * Brute-force algorithm (one-shot at app boot, ~2-5 seconds):
 *
 *   1. Reflect the framework catalog
 *      (`android.hardware.bydauto.BYDAutoFeatureIds`) → name → int.
 *   2. For each [WARM_DT], call `getIntArray(dt, allKeys)` once
 *      (Phase 3 collapsed read — single Binder hop per device-type).
 *   3. Any (name, dt) tuple whose value isn't a known sentinel
 *      becomes a live entry. First dt that returns live wins;
 *      duplicates across device-types are ignored.
 *   4. Subscribe to push for every live entry via in-app
 *      [InAppPushManager] — registry stays fresh in real time
 *      with zero polling.
 *
 * No hardcoded categories. No name humanization. No per-namespace
 * device-type table. The CALLER (UI / SDK consumer) decides how to
 * group and label entries — typically by [Entry.name] prefix
 * (everything before the first dot in the catalog name).
 *
 * Trim-aware by construction: any feature absent on a particular Han
 * / Tang / Leopard / Yangwang trim simply never enters the registry.
 * ROM upgrades that rename or add features get picked up on next
 * boot for free.
 *
 * What this does NOT auto-discover (these stay in textproto):
 *   - `fast_actions` — write commands need value semantics
 *     (`1=on, 2=off, 3=auto`) the framework doesn't expose.
 *   - `unit_actions` — DEX-spawned multi-step actions live outside
 *     `autoMgr` and need their bundle metadata.
 *   - `binder_routes` — AIDL services on a different transport.
 */
class AutoCarRegistry(
    context: Context,
    private val push: InAppPushManager,
) {

    /** App-private file path for the diagnostic dump. Survives logcat-
     *  ring rotation; pull via `run-as com.i99dev.ilink cat
     *  files/auto_registry.txt` from a developer device, or via
     *  `cp` from the daemon (shell UID can read app filesDir). */
    private val dumpFile = java.io.File(context.filesDir, "auto_registry.txt")

    /** Persistent cache of (name → dt,key) tuples. Skips the 15-20 s
     *  brute-force probe on subsequent boots — values come live from
     *  push subscriptions, so we only need the cheap routing map. */
    private val cacheFile = java.io.File(context.filesDir, "auto_registry.cache")

    /** A single live feature. [value] / [lastUpdateMs] mutate as push
     *  events arrive; everything else is immutable after [build]. */
    data class Entry(
        /** Catalog name verbatim (e.g. `Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR`). */
        val name: String,
        /** Device-type the framework dispatcher uses. */
        val dt: Int,
        /** Resolved integer feature ID. */
        val key: Int,
        @Volatile var value: Int = Int.MIN_VALUE,
        @Volatile var lastUpdateMs: Long = 0L,
    )

    /** Live feature index keyed by full catalog name. */
    private val entries = ConcurrentHashMap<String, Entry>()

    /** Push subscription cancellers, keyed by name. */
    private val pushCancellers = ConcurrentHashMap<String, () -> Unit>()

    /** External listener — fires for every push frame after the
     *  registry's internal value update. Used by [CarChannel] to
     *  forward deltas to the Dart side via an EventChannel so the
     *  SDK can ditch its 1 s polling loop. Single-listener (one
     *  Dart-side EventChannel) is fine; if we need fanout later,
     *  promote to a CopyOnWriteArrayList. */
    @Volatile var onChange: ((String, Int) -> Unit)? = null

    /** Lifetime push frames received across all entries — diagnostics
     *  signal that the framework is still pushing values to us. */
    private val pushFramesReceived = AtomicLong(0L)

    @Volatile var built: Boolean = false
        private set

    /**
     * Discover every live feature on this car. Synchronous — caller
     * runs on a background thread (typically [AutoFeatureService] init).
     * Idempotent: second call is a cheap no-op.
     */
    fun build(): Boolean {
        if (built) return true
        Log.w(TAG, "build entry: push.stats=${push.stats()}")
        if (!push.available) {
            Log.w(TAG, "push manager unavailable — cannot build registry")
            return false
        }
        val t0 = System.currentTimeMillis()

        val catalog = BydAutoFeatureIdsCatalog.byName
        if (catalog.isEmpty()) {
            Log.w(TAG, "framework catalog empty — no entries to discover")
            return false
        }

        // Cache fast path — skip the 15-20 s brute-force probe when
        // the disk-cached (name, dt, key) tuples are still valid for
        // this framework version. Tuples come from a previous boot's
        // probe; values come live from push subscriptions below.
        val cacheSig = catalogSignature(catalog)
        val loaded = loadCache(cacheSig)
        if (loaded != null) {
            for (rec in loaded) entries[rec.name] = rec
            subscribeAll()
            // Seed initial values via one bulk daemon read per dt —
            // otherwise the UI sees Int.MIN_VALUE for every entry
            // until push happens to fire (some signals only change
            // every few minutes; static ones might never push).
            seedValuesFromDaemon()
            val tookMs = System.currentTimeMillis() - t0
            Log.w(TAG, "AutoCarRegistry restored from cache: ${entries.size} entries in ${tookMs}ms")
            built = true
            return true
        }

        // Snapshot the catalog as parallel arrays — one Binder call per
        // dt operates on the shared key array, so we use the same index
        // to map results back to names.
        val names = catalog.keys.toList()
        val keys = IntArray(names.size) { catalog[names[it]] ?: 0 }
        Log.w(TAG, "build: probing ${names.size} catalog entries × ${WARM_DT.size} device-types")

        // Sanity probes — confirm individual push.getInt works for
        // known-live keys at build time. If these return sentinel,
        // the brute-force path is hopeless and the framework hasn't
        // populated values yet (need a longer warmup delay).
        val sanityKeys = mapOf(
            "Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE" to 1001,
            "Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT" to 1001,
            "Ac.AC_TEMP_INSIDE" to 1000,
        )
        for ((n, dt) in sanityKeys) {
            val k = catalog[n] ?: continue
            val vSingle = push.getInt(dt, k)
            val vArray = push.getIntArray(dt, intArrayOf(k))?.firstOrNull()
            Log.w(TAG, "  sanity $n: single=$vSingle array=$vArray")
        }

        var foundAny = 0
        val now0 = System.currentTimeMillis()

        // Cold-probe path — needs the daemon's autoMgr.getInt route
        // (in-app `super.get()` throws for keys not bound to a specific
        // BydPushDevice instance). Wait up to 30 seconds for the daemon
        // to come online (it bootstraps in parallel with the app's
        // initialization; on a fresh install we may beat it here).
        val daemon = AdbShellBridge.daemonClient()
        val daemonDeadline = System.currentTimeMillis() + 30_000L
        while (!daemon.isConnected() && System.currentTimeMillis() < daemonDeadline) {
            Thread.sleep(500L)
        }
        if (!daemon.isConnected()) {
            Log.w(TAG, "daemon never reached READY — cold probe aborted (next boot will retry)")
            return false
        }

        for (dt in WARM_DT) {
            var i = 0
            var addedThisDt = 0
            while (i < keys.size) {
                val end = minOf(i + CHUNK_SIZE, keys.size)
                val chunkKeys = keys.copyOfRange(i, end)
                // Bulk read via daemon getIntArray op — Phase 3
                // collapsed-read path. One TCP round-trip per chunk.
                val pairs = chunkKeys.map { Pair(dt, it) }
                val results = AdbShellBridge.fastBatchGet(pairs)
                for (j in chunkKeys.indices) {
                    val r = results.getOrNull(j) ?: continue
                    val raw = r["value"] ?: continue
                    val v = (raw as? Number)?.toInt() ?: continue
                    if (v in SENTINELS) continue
                    val name = names[i + j]
                    if (entries.putIfAbsent(name, Entry(
                            name = name,
                            dt = dt,
                            key = chunkKeys[j],
                            value = v,
                            lastUpdateMs = now0,
                        )) == null) {
                        addedThisDt++
                        foundAny++
                    }
                }
                i = end
            }
            Log.w(TAG, "  dt=$dt: $addedThisDt new live entries")
        }

        // Subscribe to push for every live entry. The in-app push path
        // bypasses the daemon and routes per-device — the framework's
        // dispatcher fires onPostEvent on value changes, no polling.
        subscribeAll()

        // Save the (name → dt, key) routing map so subsequent boots
        // skip the expensive probe. Values are intentionally NOT
        // cached — push subscriptions repopulate them within seconds
        // of restore, and a stale cached value would surface as
        // "ancient last-known" until the first push frame.
        saveCache(catalogSignature(catalog))

        val tookMs = System.currentTimeMillis() - t0
        Log.w(TAG, "AutoCarRegistry built: $foundAny live entries in ${tookMs}ms")
        // Diagnostic — write a snapshot to the app's filesDir so the
        // dump survives logcat-ring rotation. The shell UID daemon
        // can copy it out; on dev builds use
        // `adb shell run-as com.i99dev.ilink cat files/auto_registry.txt`.
        try {
            val dump = StringBuilder()
            dump.appendLine("AutoCarRegistry — $foundAny entries (built in ${tookMs}ms)")
            dump.appendLine("# name\tdt\tkey\tvalue")
            for (rec in entries.values.sortedBy { it.name }) {
                dump.appendLine("${rec.name}\t${rec.dt}\t${rec.key}\t${rec.value}")
            }
            dumpFile.writeText(dump.toString())
            Log.w(TAG, "wrote registry dump to ${dumpFile.absolutePath}")
        } catch (t: Throwable) {
            Log.w(TAG, "registry dump write failed: ${t.javaClass.simpleName}: ${t.message}")
        }
        built = true
        return true
    }

    // ── Query API ─────────────────────────────────────────────────────

    /** All live entries currently in the registry. */
    fun all(): Collection<Entry> = entries.values

    /** Look up by full catalog name. */
    fun get(name: String): Entry? = entries[name]

    /** Snapshot of registry state for diagnostics / observability. */
    fun stats(): Map<String, Any?> = mapOf(
        "built" to built,
        "totalEntries" to entries.size,
        "pushFramesReceived" to pushFramesReceived.get(),
    )

    /** Tear down all push subscriptions. */
    fun shutdown() {
        for ((_, c) in pushCancellers) {
            try { c() } catch (_: Throwable) {}
        }
        pushCancellers.clear()
    }

    /** Force-discard the cache and rebuild from scratch on next boot.
     *  Use sparingly — after a confirmed framework regression where
     *  the cached (name, dt) map no longer matches what the
     *  framework binds. */
    fun invalidateCache() {
        try { cacheFile.delete() } catch (_: Throwable) {}
    }

    // ── Push subscription + cache I/O ────────────────────────────────

    /**
     * Seed initial values for all cached entries via one bulk daemon
     * read per device-type. Only used on the cache-fast-path — the
     * cold-probe path sets values inline as it discovers them. Skips
     * silently if the daemon isn't reachable (push will eventually
     * fill values as signals change).
     */
    private fun seedValuesFromDaemon() {
        val daemon = AdbShellBridge.daemonClient()
        if (!daemon.isConnected()) return
        val byDt = entries.values.groupBy { it.dt }
        val now = System.currentTimeMillis()
        for ((dt, recs) in byDt) {
            val pairs = recs.map { Pair(dt, it.key) }
            val results = AdbShellBridge.fastBatchGet(pairs)
            for ((i, rec) in recs.withIndex()) {
                val r = results.getOrNull(i) ?: continue
                val raw = r["value"] ?: continue
                val v = (raw as? Number)?.toInt() ?: continue
                if (v in SENTINELS) continue
                rec.value = v
                rec.lastUpdateMs = now
            }
        }
    }

    private fun subscribeAll() {
        for (rec in entries.values) {
            val canceller = push.subscribe(rec.dt, rec.key) { newValue ->
                if (newValue !in SENTINELS) {
                    rec.value = newValue
                    rec.lastUpdateMs = System.currentTimeMillis()
                    pushFramesReceived.incrementAndGet()
                    // Forward to external listener (Dart EventChannel)
                    // so consumers can subscribe to live deltas without
                    // polling. Catch defensively — a sloppy consumer
                    // shouldn't crash our registry update path.
                    try { onChange?.invoke(rec.name, newValue) } catch (_: Throwable) {}
                }
            }
            pushCancellers[rec.name] = canceller
        }
    }

    /**
     * Cheap signature of the framework catalog. Changes when the BYD
     * ROM adds / removes / renames features (=> cache stale, must
     * rebuild). Stable across ordinary app restarts on the same ROM.
     *
     * Implementation: size + the first / last entry names. A real ROM
     * upgrade always changes at least one of these; routine app
     * boots never do.
     */
    private fun catalogSignature(catalog: Map<String, Int>): String {
        val first = catalog.keys.firstOrNull() ?: ""
        val last = catalog.keys.lastOrNull() ?: ""
        return "v1|${catalog.size}|$first|$last"
    }

    /**
     * Restore (name, dt, key) tuples from disk if the signature still
     * matches the current framework catalog. Returns null on any
     * mismatch / parse failure / missing file — caller falls back to
     * a fresh probe.
     *
     * On-disk format (line-oriented to keep parsing trivial):
     *   line 0: signature string
     *   line N (1+): `name\tdt\tkey`
     *
     * Plain text. App-private filesDir, no encryption (catalog names
     * are public framework constants — same set every BYD app sees
     * via reflection — so there's nothing to protect).
     */
    private fun loadCache(currentSig: String): List<Entry>? {
        if (!cacheFile.exists()) return null
        return try {
            val lines = cacheFile.readLines()
            if (lines.isEmpty() || lines[0] != currentSig) {
                Log.w(TAG, "cache invalidated: sig mismatch (cached=${lines.firstOrNull()}, current=$currentSig)")
                return null
            }
            val now = System.currentTimeMillis()
            val out = ArrayList<Entry>(lines.size - 1)
            for (i in 1 until lines.size) {
                val parts = lines[i].split('\t')
                if (parts.size < 3) continue
                val name = parts[0]
                val dt = parts[1].toIntOrNull() ?: continue
                val key = parts[2].toIntOrNull() ?: continue
                out.add(Entry(name = name, dt = dt, key = key, lastUpdateMs = now))
            }
            if (out.isEmpty()) null else out
        } catch (t: Throwable) {
            Log.w(TAG, "cache load failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }

    /** Persist the routing map for the next boot's fast-path. Atomic
     *  write: stage to a `.tmp` sibling then rename on top of the
     *  target. On Android filesystems this is POSIX-rename-atomic, so
     *  a crash mid-write leaves either the OLD cache (perfectly
     *  usable) or the NEW one (perfectly usable) — never a half-
     *  written file that fails parse. */
    private fun saveCache(sig: String) {
        val tmp = java.io.File(cacheFile.parentFile, "${cacheFile.name}.tmp")
        try {
            val sb = StringBuilder(entries.size * 64)
            sb.appendLine(sig)
            for (rec in entries.values) {
                sb.append(rec.name).append('\t')
                  .append(rec.dt).append('\t')
                  .append(rec.key).append('\n')
            }
            tmp.writeText(sb.toString())
            // Rename on top — atomic on POSIX. If this throws (rare,
            // e.g. filesystem full), the tmp file is left behind for
            // the next save attempt to overwrite.
            if (!tmp.renameTo(cacheFile)) {
                throw java.io.IOException("rename ${tmp.name} -> ${cacheFile.name} failed")
            }
            Log.w(TAG, "cache saved: ${entries.size} entries to ${cacheFile.absolutePath}")
        } catch (t: Throwable) {
            Log.w(TAG, "cache save failed: ${t.javaClass.simpleName}: ${t.message}")
            try { tmp.delete() } catch (_: Throwable) {}
        }
    }

    companion object {
        private const val TAG = "AutoCarRegistry"

        /** Device-types probed for the cold registry build: brute-force
         *  every catalog entry against every dt; some ints resolve under
         *  multiple device-types, first-wins. Aliases [DeviceTypes.WARM]
         *  (the single source of truth) so it can't drift from it. */
        private val WARM_DT = DeviceTypes.WARM

        /** Per-call key array size for the bulk getIntArray probe.
         *  Some ROMs reject very-large arrays; 1024 is small enough
         *  to be safe and large enough that we make ~10 Binder calls
         *  per dt for a 10k-entry catalog (40 calls per dt × 7 dts =
         *  ~280 calls total, ~1-2 sec on real hardware). */
        private const val CHUNK_SIZE = 64

        /** Framework sentinels meaning "value not bound / not initialised
         *  / permission denied". An entry returning any of these is
         *  treated as not-live and excluded from the registry. */
        private val SENTINELS = setOf(
            -10011, -10013, -10006, -10005, -10001, 65535, Int.MIN_VALUE,
        )
    }
}
