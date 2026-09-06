package com.i99dev.ilink.helper;

import android.content.Context;
import android.hardware.IBYDAutoEvent;
import android.hardware.IBYDAutoListener;
import android.hardware.bydauto.AbsBYDAutoDevice;
import android.util.Log;

import java.util.concurrent.atomic.AtomicLong;

/**
 * Per-{@code device_type} push receiver. Phase 1 Chunk B of
 * {@code PLAN_DAEMON_BYD_SDK_UPGRADE.md} — the AbsBYDAutoDevice
 * subclass that wires the BYD framework's {@code onPostEvent}
 * callback into {@link DashDaemon#onPushEvent(int, int, int)}.
 *
 * <p>Pattern verified against Dudu's 23
 * {@code DDBYDAuto<X>Device.smali} files — each binds a single
 * device-type integer via {@link #getDevicetype()} and the BYD
 * framework auto-routes value-change events for that
 * device-type to its {@link #onPostEvent(IBYDAutoEvent)}.
 *
 * <p>The framework registers the device by side-effect of the
 * {@link #AbsBYDAutoDevice(Context)} constructor (no explicit
 * {@code register} call needed — that's why Dudu's smali doesn't
 * show one); {@link DashDaemon#initAutoService} only needs to
 * instantiate one {@code BydPushDevice} per WARM device-type and
 * keep a strong reference (else GC could free it before any push
 * fires).
 *
 * <p>The (key) and (value) on each event come from
 * {@link IBYDAutoEvent#getEventType()} and
 * {@link IBYDAutoEvent#getValue()} respectively — verified ABI
 * from {@code AbsBYDAutoDeviceEx.smali} which reads the same
 * methods. The (dt) is implied by {@link #getDevicetype()} on
 * the receiving instance.
 *
 * <p>Throwables in {@link #onPostEvent} are swallowed — the
 * framework's dispatch loop should NEVER crash because of a
 * downstream sub-routing bug. Same defensive shape as
 * {@code DashDaemon.pollSubs()}.
 */
public final class BydPushDevice extends AbsBYDAutoDevice
        implements IBYDAutoListener {

    /** Functional interface for any sink that wants the routed
     *  {@code (dt, key, value)} triple from {@link #onPostEvent}. Two
     *  call sites today: (a) {@link DashDaemon} when registration runs
     *  in the shell-UID daemon process, and (b) the in-app
     *  {@code AutoFeatureService} when registration runs inside the
     *  Android app's Application context (the only path the BYD
     *  framework actually dispatches push to on DiLink 5.1 — verified
     *  empirically: shell-UID registration succeeds but the framework
     *  never calls onPostEvent on it). */
    public interface PushSink {
        void onPushEvent(int dt, int key, int value);
    }

    /** BYD device-type this instance handles (1000=AC, 1001=BODY, …). */
    private final int dt;

    /**
     * Where to route incoming push frames. Held as a strong reference
     * so the sink (typically the daemon or the app service) stays
     * alive at least as long as this device — and the sink owner
     * holds a strong reference to every BydPushDevice it created for
     * the same reason in the opposite direction.
     */
    private final PushSink sink;

    /** Process-wide push-frame counter. Surfaced via {@link #framesReceived()}
     *  so the diagnostic page can confirm whether the framework is
     *  actually dispatching onPostEvent to us. Zero after a few seconds
     *  of car activity means the framework is not pushing — the
     *  override surface is wrong, or per-key subscribe is required. */
    private static final AtomicLong FRAMES_RECEIVED = new AtomicLong(0);
    public static long framesReceived() { return FRAMES_RECEIVED.get(); }

    public BydPushDevice(Context context, int deviceType, PushSink sink) {
        super(context);
        this.dt = deviceType;
        this.sink = sink;
        // ── Push wiring ─────────────────────────────────────────────
        // The constructor alone does NOT begin push dispatch on this
        // ROM (verified empirically: BydPushDevice instances without
        // a follow-up registerListener call receive ZERO frames over
        // a 10-min observation window). Dudu's smali pairs every
        // device with a paired IBYDAutoListener and explicitly calls
        // registerListener — replicating that here.
        try {
            super.registerListener(this);
            Log.w("BydPushDevice", "registered listener for dt=" + dt);
        } catch (Throwable t) {
            Log.w("BydPushDevice",
                "registerListener failed for dt=" + dt + ": " + t.getMessage());
        }
    }

    @Override
    public int getDevicetype() {
        return dt;
    }

    /** Wildcard — receive every key for this dt. Matches Dudu's
     *  AbsBYDAutoDeviceEx pattern (verified in the decompiled smali:
     *  their getFeatureList returns const/4 v0,0x0 — null in Java).
     *  Without this the runtime AbsBYDAutoDevice may return an empty
     *  array which the framework's dispatcher reads as "subscribe to
     *  nothing" — push fires inside the framework but never crosses
     *  into our process. */
    @Override
    public int[] getFeatureList() {
        return null;
    }

    /** No permission gate on reads — matches Dudu. */
    @Override
    public String getGetPermission() {
        return "";
    }

    /** No permission gate on writes — matches Dudu. */
    @Override
    public String getSetPermission() {
        return "";
    }

    // ── Typed wrappers — Dudu's DDBYDAutoDevice pattern.
    //    Reads + writes route through `super.<x>(getDevicetype(), …)`
    //    so the framework's per-device dispatcher (the one that also
    //    fires onPostEvent) is the single source of truth. The
    //    SystemService route (`autoMgr.getInt(dt, key)`) bypasses
    //    that dispatcher and on DiLink 5.1 returns stale data for
    //    push-fed signals — verified empirically 12 May 2026: speed
    //    via autoMgr stayed at 0 while super.get(dt, key) on the
    //    correct device instance returned the real moving value.
    //    Do NOT replace these with autoMgr calls. ─────────────────

    /** {@code super.get(dt, key) -> int}. Returns the framework's
     *  sentinel (-10011, etc.) when the key isn't bound. */
    public int getInt(int key) {
        try {
            return super.get(dt, key);
        } catch (Throwable t) {
            return Integer.MIN_VALUE;
        }
    }

    /** {@code super.getDouble(dt, key) -> double}. */
    public double getDouble(int key) {
        try {
            return super.getDouble(dt, key);
        } catch (Throwable t) {
            return Double.NaN;
        }
    }

    /** {@code super.getBuffer(dt, key) -> byte[]}. */
    public byte[] getBuffer(int key) {
        try {
            return super.getBuffer(dt, key);
        } catch (Throwable t) {
            return null;
        }
    }

    /** {@code super.getIntArray(dt, keys) -> int[]}. Bulk read across
     *  many keys for the same device-type — one Binder hop per call,
     *  not per key. Phase 3's collapsed read path. */
    public int[] getIntArray(int[] keys) {
        try {
            return super.getIntArray(dt, keys);
        } catch (Throwable t) {
            return null;
        }
    }

    /** {@code super.set(dt, key, value) -> int}. Returns 0 on success,
     *  framework error code otherwise. Whether write actually lands
     *  depends on the framework's per-key permission check — some
     *  device-types refuse writes from unprivileged UIDs. */
    public int setInt(int key, int value) {
        try {
            return super.set(dt, key, value);
        } catch (Throwable t) {
            return -1;
        }
    }

    /** {@code super.set(dt, key, byte[]) -> int}. */
    public int setBytes(int key, byte[] value) {
        try {
            return super.set(dt, key, value);
        } catch (Throwable t) {
            return -1;
        }
    }

    /** {@code super.set(dt, int[], int[]) -> int}. Multi-key write
     *  in one Binder hop (Phase 2 setMulti). */
    public int setMulti(int[] keys, int[] values) {
        try {
            return super.set(dt, keys, values);
        } catch (Throwable t) {
            return -1;
        }
    }

    /**
     * Newer DiLink 5.1 ROMs route through {@code IBYDAutoDevice.getType()}
     * (the underlying interface) rather than the legacy
     * {@code AbsBYDAutoDevice.getDevicetype()}. The runtime JVM resolves
     * virtual dispatch by name+signature, so this method satisfies the
     * abstract interface contract even though our compileOnly stub
     * doesn't declare it (stub only knows about {@code getDevicetype}
     * — verified against Dudu's older smali). Without this override:
     * {@code AbstractMethodError: abstract method
     * "int android.hardware.IBYDAutoDevice.getType()"} on construct.
     *
     * Both methods return the same dt so older + newer ROMs see the
     * identical answer.
     */
    public int getType() {
        return dt;
    }

    /** IBYDAutoListener push callback. Verified from Dudu's smali —
     *  this is THE entry point the framework dispatches value-change
     *  events through after registerListener succeeds. */
    @Override
    public void onDataChanged(IBYDAutoEvent event) {
        FRAMES_RECEIVED.incrementAndGet();
        if (event == null) return;
        try {
            sink.onPushEvent(dt, event.getEventType(), event.getValue());
        } catch (Throwable t) {
            // Defensive — never let an exception bubble out into the
            // framework's dispatch loop.
        }
    }

    @Override
    public boolean onPostEvent(IBYDAutoEvent event) {
        // Some ROMs also fire onPostEvent on the device itself in
        // addition to onDataChanged on the registered listener. Count
        // and route here too so neither path silently drops frames.
        FRAMES_RECEIVED.incrementAndGet();
        if (event == null) {
            return super.onPostEvent(event);
        }
        try {
            sink.onPushEvent(dt, event.getEventType(), event.getValue());
        } catch (Throwable t) {
            // Defensive — see onDataChanged for rationale.
        }
        return super.onPostEvent(event);
    }
}
