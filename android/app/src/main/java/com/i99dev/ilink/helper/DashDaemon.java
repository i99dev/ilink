package com.i99dev.ilink.helper;

import android.content.Context;

import com.i99dev.ilink.car.DeviceTypes;
import com.i99dev.ilink.nav.transport.canfid.InstrumentHalWriter;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

// Long-running BYDAutoManager actuator. Spawned once via adb shell so it
// runs under shell UID 2000 (has BYDAUTO_* perms). Keeps the autoMgr
// reference warm so each setInt/getInt is ~5ms instead of ~1s.
//
// Listens on TCP 127.0.0.1:58733 loopback. Line-delimited JSON.
// Bootstrap: sh -c 'CLASSPATH=base.apk exec app_process64 /system/bin com.i99dev.ilink.helper.DashDaemon'
public final class DashDaemon {
    private static final int PORT = 58733;
    /** Loopback host the control port binds to — the one place the address is
     *  defined, reused by the bind, the re-bind, and the ready/exit logs. */
    private static final String HOST = "127.0.0.1";
    private static final int[] WARM_DT = DeviceTypes.WARM;

    // Package we belong to. If `pm path` can't find this pkg, dash has been
    // uninstalled out from under the daemon (daemon runs under shell UID
    // 2000 so Android doesn't kill it on uninstall) — we clean up our DEX
    // staging area and exit. See plan Phase 4.
    private static final String PARENT_PKG = "com.i99dev.ilink";
    // Staging directory for unit DEX files. Kept in sync with the Kotlin
    // side (AdbShellBridge.TMP / UnitDexStager.STAGE_DIR) — a single
    // source of truth lands when the CarTable proto absorbs these.
    private static final String STAGE_DIR = "/data/local/tmp";
    private static final long UNINSTALL_CHECK_PERIOD_SEC = 60L;

    // BYDAutoManager reflection surface — resolve `autoMgr`, reflect the
    // get/set overloads, expose them as typed calls + capability flags.
    // Extracted so the daemon keeps only wire + lifecycle. See
    // AutoManagerActuator.
    private final AutoManagerActuator actuator = new AutoManagerActuator();

    // Nav-HUD CAN-FID writer for 7.0UI clusters (Leopard 7). Lazily built from
    // the actuator's system context; drives BYDAutoInstrumentDevice directly.
    // Held here so the expensive system-context + getInstance happen ONCE and
    // the app streams frames over IPC (no per-frame app_process spawn).
    private InstrumentHalWriter halWriter;

    // Status subscription + push engine — the active-sub map, the grouped
    // poll loop, the BYD push devices + onPushEvent callback, and the
    // push/poll observability counters. Reads CAN values through the
    // actuator. See StatusSubscriptionEngine.
    private final StatusSubscriptionEngine engine = new StatusSubscriptionEngine(actuator);

    // Synthetic touch/key injection (cluster touchpad FAST path + mini-app
    // gesture family). Holds the reflected InputManager.injectInputEvent +
    // MotionEvent.setDisplayId handles; injects MotionEvent streams to any
    // display at native latency (no per-event `input -d N` shell fork). Only
    // the daemon can do this — it has INJECT_EVENTS via the shell domain.
    // Advertised via the `inject` capability once init() reflects.
    private final InputInjector injector = new InputInjector();

    /** Wall-clock ms when the daemon process started. Used by the
     *  `stats` op to report uptime. */
    private final long bootMs = System.currentTimeMillis();
    private ScheduledExecutorService maintenance;

    /** Shared secret the parent app passes via the spawn env
     *  (`DASHD_EXEC_TOKEN`). Gates the `exec` op: 58733 is loopback but
     *  any local app can reach it, and `exec` runs shell commands as
     *  uid 2000, so it must not be open. The token rides the spawn
     *  environment because `/proc/<pid>/environ` is readable only by the
     *  process's own uid or root — unlike argv, it doesn't leak to other
     *  apps. Null/empty when an older app (pre-exec) spawned this daemon;
     *  in that case `exec` is neither advertised nor honoured, and the
     *  bridge falls back to its direct loopback-adb path. */
    private final String execToken = System.getenv("DASHD_EXEC_TOKEN");

    /** Cap on the combined stdout+stderr an `exec` returns. Bounds the
     *  JSON frame so a runaway `dumpsys` can't OOM the daemon or wedge
     *  the client's line reader. Output past this is dropped and the
     *  reply carries `truncated:true`. */
    private static final int MAX_EXEC_OUT = 1 << 20; // 1 MiB

    /** Runs `exec` commands off the per-socket serve thread so a slow
     *  command can't stall the status get/set/subscribe traffic the app
     *  multiplexes over the same connection. Replies stay id-correlated so
     *  out-of-order completion is fine. Bounded (0..4 threads, 16-deep
     *  queue) so a misbehaving client can't spawn unbounded shells;
     *  overflow runs on the caller (serve) thread as backpressure. */
    private final ExecutorService execPool = new ThreadPoolExecutor(
            0, 4, 30L, TimeUnit.SECONDS, new LinkedBlockingQueue<>(16),
            r -> { Thread t = new Thread(r, "dashd-exec"); t.setDaemon(true); return t; },
            new ThreadPoolExecutor.CallerRunsPolicy());

    public static void main(String[] args) {
        try {
            new DashDaemon().run();
        } catch (Throwable t) {
            System.err.println("DashDaemon fatal: " + t);
            t.printStackTrace(System.err);
            System.exit(2);
        }
    }

    /**
     * Bind the loopback control port. With {@code SO_REUSEADDR} this succeeds
     * over a dead predecessor's {@code TIME_WAIT} remnant (clean restart) but
     * FAILS while any live daemon is actively LISTENing on it — which is
     * exactly what makes the port a single-instance mutex. No hardcoded paths
     * or extra state: the same {@link #PORT} the daemon already serves on is
     * the lock.
     */
    private static ServerSocket bindPort() throws IOException {
        ServerSocket s = new ServerSocket();
        s.setReuseAddress(true);
        s.bind(new InetSocketAddress(InetAddress.getByName(HOST), PORT));
        return s;
    }

    private void run() throws IOException {
        // One-shot uninstall check before we open the socket. If dash has
        // already been uninstalled while the daemon was down, this clears
        // the staging area and exits before we advertise on loopback.
        if (isParentMissing()) {
            log("parent pkg " + PARENT_PKG + " missing on boot — cleaning");
            cleanupAndExit();
            return;
        }
        // Single-instance gate: the PORT is the mutex (kernel-enforced, so no
        // flaky advisory file lock — the file-lock attempt silently fail-opened
        // on the BYD ROM's filesystem and let duplicates through). Try to bind
        // ONCE; if the port is already owned, another daemon is live, so EXIT
        // immediately instead of becoming an orphan that spins in the re-bind
        // loop and contends for the port — that pile-up is the "can't reach
        // car" window seen on-car.
        ServerSocket server;
        try {
            server = bindPort();
        } catch (IOException firstBindFailed) {
            log("port " + PORT + " already owned by a live daemon — exiting (no orphan): "
                + firstBindFailed);
            return;
        }
        initAutoService();
        startMaintenance();
        engine.start();
        // Resolve the input-injection reflection surface once at boot so the
        // `inject` capability is truthful at the client's connect-time caps
        // probe. Best-effort: a ROM that doesn't expose injectInputEvent leaves
        // the capability off and the client falls back to a11y / ADB.
        log("input injector " + (injector.init() ? "ready" : "unavailable"));
        log("ready on " + HOST + ":" + PORT);
        // Resilient listener. The daemon's whole job is to stay reachable on
        // PORT; the old loop bound ONCE and, if the ServerSocket was ever
        // closed out from under it (BYD ROM reaping the fd, a transient error),
        // accept() threw every iteration and the IOException-catch just
        // continue()d — spinning forever on a dead socket: process alive, PORT
        // not listening = the "can't reach car" zombie. Now we RE-BIND when the
        // listener dies, so we self-heal that case — UNLESS a fresh daemon
        // grabbed the port while we were down, in which case the re-bind fails
        // and we exit, never resurrecting into a second instance.
        while (true) {
            try {
                while (true) {
                    Socket client = server.accept();
                    Thread t = new Thread(() -> serve(client), "dashd-client");
                    t.setDaemon(true);
                    t.start();
                }
            } catch (Throwable t) {
                log("listener died (" + t + ") — re-binding in 1s");
                try { server.close(); } catch (Throwable ignored) {}
                try {
                    Thread.sleep(1_000L);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    return;
                }
                try {
                    server = bindPort();
                    log("re-bound on " + HOST + ":" + PORT);
                } catch (IOException reBindFailed) {
                    log("re-bind failed — another daemon took over, exiting: " + reBindFailed);
                    return;
                }
            }
        }
    }

    private void initAutoService() {
        // Reflection + auto-service resolution + WARM enable now live in
        // the actuator. A false return means the Phase-1 base API didn't
        // reflect (actuator logged the cause); skip push registration +
        // the warm-summary line, same as the pre-extraction outer-catch
        // path (pushAvailable stays false until a later op succeeds).
        if (!actuator.init()) return;
        try {
            // Phase 1 Chunk B — register one BydPushDevice per WARM
            // device-type (best-effort, poller-fallback on a stripped
            // ROM); the engine owns the devices + the onPushEvent target.
            engine.registerPushDevices(actuator.systemContext(), WARM_DT);
            log("autoMgr warm, DTs enabled. caps: " + actuator.capsLine()
                + " push=" + engine.pushAvailable() + " (" + engine.pushDeviceCount() + "/"
                + WARM_DT.length + " devices) dts=" + engine.pushDtStatusString());
        } catch (Throwable t) {
            log("init failed: " + t);
        }
    }

    private void serve(Socket sock) {
        OutputStream registered = null;
        try (Socket s = sock;
             BufferedReader in = new BufferedReader(
                     new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8))) {
            OutputStream out = s.getOutputStream();
            engine.registerClient(out, s);
            registered = out;
            String line;
            while ((line = in.readLine()) != null) {
                if (line.isEmpty()) continue;
                JSONObject resp;
                try {
                    resp = handle(new JSONObject(line), out);
                } catch (JSONException je) {
                    resp = new JSONObject();
                    try { resp.put("error", "bad json: " + je.getMessage()); }
                    catch (JSONException ignored) {}
                }
                // null = the op writes its own reply later (async exec), so
                // a slow command can't head-of-line-block this socket's
                // status polling. The reply is id-correlated; the client
                // routes it out of order.
                if (resp == null) continue;
                writeFrame(out, resp);
            }
        } catch (IOException e) {
            // client disconnected
        } finally {
            // Drop any subs this client owned. The poll thread skips
            // entries whose owner stream is closed, but cleaning up
            // proactively keeps the map bounded.
            engine.removeSubsForOwner(sock);
            if (registered != null) engine.unregisterClient(registered);
        }
    }

    private JSONObject handle(JSONObject req, OutputStream owner) throws JSONException {
        JSONObject r = new JSONObject();
        String id = req.optString("id", "");
        if (!id.isEmpty()) r.put("id", id);
        String op = req.optString("op", "");
        try {
            switch (op) {
                case "set":         return doSet(r, req);
                case "get":         return doGet(r, req);
                case "enable":      return doEnable(r, req);
                case "batch":       return doBatch(r, req);
                case "ping":        return r.put("pong", true);
                case "caps":        return doCaps(r);
                case "stats":       return doStats(r);
                case "dumpCatalog": return doDumpCatalog(r);
                // Phase 2 — wider get/set surface. Each op feature-
                // detects its reflected Method handle; if the ROM
                // doesn't expose the overload the call returns
                // `{error: "not supported"}` so the client falls
                // back via its capabilities() check.
                case "getD":        return doGetDouble(r, req);
                case "getB":        return doGetBuffer(r, req);
                case "getIA":       return doGetIntArray(r, req);
                case "setB":        return doSetBytes(r, req);
                case "halGuide":    return doHalGuide(r, req);
                case "setMulti":    return doSetMulti(r, req);
                case "subscribe":   return doSubscribe(r, req, owner);
                case "unsubscribe": return doUnsubscribe(r, req);
                // Synthetic input (cluster touchpad FAST path + gesture family).
                // Feature-detected via caps.inject; the client only sends these
                // when the daemon advertised the capability. `injPtr` move frames
                // arrive as fire-and-forget (sendOneWay) for low-latency streaming.
                case "injTap":      return doInjTap(r, req);
                case "injSwipe":    return doInjSwipe(r, req);
                case "injLong":     return doInjLong(r, req);
                case "injPtr":      return doInjPtr(r, req);
                case "injKey":      return doInjKey(r, req);
                // Shell-exec over the warm daemon connection. The bridge
                // routes every shell action here so it opens a fresh
                // loopback-adb connection at most once per daemon lifetime
                // (each fresh connect flashes the system "Allow USB
                // debugging" dialog on DiLink5.0). Token-gated, and run on
                // a worker pool (returns null here) so a slow command
                // doesn't block this socket's status traffic.
                case "exec":        doExecAsync(r, req, owner); return null;
                // Relocate a running task onto a display + pin focus (the
                // the reference `launchAndForce` equivalent). Privileged: only the
                // shell-uid daemon can call IActivityTaskManager.moveRootTaskToDisplay,
                // which is what makes a foreign nav app STAY on our cluster VD
                // where an app-uid `am start --display` gets re-homed by BYD's
                // scene manager. Token-gated like exec.
                case "moveTask":    return doMoveTask(r, req);
                default: return r.put("error", "unknown op: " + op);
            }
        } catch (Throwable t) {
            Throwable c = unwrap(t);
            return r.put("error", c.getClass().getSimpleName() + ": " + c.getMessage());
        }
    }

    /**
     * Capability discovery op. Clients call this once at connect time
     * and feature-detect before sending newer ops (per the plan's
     * AD-5 wire-stability rule). Each flag is set the moment the
     * matching daemon code lands — so an older client + newer daemon
     * sees flags=true and uses the new ops; a newer client + older
     * daemon sees flags missing/false and falls back gracefully.
     *
     * Adding a flag: update both this op and the matching client
     * `capabilities()` allow-list in DashDaemonClient.kt.
     */
    private JSONObject doCaps(JSONObject r) throws JSONException {
        // push: true when at least one BydPushDevice was registered
        //   with the framework. Flips to false on non-BYD ROMs (no
        //   AbsBYDAutoDevice class) or when every WARM dt's device
        //   constructor refused — both fall back to the poller path
        //   transparently (same shape as Phase 1A scaffolding).
        // getDouble/getBuffer/getIntArray/setBytes/setMulti/area:
        //   true iff the matching Method handle reflected
        //   successfully on autoMgr (Phase 2 lookups).
        return r
            .put("push",        engine.pushAvailable())
            .put("getDouble",   actuator.hasGetDouble())
            .put("getBuffer",   actuator.hasGetBuffer())
            .put("getIntArray", actuator.hasGetIntArray())
            .put("setBytes",    actuator.hasSetBytes())
            .put("setMulti",    actuator.hasSetMulti())
            .put("area",        actuator.hasSetIntArea())
            // exec: advertised only when a token is configured, so an
            // older-app-spawned daemon (no token) reports false and the
            // bridge keeps using its direct adb path until this daemon is
            // respawned by the exec-aware app.
            .put("exec",        execEnabled())
            // inject: true once InputInjector reflected injectInputEvent +
            // MotionEvent.setDisplayId. A daemon that pre-dates input injection,
            // or a ROM that hides the API, reports false and the gesture plugin
            // falls back to a11y dispatchGesture / ADB `input`.
            .put("inject",      injector.isReady())
            // moveTask: shares the exec token gate; advertised when a token is
            // configured (same daemon-vintage signal as exec).
            .put("moveTask",    execEnabled());
    }

    private boolean execEnabled() {
        return execToken != null && !execToken.isEmpty();
    }

    /**
     * Liveness + push-pipeline observability op. Returns counters that
     * let an operator answer "is push actually working?" without grepping
     * the daemon log:
     *
     *   pushFramesReceived  — total framework `onPostEvent` callbacks
     *                          since boot. Stuck-at-0 with `caps.push=true`
     *                          means the framework registered our
     *                          BydPushDevice subclasses but never invokes
     *                          them — usually a missing / wrong activity
     *                          context (the BYD framework dispatches
     *                          per-context).
     *   pollFramesEmitted   — total `change` frames the safety-net poller
     *                          has emitted. A rising value next to a high
     *                          armed-sub count means push is regressing
     *                          mid-session and the staleness fallback is
     *                          carrying the load.
     *   subsTotal / subsArmed — current sub map size + how many have
     *                          received at least one push. ratio = push
     *                          coverage on this ROM.
     *   pushDevicesRegistered  — list-string of WARM dts whose
     *                          BydPushDevice constructor succeeded. Same
     *                          map the boot log dumps; replicated here so
     *                          a diagnostic doesn't need log access.
     *   uptimeMs            — wall-clock since `initAutoService` began.
     */
    /**
     * Reflect on {@code android.hardware.bydauto.BYDAutoFeatureIds}
     * (root + every nested class) and dump every {@code public static
     * final int} field as a TSV {@code <NAME>\t<INT>} line to
     * {@code /data/local/tmp/byd_catalog.tsv}.
     *
     * One-shot op for the textproto migration: pull the file via
     * {@code adb pull}, build int → name reverse lookup, rewrite each
     * {@code key: <hex>} entry as {@code feature_name: "<NAME>"}.
     * After migration this op can be removed (or kept for diagnostics
     * — it's idempotent and cheap to call).
     *
     * Returns {@code {count: N, path: "..."}} on success, or
     * {@code {error: ...}} when the framework class isn't present.
     */
    private JSONObject doDumpCatalog(JSONObject r) throws JSONException {
        try {
            java.util.LinkedHashMap<String, Integer> map = new java.util.LinkedHashMap<>();
            Class<?> root = Class.forName("android.hardware.bydauto.BYDAutoFeatureIds");
            collectIntFieldsTo(root, map);
            for (Class<?> nested : root.getDeclaredClasses()) {
                try {
                    collectIntFieldsTo(nested, map);
                } catch (Throwable ignored) {}
            }
            String path = "/data/local/tmp/byd_catalog.tsv";
            try (java.io.PrintWriter w = new java.io.PrintWriter(
                    new java.io.FileWriter(path))) {
                for (var e : map.entrySet()) {
                    w.print(e.getKey());
                    w.print('\t');
                    w.println(e.getValue());
                }
            }
            return r.put("count", map.size()).put("path", path);
        } catch (Throwable t) {
            return r.put("error", t.getClass().getSimpleName() + ": " + t.getMessage());
        }
    }

    private static void collectIntFieldsTo(
            Class<?> cls, java.util.Map<String, Integer> out) throws Throwable {
        for (java.lang.reflect.Field f : cls.getDeclaredFields()) {
            int mods = f.getModifiers();
            if (!java.lang.reflect.Modifier.isStatic(mods)) continue;
            if (!java.lang.reflect.Modifier.isFinal(mods)) continue;
            if (f.getType() != int.class) continue;
            f.setAccessible(true);
            // Prefix with nested class name when present so name
            // collisions across nested groups (Safety.X vs root X)
            // can be disambiguated. Root-level entries stay unprefixed.
            String prefix = (cls.getEnclosingClass() != null)
                    ? cls.getSimpleName() + "."
                    : "";
            out.put(prefix + f.getName(), f.getInt(null));
        }
    }

    private JSONObject doStats(JSONObject r) throws JSONException {
        return r
            .put("pushFramesReceived",     engine.pushFramesReceived())
            .put("pollFramesEmitted",      engine.pollFramesEmitted())
            .put("subsTotal",              engine.subsTotal())
            .put("subsArmed",              engine.subsArmed())
            .put("pushAvailable",          engine.pushAvailable())
            .put("pushDevicesRegistered",  engine.pushDtStatusString())
            .put("uptimeMs",               System.currentTimeMillis() - bootMs);
    }

    private JSONObject doSet(JSONObject r, JSONObject req) throws Throwable {
        int dt = req.getInt("dt"), key = req.getInt("key"), val = req.getInt("val");
        // Phase 2: optional `area` selects the multi-zone overload
        // setInt(dt, key, val, area). Without area, fall back to the
        // 3-arg overload — same wire shape as Phase 1 clients sent.
        int code;
        if (req.has("area") && actuator.hasSetIntArea()) {
            code = actuator.setIntArea(dt, key, val, req.getInt("area"));
        } else {
            code = actuator.setInt(dt, key, val);
        }
        return r.put("ok", code == 0).put("code", code);
    }

    private JSONObject doGet(JSONObject r, JSONObject req) throws Throwable {
        int v = actuator.getInt(req.getInt("dt"), req.getInt("key"));
        return r.put("value", v);
    }

    private JSONObject doEnable(JSONObject r, JSONObject req) throws Throwable {
        int code = actuator.enableDevice(req.getInt("dt"));
        return r.put("code", code);
    }

    // ── Phase 2 — wider get/set ─────────────────────────────────────
    // Each op feature-detects: a missing reflected Method (overload not
    // present on this ROM) returns `{error: "not supported"}` and the
    // client is expected to have feature-detected via `caps` first.
    // The error is structured so the matching test can assert on the
    // exact code instead of free-text matching.

    private JSONObject doGetDouble(JSONObject r, JSONObject req) throws Throwable {
        if (!actuator.hasGetDouble()) return notSupported(r, "getDouble");
        double v = actuator.getDouble(req.getInt("dt"), req.getInt("key"));
        return r.put("value", v);
    }

    private JSONObject doGetBuffer(JSONObject r, JSONObject req) throws Throwable {
        if (!actuator.hasGetBuffer()) return notSupported(r, "getBuffer");
        byte[] bytes = actuator.getBuffer(req.getInt("dt"), req.getInt("key"));
        // Base64 because JSON has no native byte-array; Standard
        // (not URL-safe) encoder so the client uses the matching
        // Base64.getDecoder() without flipping a flag.
        String b64 = bytes == null ? null : Base64.getEncoder().encodeToString(bytes);
        return r.put("value", b64).put("len", bytes == null ? 0 : bytes.length);
    }

    private JSONObject doGetIntArray(JSONObject r, JSONObject req) throws Throwable {
        if (!actuator.hasGetIntArray()) return notSupported(r, "getIntArray");
        int dt = req.getInt("dt");
        JSONArray keysJson = req.getJSONArray("keys");
        int[] keys = new int[keysJson.length()];
        for (int i = 0; i < keys.length; i++) keys[i] = keysJson.getInt(i);
        int[] values = actuator.getIntArray(dt, keys);
        JSONArray valuesJson = new JSONArray();
        if (values != null) {
            for (int v : values) valuesJson.put(v);
        }
        return r.put("values", valuesJson);
    }

    private JSONObject doSetBytes(JSONObject r, JSONObject req) throws Throwable {
        if (!actuator.hasSetBytes()) return notSupported(r, "setBytes");
        int dt = req.getInt("dt"), key = req.getInt("key");
        byte[] bytes = Base64.getDecoder().decode(req.getString("val"));
        int code = actuator.setBytes(dt, key, bytes);
        return r.put("ok", code == 0).put("code", code);
    }

    /**
     * Nav-HUD 7.0UI: write one guidance frame to the instrument cluster via the
     * BYD HAL (BYDAutoInstrumentDevice), the path Leopard 7 clusters read (the
     * 5.0UI SOME/IP RoadInfo service is dead there). The persistent daemon holds
     * the writer + its system context, so the app streams frames over IPC — no
     * per-frame app_process spawn. Body: {icon, dist, road, on}.
     */
    private JSONObject doHalGuide(JSONObject r, JSONObject req) throws Throwable {
        if (halWriter == null) halWriter = new InstrumentHalWriter(actuator.systemContext());
        boolean ok = halWriter.writeFrame(
                req.optInt("icon", 0), req.optInt("dist", -1),
                req.optString("road", ""),
                req.optInt("remTime", -1), req.optInt("remDist", -1),
                req.optBoolean("on", true),
                req.optInt("camType", -1), req.optInt("camDist", -1), req.optInt("camState", -1),
                req.optInt("safeType", -1), req.optInt("safeDist", -1), req.optInt("safeState", -1));
        // `awake` = the 7.0UI HUD wake handshake has verified (cluster reports
        // NAVI_STATUS active); surfaced for the on-car nav-HUD diagnostics.
        return r.put("ok", ok).put("awake", halWriter.hudAwake());
    }

    private JSONObject doSetMulti(JSONObject r, JSONObject req) throws Throwable {
        if (!actuator.hasSetMulti()) return notSupported(r, "setMulti");
        int dt = req.getInt("dt");
        JSONArray keysJson = req.getJSONArray("keys");
        JSONArray valsJson = req.getJSONArray("vals");
        if (keysJson.length() != valsJson.length()) {
            return r.put("error", "keys/vals length mismatch")
                    .put("code", "ARG_MISMATCH");
        }
        int[] keys = new int[keysJson.length()];
        int[] vals = new int[valsJson.length()];
        for (int i = 0; i < keys.length; i++) {
            keys[i] = keysJson.getInt(i);
            vals[i] = valsJson.getInt(i);
        }
        int code = actuator.setMulti(dt, keys, vals);
        return r.put("ok", code == 0).put("code", code);
    }

    private static JSONObject notSupported(JSONObject r, String op) throws JSONException {
        return r.put("error", "not supported on this ROM")
                .put("code", "NOT_SUPPORTED")
                .put("op", op);
    }

    // ── Synthetic input injection ───────────────────────────────────────────
    // All five ops feature-detect against injector.isReady() and return the
    // structured NOT_SUPPORTED envelope (same shape as the Phase-2 overloads) so
    // a client that skipped the caps check still degrades cleanly instead of
    // hanging. Coordinates are display-local pixels (the app resolves the input
    // display id + maps to pixels before sending — the daemon just injects).
    //
    // Security posture: these are intentionally NOT token-gated, matching the
    // existing `set`/`get` CAN ops on this same loopback port — which are MORE
    // sensitive (they actuate AC / windows / instrument cluster). Only `exec`
    // (arbitrary shell as uid 2000) carries the token. Any local app that can
    // reach 127.0.0.1:PORT can already drive the car bus here; synthetic touch
    // is a strictly smaller capability, so it inherits the same posture rather
    // than introducing an inconsistent gate. Token-gating ALL mutating ops is a
    // separate, deliberate hardening that would touch the existing ops too.

    private JSONObject doInjTap(JSONObject r, JSONObject req) throws JSONException {
        if (!injector.isReady()) return notSupported(r, "inject");
        boolean ok = injector.tap(
                req.getInt("displayId"),
                (float) req.getDouble("x"), (float) req.getDouble("y"));
        return r.put("ok", ok);
    }

    private JSONObject doInjSwipe(JSONObject r, JSONObject req) throws JSONException {
        if (!injector.isReady()) return notSupported(r, "inject");
        boolean ok = injector.swipe(
                req.getInt("displayId"),
                (float) req.getDouble("x1"), (float) req.getDouble("y1"),
                (float) req.getDouble("x2"), (float) req.getDouble("y2"),
                req.optLong("durationMs", 200L));
        return r.put("ok", ok);
    }

    private JSONObject doInjLong(JSONObject r, JSONObject req) throws JSONException {
        if (!injector.isReady()) return notSupported(r, "inject");
        boolean ok = injector.longPress(
                req.getInt("displayId"),
                (float) req.getDouble("x"), (float) req.getDouble("y"),
                req.optLong("durationMs", 800L));
        return r.put("ok", ok);
    }

    /**
     * Streamed pointer session. {@code phase} ∈ {down, move, up, cancel}. `move`
     * frames arrive fire-and-forget (id {@code o…}); the reply is written but the
     * client never awaits it, so a 60 Hz drag never pays a request/response
     * round-trip. The daemon owns the {@code downTime} so the client only sends
     * coordinates; a lost {@code up} is recovered by the injector's auto-lift.
     */
    private JSONObject doInjPtr(JSONObject r, JSONObject req) throws JSONException {
        if (!injector.isReady()) return notSupported(r, "inject");
        String phase = req.optString("phase", "");
        int displayId = req.optInt("displayId", 0);
        float x = (float) req.optDouble("x", 0);
        float y = (float) req.optDouble("y", 0);
        boolean ok;
        switch (phase) {
            case "down":   ok = injector.ptrDown(displayId, x, y); break;
            case "move":   ok = injector.ptrMove(displayId, x, y); break;
            case "up":     ok = injector.ptrUp(x, y); break;
            case "cancel": ok = injector.ptrCancel(); break;
            default:       return r.put("error", "bad ptr phase: " + phase);
        }
        return r.put("ok", ok);
    }

    private JSONObject doInjKey(JSONObject r, JSONObject req) throws JSONException {
        if (!injector.isReady()) return notSupported(r, "inject");
        boolean ok = injector.key(req.getInt("displayId"), req.getInt("keycode"));
        return r.put("ok", ok);
    }

    private JSONObject doBatch(JSONObject r, JSONObject req) throws Throwable {
        JSONArray cmds = req.getJSONArray("cmds");
        JSONArray results = new JSONArray();
        for (int i = 0; i < cmds.length(); i++) {
            JSONObject c = cmds.getJSONObject(i);
            JSONObject inner = new JSONObject();
            try {
                switch (c.optString("op")) {
                    case "set":     doSet(inner, c); break;
                    case "get":     doGet(inner, c); break;
                    case "enable":  doEnable(inner, c); break;
                    // Phase 2/3 — bulk inner ops. Client groups
                    // status keys by device_type and submits one
                    // {op:"getIA", dt, keys[]} per dt; daemon returns
                    // {values[]} aligned with the input keys[]. One
                    // Binder hop per device_type instead of one per
                    // (dt, key) tuple.
                    case "getIA":   doGetIntArray(inner, c); break;
                    case "getD":    doGetDouble(inner, c); break;
                    case "getB":    doGetBuffer(inner, c); break;
                    case "setB":    doSetBytes(inner, c); break;
                    default: inner.put("error", "unknown batch op");
                }
            } catch (Throwable t) {
                Throwable cc = unwrap(t);
                inner.put("error", cc.getClass().getSimpleName() + ": " + cc.getMessage());
            }
            results.put(inner);
        }
        return r.put("results", results);
    }

    private static Throwable unwrap(Throwable t) {
        while (t.getCause() != null && t.getCause() != t) t = t.getCause();
        return t;
    }

    // -------- Subscription wire adapters --------------------------------
    // The active-sub map, grouped poller, push devices, and onPushEvent
    // callback live in StatusSubscriptionEngine; these stay as the thin
    // JSON adapters the handle() dispatch calls.

    private JSONObject doSubscribe(JSONObject r, JSONObject req, OutputStream owner) throws Throwable {
        int dt = req.getInt("dt"), key = req.getInt("key");
        // periodMs absent → -1 sentinel; the engine defaults to its poll
        // floor and floors any supplied value there (unchanged cadence).
        String subId = engine.subscribe(dt, key, req.optInt("periodMs", -1), owner);
        if (subId == null) return r.put("error", "no owner socket");
        return r.put("subId", subId);
    }

    private JSONObject doUnsubscribe(JSONObject r, JSONObject req) throws JSONException {
        String subId = req.optString("subId", "");
        if (subId.isEmpty()) return r.put("error", "missing subId");
        return r.put("ok", engine.unsubscribe(subId));
    }

    // -------- Shell exec ------------------------------------------------

    /**
     * Dispatch [exec] to the worker pool and write its id-correlated
     * reply when it finishes. handle() returns null for exec so the
     * serve loop keeps reading this socket's status traffic meanwhile.
     */
    private void doExecAsync(JSONObject r, JSONObject req, OutputStream out) {
        execPool.submit(() -> {
            try {
                writeFrame(out, doExec(r, req));
            } catch (Throwable t) {
                try {
                    writeFrame(out, r.put("error", "exec failed: " + t.getMessage())
                            .put("code", "EXEC_FAILED"));
                } catch (Throwable ignored) {
                    // socket closed mid-exec — nothing to deliver to
                }
            }
        });
    }

    /** Write one line-delimited JSON frame; synchronized so async exec
     *  replies and the serve loop's writes never interleave on a byte. */
    private static void writeFrame(OutputStream out, JSONObject obj) throws IOException {
        byte[] bytes = (obj.toString() + "\n").getBytes(StandardCharsets.UTF_8);
        synchronized (out) {
            out.write(bytes);
            out.flush();
        }
    }

    /**
     * Run a shell command as uid 2000 in this daemon's `shell` SELinux
     * domain — identical privilege to `adb shell <cmd>`, so callers that
     * used the bridge's direct-adb path see the same result.
     *
     * Request:  {op:"exec", cmd, timeoutMs?, token}
     * Reply OK: {out:String, code:int, truncated:bool, timeout?:bool}
     * Reply NG: {error, code:"EXEC_DISABLED"|"EXEC_UNAUTHORIZED"|
     *            "EXEC_EMPTY"|"EXEC_FAILED"}
     *
     * The structured `code` lets the bridge distinguish an auth failure
     * (respawn this daemon with our token, then retry) from a transport
     * failure (fall back to the adb path) without parsing free text.
     */
    private JSONObject doExec(JSONObject r, JSONObject req) throws JSONException {
        if (!execEnabled()) {
            return r.put("error", "exec not enabled").put("code", "EXEC_DISABLED");
        }
        if (!constantTimeEquals(req.optString("token", ""), execToken)) {
            return r.put("error", "unauthorized").put("code", "EXEC_UNAUTHORIZED");
        }
        String cmd = req.optString("cmd", "");
        if (cmd.isEmpty()) return r.put("error", "empty cmd").put("code", "EXEC_EMPTY");
        long timeoutMs = req.optLong("timeoutMs", 5_000L);
        return runExec(r, cmd, timeoutMs);
    }

    private JSONObject runExec(JSONObject r, String cmd, long timeoutMs) throws JSONException {
        Process p = null;
        try {
            p = new ProcessBuilder("sh", "-c", cmd).redirectErrorStream(true).start();
            final Process proc = p;
            final StringBuilder sb = new StringBuilder();
            final boolean[] truncated = {false};
            // Drain stdout on a side thread so a full pipe can't deadlock
            // against a process that out-writes our cap, while waitFor()
            // bounds the wall-clock on the main path.
            Thread reader = new Thread(() -> {
                try (BufferedReader br = new BufferedReader(new InputStreamReader(
                        proc.getInputStream(), StandardCharsets.UTF_8))) {
                    char[] buf = new char[8192];
                    int n;
                    while ((n = br.read(buf)) != -1) {
                        synchronized (sb) {
                            int room = MAX_EXEC_OUT - sb.length();
                            if (room <= 0) { truncated[0] = true; continue; } // keep draining
                            sb.append(buf, 0, Math.min(n, room));
                            if (n > room) truncated[0] = true;
                        }
                    }
                } catch (IOException ignored) {
                    // pipe closed on destroy / process exit
                }
            }, "dashd-exec-read");
            reader.setDaemon(true);
            reader.start();
            boolean done = p.waitFor(timeoutMs, TimeUnit.MILLISECONDS);
            if (!done) {
                p.destroyForcibly();
                reader.join(500);
                synchronized (sb) {
                    return r.put("out", sb.toString()).put("code", -1)
                            .put("timeout", true).put("truncated", truncated[0]);
                }
            }
            reader.join(1_000);
            synchronized (sb) {
                return r.put("out", sb.toString()).put("code", p.exitValue())
                        .put("truncated", truncated[0]);
            }
        } catch (Throwable t) {
            if (p != null) { try { p.destroyForcibly(); } catch (Throwable ignored) {} }
            return r.put("error", "exec failed: " + t.getMessage()).put("code", "EXEC_FAILED");
        }
    }

    /**
     * Relocate [pkg]'s running root task onto display [displayId] and pin focus —
     * the reference `launchAndForce` equivalent. Runs the move+focus twice (200ms
     * apart) to survive BYD's scene-manager re-home window. Reflection only; only
     * works from the shell-uid daemon (IActivityTaskManager rejects the app uid).
     * Body: {pkg, displayId, w?, h?, token}. Returns {ok, taskId, hasMove, hasFocus}.
     */
    private JSONObject doMoveTask(JSONObject r, JSONObject req) throws JSONException {
        if (!execEnabled()) return r.put("ok", false).put("error", "exec not enabled").put("code", "EXEC_DISABLED");
        if (!constantTimeEquals(req.optString("token", ""), execToken)) {
            return r.put("ok", false).put("error", "unauthorized").put("code", "EXEC_UNAUTHORIZED");
        }
        String pkg = req.optString("pkg", "");
        int displayId = req.optInt("displayId", -1);
        int w = req.optInt("w", 0);
        int h = req.optInt("h", 0);
        if (pkg.isEmpty() || displayId < 0) return r.put("ok", false).put("err", "bad args");
        try {
            Object atm = Class.forName("android.app.ActivityTaskManager")
                    .getMethod("getService").invoke(null);
            int taskId = findRootTaskForPkg(atm, pkg);
            if (taskId < 0) return r.put("ok", false).put("err", "task not found").put("pkg", pkg);
            java.lang.reflect.Method move = atmMethod(atm, "moveRootTaskToDisplay", int.class, int.class);
            java.lang.reflect.Method focus = atmMethod(atm, "setFocusedRootTask", int.class);
            java.lang.reflect.Method resize = atmMethod(atm, "resizeTask", int.class, android.graphics.Rect.class);
            boolean moved = false;
            for (int i = 0; i < 2; i++) {
                if (move != null) {
                    try { move.invoke(atm, taskId, displayId); moved = true; } catch (Throwable ignored) {}
                }
                if (resize != null && w > 0 && h > 0) {
                    try { resize.invoke(atm, taskId, new android.graphics.Rect(0, 0, w, h)); } catch (Throwable ignored) {}
                }
                if (focus != null) {
                    try { focus.invoke(atm, taskId); } catch (Throwable ignored) {}
                }
                try { Thread.sleep(200); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
            }
            return r.put("ok", moved).put("taskId", taskId)
                    .put("hasMove", move != null).put("hasFocus", focus != null);
        } catch (Throwable t) {
            Throwable c = unwrap(t);
            return r.put("ok", false).put("err", c.getClass().getSimpleName() + ": " + c.getMessage());
        }
    }

    /** Find the root-task id whose top activity belongs to [pkg], across all
     *  displays. Reflection over IActivityTaskManager.getAllRootTaskInfos
     *  (Android 12+) with an Android-11 getAllStackInfos fallback. -1 if absent. */
    private int findRootTaskForPkg(Object atm, String pkg) {
        try {
            java.lang.reflect.Method getAll = atmMethod(atm, "getAllRootTaskInfos");
            if (getAll == null) getAll = atmMethod(atm, "getAllStackInfos");
            if (getAll == null) return -1;
            Object res = getAll.invoke(atm);
            if (!(res instanceof java.util.List)) return -1;
            for (Object info : (java.util.List<?>) res) {
                android.content.ComponentName top = null;
                try {
                    top = (android.content.ComponentName) info.getClass().getField("topActivity").get(info);
                } catch (Throwable ignored) {}
                if (top != null && pkg.equals(top.getPackageName())) {
                    try { return info.getClass().getField("taskId").getInt(info); } catch (Throwable ignored) {}
                }
            }
        } catch (Throwable ignored) {}
        return -1;
    }

    private java.lang.reflect.Method atmMethod(Object atm, String name, Class<?>... params) {
        try {
            java.lang.reflect.Method m = atm.getClass().getMethod(name, params);
            m.setAccessible(true);
            return m;
        } catch (Throwable t) {
            return null;
        }
    }

    /** Length-aware constant-time compare — avoids leaking the token via
     *  early-exit timing. Both args UTF-8 encoded. */
    private static boolean constantTimeEquals(String a, String b) {
        if (a == null || b == null) return false;
        return MessageDigest.isEqual(
                a.getBytes(StandardCharsets.UTF_8), b.getBytes(StandardCharsets.UTF_8));
    }

    // -------- Uninstall self-check --------------------------------------

    /**
     * Schedules a periodic re-check of the parent package's presence. The
     * daemon survives uninstall (shell UID, not app UID), so this is the
     * only way to reliably free the staging area + stop the daemon itself.
     */
    private void startMaintenance() {
        if (maintenance != null) return;
        maintenance = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "dashd-maintenance");
            t.setDaemon(true);
            return t;
        });
        maintenance.scheduleWithFixedDelay(() -> {
            try {
                if (isParentMissing()) {
                    log("parent pkg " + PARENT_PKG + " went missing — cleaning");
                    cleanupAndExit();
                }
            } catch (Throwable t) {
                log("maintenance tick failed: " + t);
            }
        }, UNINSTALL_CHECK_PERIOD_SEC, UNINSTALL_CHECK_PERIOD_SEC, TimeUnit.SECONDS);
    }

    /**
     * Ask `pm path <pkg>` whether the APK is still installed. Runs via shell
     * because the daemon has no direct PackageManager access (shell UID).
     * Returns true only on a confident "not installed" — any transient
     * failure (pm service not up yet, exec interrupted, etc.) is treated
     * as "still installed" so we don't false-positive on a boot race.
     */
    private static boolean isParentMissing() {
        try {
            Process p = new ProcessBuilder("sh", "-c", "pm path " + PARENT_PKG + " 2>&1; echo __rc=$?")
                .redirectErrorStream(true)
                .start();
            StringBuilder sb = new StringBuilder();
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = r.readLine()) != null) sb.append(line).append('\n');
            }
            p.waitFor(5, TimeUnit.SECONDS);
            String out = sb.toString();
            // `pm path` prints `package:/path/to/base.apk` for installed
            // packages and `Error: Could not access the Package Manager...`
            // or empty output with non-zero exit for missing ones. Require
            // the positive signal (package:) to call it present.
            return !out.contains("package:");
        } catch (Throwable t) {
            // Transient failure — treat as present.
            return false;
        }
    }

    /**
     * Remove staged unit DEX files + this daemon's own log, then exit.
     * Deliberately best-effort: a failure to delete one file shouldn't
     * keep the daemon running, and since we're already confirmed orphaned,
     * there's nothing left to observe the errors.
     */
    private void cleanupAndExit() {
        File dir = new File(STAGE_DIR);
        File[] children = dir.listFiles();
        if (children != null) {
            for (File f : children) {
                String name = f.getName();
                if (name.endsWith(".dex") || name.equals("dashd.log")) {
                    try {
                        if (f.delete()) log("removed " + f.getPath());
                    } catch (Throwable ignored) {}
                }
            }
        }
        if (maintenance != null) {
            maintenance.shutdownNow();
        }
        log("orphan daemon exiting");
        System.exit(0);
    }

    private static void log(String msg) {
        System.out.println("[DashDaemon " + ts() + "] " + msg);
        System.out.flush();
    }

    private static String ts() {
        return String.format("%tT.%<tL", System.currentTimeMillis());
    }
}
