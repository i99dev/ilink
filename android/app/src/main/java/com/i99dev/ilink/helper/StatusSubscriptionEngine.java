package com.i99dev.ilink.helper;

import android.content.Context;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.io.OutputStream;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Status subscription + push engine extracted from {@link DashDaemon}.
 * Owns the active-subscription map, the grouped poll loop, the BYD
 * push-device registration + {@code onPushEvent} callback, and the
 * push/poll observability counters. Reads CAN values through the injected
 * {@link AutoManagerActuator}.
 *
 * <p>Behaviour moved verbatim from the daemon — the wire event frame
 * ({@code {event:"change",subId,value,atMs}}) is byte-frozen so the Kotlin
 * {@code DashDaemonClient} needs no protocol change. The daemon keeps the
 * thin {@code subscribe}/{@code unsubscribe}/{@code stats}/{@code caps} JSON
 * adapters and delegates here.
 */
final class StatusSubscriptionEngine {

    private static final long SUB_POLL_PERIOD_MS = 200L;

    /** Max age of {@link Sub#lastPushAtMs} before the poller stops
     *  trusting the push path for this sub and falls back to polling.
     *  Picked to be ~5× the longest "real" inter-push gap we expect
     *  on a healthy bus (~1 s for slow signals like cabin temp), so
     *  we don't false-positive on sparse but still-live signals.
     *  When a fresh push arrives, lastPushAtMs gets bumped and the
     *  poller goes back to skipping. */
    private static final long PUSH_STALENESS_MS = 5_000L;

    private final AutoManagerActuator actuator;

    StatusSubscriptionEngine(AutoManagerActuator actuator) {
        this.actuator = actuator;
    }

    /** All active subscriptions across all client connections. Keyed by
     *  the sub id we mint on `subscribe`; the entry carries the (dt,key)
     *  to poll, the last value seen (so we only emit on change), and
     *  a back-reference to the client socket's output stream so the
     *  poll thread can push events without going through the
     *  request/response thread. */
    private final ConcurrentHashMap<String, Sub> subs = new ConcurrentHashMap<>();

    /** Reverse-lookup the Socket whose getOutputStream() == [out]. We
     *  only have the OutputStream in the daemon's handle(), so the map of
     *  active client sockets is the easiest crosswalk. */
    private final ConcurrentHashMap<OutputStream, Socket> outToSock = new ConcurrentHashMap<>();

    private ScheduledExecutorService subPoller;

    // Phase 1 Chunk B — registered AbsBYDAutoDevice subclasses, one
    // per WARM device-type. Held as strong references so the framework
    // doesn't GC them mid-lifetime (the framework registers via
    // constructor side-effect; if we drop the reference before any
    // push fires, we silently lose the subscription). Empty when
    // either (a) the BYD framework is missing on this ROM, or
    // (b) `enableDevice` failed for every WARM dt — both cases
    // collapse to "poller carries the load", same as Phase 1A.
    private final List<BydPushDevice> pushDevices = new ArrayList<>();
    private boolean pushAvailable = false;
    /** Per-dt registration outcome — `true` = BydPushDevice constructor
     *  succeeded for this dt, `false` = framework refused. Surfaced by
     *  the `stats` op so an operator can tell which device-types are
     *  actually push-eligible without grepping logs. */
    private final LinkedHashMap<Integer, Boolean> pushDtStatus = new LinkedHashMap<>();
    /** Total push frames received across the daemon's lifetime. Bumped
     *  in {@link #onPushEvent}; surfaced by the `stats` op. A stuck-at-0
     *  value with `pushAvailable=true` means the framework registered
     *  our subclasses but never invokes them — usually a sign the
     *  current activity context isn't dispatching events. */
    private final AtomicLong pushFramesReceived = new AtomicLong(0L);
    /** Total `change` frames the poller has emitted (push or poll path).
     *  Increments inside {@link #pollSubs} on every emit. */
    private final AtomicLong pollFramesEmitted = new AtomicLong(0L);

    // ── Client socket bookkeeping (called from the daemon's serve()). ──

    void registerClient(OutputStream out, Socket s) { outToSock.put(out, s); }

    void unregisterClient(OutputStream out) { outToSock.remove(out); }

    void removeSubsForOwner(Socket owner) {
        // Iterating the map while removing entries is safe on
        // ConcurrentHashMap, and we only race the poll thread which
        // also tolerates a missing key.
        for (var entry : subs.entrySet()) {
            if (entry.getValue().owner == owner) {
                subs.remove(entry.getKey());
            }
        }
    }

    // ── subscribe / unsubscribe (typed; the daemon builds the JSON). ──

    /**
     * Register a subscription for the client owning [out]. Returns the
     * minted subId, or {@code null} if no owner socket is registered for
     * [out] (the daemon turns that into the `no owner socket` error).
     *
     * {@code requestedPeriodMs < 0} means "client didn't supply one" →
     * defaults to {@link #SUB_POLL_PERIOD_MS}; any value is floored at it
     * (finer cadence than the scheduler tick is meaningless).
     */
    String subscribe(int dt, int key, int requestedPeriodMs, OutputStream out) {
        Socket sock = outToSock.get(out);
        if (sock == null) return null;
        int periodMs = (int) Math.max(
            SUB_POLL_PERIOD_MS,
            requestedPeriodMs < 0 ? (int) SUB_POLL_PERIOD_MS : requestedPeriodMs);
        String subId = "s-" + UUID.randomUUID().toString().substring(0, 8);
        subs.put(subId, new Sub(dt, key, periodMs, sock, out));
        return subId;
    }

    boolean unsubscribe(String subId) {
        return subs.remove(subId) != null;
    }

    // ── Push-device registration (called from the daemon's init). ──

    /**
     * Register one {@link BydPushDevice} per WARM device-type against
     * [ctx], routing framework {@code onPostEvent} callbacks into
     * {@link #onPushEvent}. Best-effort + per-dt isolated, same as the
     * pre-extraction path: a missing framework class falls back cleanly
     * to the poller-only path.
     */
    void registerPushDevices(Context ctx, int[] warmDts) {
        try {
            for (int dt : warmDts) {
                try {
                    pushDevices.add(new BydPushDevice(ctx, dt, this::onPushEvent));
                    pushDtStatus.put(dt, true);
                } catch (Throwable perDt) {
                    // Per-dt isolation — one missing device-type doesn't
                    // tank the rest. Log the actual cause (only at boot,
                    // so it doesn't spam) so an operator can tell whether
                    // it's a permission refusal, missing class, or
                    // framework-internal check.
                    pushDtStatus.put(dt, false);
                    Throwable c = unwrap(perDt);
                    log("BydPushDevice(dt=" + dt + ") failed: "
                        + c.getClass().getName() + ": " + c.getMessage());
                }
            }
            pushAvailable = !pushDevices.isEmpty();
        } catch (NoClassDefFoundError e) {
            // No BYD framework — push path stays disabled, poller carries
            // the load (already its own code path).
            pushAvailable = false;
            for (int dt : warmDts) pushDtStatus.put(dt, false);
        }
    }

    // ── Poller ──

    void start() {
        if (subPoller != null) return;
        subPoller = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "dashd-sub-poll");
            t.setDaemon(true);
            return t;
        });
        subPoller.scheduleWithFixedDelay(this::pollSubs,
            SUB_POLL_PERIOD_MS, SUB_POLL_PERIOD_MS, TimeUnit.MILLISECONDS);
    }

    /**
     * Grouped poll loop. Runs at SUB_POLL_PERIOD_MS (the floor). Each
     * tick:
     *   1. Drop subs whose owner socket is closed.
     *   2. Filter to subs eligible this tick — push not fresh, period
     *      elapsed, etc.
     *   3. Group eligible subs by `dt` and call
     *      {@code getIntArray(dt, keys[])} ONCE per dt — instead of
     *      one {@code getInt(dt, key)} per sub.
     *
     * Scaling: N subs across K device-types collapse to K binder hops
     * per tick instead of N. With 22 hot subs across 4 dts, that's
     * 4 hops/tick (20/sec) vs the old 22 hops/tick (110/sec) — ~5×
     * fewer framework calls for the same dataflow. Gate-probe-style
     * "watch everything" surfaces benefit even more (176 subs → 7 hops).
     *
     * Per-sub cadence: each sub carries its own {@code periodMs}.
     * A 2 s sub is only polled every 10 ticks (2000 / 200), letting
     * cabin-temp / SOC stay snappy enough without driving 200 ms
     * binder churn for values that only change every few seconds.
     */
    private void pollSubs() {
        if (subs.isEmpty() || !actuator.isReady()) return;
        // Prefer batched read when available; fall back to per-key
        // getInt on older ROMs. The ROM-feature decision was made at
        // boot via lookupMethod — we just check the actuator's flags.
        boolean hasBatch = actuator.hasGetIntArray();
        if (!hasBatch && !actuator.canGetInt()) return;
        long nowMs = System.currentTimeMillis();

        // Bucket eligible subs by dt. Keys: dt → list of (subId, sub).
        // SubEntry carries the JSON name we'll use for the event frame.
        Map<Integer, List<SubEntry>> byDt = new HashMap<>();
        for (var entry : subs.entrySet()) {
            Sub s = entry.getValue();
            if (s.owner.isClosed()) {
                subs.remove(entry.getKey());
                continue;
            }
            // Push fast-skip + staleness safety net (unchanged from
            // single-poll variant — same callbackArmed semantics).
            if (s.callbackArmed
                    && s.lastValue != Integer.MIN_VALUE
                    && (nowMs - s.lastPushAtMs) < PUSH_STALENESS_MS) {
                continue;
            }
            // Per-sub cadence: skip until the period has elapsed since
            // last poll. First-tick subs (lastPollAtMs == 0) always run
            // so the client gets its initial value within one tick.
            if (s.lastPollAtMs != 0L && (nowMs - s.lastPollAtMs) < s.periodMs) {
                continue;
            }
            byDt.computeIfAbsent(s.dt, k -> new ArrayList<>())
                .add(new SubEntry(entry.getKey(), s));
        }
        if (byDt.isEmpty()) return;

        // One framework call per dt group.
        for (var grp : byDt.entrySet()) {
            int dt = grp.getKey();
            List<SubEntry> entries = grp.getValue();
            int n = entries.size();
            int[] keys = new int[n];
            for (int i = 0; i < n; i++) keys[i] = entries.get(i).sub.key;

            int[] values;
            try {
                if (hasBatch) {
                    values = actuator.getIntArray(dt, keys);
                    // Defensive — some ROMs return null on a partial-fail
                    // batch. Fall back to per-key path so the poll-tick
                    // doesn't drop the whole group.
                    if (values == null || values.length != n) {
                        values = actuator.perKeyFallback(dt, keys);
                    }
                } else {
                    values = actuator.perKeyFallback(dt, keys);
                }
            } catch (Throwable ignored) {
                // Whole-group failure (binder DEAD_OBJECT, framework
                // restart). Mark each as "polled now" so we don't
                // hammer the same broken dt every tick, then move on.
                for (var e : entries) e.sub.lastPollAtMs = nowMs;
                continue;
            }

            for (int i = 0; i < n; i++) {
                SubEntry e = entries.get(i);
                Sub s = e.sub;
                s.lastPollAtMs = nowMs;
                int v = values[i];
                if (v == s.lastValue) continue;
                s.lastValue = v;
                emitChangeFrame(e.subId, s, v, nowMs);
            }
        }
    }

    /** Write one `{event:"change", subId, value, atMs}` line to the
     *  client owning [s]. Drops the sub if the socket is gone. Same
     *  shape as the legacy single-poll emit so the client (Kotlin
     *  DashDaemonClient) needs no protocol change. */
    private void emitChangeFrame(String subId, Sub s, int v, long nowMs) {
        JSONObject evt = new JSONObject();
        try {
            evt.put("event", "change");
            evt.put("subId", subId);
            evt.put("value", v);
            evt.put("atMs", nowMs);
        } catch (JSONException je) {
            return;
        }
        byte[] bytes = (evt.toString() + "\n").getBytes(StandardCharsets.UTF_8);
        try {
            synchronized (s.out) {
                s.out.write(bytes);
                s.out.flush();
            }
            pollFramesEmitted.incrementAndGet();
        } catch (IOException ioe) {
            subs.remove(subId);
        }
    }

    /**
     * Push entry-point for Phase 1 Chunk B.
     *
     * The AbsBYDAutoDevice subclass that gets registered in
     * {@link #registerPushDevices} routes incoming
     * {@code onPostEvent(IBYDAutoEvent)} frames here. This method walks
     * active subs for the matching (dt, key), arms them for the poller,
     * and emits a `change` frame to the client — same shape the poller
     * produces, so consumers can't tell the difference.
     *
     * Package-private so the framework subclass can call into it without
     * reflection.
     */
    void onPushEvent(int dt, int key, int value) {
        // Bump the lifetime push counter unconditionally — we want to
        // see incoming push activity even when no client has subscribed
        // yet (proves the framework is dispatching at all).
        pushFramesReceived.incrementAndGet();
        if (subs.isEmpty()) return;
        long nowMs = System.currentTimeMillis();
        for (var entry : subs.entrySet()) {
            Sub s = entry.getValue();
            if (s.dt != dt || s.key != key) continue;
            // Mark armed + stamp lastPushAtMs BEFORE checking value
            // so the poller's skip-armed path takes over even on a
            // same-value tick AND the staleness check sees a fresh
            // timestamp.
            s.callbackArmed = true;
            s.lastPushAtMs = nowMs;
            if (s.owner.isClosed()) { subs.remove(entry.getKey()); continue; }
            if (value == s.lastValue) continue;
            s.lastValue = value;
            JSONObject evt = new JSONObject();
            try {
                evt.put("event", "change");
                evt.put("subId", entry.getKey());
                evt.put("value", value);
                evt.put("atMs", nowMs);
            } catch (JSONException je) {
                continue;
            }
            byte[] bytes = (evt.toString() + "\n").getBytes(StandardCharsets.UTF_8);
            try {
                synchronized (s.out) {
                    s.out.write(bytes);
                    s.out.flush();
                }
            } catch (IOException ioe) {
                subs.remove(entry.getKey());
            }
        }
    }

    // ── stats / caps accessors (read by the daemon's doStats / doCaps). ──

    boolean pushAvailable()        { return pushAvailable; }
    String  pushDtStatusString()   { return pushDtStatus.toString(); }
    int     pushDeviceCount()      { return pushDevices.size(); }
    long    pushFramesReceived()   { return pushFramesReceived.get(); }
    long    pollFramesEmitted()    { return pollFramesEmitted.get(); }
    int     subsTotal()            { return subs.size(); }
    int     subsArmed() {
        int armed = 0;
        for (Sub s : subs.values()) if (s.callbackArmed) armed++;
        return armed;
    }

    private static Throwable unwrap(Throwable t) {
        while (t.getCause() != null && t.getCause() != t) t = t.getCause();
        return t;
    }

    private static void log(String msg) {
        System.out.println("[StatusSubscriptionEngine " + ts() + "] " + msg);
        System.out.flush();
    }

    private static String ts() {
        return String.format("%tT.%<tL", System.currentTimeMillis());
    }

    /**
     * One active subscription. The poll thread reads the (dt, key) at
     * [SUB_POLL_PERIOD_MS] and emits an event frame to [out] whenever
     * the integer value differs from [lastValue]. [owner] is the client
     * socket so we can clean up on disconnect; [out] is the pre-acquired
     * output stream used for the synchronous request/response path so
     * the same `synchronized(out)` lock keeps event frames and replies
     * from interleaving on the wire.
     */
    private static final class Sub {
        final int dt;
        final int key;
        final Socket owner;
        final OutputStream out;
        /** Per-sub poll cadence. The grouped poller runs at SUB_POLL_PERIOD_MS
         *  (the floor) and skips this sub on ticks where (now - lastPollAtMs)
         *  < periodMs. Defaults to SUB_POLL_PERIOD_MS for back-compat with
         *  clients that don't pass a period. */
        final int periodMs;
        /** Wall-clock ms of last poll attempt for this sub. Used to
         *  enforce the per-sub cadence inside the grouped poller. */
        volatile long lastPollAtMs = 0L;
        // Sentinel meaning "never seen" so the very first poll always
        // emits a frame and the client gets its initial value without
        // waiting for a CAN-side change.
        volatile int lastValue = Integer.MIN_VALUE;
        // Phase 1: set true when an `AbsBYDAutoDevice.onPostEvent`
        // callback for this (dt, key) has fired at least once. Once
        // armed, the poller skips this sub — the framework drives it
        // via push instead. Cleared by the 2 s watchdog if no callback
        // arrives (stripped ROM / unsupported feature) so the poller
        // takes over.
        volatile boolean callbackArmed = false;
        // Wall-clock ms of the most recent push frame for this (dt, key).
        // The poller uses this to detect push staleness: if the
        // framework armed us but then stopped pushing (transient ROM
        // glitch, framework-side regression), the poller falls back to
        // polling so the value can't go infinitely stale. See
        // PUSH_STALENESS_MS + pollSubs() comment for the full rationale.
        volatile long lastPushAtMs = 0L;
        // Wall-clock ms when the sub was registered. Kept for diagnostics
        // (visible via the `stats` op) so an operator can see how long
        // a sub has been alive without a push.
        final long registeredAtMs = System.currentTimeMillis();
        Sub(int dt, int key, int periodMs, Socket owner, OutputStream out) {
            this.dt = dt; this.key = key; this.periodMs = periodMs;
            this.owner = owner; this.out = out;
        }
    }

    private static final class SubEntry {
        final String subId;
        final Sub sub;
        SubEntry(String subId, Sub sub) { this.subId = subId; this.sub = sub; }
    }
}
