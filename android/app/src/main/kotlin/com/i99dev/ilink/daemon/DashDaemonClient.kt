package com.i99dev.ilink.daemon

import android.util.Log
import com.i99dev.ilink.BuildConfig
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

// TCP client for DashDaemon. Thread-safe; id-correlated so concurrent
// callers share one socket. Caller must run this off the main thread.
class DashDaemonClient {
    companion object {
        private const val TAG = "DashDaemonClient"
        // Populated from dash's compile-time AppConfig (see
        // `android/app/build.gradle.kts`). Plain `./gradlew` builds without
        // --dart-define still get the production defaults (127.0.0.1:58733).
        private val HOST: String = BuildConfig.DAEMON_HOST
        private val PORT: Int = BuildConfig.DAEMON_PORT
        private const val DEFAULT_TIMEOUT_MS = 2_000L

        /** Extra wait the [exec] round-trip allows on top of the command's
         *  own `timeoutMs`, covering the daemon's process spawn + the TCP
         *  hop so the client doesn't time out a command that the daemon is
         *  still legitimately running. */
        private const val EXEC_ROUND_TRIP_SLACK_MS = 2_000L
    }

    private val idSeq = AtomicLong(1)
    private val pending = ConcurrentHashMap<String, Waiter>()
    private val connected = AtomicBoolean(false)

    /// Per-subscription handlers, keyed by the daemon-issued `subId`.
    /// The reader thread routes incoming `{event:"change", subId, ...}`
    /// frames to the matching handler. Set on `subscribe`, cleared on
    /// `unsubscribe` or disconnect.
    private val subHandlers = ConcurrentHashMap<String, (JSONObject) -> Unit>()

    /// Cached capability set the daemon advertises via the `caps` op.
    /// Populated once at [connect] time. Empty when (a) the daemon is
    /// older than Phase 1 (no `caps` op → request returns `error`), or
    /// (b) we're not connected yet. Callers must feature-detect
    /// before sending any post-Phase-1 op:
    ///
    /// ```kotlin
    /// if (client.capabilities().contains("getIntArray")) {
    ///   client.getIntArray(...)
    /// } else {
    ///   client.batch(...)  // pre-Phase-3 fallback
    /// }
    /// ```
    private val capabilities = ConcurrentHashMap.newKeySet<String>()

    private var socket: Socket? = null
    private var out: OutputStream? = null

    @Synchronized
    fun connect(timeoutMs: Int = 800): Boolean {
        if (connected.get()) return true
        try {
            val sock = Socket()
            sock.connect(InetSocketAddress(HOST, PORT), timeoutMs)
            sock.soTimeout = 30_000
            sock.tcpNoDelay = true
            socket = sock
            out = sock.getOutputStream()
            connected.set(true)
            Thread({ runReader(sock) }, "dashd-reader").apply {
                isDaemon = true
                start()
            }
            Log.i(TAG, "connected to daemon")
            // Refresh the capabilities cache as the FIRST request after
            // connect — every subsequent feature-detect call (e.g.
            // `if (capabilities().contains("getIntArray")) …`) sees a
            // populated set even on the very first tick. The cache
            // empties on disconnect (see [disconnect]).
            refreshCapabilities()
            return true
        } catch (e: Throwable) {
            // Defensive teardown: if connect partially initialised (socket
            // assigned + reader started) before a later line threw, drop it so
            // we never cache a half-open zombie that send()'s liveness check
            // would trust. No-op when sock.connect() itself threw (nothing
            // assigned yet).
            try {
                socket?.close()
            } catch (_: Throwable) {
            }
            socket = null
            out = null
            connected.set(false)
            Log.w(TAG, "connect failed: ${e.javaClass.simpleName}: ${e.message}")
            return false
        }
    }

    fun isConnected(): Boolean = connected.get()

    /**
     * Capability flags the daemon advertises via the `caps` op.
     *
     * Returned set contains every flag the daemon set to `true` (e.g.
     * `"push"`, `"getDouble"`, `"getIntArray"`, `"area"`).
     * Empty when the daemon is older than Phase 1 (caps op returns
     * `error: unknown op`) or when not connected.
     *
     * Refreshed once at [connect]; clients that need to re-poll after
     * a daemon restart can call [refreshCapabilities] explicitly.
     */
    fun capabilities(): Set<String> = capabilities.toSet()

    /**
     * Re-issue the `caps` op and overwrite the cache. Used by the
     * connect flow + by tests that swap a daemon mid-session. Safe
     * to call concurrently — `ConcurrentHashMap.newKeySet` is the
     * underlying set.
     */
    fun refreshCapabilities() {
        capabilities.clear()
        if (!connected.get()) return
        // Short timeout — caps is one round-trip on already-warm
        // socket. Failure is non-fatal: empty set means "no advanced
        // ops supported", same as a pre-Phase-1 daemon.
        val resp = send("caps", body = {}, timeoutMs = 800)
        if (resp.has("error")) return
        val keys = resp.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            if (k == "id") continue
            if (resp.optBoolean(k, false)) capabilities.add(k)
        }
    }

    /**
     * Fetch the daemon's `stats` op for production observability.
     * Returns the raw response with counters: `pushFramesReceived`,
     * `pollFramesEmitted`, `subsTotal`, `subsArmed`, `pushAvailable`,
     * `pushDevicesRegistered`, `uptimeMs`. On error returns the error
     * envelope so callers can surface the failure rather than a stale
     * 0-valued counter.
     *
     * Use this to verify push is actually delivering on a real BYD
     * device — if `pushFramesReceived` stays at 0 after several seconds
     * of car activity but `pushAvailable=true`, the framework registered
     * us but isn't dispatching events to our context.
     */
    fun stats(): JSONObject {
        if (!connected.get()) return JSONObject().put("error", "disconnected")
        return send("stats", body = {}, timeoutMs = 800)
    }

    fun disconnect() {
        connected.set(false)
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        out = null
        val err = JSONObject().put("error", "disconnected")
        pending.values.forEach { it.complete(err) }
        pending.clear()
        subHandlers.clear()
        // Clear the cached capability flags — a reconnect against a
        // potentially-different daemon (e.g. after sideload upgrade)
        // must re-issue `caps` rather than reuse stale advertised
        // flags. Also keeps the empty-set semantic ("not connected")
        // honest at the type level.
        capabilities.clear()
    }

    fun send(
        op: String,
        body: JSONObject.() -> Unit = {},
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    ): JSONObject {
        if (!connected.get()) return JSONObject().put("error", "not connected")
        val id = "c${idSeq.getAndIncrement()}"
        val payload = JSONObject().apply {
            put("id", id)
            put("op", op)
            body()
        }
        val waiter = Waiter()
        pending[id] = waiter
        try {
            val bytes = (payload.toString() + "\n").toByteArray(StandardCharsets.UTF_8)
            val o = out ?: return JSONObject().put("error", "no output stream")
            synchronized(o) { o.write(bytes); o.flush() }
        } catch (e: Throwable) {
            pending.remove(id)
            disconnect()
            return JSONObject().put("error", "write failed: ${e.message}")
        }
        val resp = waiter.await(timeoutMs)
        if (resp != null) return resp
        // Timeout — the peer never answered. A half-open socket to a daemon
        // whose serve loop died (process alive, listener gone) stays
        // `isConnected() == true` forever, so ensureDaemon's liveness fast-path
        // would keep trusting it and every op would time out. Drop it now so
        // the next ensureDaemon reconnects — or respawns — a live daemon.
        // (Write failures already disconnect above; this covers the read side.)
        pending.remove(id)
        disconnect()
        return JSONObject().put("error", "timeout").put("id", id)
    }

    /**
     * Fire-and-forget write for high-frequency, non-critical ops (nav-HUD frames):
     * serialise + flush, NO response wait. The daemon still processes the op and
     * replies; that reply is just an un-awaited event the reader drops (no waiter
     * is registered for an `o…` id). Returns false (and drops the socket) only on
     * a write failure, so the transport can fall back. This keeps the nav-hud
     * thread off the 2 s request/response round-trip on every frame.
     */
    fun sendOneWay(op: String, body: JSONObject.() -> Unit = {}): Boolean {
        if (!connected.get()) return false
        val payload = JSONObject().apply {
            put("id", "o${idSeq.getAndIncrement()}") // id present but never awaited
            put("op", op)
            body()
        }
        return try {
            val bytes = (payload.toString() + "\n").toByteArray(StandardCharsets.UTF_8)
            val o = out ?: return false
            synchronized(o) { o.write(bytes); o.flush() }
            true
        } catch (e: Throwable) {
            disconnect()
            false
        }
    }

    fun ping(timeoutMs: Long = 400): Boolean =
        send("ping", body = {}, timeoutMs = timeoutMs).optBoolean("pong", false)

    fun setInt(dt: Int, key: Int, value: Int, area: Int? = null): JSONObject =
        send("set", body = {
            put("dt", dt); put("key", key); put("val", value)
            // Phase 2 — multi-zone overload. Daemon picks the
            // setInt(dt, key, val, area) overload iff `area` present
            // AND `caps.area` was true at connect. Caller is expected
            // to feature-detect via `capabilities().contains("area")`
            // before passing area; the daemon also silently drops
            // back to the 3-arg overload if its own area-Method
            // reflection failed, so this is fail-safe.
            if (area != null) put("area", area)
        })

    fun getInt(dt: Int, key: Int): JSONObject =
        send("get", body = {
            put("dt", dt); put("key", key)
        })

    // Batched GET/SET/ENABLE/getIA. `cmds` elements are the same JSON
    // shape as individual ops (without `id`). Response is
    // {"results": [...]}, aligned 1:1 with input order.
    //
    // Phase 3 callers wrap a list of `{op:"getIA", dt, keys:[...]}`
    // entries — one per device_type — so a 30-key snapshot becomes
    // ~7 Binder hops instead of 30. See AdbShellBridge.fastBatchGetGrouped.
    fun batch(cmds: List<JSONObject>): JSONObject {
        val arr = org.json.JSONArray()
        cmds.forEach { arr.put(it) }
        return send("batch", body = { put("cmds", arr) }, timeoutMs = 5_000)
    }

    // ── Phase 2 — wider get/set surface ────────────────────────────
    // Each method maps 1:1 to a daemon op. Caller MUST feature-detect
    // via `capabilities().contains(name)` before calling — the daemon
    // returns `{error: "not supported", code: "NOT_SUPPORTED"}` on
    // ROMs that lack the underlying overload, but checking up front
    // avoids burning a round-trip.

    /**
     * Read a double-precision value (e.g. STATISTIC_WATER_TEMPERATURE,
     * AC_TEMP_*). Response shape: `{value: double}` or
     * `{error, code: "NOT_SUPPORTED"}`.
     */
    fun getDouble(dt: Int, key: Int): JSONObject =
        send("getD", body = { put("dt", dt); put("key", key) })

    /**
     * Read a byte buffer (e.g. media metadata blob, DTC dump).
     * Response shape: `{value: Base64String?, len: int}`. Decode
     * via `Base64.getDecoder().decode(resp.getString("value"))`.
     */
    fun getBuffer(dt: Int, key: Int): JSONObject =
        send("getB", body = { put("dt", dt); put("key", key) })

    /**
     * Bulk-read a list of keys for ONE device_type in a single
     * Binder hop. Used by Phase 3's grouped readStatus path —
     * collapses N keys × 1 hop each → 1 hop for N keys.
     *
     * Response shape: `{values: [int, int, ...]}`, aligned 1:1 with
     * the input `keys` list.
     */
    fun getIntArray(dt: Int, keys: List<Int>): JSONObject {
        val arr = org.json.JSONArray()
        keys.forEach { arr.put(it) }
        return send("getIA", body = { put("dt", dt); put("keys", arr) })
    }

    /**
     * Write a byte buffer. Encoder is standard Base64 (matches the
     * daemon's `Base64.getDecoder()`). Response: `{ok, code}` like
     * setInt.
     */
    fun setBytes(dt: Int, key: Int, value: ByteArray): JSONObject {
        val b64 = java.util.Base64.getEncoder().encodeToString(value)
        return send("setB", body = {
            put("dt", dt); put("key", key); put("val", b64)
        })
    }

    /**
     * Multi-key atomic set. `keys` and `values` MUST be the same
     * length (the daemon validates and returns
     * `{error, code: "ARG_MISMATCH"}` otherwise). Use for a single
     * binder write that touches several aligned signals — e.g.
     * "set fan level + wind mode + temp" on the AC subsystem.
     */
    fun setMulti(dt: Int, keys: List<Int>, values: List<Int>): JSONObject {
        require(keys.size == values.size) {
            "setMulti: keys.size=${keys.size} != values.size=${values.size}"
        }
        val ka = org.json.JSONArray(); keys.forEach { ka.put(it) }
        val va = org.json.JSONArray(); values.forEach { va.put(it) }
        return send("setMulti", body = { put("dt", dt); put("keys", ka); put("vals", va) })
    }

    /**
     * Run a shell command on the daemon (uid 2000, `shell` SELinux
     * domain — same privilege as `adb shell <cmd>`). Routing shell
     * actions here keeps the app from opening a fresh loopback-adb
     * connection per action, which on DiLink5.0 flashes the system
     * "Allow USB debugging" dialog every time.
     *
     * [token] gates the op (see DashDaemon.execToken). Response shape:
     * `{out:String, code:Int, truncated:Bool, timeout?:Bool}` on success,
     * or `{error, code:"EXEC_*"}` — callers branch on `code` to tell an
     * auth failure (respawn + retry) from a transport failure (fall back).
     *
     * Feature-detect with `capabilities().contains("exec")` first; a
     * daemon spawned by a pre-exec app won't advertise it.
     */
    fun exec(cmd: String, timeoutMs: Long, token: String): JSONObject =
        send("exec", body = {
            put("cmd", cmd); put("timeoutMs", timeoutMs); put("token", token)
        }, timeoutMs = timeoutMs + EXEC_ROUND_TRIP_SLACK_MS)

    /**
     * Relocate [pkg]'s running task onto [displayId] and pin focus (the reference
     * `launchAndForce` equivalent) so a foreign nav app STAYS on our cluster VD
     * instead of being re-homed by BYD's scene manager. [token] gates it like
     * [exec]. The daemon runs the privileged move+focus twice internally, so this
     * blocks ~500ms. Response: `{ok, taskId, hasMove, hasFocus}` or `{error, code}`.
     * Feature-detect with `capabilities().contains("moveTask")`.
     */
    fun moveTaskToDisplay(
        pkg: String,
        displayId: Int,
        w: Int,
        h: Int,
        token: String,
    ): JSONObject =
        send("moveTask", body = {
            put("pkg", pkg); put("displayId", displayId)
            put("w", w); put("h", h); put("token", token)
        }, timeoutMs = 2_000L)

    // ── Synthetic input injection (caps.inject) ────────────────────────────
    // The FAST path the cluster touchpad + gesture family ride: the daemon
    // injects MotionEvent/KeyEvent streams via reflected
    // InputManager.injectInputEvent + MotionEvent.setDisplayId — no per-event
    // `input -d N` shell fork, per-display, full streaming. Feature-detect with
    // `capabilities().contains("inject")`; an older daemon / a ROM that hides
    // the API reports the flag false and the plugin falls back to a11y / ADB.
    //
    // Coordinates are display-local pixels on the resolved input display id (the
    // plugin resolves + maps before calling — the daemon just injects).

    /** Single tap (DOWN+UP) at (x,y). Awaited; returns daemon `ok`. */
    fun injTap(displayId: Int, x: Double, y: Double): Boolean =
        send("injTap", body = { put("displayId", displayId); put("x", x); put("y", y) })
            .optBoolean("ok", false)

    /** One-shot swipe DOWN→MOVE→UP. For a real streamed drag prefer
     *  [ptrDown]/[ptrMove]/[ptrUp]; this matches the discrete-swipe contract. */
    fun injSwipe(
        displayId: Int,
        x1: Double, y1: Double, x2: Double, y2: Double,
        durationMs: Int,
    ): Boolean =
        send("injSwipe", body = {
            put("displayId", displayId)
            put("x1", x1); put("y1", y1); put("x2", x2); put("y2", y2)
            put("durationMs", durationMs)
        }).optBoolean("ok", false)

    /** Long-press at (x,y) for [durationMs]. Awaited; returns daemon `ok`. */
    fun injLongPress(displayId: Int, x: Double, y: Double, durationMs: Int): Boolean =
        send("injLong", body = {
            put("displayId", displayId); put("x", x); put("y", y)
            put("durationMs", durationMs)
        }).optBoolean("ok", false)

    /** Begin a streamed pointer session (ACTION_DOWN). Awaited — the DOWN must
     *  land before any MOVE/UP, so it's worth one round-trip to confirm. */
    fun ptrDown(displayId: Int, x: Double, y: Double): Boolean =
        send("injPtr", body = {
            put("phase", "down"); put("displayId", displayId); put("x", x); put("y", y)
        }).optBoolean("ok", false)

    /**
     * Stream a MOVE on the live session — **fire-and-forget** ([sendOneWay]) so a
     * 60 Hz drag never pays the request/response round-trip. Returns false only
     * on a write failure (transport dropped); the caller throttles the rate.
     */
    fun ptrMove(displayId: Int, x: Double, y: Double): Boolean =
        sendOneWay("injPtr") {
            put("phase", "move"); put("displayId", displayId); put("x", x); put("y", y)
        }

    /** End the live session (ACTION_UP) at (x,y). Awaited. */
    fun ptrUp(x: Double, y: Double): Boolean =
        send("injPtr", body = { put("phase", "up"); put("x", x); put("y", y) })
            .optBoolean("ok", false)

    /** Abort the live session (ACTION_CANCEL) — sheet closed mid-drag. */
    fun ptrCancel(): Boolean =
        send("injPtr", body = { put("phase", "cancel") }).optBoolean("ok", false)

    /** Inject a key (DOWN+UP) on [displayId]. setDisplayId is best-effort on the
     *  daemon, so the plugin still prefers a11y/ADB for text-bearing keys. */
    fun injKey(displayId: Int, keycode: Int): Boolean =
        send("injKey", body = { put("displayId", displayId); put("keycode", keycode) })
            .optBoolean("ok", false)

    /**
     * Subscribe to (dt, key) changes. Daemon mints a `subId`, polls the
     * value at [periodMs] (floor ~200 ms; daemon will clamp anything
     * shorter) internally and pushes `{event:"change", subId, value,
     * atMs}` frames on diff. [onChange] runs on the reader thread —
     * keep it cheap; heavy work belongs downstream.
     *
     * Pick periodMs by signal volatility:
     *   * 200 ms — speed, gear, wheel angle (driver-visible motion)
     *   * 500 ms — door / lock state, beam state, window position
     *   * 2000 ms — AC mode/temp, SOC, range, cabin temp
     *   * 5000 ms — settings, brightness, locale, anything user-pace
     *
     * Defaults to 200 ms so legacy callers keep the snappy cadence.
     */
    fun subscribe(
        dt: Int,
        key: Int,
        periodMs: Int = 200,
        onChange: (JSONObject) -> Unit,
    ): String? {
        val resp = send("subscribe", body = {
            put("dt", dt); put("key", key); put("periodMs", periodMs)
        })
        val subId = resp.optString("subId", "")
        if (subId.isEmpty()) return null
        subHandlers[subId] = onChange
        return subId
    }

    /** Idempotent. Local handler is removed regardless of daemon reply. */
    fun unsubscribe(subId: String) {
        subHandlers.remove(subId)
        if (connected.get()) {
            send("unsubscribe", body = { put("subId", subId) }, timeoutMs = 500)
        }
    }

    private fun runReader(sock: Socket) {
        try {
            BufferedReader(InputStreamReader(sock.getInputStream(), StandardCharsets.UTF_8))
                .use { reader ->
                    while (connected.get()) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) continue
                        try {
                            val obj = JSONObject(line)
                            val id = obj.optString("id", "")
                            if (id.isEmpty()) {
                                // Event frame — route by subId. We
                                // never invent fake replies here, so
                                // pending waiters time out as before.
                                if (obj.optString("event") == "change") {
                                    val subId = obj.optString("subId", "")
                                    subHandlers[subId]?.invoke(obj)
                                }
                                continue
                            }
                            pending.remove(id)?.complete(obj)
                        } catch (e: Throwable) {
                            Log.w(TAG, "parse: ${e.message}  line=$line")
                        }
                    }
                }
        } catch (e: Throwable) {
            Log.w(TAG, "reader died: ${e.message}")
        } finally {
            disconnect()
        }
    }

    private class Waiter {
        private val latch = CountDownLatch(1)
        @Volatile private var result: JSONObject? = null
        fun complete(r: JSONObject) { result = r; latch.countDown() }
        fun await(timeoutMs: Long): JSONObject? =
            if (latch.await(timeoutMs, TimeUnit.MILLISECONDS)) result else null
    }
}
