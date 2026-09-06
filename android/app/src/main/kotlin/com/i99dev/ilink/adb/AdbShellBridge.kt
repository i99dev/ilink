package com.i99dev.ilink.adb

import android.content.Context
import android.util.Base64
import android.util.Log
import com.i99dev.ilink.daemon.DashDaemonClient
import java.security.SecureRandom
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock

// Persistent loopback ADB session + long-lived DashDaemon.
//
// Lifecycle:
//   1) Lazy-connect to adbd over TCP (127.0.0.1:5555).
//   2) On first touch, sweep orphan helpers and spawn DashDaemon detached.
//   3) Connect the in-process DashDaemonClient to daemon's TCP 58733.
//   4) fastCall* routes commands through the daemon: ~5-10ms per tap.
//      shell() remains for one-shot debug/diagnostic commands.
//
// All methods are thread-safe. Must be called from a background thread
// (do not invoke from the UI main thread — Android forbids net I/O there).
object AdbShellBridge {
    private const val TAG = "AdbShellBridge"
    private val lock = ReentrantLock()
    private var appContext: Context? = null
    @Volatile private var connection: AdbConnection? = null
    private val daemon = DashDaemonClient()
    private val daemonBootstrapped = AtomicBoolean(false)
    // Liveness throttle: once a ping succeeds, trust the connection for
    // [livenessTtlMs] so a burst of reads (e.g. the warm-set batch) pays
    // one ping instead of one per call. A daemon that dies inside the
    // window is still caught — the failing op disconnects the client
    // (DashDaemonClient.send self-heals), so the next ensureDaemon sees
    // !isConnected and reconnects. Monotonic clock (elapsedRealtime).
    @Volatile private var lastPingOkMs = 0L
    private val livenessTtlMs = 1_000L
    // True only while a thread is actively spawning the daemon. Other
    // callers observe it and wait cooperatively rather than queueing
    // behind `lock` (which would hold a mutex across net I/O).
    private val bootstrapInProgress = AtomicBoolean(false)

    // Unit class names we must never leave orphaned between runs.
    private val ORPHAN_CLASSES = listOf(
        "DoorUnit", "TrunkUnit", "AcUnit", "WindowUnit",
        "SeatMassageUnit", "FragranceUnit",
        "LightExteriorUnit", "LightInteriorUnit",
        "SeatHeatVentUnit", "SeatAdjustUnit",
        "AcSettingsUnit", "AirQualityUnit", "MirrorUnit",
        "DashDaemon", "DashCtrl",
    )

    @Volatile var lastError: String? = null
        private set

    // ── Daemon exec routing ────────────────────────────────────────────
    // shell() prefers the daemon's `exec` op over opening a fresh
    // loopback-adb connection. Each fresh adb connect makes the DiLink5.0
    // SystemUI flash the "Allow USB debugging" dialog (even for an
    // already-trusted key); routing through the warm daemon means we open
    // adb at most once per daemon lifetime — the spawn — and never again.
    // (DiLink5.1 auto-authorizes silently, so it's unaffected either way.)
    private const val CAP_EXEC = "exec"
    private const val CAP_MOVETASK = "moveTask"
    // Capability the daemon advertises once InputInjector reflected
    // injectInputEvent + MotionEvent.setDisplayId. A daemon spawned by a
    // pre-inject app build (shell uid survives reinstall, so the OLD daemon
    // keeps serving after an upgrade) won't advertise it — see [injectReady].
    private const val CAP_INJECT = "inject"
    private const val EXEC_TOKEN_ENV = "DASHD_EXEC_TOKEN"
    private const val BRIDGE_PREFS = "ilink.adb.bridge"
    private const val PREF_EXEC_TOKEN = "exec_token"
    // Structured `code`s from a token-gated daemon that mean "respawn me
    // with your token, then retry" (vs. a transport error → adb fallback).
    private val EXEC_AUTH_FAIL_CODES = setOf("EXEC_UNAUTHORIZED", "EXEC_DISABLED")
    private val tokenLock = Any()
    @Volatile private var cachedExecToken: String? = null
    // One-shot guard: when a stale pre-inject daemon is found, respawn ONCE to
    // upgrade it to the inject-capable build. Guarded so a ROM that genuinely
    // can't inject (hidden-API blocked) doesn't spawn-storm — it falls back to
    // a11y after the single attempt. Reset per process (a relaunch re-tries).
    private val injectUpgradeAttempted = AtomicBoolean(false)

    /**
     * Per-install secret that gates the daemon's `exec` op (the daemon's
     * TCP port is loopback but reachable by any local app, and exec runs
     * as uid 2000). Generated once, persisted app-private — survives app
     * restarts; only a reinstall / data-clear rotates it — and handed to
     * the daemon via the spawn environment (`/proc/<pid>/environ` is not
     * readable by other non-root apps, so the token doesn't leak).
     */
    private fun execToken(ctx: Context): String {
        cachedExecToken?.let { return it }
        return synchronized(tokenLock) {
            cachedExecToken ?: run {
                val prefs = ctx.getSharedPreferences(BRIDGE_PREFS, Context.MODE_PRIVATE)
                val existing = prefs.getString(PREF_EXEC_TOKEN, null)
                val token = if (!existing.isNullOrEmpty()) existing else {
                    val raw = ByteArray(24).also { SecureRandom().nextBytes(it) }
                    Base64.encodeToString(
                        raw, Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING,
                    ).also { prefs.edit().putString(PREF_EXEC_TOKEN, it).apply() }
                }
                cachedExecToken = token
                token
            }
        }
    }

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        // Stage encrypted unit DEX files (if the encrypted bundle ships)
        // once at app start, independent of daemon state. If we waited
        // to do this inside ensureDaemon() below, an already-running
        // daemon (left alive from a previous install — shell UID
        // persists across app uninstall) would make us take the fast-
        // path TCP return and skip staging entirely. The stager is
        // idempotent: if the on-disk DEX SHA already matches the
        // manifest, it's a quick sanity check.
        //
        // Off the main thread because the staging path opens an adb-
        // shell TCP loopback connection per unit — Android's
        // StrictMode panics with NetworkOnMainThreadException if we
        // call that from MainActivity.onCreate. The whole staging is
        // best-effort: the daemon's first ``ensureDaemon`` later will
        // re-attempt the same idempotent path on the worker thread if
        // something here goes wrong.
        Thread({
            try {
                UnitDexStager.stageAllIfNeeded(ctx.applicationContext)
            } catch (t: Throwable) {
                Log.w(
                    TAG,
                    "stageAllIfNeeded threw: " +
                        "${t.javaClass.simpleName}: ${t.message}",
                )
            }
        }, "UnitDexStager-boot").start()
    }
    fun isConnected(): Boolean = connection != null
    fun isDaemonReady(): Boolean = daemon.isConnected()

    fun daemonClient(): DashDaemonClient = daemon

    // One-shot shell command. Use fastCall* for hot path.
    //
    // Prefers the warm daemon's `exec` op so a shell action doesn't open
    // a fresh loopback-adb connection (which flashes the "Allow USB
    // debugging" dialog on DiLink5.0). Falls back to the direct adb path
    // only when the daemon can't serve exec — the cold spawn, or a stale
    // pre-exec daemon we can't upgrade.
    fun shell(cmd: String, timeoutMs: Long = 5_000): String {
        val ctx = appContext ?: return "Error: bridge not init'd"
        daemonExec(ctx, cmd, timeoutMs)?.let { return it }
        return shellViaAdb(ctx, cmd, timeoutMs)
    }

    /**
     * Binary push of [localFile] → [remotePath] (shell uid) over the direct
     * loopback-adb connection — the fast path for staging large APKs (raw
     * bytes in 1 MB stream packets vs thousands of 128 KB base64 shell
     * commands). Returns false if the bridge isn't ready, is busy, or the
     * push fails, so the caller can fall back to base64 staging. Reuses the
     * live connection (no new auth prompt); on push failure the connection
     * is closed and the next shell() reconnects.
     */
    fun pushFile(localFile: File, remotePath: String, timeoutMs: Long = 180_000): Boolean {
        val ctx = appContext ?: return false
        // DEDICATED connection — NOT the shared one behind `lock`. A multi-second
        // transfer must not hold the bridge lock, or the main thread's routine
        // shell calls (daemon liveness ping) block on it → ANR → the app freezes
        // mid-push. adbd allows multiple client sockets; the app's key is already
        // authorised, so no second "Allow USB debugging" prompt fires.
        val conn = try {
            AdbConnection.connect(ctx)
        } catch (e: Throwable) {
            Log.w(TAG, "pushFile connect failed: ${e.message}")
            return false
        }
        return try {
            conn.pushFile(localFile, remotePath, timeoutMs)
        } catch (e: Throwable) {
            Log.w(TAG, "pushFile($remotePath) failed: ${e.message}")
            false
        } finally {
            conn.close()
        }
    }

    /** Direct loopback-adb shell — the original path, now the fallback
     *  used only when [daemonExec] can't serve the command. */
    private fun shellViaAdb(ctx: Context, cmd: String, timeoutMs: Long): String {
        // Lock acquisition uses tryLock with the caller's own timeout
        // instead of an indefinite lock. Why: a cold-pair ADB auth
        // (first ``ensureAdb`` after install) holds the lock while
        // AdbConnection.connect sits on its IO_SLOW = 90 s socket
        // read waiting for the user to tap ALLOW. Before this guard,
        // every subsequent shell call — including the launcher-
        // privilege probe's 1.5 s budget — silently waited up to 90 s
        // behind the cold-pair auth. Result: "Grant all" / "Make
        // default home" buttons spin indefinitely on a fresh install
        // (reported 2026-05-15) with no UX recovery. Fast-failing here
        // surfaces a recoverable "bridge busy" so the caller's probe
        // returns ``adb_unreachable`` and the UI can show a clean
        // retry affordance instead of a forever spinner. The bridge
        // recovers automatically once the in-flight auth completes
        // and releases the lock.
        if (!lock.tryLock(timeoutMs, TimeUnit.MILLISECONDS)) {
            return "Error: bridge busy (cold-pair auth in progress)"
        }
        try {
            // Mark Authorizing only if no live ADB connection exists —
            // otherwise we're piggy-backing on an already-authorised
            // session and no system prompt will fire.
            val needsConnect = connection == null
            if (needsConnect) AdbSetupBus.setState(AdbSetupPhase.Authorizing)
            val conn = ensureAdb(ctx)
            if (conn == null) {
                if (needsConnect) {
                    AdbSetupBus.setState(AdbSetupPhase.Failed, lastError)
                }
                return "Error: adb connect failed: $lastError"
            }
            val result = try {
                conn.shell(cmd, timeoutMs)
            } catch (e: Throwable) {
                Log.w(TAG, "shell reconnect: ${e.message}")
                try {
                    connection?.close()
                    connection = AdbConnection.connect(ctx)
                    connection!!.shell(cmd, timeoutMs)
                } catch (e2: Throwable) {
                    lastError = e2.message ?: e2.javaClass.simpleName
                    if (needsConnect) {
                        AdbSetupBus.setState(AdbSetupPhase.Failed, lastError)
                    }
                    return "Error: $lastError"
                }
            }
            // Connection is alive and the first shell command returned —
            // the user-facing "Allow USB debugging?" step is over. Flip
            // to Ready so the overlay dismisses. If a later ensureDaemon
            // call discovers the daemon needs spawning, it will re-emit
            // Authorizing/Spawning around its own shell sequence.
            if (needsConnect) AdbSetupBus.setState(AdbSetupPhase.Ready)
            return result
        } finally { lock.unlock() }
    }

    // Make sure the daemon is up + client connected. Idempotent and
    // cooperative: concurrent callers wait for the in-flight bootstrap
    // instead of serializing on a mutex held across net I/O.
    //
    // `maxAttempts` defaults to 1 (one spawn is plenty when the daemon
    // is already configured). Call sites that want the legacy 3-attempt
    // retry (e.g. initial cold-start warmup) can pass 3 explicitly.
    fun ensureDaemon(maxAttempts: Int = 1): Boolean {
        // Fast path — already connected. Throttle the liveness ping: once
        // a ping succeeds we trust the connection for [livenessTtlMs], so
        // a burst of reads collapses N pings to ~1 (was one ping + one op
        // per fastGet). A mid-window daemon death is still safe — see
        // [lastPingOkMs].
        if (daemon.isConnected()) {
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - lastPingOkMs < livenessTtlMs) return true
            if (daemon.ping()) {
                lastPingOkMs = now
                return true
            }
        }
        // Try a direct TCP connect first. A previous app launch (or a dev
        // adb invocation) may have already spawned DashDaemon under shell
        // UID, in which case it's still listening on 58733 and we can skip
        // the adbd auth dance entirely. `connect()` is a quick timeout-
        // bounded TCP attempt; no ADB involvement.
        if (daemon.connect() && daemon.ping()) {
            lastPingOkMs = android.os.SystemClock.elapsedRealtime()
            daemonBootstrapped.set(true)
            return true
        }

        // Another thread is already bootstrapping. Wait for it briefly
        // rather than contending on the mutex.
        if (!bootstrapInProgress.compareAndSet(false, true)) {
            repeat(30) { // 30 × 250ms = 7.5s cooperative wait
                Thread.sleep(250)
                if (daemon.isConnected() && daemon.ping()) return true
                if (!bootstrapInProgress.get()) return daemon.isConnected()
            }
            return daemon.isConnected()
        }

        try {
            val ctx = appContext ?: return false
            // Heads-up to the overlay BEFORE we touch ensureAdb — the
            // system "Allow USB debugging?" prompt can land within
            // milliseconds of opening the loopback socket, so we
            // need the contextual card painted first.
            AdbSetupBus.setState(AdbSetupPhase.Authorizing)
            repeat(maxAttempts) { attempt ->
                val conn = ensureAdb(ctx) ?: return@repeat
                // Connection authorised — flip to Spawning so the
                // overlay copy switches from "Allow USB debugging"
                // to "Starting background services".
                AdbSetupBus.setState(AdbSetupPhase.Spawning)
                val sweep = conn.shell(
                    "pkill -9 -f '${ORPHAN_CLASSES.joinToString("|")}' 2>/dev/null; echo swept",
                    3_000,
                )
                Log.i(TAG, "[attempt ${attempt + 1}/$maxAttempts] orphan sweep: ${sweep.take(60)}")
                val apk = ctx.applicationInfo.sourceDir
                // Hand the daemon the exec-gate token via its environment.
                // Token is URL-safe base64 (no quote/space chars) so it's
                // safe to embed bare inside the single-quoted `sh -c`, and
                // it lands in the daemon's environ — not its argv — so
                // other apps can't read it. `VAR=val exec prog` carries the
                // assignment into the exec'd app_process.
                val token = execToken(ctx)
                val spawnCmd = buildString {
                    append("nohup sh -c '")
                    append("$EXEC_TOKEN_ENV=$token ")
                    append("CLASSPATH=\"$apk\" exec app_process64 /system/bin com.i99dev.ilink.helper.DashDaemon")
                    append("' </dev/null >/data/local/tmp/dashd.log 2>&1 &")
                    append(" sleep 0.2; echo spawned=\$!")
                }
                val out = conn.shell(spawnCmd, 6_000)
                Log.i(TAG, "[attempt ${attempt + 1}/$maxAttempts] daemon spawn: ${out.take(120)}")
                val waitIters = 16 + attempt * 8
                repeat(waitIters) {
                    if (daemon.connect() && daemon.ping()) {
                        daemonBootstrapped.set(true)
                        AdbSetupBus.setState(AdbSetupPhase.Ready)
                        return true
                    }
                    Thread.sleep(250)
                }
                Log.w(TAG, "[attempt ${attempt + 1}/$maxAttempts] daemon did not bind within ${waitIters * 250}ms")
            }
            daemonBootstrapped.set(false)
            Log.e(TAG,
                "daemon failed to come up after $maxAttempts attempt(s). " +
                    "Inspect /data/local/tmp/dashd.log for the spawn output.",
            )
            AdbSetupBus.setState(
                AdbSetupPhase.Failed,
                lastError ?: "daemon failed to bind after $maxAttempts attempt(s)",
            )
            return false
        } finally {
            bootstrapInProgress.set(false)
        }
    }

    // Fast path — goes through the already-running daemon (~5-10ms).
    // Falls back to a one-shot shell invocation if the daemon is unreachable.
    fun fastSet(dt: Int, key: Int, value: Int): Map<String, Any?> =
        fastOp { daemon.setInt(dt, key, value) }

    fun fastGet(dt: Int, key: Int): Map<String, Any?> =
        fastOp { daemon.getInt(dt, key) }

    /**
     * Run a single daemon op with daemon-death self-heal. Two attempts: if the
     * daemon's serve loop died while its socket lingered half-open, the first
     * op times out and [DashDaemonClient.send] drops the dead connection — so
     * the retry's [ensureDaemon] reconnects to, or respawns (pkill + fresh
     * spawn), a live daemon. Recovers "process alive but not serving" without
     * an onboarding re-run. Returns `{error: daemon unreachable}` only when a
     * respawn genuinely couldn't bring the daemon back.
     */
    private inline fun fastOp(op: () -> org.json.JSONObject): Map<String, Any?> {
        var last: Map<String, Any?> = mapOf("error" to "daemon unreachable")
        repeat(2) {
            if (ensureDaemon()) {
                last = jsonToMap(op())
                if (last["error"] == null) return last
            }
        }
        return last
    }

    // Batch N gets in one TCP round-trip. Each entry: {dt, key}.
    // Returns per-entry map aligned with input order.
    //
    // This is the Phase 1 path — one inner `get` op per (dt, key)
    // pair, so a 30-key snapshot still produces 30 Binder hops on
    // the framework side (one per inner op). Phase 3's
    // [fastBatchGetGrouped] collapses those down to ~7 — one per
    // distinct device_type — when the daemon advertises the
    // `getIntArray` capability.
    fun fastBatchGet(entries: List<Pair<Int, Int>>): List<Map<String, Any?>> {
        if (!ensureDaemon()) return entries.map { mapOf("error" to "daemon unreachable") }
        val cmds = entries.map { (dt, key) ->
            org.json.JSONObject().apply {
                put("op", "get"); put("dt", dt); put("key", key)
            }
        }
        val r = daemon.batch(cmds)
        val arr = r.optJSONArray("results") ?: return entries.map { mapOf("error" to "no results") }
        val out = mutableListOf<Map<String, Any?>>()
        for (i in 0 until arr.length()) {
            out += jsonToMap(arr.getJSONObject(i))
        }
        // Pad if daemon returned fewer than requested.
        while (out.size < entries.size) out += mapOf("error" to "missing")
        return out
    }

    /**
     * Phase 3 — bulk read collapse. Groups [entries] by device_type
     * and issues one `getIA` (getIntArray) inner op per group. A 30-
     * key snapshot across 7 device types becomes 7 Binder hops
     * instead of 30 — typically a 4-5× CPU drop on the daemon's
     * polling tick.
     *
     * **Caller MUST feature-detect** via
     * `daemon.capabilities().contains("getIntArray")` first; this
     * function does NOT internally fall back to [fastBatchGet]
     * because the choice belongs in [AutoFeatureService.readStatus]
     * where the policy lives.
     *
     * Result is aligned 1:1 with the input [entries] order — same
     * contract as [fastBatchGet], so swapping the two is a one-line
     * change at the call site.
     */
    fun fastBatchGetGrouped(entries: List<Pair<Int, Int>>): List<Map<String, Any?>> {
        if (!ensureDaemon()) return entries.map { mapOf("error" to "daemon unreachable") }
        if (entries.isEmpty()) return emptyList()
        // Group preserving original index so we can re-align the result
        // list at the end. Each group fires one `getIA` inner op.
        val groups: Map<Int, List<IndexedValue<Pair<Int, Int>>>> =
            entries.withIndex().groupBy { it.value.first }
        val cmds = groups.map { (dt, members) ->
            val keysArr = org.json.JSONArray()
            members.forEach { keysArr.put(it.value.second) }
            org.json.JSONObject().apply {
                put("op", "getIA"); put("dt", dt); put("keys", keysArr)
            }
        }
        val r = daemon.batch(cmds)
        val arr = r.optJSONArray("results")
            ?: return entries.map { mapOf("error" to "no results") }
        // Build the output array indexed by original position.
        val out = arrayOfNulls<Map<String, Any?>>(entries.size)
        groups.entries.forEachIndexed { groupIdx, (_, members) ->
            val groupResult = if (groupIdx < arr.length()) {
                jsonToMap(arr.getJSONObject(groupIdx))
            } else {
                null
            }
            // groupResult is `{values: [...]}` on success or
            // `{error, code}` on failure. Failure → fan the error
            // out to every member of the group so the caller's
            // per-key handling still has something aligned.
            if (groupResult == null || groupResult["error"] != null) {
                val err = groupResult ?: mapOf("error" to "missing")
                members.forEach { out[it.index] = err }
                return@forEachIndexed
            }
            val values = groupResult["values"] as? org.json.JSONArray
            if (values == null) {
                members.forEach { out[it.index] = mapOf("error" to "no values") }
                return@forEachIndexed
            }
            members.forEachIndexed { memberIdx, m ->
                val v = if (memberIdx < values.length()) values.opt(memberIdx) else null
                out[m.index] = if (v != null) {
                    mapOf("value" to v)
                } else {
                    mapOf("error" to "short array")
                }
            }
        }
        @Suppress("UNCHECKED_CAST")
        return out.map { it ?: mapOf("error" to "unfilled") }
    }

    // ── Synthetic input injection (daemon FAST path) ───────────────────────
    // Mirrors fastSet/fastGet: ensure the daemon is up, then route the inject
    // op through it. Each `inject*` returns `null` when the daemon route is
    // unavailable — not up, or this daemon build predates input injection
    // (caps lacks "inject") — so [InputPlatformPlugin] falls through to its
    // a11y / ADB tiers. A non-null Boolean is the daemon's own dispatch verdict.
    //
    // The streamed `ptrMove`/`ptrUp`/`ptrCancel` deliberately SKIP ensureDaemon
    // (no liveness ping per frame): the session was established by a gated
    // ptrDown, and the client's sendOneWay/send self-heal a dropped socket. A
    // 60 Hz drag therefore never pays a round-trip or a ping.

    private fun injectReady(): Boolean {
        if (!ensureDaemon()) return false
        if (daemon.capabilities().contains(CAP_INJECT)) return true
        // Daemon is up but doesn't advertise inject. The common cause is a stale
        // daemon left running by a PRE-inject app build (shell uid persists
        // across reinstall), so the freshly-installed inject-capable code never
        // got a chance to run. Respawn ONCE to swap in the new code — same
        // mechanism the exec path uses for its capability upgrade. Guarded by a
        // one-shot flag so a ROM that genuinely can't inject doesn't spawn-storm.
        val ctx = appContext ?: return false
        if (injectUpgradeAttempted.compareAndSet(false, true)) {
            Log.i(TAG, "daemon lacks inject — respawning once to upgrade")
            respawnDaemonWithToken(ctx)
            return daemon.capabilities().contains(CAP_INJECT)
        }
        return false
    }

    fun injectTap(displayId: Int, x: Double, y: Double): Boolean? =
        if (injectReady()) daemon.injTap(displayId, x, y) else null

    fun injectSwipe(
        displayId: Int,
        x1: Double, y1: Double, x2: Double, y2: Double,
        durationMs: Int,
    ): Boolean? =
        if (injectReady()) daemon.injSwipe(displayId, x1, y1, x2, y2, durationMs) else null

    fun injectLongPress(displayId: Int, x: Double, y: Double, durationMs: Int): Boolean? =
        if (injectReady()) daemon.injLongPress(displayId, x, y, durationMs) else null

    fun injectKey(displayId: Int, keycode: Int): Boolean? =
        if (injectReady()) daemon.injKey(displayId, keycode) else null

    /** Open a streamed pointer session. Gated (ensureDaemon) because the DOWN
     *  must land on a live daemon before any move; returns null if unavailable. */
    fun injectPtrDown(displayId: Int, x: Double, y: Double): Boolean? =
        if (injectReady()) daemon.ptrDown(displayId, x, y) else null

    /** Stream a MOVE on the open session — no ping, fire-and-forget. */
    fun injectPtrMove(displayId: Int, x: Double, y: Double): Boolean =
        daemon.isConnected() && daemon.ptrMove(displayId, x, y)

    /** Close the open session. Best-effort; no ping. */
    fun injectPtrUp(x: Double, y: Double): Boolean =
        daemon.isConnected() && daemon.ptrUp(x, y)

    /** Abort the open session. Best-effort; no ping. */
    fun injectPtrCancel(): Boolean =
        daemon.isConnected() && daemon.ptrCancel()

    fun close() {
        lock.lock()
        try {
            daemon.disconnect()
            connection?.close()
            connection = null
            daemonBootstrapped.set(false)
            AdbSetupBus.setState(AdbSetupPhase.Idle)
        } finally { lock.unlock() }
    }

    /**
     * Try to run [cmd] through the daemon's token-gated `exec` op.
     * Returns the trimmed combined stdout/stderr on success, or `null`
     * when the daemon route is unavailable / errored — the caller then
     * falls back to [shellViaAdb]. In steady state this opens NO adb
     * connection (it rides the warm daemon socket); it only touches adb
     * via the rare [respawnDaemonWithToken] path (stale pre-exec daemon
     * or a foreign token after a reinstall).
     */
    private fun daemonExec(ctx: Context, cmd: String, timeoutMs: Long): String? {
        // Ride the daemon only if it's reachable NOW. `daemon.connect()`
        // is a quick TCP attempt (no adb, no spawn) that re-attaches to a
        // daemon surviving an app restart; if nothing's listening it fails
        // fast and we fall back to the adb path (which fail-fasts via
        // tryLock). The daemon's actual spawn stays owned by ensureDaemon
        // (eager boot + status polling) so a short-timeout probe never
        // blocks on a cold spawn here.
        if (!daemon.isConnected() && !daemon.connect()) return null
        // A daemon left running by a pre-exec app build won't advertise
        // `exec`; respawn once so the exec-aware code + our token take over.
        if (!daemon.capabilities().contains(CAP_EXEC) && !respawnDaemonWithToken(ctx)) {
            return null
        }
        val token = execToken(ctx)
        var resp = daemon.exec(cmd, timeoutMs, token)
        if (resp.optString("code") in EXEC_AUTH_FAIL_CODES) {
            // Live daemon rejects our token — spawned with a different one
            // (e.g. survived a reinstall). Respawn with ours and retry once.
            if (respawnDaemonWithToken(ctx)) resp = daemon.exec(cmd, timeoutMs, token)
        }
        // A transport/daemon error (not a clean exec result) → let the
        // adb path try instead of surfacing a confusing daemon error.
        if (resp.has("error")) return null
        return resp.optString("out", "").trim()
    }

    /**
     * Relocate [pkg]'s running task onto display [displayId] and pin it there
     * (the reference cluster-cast `launchAndForce`). Runs in the shell-uid daemon —
     * the only context whose `IActivityTaskManager.moveRootTaskToDisplay` BYD
     * honours; an app-uid `am start --display` gets re-homed. [w]/[h] size the task
     * to fill the VD. Returns true if the daemon reported the move succeeded.
     * No adb fallback — this op is daemon-only (app uid can't do it).
     */
    fun castTaskToDisplay(ctx: Context, pkg: String, displayId: Int, w: Int, h: Int): Boolean {
        if (!daemon.isConnected() && !daemon.connect()) return false
        if (!daemon.capabilities().contains(CAP_MOVETASK) && !respawnDaemonWithToken(ctx)) {
            return false
        }
        val token = execToken(ctx)
        var resp = daemon.moveTaskToDisplay(pkg, displayId, w, h, token)
        if (resp.optString("code") in EXEC_AUTH_FAIL_CODES) {
            if (respawnDaemonWithToken(ctx)) resp = daemon.moveTaskToDisplay(pkg, displayId, w, h, token)
        }
        return resp.optBoolean("ok", false)
    }

    /** Kill the current daemon and spawn a fresh one carrying our exec
     *  token. Costs one adb connect, but only on the rare stale-daemon
     *  path (post-OTA / post-reinstall), never per action. Returns true
     *  iff the respawned daemon advertises `exec`. */
    private fun respawnDaemonWithToken(ctx: Context): Boolean {
        lock.lock()
        try {
            daemon.disconnect()
            // ensureDaemon's TCP fast-path would just reconnect to the
            // stale daemon, so kill it directly over adb first.
            ensureAdb(ctx)?.let { conn ->
                try {
                    conn.shell(
                        "pkill -9 -f '${ORPHAN_CLASSES.joinToString("|")}' 2>/dev/null; echo k",
                        3_000,
                    )
                } catch (_: Throwable) {}
            }
        } finally { lock.unlock() }
        return ensureDaemon(maxAttempts = 1) && daemon.capabilities().contains(CAP_EXEC)
    }

    private fun ensureAdb(ctx: Context): AdbConnection? {
        val existing = connection
        if (existing != null) return existing
        return try {
            val c = AdbConnection.connect(ctx)
            connection = c
            lastError = null
            Log.i(TAG, "adb connected")
            c
        } catch (e: Throwable) {
            lastError = e.message ?: e.javaClass.simpleName
            Log.w(TAG, "adb connect failed: $lastError")
            null
        }
    }

    private fun jsonToMap(j: org.json.JSONObject): Map<String, Any?> {
        val m = linkedMapOf<String, Any?>()
        val it = j.keys()
        while (it.hasNext()) {
            val k = it.next()
            m[k] = j.opt(k)
        }
        return m
    }
}
