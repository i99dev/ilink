package com.i99dev.ilink.helper;

import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.lang.reflect.Method;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/**
 * Synthetic touch / key injection for {@link DashDaemon}, running inside the
 * shell-uid ({@code 2000}) {@code app_process64} daemon.
 *
 * <p><b>Why here and not in the app:</b> {@code InputManager.injectInputEvent}
 * + {@code MotionEvent.setDisplayId} are the only path that delivers a
 * synthetic touch to an <i>arbitrary</i> display (the driver cluster) at native
 * latency — no per-event {@code input -d N} shell fork, full streaming. They are
 * hidden/blacklisted APIs and require {@code INJECT_EVENTS}, which the daemon
 * holds by virtue of running in the {@code shell} domain. The app process can't
 * do this; the daemon can. This is the same "FAST path" a reverse-engineered
 * reference dashboard app uses — dex-verified:
 * {@code InputManager.getInstance()} singleton, {@code injectInputEvent(ev, 0)}
 * (mode {@code INJECT_INPUT_EVENT_MODE_ASYNC}), {@code MotionEvent.setDisplayId},
 * {@code MotionEvent.obtain(...)} with {@code source=0x1002} (TOUCHSCREEN).
 *
 * <p><b>Reflection surface</b> (resolved once in {@link #init()}, then hot):
 * <ul>
 *   <li>{@code android.hardware.input.InputManager#getInstance()} → singleton</li>
 *   <li>{@code InputManager#injectInputEvent(InputEvent, int)}</li>
 *   <li>{@code MotionEvent#setDisplayId(int)} (hidden)</li>
 *   <li>{@code KeyEvent#setDisplayId(int)} (hidden, best-effort — may be absent
 *       on a ROM; key injection then lands on the default display)</li>
 * </ul>
 * Hidden-API access is unlocked once via {@code VMRuntime.setHiddenApiExemptions}
 * (best-effort; app_process daemons are usually already exempt, but the
 * reference implementation does this defensively and so do we).
 *
 * <p><b>Pointer session model:</b> a synthetic drag must be a real
 * DOWN → MOVE… → UP stream sharing one {@code downTime}, or the window manager
 * won't deliver the MOVE/UP to the same window. The daemon owns that session
 * state ({@link #ptrDown}/{@link #ptrMove}/{@link #ptrUp}) so the client just
 * streams coordinates. A dropped {@code up} (finger-lift frame lost on the wire)
 * would otherwise wedge a stuck synthetic pointer on the cluster, so an
 * {@linkplain #AUTO_LIFT_MS auto-lift watchdog} force-lifts an idle session.
 *
 * <p>All injection is serialized on {@link #lock}: a single shared
 * {@link MotionEvent.PointerCoords} buffer is reused across calls and the
 * session fields are non-atomic. The cluster touchpad is single-finger and one
 * socket, so there is never legitimate concurrency here; the lock just keeps the
 * reused buffers + session coherent against the auto-lift thread.
 */
final class InputInjector {

    /** {@code InputManager.injectInputEvent} async mode — fire and don't block
     *  on dispatch. Dex-verified literal {@code 0} in the reference injector. */
    private static final int INJECT_MODE_ASYNC = 0;

    /** The source a cluster app's window expects for touch. Use the framework
     *  constant directly ({@code = 0x1002}) rather than a magic literal — it's
     *  self-documenting and keeps the value out of the BYD-constant CI gate. */
    private static final int SOURCE_TOUCHSCREEN = InputDevice.SOURCE_TOUCHSCREEN;

    /** {@code MotionEvent.TOOL_TYPE_FINGER}. */
    private static final int TOOL_TYPE_FINGER = MotionEvent.TOOL_TYPE_FINGER;

    /** Force-lift an idle pointer session after this long with no move/up, so a
     *  lost finger-lift frame can't leave a synthetic pointer stuck down on the
     *  cluster. Generous vs. a human drag pause; short enough to self-heal. */
    private static final long AUTO_LIFT_MS = 1_500L;

    private final Object lock = new Object();

    private Object inputManager;          // android.hardware.input.InputManager singleton
    private Method injectInputEvent;      // (InputEvent, int) -> boolean
    private Method motionSetDisplayId;    // MotionEvent.setDisplayId(int)
    private Method keySetDisplayId;       // KeyEvent.setDisplayId(int), may be null
    private volatile boolean ready;

    // Reused per-pointer buffers (single finger). Guarded by `lock`.
    private final MotionEvent.PointerProperties[] props =
            new MotionEvent.PointerProperties[] { new MotionEvent.PointerProperties() };
    private final MotionEvent.PointerCoords[] coords =
            new MotionEvent.PointerCoords[] { new MotionEvent.PointerCoords() };

    // ── active pointer session (guarded by `lock`) ──────────────────────────
    private boolean sessionActive;
    private int sessionDisplayId;
    private long sessionDownTime;
    private float lastX, lastY;
    private long lastActivityMs;

    private final ScheduledExecutorService autoLift =
            Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "dashd-autolift");
                t.setDaemon(true);
                return t;
            });
    private ScheduledFuture<?> autoLiftTask;

    /**
     * Resolve the reflection surface. Idempotent; returns {@link #ready}. A
     * false return means this ROM didn't expose {@code injectInputEvent} (the
     * daemon then never advertises the {@code inject} capability and the client
     * falls back to the a11y / ADB tiers).
     */
    boolean init() {
        if (ready) return true;
        synchronized (lock) {
            if (ready) return true;
            try {
                unlockHiddenApis();
                props[0].id = 0;
                props[0].toolType = TOOL_TYPE_FINGER;

                Class<?> im = Class.forName("android.hardware.input.InputManager");
                inputManager = im.getMethod("getInstance").invoke(null);
                injectInputEvent = im.getMethod(
                        "injectInputEvent", InputEvent.class, int.class);
                motionSetDisplayId = MotionEvent.class.getMethod("setDisplayId", int.class);
                // KeyEvent.setDisplayId is hidden and not present on every ROM —
                // key injection still works without it (lands on the default
                // display), so treat its absence as non-fatal.
                try {
                    keySetDisplayId = KeyEvent.class.getMethod("setDisplayId", int.class);
                } catch (Throwable ignored) {
                    keySetDisplayId = null;
                }
                ready = inputManager != null && injectInputEvent != null
                        && motionSetDisplayId != null;
            } catch (Throwable t) {
                System.err.println("InputInjector.init failed: " + t);
                ready = false;
            }
            return ready;
        }
    }

    boolean isReady() {
        return ready;
    }

    /**
     * Single tap: DOWN immediately followed by UP at the same point. Atomic —
     * does not touch the streaming pointer session (a tap mid-drag is nonsense
     * and the touchpad never issues one).
     */
    boolean tap(int displayId, float x, float y) {
        if (!ready) return false;
        synchronized (lock) {
            long t = SystemClock.uptimeMillis();
            boolean down = inject(displayId, MotionEvent.ACTION_DOWN, t, t, x, y);
            boolean up = inject(displayId, MotionEvent.ACTION_UP, t, t, x, y);
            return down && up;
        }
    }

    /** Long-press: DOWN, hold {@code durationMs}, UP. The hold is realised by
     *  the UP carrying an {@code eventTime} {@code durationMs} after the DOWN —
     *  the window's long-press timeout keys off the event timeline, not wall
     *  clock, so we don't actually sleep the serve thread. */
    boolean longPress(int displayId, float x, float y, long durationMs) {
        if (!ready) return false;
        synchronized (lock) {
            long t = SystemClock.uptimeMillis();
            boolean down = inject(displayId, MotionEvent.ACTION_DOWN, t, t, x, y);
            boolean up = inject(displayId, MotionEvent.ACTION_UP, t, t + durationMs, x, y);
            return down && up;
        }
    }

    /**
     * One-shot swipe: DOWN at (x1,y1), a MOVE, then UP at (x2,y2). For a real
     * streamed drag use {@link #ptrDown}/{@link #ptrMove}/{@link #ptrUp}
     * instead; this exists so the discrete {@code swipe} op has a daemon-fast
     * path matching the a11y/ADB fallbacks' contract.
     */
    boolean swipe(int displayId, float x1, float y1, float x2, float y2, long durationMs) {
        if (!ready) return false;
        synchronized (lock) {
            long t = SystemClock.uptimeMillis();
            boolean ok = inject(displayId, MotionEvent.ACTION_DOWN, t, t, x1, y1);
            ok &= inject(displayId, MotionEvent.ACTION_MOVE, t, t + durationMs / 2, x2, y2);
            ok &= inject(displayId, MotionEvent.ACTION_UP, t, t + durationMs, x2, y2);
            return ok;
        }
    }

    /** Begin a streamed pointer session: inject ACTION_DOWN and remember the
     *  {@code downTime} every subsequent MOVE/UP must share. Replaces any prior
     *  live session (force-lifts it first so we never leak a stuck pointer). */
    boolean ptrDown(int displayId, float x, float y) {
        if (!ready) return false;
        synchronized (lock) {
            if (sessionActive) forceLiftLocked();
            long t = SystemClock.uptimeMillis();
            boolean ok = inject(displayId, MotionEvent.ACTION_DOWN, t, t, x, y);
            sessionActive = true;
            sessionDisplayId = displayId;
            sessionDownTime = t;
            lastX = x;
            lastY = y;
            lastActivityMs = System.currentTimeMillis();
            armAutoLift();
            return ok;
        }
    }

    /** Stream a MOVE on the live session. Starts a session on the fly if a
     *  DOWN was lost (defensive) so a stray move still produces visible input. */
    boolean ptrMove(int displayId, float x, float y) {
        if (!ready) return false;
        synchronized (lock) {
            if (!sessionActive || sessionDisplayId != displayId) {
                return ptrDownLocked(displayId, x, y);
            }
            long t = SystemClock.uptimeMillis();
            boolean ok = inject(displayId, MotionEvent.ACTION_MOVE, sessionDownTime, t, x, y);
            lastX = x;
            lastY = y;
            lastActivityMs = System.currentTimeMillis();
            return ok;
        }
    }

    /** End the live session with ACTION_UP at (x,y). No-op (returns true) if no
     *  session is active — an idempotent up is harmless. */
    boolean ptrUp(float x, float y) {
        if (!ready) return false;
        synchronized (lock) {
            if (!sessionActive) return true;
            long t = SystemClock.uptimeMillis();
            boolean ok = inject(sessionDisplayId, MotionEvent.ACTION_UP, sessionDownTime, t, x, y);
            clearSessionLocked();
            return ok;
        }
    }

    /** Cancel the live session (ACTION_CANCEL) — e.g. the sheet closed mid-drag.
     *  Like {@link #ptrUp} but tells the window the gesture was aborted. */
    boolean ptrCancel() {
        if (!ready) return false;
        synchronized (lock) {
            if (!sessionActive) return true;
            long t = SystemClock.uptimeMillis();
            boolean ok = inject(sessionDisplayId, MotionEvent.ACTION_CANCEL,
                    sessionDownTime, t, lastX, lastY);
            clearSessionLocked();
            return ok;
        }
    }

    /** Inject a key as DOWN+UP on {@code displayId}. setDisplayId is best-effort
     *  (hidden, ROM-dependent); without it the key lands on the default display,
     *  which is why the plugin still prefers a11y/ADB for text-bearing keys. */
    boolean key(int displayId, int keyCode) {
        if (!ready) return false;
        synchronized (lock) {
            long t = SystemClock.uptimeMillis();
            boolean ok = injectKey(displayId, KeyEvent.ACTION_DOWN, t, keyCode);
            ok &= injectKey(displayId, KeyEvent.ACTION_UP, t, keyCode);
            return ok;
        }
    }

    // ── internals (all callers hold `lock`) ─────────────────────────────────

    private boolean ptrDownLocked(int displayId, float x, float y) {
        long t = SystemClock.uptimeMillis();
        boolean ok = inject(displayId, MotionEvent.ACTION_DOWN, t, t, x, y);
        sessionActive = true;
        sessionDisplayId = displayId;
        sessionDownTime = t;
        lastX = x;
        lastY = y;
        lastActivityMs = System.currentTimeMillis();
        armAutoLift();
        return ok;
    }

    private boolean inject(int displayId, int action, long downTime, long eventTime,
                           float x, float y) {
        MotionEvent ev = null;
        try {
            coords[0].clear();
            coords[0].x = x;
            coords[0].y = y;
            coords[0].pressure = 1.0f;
            coords[0].size = 1.0f;
            ev = MotionEvent.obtain(
                    downTime, eventTime, action,
                    /* pointerCount */ 1, props, coords,
                    /* metaState */ 0, /* buttonState */ 0,
                    /* xPrecision */ 1.0f, /* yPrecision */ 1.0f,
                    /* deviceId */ 0, /* edgeFlags */ 0,
                    SOURCE_TOUCHSCREEN, /* flags */ 0);
            try {
                motionSetDisplayId.invoke(ev, displayId);
            } catch (Throwable t) {
                // Non-fatal: lands on the default display rather than failing.
            }
            Object r = injectInputEvent.invoke(inputManager, ev, INJECT_MODE_ASYNC);
            return !(r instanceof Boolean) || (Boolean) r;
        } catch (Throwable t) {
            System.err.println("InputInjector.inject(" + action + ") failed: " + t);
            return false;
        } finally {
            if (ev != null) ev.recycle();
        }
    }

    private boolean injectKey(int displayId, int action, long eventTime, int keyCode) {
        KeyEvent ev = new KeyEvent(eventTime, eventTime, action, keyCode, 0);
        try {
            if (keySetDisplayId != null) {
                try {
                    keySetDisplayId.invoke(ev, displayId);
                } catch (Throwable ignored) {
                }
            }
            Object r = injectInputEvent.invoke(inputManager, ev, INJECT_MODE_ASYNC);
            return !(r instanceof Boolean) || (Boolean) r;
        } catch (Throwable t) {
            System.err.println("InputInjector.injectKey failed: " + t);
            return false;
        }
    }

    private void armAutoLift() {
        if (autoLiftTask != null) autoLiftTask.cancel(false);
        autoLiftTask = autoLift.schedule(this::autoLiftTick, AUTO_LIFT_MS, TimeUnit.MILLISECONDS);
    }

    private void autoLiftTick() {
        synchronized (lock) {
            if (!sessionActive) return;
            long idle = System.currentTimeMillis() - lastActivityMs;
            if (idle >= AUTO_LIFT_MS) {
                System.out.println("[InputInjector] auto-lift: session idle " + idle + "ms");
                forceLiftLocked();
            } else {
                // Activity arrived after we were scheduled — re-arm for the
                // remaining window instead of lifting a live drag.
                autoLiftTask = autoLift.schedule(
                        this::autoLiftTick, AUTO_LIFT_MS - idle, TimeUnit.MILLISECONDS);
            }
        }
    }

    private void forceLiftLocked() {
        long t = SystemClock.uptimeMillis();
        inject(sessionDisplayId, MotionEvent.ACTION_UP, sessionDownTime, t, lastX, lastY);
        clearSessionLocked();
    }

    private void clearSessionLocked() {
        sessionActive = false;
        if (autoLiftTask != null) {
            autoLiftTask.cancel(false);
            autoLiftTask = null;
        }
    }

    /** Best-effort hidden-API unlock so {@code injectInputEvent} /
     *  {@code setDisplayId} reflect without a greylist warning/deny. Mirrors the
     *  reference app's {@code VMRuntime.setHiddenApiExemptions(["L"])}. */
    private static void unlockHiddenApis() {
        try {
            Class<?> vmRuntime = Class.forName("dalvik.system.VMRuntime");
            Object runtime = vmRuntime.getDeclaredMethod("getRuntime").invoke(null);
            Method exempt = vmRuntime.getDeclaredMethod(
                    "setHiddenApiExemptions", String[].class);
            exempt.invoke(runtime, (Object) new String[] { "L" });
        } catch (Throwable t) {
            // Already exempt (typical for app_process daemons) or the API moved.
        }
    }
}
