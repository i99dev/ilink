package com.i99dev.ilink.voice

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import com.i99dev.ilink.MainActivity
import com.i99dev.ilink.adb.AdbShellBridge
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Process-wide owner of the dynamic wheel-voice override: it holds the
 * resolved [WheelVoiceKey] and turns a matching key press into our AI voice
 * assistant, replacing BYD's `com.byd.autovoice`.
 *
 * Three interception points all key on the **dynamically-resolved scancode**
 * (never a hardcoded keycode):
 *   - the accessibility key filter ([handleKeyEvent], works while the dash is
 *     backgrounded and can *consume* the press so BYD never sees it);
 *   - `MainActivity.dispatchKeyEvent` (foreground);
 *   - (future) a `getevent` monitor on [WheelVoiceKey.deviceNode] over the
 *     loopback-ADB bridge, for trims where the key never surfaces to a11y.
 *
 * Firing the assistant works whether or not the Flutter engine is alive:
 * [VoiceSessionService.pushHardwareKey] delivers straight to the listening
 * Dart `VoiceController` when the engine is up; otherwise we bring the app to
 * the foreground with an `ACTION_ASSIST` intent (which `MainActivity` already
 * forwards to Dart).
 *
 * Suppression of BYD's own assistant is opt-in and reversible: the ROM
 * exposes `persist.sys.autovoice.enable`, which BYD itself toggles. We leave
 * it ON by default (non-destructive — our voice fires *alongside* BYD's if
 * a11y can't swallow the key) and only flip it off when the owner enables
 * suppression for a clean replace.
 */
object WheelVoiceController {
    private const val TAG = "WheelVoice"

    private const val PREFS = "wheel_voice"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_SUPPRESS = "suppress_byd"

    /** BYD's documented, reversible kill-switch for `com.byd.autovoice`. */
    private const val AUTOVOICE_PROP = "persist.sys.autovoice.enable"

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Dedupes concurrent resolves: the boot retry and any key-triggered
     *  lazy resolve must never overlap (each shells the bridge). */
    private val resolving = AtomicBoolean(false)

    /** Boot resolve retry budget — the loopback-ADB bridge can take a few
     *  seconds to authorise + spawn the daemon, and on some units it isn't
     *  ready when [warmUp] first runs. Six attempts × 3 s covers the late-
     *  bridge case without busy-waiting. */
    private const val WARMUP_ATTEMPTS = 6
    private const val WARMUP_DELAY_MS = 3_000L

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Whole-feature switch. **Hard-off**: the product is hands-free only
     *  (tap the mic → AI / Car-Command picker, or the on-device "Hey BYD" /
     *  "Hey AI" wake words). The steering-wheel override was removed, so the
     *  wheel key always passes straight through to BYD's own autovoice and we
     *  never intercept it. Kept as a single return-false lever (rather than
     *  ripping out the resolver + a11y plumbing) so re-enabling later is a
     *  one-line change and nothing downstream had to be rewired. */
    fun isEnabled(context: Context): Boolean = false

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    /** Whether to disable BYD's own autovoice via [AUTOVOICE_PROP]. Default
     *  off — destructive-ish (system-wide + persistent), so opt-in. */
    fun shouldSuppressByd(context: Context): Boolean =
        prefs(context).getBoolean(KEY_SUPPRESS, false)

    /** Persist the suppression preference and apply it now. Shells to the
     *  bridge, so it offloads onto a worker thread. */
    fun setSuppressByd(context: Context, suppress: Boolean) {
        prefs(context).edit().putBoolean(KEY_SUPPRESS, suppress).apply()
        Thread({ setProp(AUTOVOICE_PROP, if (suppress) "false" else "true") }, "wheel-voice-suppress")
            .apply { isDaemon = true }
            .start()
    }

    /** The currently resolved key (or null until [warmUp] succeeds). */
    fun resolvedKey(): WheelVoiceKey? = WheelVoiceKeyResolver.cached()

    /**
     * Resolve the wheel-voice key for this car and apply the suppression
     * preference, retrying while the loopback-ADB bridge warms up. **Worker
     * thread only** — shells to the bridge and sleeps between attempts. Safe
     * to call repeatedly; resolution is cached and the [resolving] guard
     * prevents overlap with a key-triggered lazy resolve.
     */
    fun warmUp(context: Context) {
        resolveWithRetry(context, WARMUP_ATTEMPTS, WARMUP_DELAY_MS)
    }

    private fun resolveWithRetry(context: Context, attempts: Int, delayMs: Long) {
        if (!resolving.compareAndSet(false, true)) return
        try {
            repeat(attempts) { i ->
                val key = WheelVoiceKeyResolver.resolve()
                if (key != null) {
                    if (isEnabled(context) && shouldSuppressByd(context)) {
                        setProp(AUTOVOICE_PROP, "false")
                    }
                    return
                }
                if (i < attempts - 1 && delayMs > 0) Thread.sleep(delayMs)
            }
            Log.i(TAG, "wheel-voice key unresolved after $attempts attempt(s) — bridge not ready or no key declared")
        } catch (t: Throwable) {
            Log.w(TAG, "resolveWithRetry threw: ${t.message}")
        } finally {
            resolving.set(false)
        }
    }

    /** Kick a one-shot background resolve (off the calling thread) when a key
     *  arrives before the boot resolve succeeded — so the *next* press works
     *  even if the bridge came up after [warmUp] gave up. The [resolving]
     *  guard makes rapid presses cheap (at most one resolve in flight). */
    private fun kickLazyResolve(context: Context) {
        if (resolving.get()) return
        val app = context.applicationContext
        Thread({ resolveWithRetry(app, attempts = 1, delayMs = 0L) }, "wheel-voice-lazy")
            .apply { isDaemon = true }
            .start()
    }

    /**
     * Accessibility / dispatch key handler. Returns true to **consume** the
     * event (so BYD's autovoice never sees it) when the press matches the
     * resolved voice scancode and the override is enabled — both the DOWN and
     * the UP are swallowed so no dangling half-press leaks through. Returns
     * false (passthrough) otherwise.
     */
    fun handleKeyEvent(event: KeyEvent, context: Context): Boolean {
        val key = WheelVoiceKeyResolver.cached()
        if (key == null) {
            // Not resolved yet (bridge wasn't ready at boot). Kick a one-shot
            // background resolve so a later press works, and let THIS press
            // fall through to BYD for now.
            if (isEnabled(context) && event.action == KeyEvent.ACTION_DOWN) kickLazyResolve(context)
            return false
        }
        if (event.scanCode == 0 || event.scanCode != key.scanCode) return false
        if (!isEnabled(context)) return false
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            Log.i(TAG, "intercepted wheel-voice key scanCode=${event.scanCode} (${key.label}) — firing voice")
            fireVoice(context)
        }
        return true
    }

    /**
     * Trigger the AI voice assistant. Delivers to the live Flutter engine
     * when one is listening; otherwise brings the app to the foreground with
     * an assist intent. Always hops to the main thread first
     * ([VoiceSessionService.pushHardwareKey] and `startActivity` both want it).
     */
    fun fireVoice(context: Context) {
        val app = context.applicationContext
        mainHandler.post {
            if (VoiceSessionService.pushHardwareKey()) return@post
            try {
                val intent = Intent(app, MainActivity::class.java)
                    .setAction(Intent.ACTION_ASSIST)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                app.startActivity(intent)
            } catch (t: Throwable) {
                Log.w(TAG, "assist-intent fallback failed: ${t.message}")
            }
        }
    }

    /** One-shot `setprop`; logs the (usually empty) body. Best-effort —
     *  whether the shell UID may write a given `persist.sys.*` prop depends
     *  on the ROM's property_contexts, so a denial here is non-fatal. */
    private fun setProp(name: String, value: String) {
        val out = AdbShellBridge.shell("setprop $name $value 2>&1; getprop $name", 3_000)
        Log.i(TAG, "setprop $name=$value -> '${out.trim().take(40)}'")
    }
}
