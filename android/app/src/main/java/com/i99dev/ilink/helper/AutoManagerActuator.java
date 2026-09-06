package com.i99dev.ilink.helper;

import android.content.Context;
import android.os.Looper;

import com.i99dev.ilink.car.DeviceTypes;

import java.lang.reflect.Method;

/**
 * BYDAutoManager reflection actuator — the typed, JSON-free hardware
 * surface extracted from {@link DashDaemon}. Resolves the framework
 * {@code "auto"} service via the ActivityThread system context, reflects
 * the get/set overloads once at init, and exposes them as typed calls.
 *
 * <p>Capability flags ({@link #hasGetDouble()} etc.) mirror which Phase-2
 * overloads the running ROM actually exposes — a {@code null} cached
 * {@link Method} means the overload is absent and the matching flag is
 * false, so the daemon's JSON layer can return {@code NOT_SUPPORTED}.
 *
 * <p>Behaviour is moved verbatim from {@code DashDaemon.initAutoService}
 * + the {@code do*} handlers — no logic change. That deliberately includes
 * the L8 quirk where the framework's {@code getDouble} reflects a method
 * returning {@code Float}, so {@link #getDouble} throws
 * {@code ClassCastException} on that ROM. Preserved on purpose; fixing it
 * is a separate, behaviour-changing follow-up.
 */
final class AutoManagerActuator {

    private Object autoMgr;
    private Context systemContext;

    // Phase 1 base reflection — required; init() fails if any is absent.
    private Method setIntM;
    private Method getIntM;
    private Method enableM;
    // Phase 2 wider surface — each may be null on a stripped ROM; the
    // matching capability flag is `handle != null`.
    private Method getDoubleM;
    private Method getBufferM;
    private Method getIntArrayM;
    private Method setBytesM;
    private Method setMultiM;
    private Method setIntAreaM;

    /**
     * Resolve {@code autoMgr}, reflect the get/set surface, and warm the
     * WARM device-types via {@code enableDevice}. Returns true when the
     * Phase-1 base API reflected successfully (the daemon can't actuate
     * without it); Phase-2 overloads are best-effort and a missing one
     * just clears its capability flag.
     */
    boolean init() {
        try {
            if (Looper.myLooper() == null) Looper.prepareMainLooper();
            Class<?> atCls = Class.forName("android.app.ActivityThread");
            Method sysMain = atCls.getDeclaredMethod("systemMain");
            sysMain.setAccessible(true);
            Object at = sysMain.invoke(null);
            Method getSysCtx = atCls.getDeclaredMethod("getSystemContext");
            systemContext = (Context) getSysCtx.invoke(at);
            autoMgr = systemContext.getSystemService("auto");
            if (autoMgr == null) throw new IllegalStateException("no auto service");
            Class<?> mc = autoMgr.getClass();
            // Phase 1 — required base API. A miss here throws and the
            // daemon surfaces `init failed`.
            setIntM = mc.getMethod("setInt", int.class, int.class, int.class);
            getIntM = mc.getMethod("getInt", int.class, int.class);
            enableM = mc.getMethod("enableDevice", int.class);
            // Phase 2 — wider get/set surface. Each lookup is independent
            // so a missing overload on a stripped ROM only loses that op,
            // not the whole init.
            getDoubleM   = lookupMethod(mc, "getDouble",   int.class, int.class);
            getBufferM   = lookupMethod(mc, "getBuffer",   int.class, int.class);
            getIntArrayM = lookupMethod(mc, "getIntArray", int.class, int[].class);
            setBytesM    = lookupMethod(mc, "set",         int.class, int.class, byte[].class);
            setMultiM    = lookupMethod(mc, "set",         int.class, int[].class, int[].class);
            setIntAreaM  = lookupMethod(mc, "setInt",      int.class, int.class, int.class, int.class);
            for (int dt : DeviceTypes.WARM) {
                try { enableM.invoke(autoMgr, dt); } catch (Throwable ignored) {}
            }
            return true;
        } catch (Throwable t) {
            log("init failed: " + t);
            return false;
        }
    }

    /**
     * Reflect a single overload off {@code mc}, returning null on miss
     * instead of throwing — so a stripped ROM only loses the missing
     * methods, not the whole init.
     */
    private static Method lookupMethod(Class<?> mc, String name, Class<?>... params) {
        try {
            return mc.getMethod(name, params);
        } catch (NoSuchMethodException e) {
            return null;
        }
    }

    /** True once {@link #init} resolved the {@code auto} service. */
    boolean isReady() { return autoMgr != null; }

    /** True when the required {@code getInt} overload reflected — the
     *  poller's per-key fallback needs it even where the batched
     *  {@code getIntArray} overload is absent. */
    boolean canGetInt() { return getIntM != null; }

    /** System context resolved during {@link #init} (used by the daemon
     *  to register its BydPushDevice subclasses against the same ctx). */
    Context systemContext() { return systemContext; }

    boolean hasGetDouble()   { return getDoubleM   != null; }
    boolean hasGetBuffer()   { return getBufferM   != null; }
    boolean hasGetIntArray() { return getIntArrayM != null; }
    boolean hasSetBytes()    { return setBytesM    != null; }
    boolean hasSetMulti()    { return setMultiM    != null; }
    boolean hasSetIntArea()  { return setIntAreaM  != null; }

    /** Compact one-line summary of which Phase-2 reflections succeeded.
     *  Logged once at boot so a fresh dashd grep tells you exactly which
     *  advanced ops the ROM supports. */
    String capsLine() {
        StringBuilder sb = new StringBuilder("[");
        if (getDoubleM != null)   sb.append("getDouble,");
        if (getBufferM != null)   sb.append("getBuffer,");
        if (getIntArrayM != null) sb.append("getIntArray,");
        if (setBytesM != null)    sb.append("setBytes,");
        if (setMultiM != null)    sb.append("setMulti,");
        if (setIntAreaM != null)  sb.append("area,");
        if (sb.length() > 1) sb.setLength(sb.length() - 1);  // trim trailing ","
        sb.append("]");
        return sb.toString();
    }

    // ── Typed actuation surface. Each throws on a reflection/invoke
    //    failure; the daemon's handle() try/catch turns that into the
    //    structured `{error: ...}` wire response. ──

    int getInt(int dt, int key) throws Throwable {
        return (Integer) getIntM.invoke(autoMgr, dt, key);
    }

    int setInt(int dt, int key, int val) throws Throwable {
        return (Integer) setIntM.invoke(autoMgr, dt, key, val);
    }

    int setIntArea(int dt, int key, int val, int area) throws Throwable {
        return (Integer) setIntAreaM.invoke(autoMgr, dt, key, val, area);
    }

    int enableDevice(int dt) throws Throwable {
        return (Integer) enableM.invoke(autoMgr, dt);
    }

    // (Double) cast is intentional — it reproduces the L8 ClassCastException
    // where the reflected getDouble actually returns a Float. See class doc.
    double getDouble(int dt, int key) throws Throwable {
        return (Double) getDoubleM.invoke(autoMgr, dt, key);
    }

    byte[] getBuffer(int dt, int key) throws Throwable {
        return (byte[]) getBufferM.invoke(autoMgr, dt, key);
    }

    int[] getIntArray(int dt, int[] keys) throws Throwable {
        return (int[]) getIntArrayM.invoke(autoMgr, dt, keys);
    }

    int setBytes(int dt, int key, byte[] bytes) throws Throwable {
        return (Integer) setBytesM.invoke(autoMgr, dt, key, bytes);
    }

    int setMulti(int dt, int[] keys, int[] vals) throws Throwable {
        return (Integer) setMultiM.invoke(autoMgr, dt, keys, vals);
    }

    /**
     * Per-key {@code getInt} fallback for ROMs without {@code getIntArray}
     * or for a partial/null batched result. {@code MIN_VALUE} on a per-key
     * failure so the caller's diff treats it as "never seen". Moved verbatim.
     */
    int[] perKeyFallback(int dt, int[] keys) {
        int[] out = new int[keys.length];
        for (int i = 0; i < keys.length; i++) {
            try {
                out[i] = (Integer) getIntM.invoke(autoMgr, dt, keys[i]);
            } catch (Throwable t) {
                out[i] = Integer.MIN_VALUE; // looks like "never seen" — no diff emit
            }
        }
        return out;
    }

    private static void log(String msg) {
        System.out.println("[AutoManagerActuator " + ts() + "] " + msg);
        System.out.flush();
    }

    private static String ts() {
        return String.format("%tT.%<tL", System.currentTimeMillis());
    }
}
