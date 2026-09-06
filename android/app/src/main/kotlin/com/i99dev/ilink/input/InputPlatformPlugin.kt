package com.i99dev.ilink.input

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge
import com.i99dev.ilink.display.DisplayInputResolver
import com.i99dev.ilink.miniapps.MiniAppShellCommands
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * `gesture` family — the ONE input-injection seam. Every synthetic
 * tap / swipe / longPress / key / streamed pointer (mini-app gesture
 * family AND the cluster touchpad) flows through here, so there is a
 * single tier ladder and a single display-remap authority.
 *
 * Tier ladder (each feature-detected, fall through on absence):
 *
 *   0. **DashDaemon inject (FAST)** — the daemon (shell uid) reflects
 *      `InputManager.injectInputEvent` + `MotionEvent.setDisplayId`,
 *      injecting MotionEvent streams to any display at native latency
 *      with no per-event shell fork. This is the path the reference dashboard
 *      app ships; it's also the only one that can STREAM (`ptr` down/move/up), so the
 *      relative-trackpad drag rides it. Gated on `caps.inject`.
 *   1. **a11y `dispatchGesture(displayId)`** — discrete gestures on a
 *      non-default display without a system signature. Used when the
 *      daemon isn't up / predates inject. Can't stream.
 *   2. **ADB `input -d N …`** — last resort when neither is available
 *      (a11y disabled and daemon unreachable).
 *
 * Input is net I/O (daemon TCP) so every op runs on [inputExecutor] —
 * a SINGLE thread, which also serialises a streamed gesture's
 * down→move…→up so the daemon sees them in order.
 *
 * Wire shape (matches `GestureNativeBridge.dart`):
 *
 *     {
 *       dispatched: Bool,        // true on success
 *       reason: String?,         // "accessibility_disabled" /
 *                                //  "adb_unreachable" /
 *                                //  "dispatch_rejected" /
 *                                //  "stream_unavailable"
 *       path: String?,           // "daemon" / "a11y" / "adb" — which
 *                                //  tier handled it (diagnostics)
 *     }
 */
class InputPlatformPlugin(
    private val applicationContext: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val methodChannel = MethodChannel(messenger, "ilink/gesture").also {
        it.setMethodCallHandler(this)
    }

    /**
     * Off-main worker for ALL input ops. Input is net I/O (the daemon TCP
     * socket) and a11y/ADB are IPC, so none may run on the platform-channel
     * (main) thread. SINGLE thread on purpose: it serialises a streamed
     * gesture's down→move…→up frames so the daemon injects them in order.
     */
    private val inputExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Translates `gesture.dispatch(displayId=N)` to the displayId
     * where the OS actually routes input. On XDJA-virtualized
     * clusters, mini-apps may pass `displayId=5` (the launch slot),
     * but the launched window's input channel lives on `displayId=3`
     * (the surface composition target). The resolver papers over
     * that — see [DisplayInputResolver] for the why.
     *
     * Identity map on cars without XDJA, so non-cluster cars and
     * non-cluster targets (IVI, passenger) are unaffected.
     */
    private val displayResolver = DisplayInputResolver(applicationContext)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "tap" -> handleTap(call, result)
            "swipe" -> handleSwipe(call, result)
            "longPress" -> handleLongPress(call, result)
            "text" -> handleText(call, result)
            "key" -> handleKey(call, result)
            "ptr" -> handlePtr(call, result)
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        inputExecutor.shutdown()
    }

    // ── handlers ─────────────────────────────────────────────────

    private fun handleTap(call: MethodCall, result: MethodChannel.Result) {
        val requestedDisplayId = call.argInt("displayId") ?: return result.bad("displayId")
        val displayId = displayResolver.resolve(requestedDisplayId)
        val x = call.argDouble("x") ?: return result.bad("x")
        val y = call.argDouble("y") ?: return result.bad("y")
        inputExecutor.execute {
            val r = injectTapTiered(displayId, x, y)
            mainHandler.post { result.success(r) }
        }
    }

    private fun handleSwipe(call: MethodCall, result: MethodChannel.Result) {
        val requestedDisplayId = call.argInt("displayId") ?: return result.bad("displayId")
        val displayId = displayResolver.resolve(requestedDisplayId)
        val fromX = call.argDouble("fromX") ?: return result.bad("fromX")
        val fromY = call.argDouble("fromY") ?: return result.bad("fromY")
        val toX = call.argDouble("toX") ?: return result.bad("toX")
        val toY = call.argDouble("toY") ?: return result.bad("toY")
        val durationMs = call.argInt("durationMs") ?: 300
        inputExecutor.execute {
            val r = injectSwipeTiered(displayId, fromX, fromY, toX, toY, durationMs)
            mainHandler.post { result.success(r) }
        }
    }

    private fun handleLongPress(call: MethodCall, result: MethodChannel.Result) {
        val requestedDisplayId = call.argInt("displayId") ?: return result.bad("displayId")
        val displayId = displayResolver.resolve(requestedDisplayId)
        val x = call.argDouble("x") ?: return result.bad("x")
        val y = call.argDouble("y") ?: return result.bad("y")
        val durationMs = call.argInt("durationMs") ?: 800
        inputExecutor.execute {
            val r = injectLongPressTiered(displayId, x, y, durationMs)
            mainHandler.post { result.success(r) }
        }
    }

    /**
     * Streamed pointer session for the relative trackpad. Daemon-only — a11y
     * dispatchGesture can't stream and ADB has no per-frame path, so when the
     * daemon route is unavailable we answer `stream_unavailable` and the Dart
     * controller degrades to coalesced discrete swipes.
     *
     * `phase` ∈ {down, move, up, cancel}. `down`/`move` carry `displayId,x,y`;
     * `up` carries `x,y`; `cancel` carries nothing. Coordinates are pixels on
     * the target (already display-local from the Dart side).
     */
    private fun handlePtr(call: MethodCall, result: MethodChannel.Result) {
        val phase = call.argument<String>("phase") ?: return result.bad("phase")
        // down/move resolve the display; up/cancel act on the open session.
        val displayId = call.argInt("displayId")?.let { displayResolver.resolve(it) } ?: 0
        val x = call.argDouble("x") ?: 0.0
        val y = call.argDouble("y") ?: 0.0
        inputExecutor.execute {
            val r = when (phase) {
                "down" -> {
                    when (val ok = AdbShellBridge.injectPtrDown(displayId, x, y)) {
                        null -> envelope(false, "stream_unavailable", "none")
                        else -> envelope(ok, if (ok) null else "dispatch_rejected", "daemon")
                    }
                }
                "move" -> {
                    val ok = AdbShellBridge.injectPtrMove(displayId, x, y)
                    envelope(ok, if (ok) null else "stream_unavailable", "daemon")
                }
                "up" -> envelope(AdbShellBridge.injectPtrUp(x, y), null, "daemon")
                "cancel" -> envelope(AdbShellBridge.injectPtrCancel(), null, "daemon")
                else -> envelope(false, "bad_phase", "none")
            }
            mainHandler.post { result.success(r) }
        }
    }

    // ── tiered dispatch (daemon → a11y → ADB) ────────────────────────────
    // Each runs on inputExecutor. Tier 0 is the daemon (returns null when
    // unavailable → fall through); tier 1 is a11y; tier 2 is ADB.

    private fun injectTapTiered(displayId: Int, x: Double, y: Double): Map<String, Any?> {
        AdbShellBridge.injectTap(displayId, x, y)?.let {
            return envelope(it, if (it) null else "dispatch_rejected", "daemon")
        }
        RemoteControlAccessibilityService.instance?.let { svc ->
            val ok = svc.dispatchTap(displayId, x.toFloat(), y.toFloat())
            return envelope(ok, if (ok) null else "dispatch_rejected", "a11y")
        }
        return adbInputTap(displayId, x, y)
    }

    private fun injectSwipeTiered(
        displayId: Int,
        fromX: Double, fromY: Double, toX: Double, toY: Double,
        durationMs: Int,
    ): Map<String, Any?> {
        AdbShellBridge.injectSwipe(displayId, fromX, fromY, toX, toY, durationMs)?.let {
            return envelope(it, if (it) null else "dispatch_rejected", "daemon")
        }
        RemoteControlAccessibilityService.instance?.let { svc ->
            val ok = svc.dispatchSwipe(
                displayId, fromX.toFloat(), fromY.toFloat(),
                toX.toFloat(), toY.toFloat(), durationMs.toLong(),
            )
            return envelope(ok, if (ok) null else "dispatch_rejected", "a11y")
        }
        return adbInputSwipe(displayId, fromX, fromY, toX, toY, durationMs)
    }

    private fun injectLongPressTiered(
        displayId: Int, x: Double, y: Double, durationMs: Int,
    ): Map<String, Any?> {
        AdbShellBridge.injectLongPress(displayId, x, y, durationMs)?.let {
            return envelope(it, if (it) null else "dispatch_rejected", "daemon")
        }
        RemoteControlAccessibilityService.instance?.let { svc ->
            val ok = svc.dispatchLongPress(displayId, x.toFloat(), y.toFloat(), durationMs.toLong())
            return envelope(ok, if (ok) null else "dispatch_rejected", "a11y")
        }
        // ADB has no native long-press; emulate with a zero-length swipe.
        return adbInputSwipe(displayId, x, y, x, y, durationMs)
    }

    /**
     * Type text into the focused input on the target display.
     * Backed by `input -d N text <shell-escaped>` over loopback ADB —
     * no AccessibilityService path because dispatchGesture only
     * handles touch gestures, not key events. The OEM IME on Leopard 8
     * isn't reliable enough to act as the universal route, so we go
     * straight to `input` which works on every Android display whose
     * id is enumerable from `dumpsys SurfaceFlinger`.
     *
     * `displayId` resolves through [DisplayInputResolver] for symmetry
     * with tap / swipe / longPress — XDJA's launch≠input asymmetry
     * applies here too.
     */
    private fun handleText(call: MethodCall, result: MethodChannel.Result) {
        val requestedDisplayId = call.argInt("displayId") ?: return result.bad("displayId")
        val displayId = displayResolver.resolve(requestedDisplayId)
        val text = call.argument<String>("text") ?: return result.bad("text")
        if (text.isEmpty()) {
            result.success(envelope(true, null))
            return
        }
        inputExecutor.execute {
            val r = injectTextTiered(displayId, text)
            mainHandler.post { result.success(r) }
        }
    }

    /**
     * Text has NO daemon tier — synthetic key/IME injection can't reliably
     * reach a focused EditText on an XDJA cluster window (per-display focus is
     * null there). Accessibility's `ACTION_SET_TEXT` walks the a11y tree and
     * mutates the field directly, so it stays the primary; ADB `input text` is
     * the fallback when a11y is off.
     */
    private fun injectTextTiered(displayId: Int, text: String): Map<String, Any?> {
        RemoteControlAccessibilityService.instance?.let { svc ->
            val ok = svc.dispatchSetText(displayId, text)
            return envelope(ok, if (ok) null else "no_focused_input", "a11y")
        }
        return adbInputText(displayId, text)
    }

    private fun handleKey(call: MethodCall, result: MethodChannel.Result) {
        val requestedDisplayId = call.argInt("displayId") ?: return result.bad("displayId")
        val displayId = displayResolver.resolve(requestedDisplayId)
        val keycode = call.argInt("keycode") ?: return result.bad("keycode")
        inputExecutor.execute {
            val r = injectKeyTiered(displayId, keycode)
            mainHandler.post { result.success(r) }
        }
    }

    /**
     * KEYCODE_DEL (67) edits the focused EditText, so accessibility's
     * `dispatchDeleteLastChar` is the reliable path (a synthetic DEL key event
     * doesn't route to an unfocused cluster window) — prefer a11y, then daemon,
     * then ADB. Every other keycode goes daemon (FAST, per-display) → ADB; a11y
     * has no generic key-event surface.
     */
    private fun injectKeyTiered(displayId: Int, keycode: Int): Map<String, Any?> {
        if (keycode == KEYCODE_DEL) {
            RemoteControlAccessibilityService.instance?.let { svc ->
                val ok = svc.dispatchDeleteLastChar(displayId)
                return envelope(ok, if (ok) null else "no_focused_input", "a11y")
            }
        }
        AdbShellBridge.injectKey(displayId, keycode)?.let {
            return envelope(it, if (it) null else "dispatch_rejected", "daemon")
        }
        return adbInputKey(displayId, keycode)
    }

    // ── ADB fallback ─────────────────────────────────────────────

    private fun adbInputTap(displayId: Int, x: Double, y: Double): Map<String, Any?> {
        val probe = AdbShellBridge.shell("echo ok", 1_500).trim()
        if (probe.startsWith("Error:")) return envelope(false, "adb_unreachable", "adb")
        // `input -d N tap X Y` lands on the requested display. Some
        // Leopard 8 builds reject `-d` for non-shell uids; running
        // through loopback ADB is shell uid, so this is the safe path.
        // The command shape lives in the encrypted mini-app table —
        // MiniAppShellCommands resolves it at runtime so the literal
        // doesn't ship in classes.dex.
        val cmd = MiniAppShellCommands.inputTap(displayId, x.toInt(), y.toInt())
        val out = AdbShellBridge.shell(cmd, 3_000).trim()
        return if (looksLikeAdbInputFailure(out)) {
            Log.w(TAG, "input tap failed: $out")
            envelope(false, "dispatch_rejected", "adb")
        } else {
            envelope(true, null, "adb")
        }
    }

    /**
     * `input -d N text <shell-escaped>` over loopback ADB.
     *
     * Shell escaping: wrap the text in single quotes after replacing
     * each embedded single quote with `'\''` (close, escape, reopen).
     * This is shell-safe for every Unicode codepoint — `input text`
     * accepts UTF-8, and the surrounding single quotes neutralise
     * every char inside (no variable expansion, no globbing,
     * apostrophes get escaped explicitly).
     */
    private fun adbInputText(displayId: Int, text: String): Map<String, Any?> {
        val probe = AdbShellBridge.shell("echo ok", 1_500).trim()
        if (probe.startsWith("Error:")) return envelope(false, "adb_unreachable", "adb")
        val escaped = "'" + text.replace("'", "'\\''") + "'"
        val cmd = "input -d $displayId text $escaped"
        val out = AdbShellBridge.shell(cmd, 3_000).trim()
        return if (looksLikeAdbInputFailure(out)) {
            Log.w(TAG, "input text failed: $out")
            envelope(false, "dispatch_rejected", "adb")
        } else {
            envelope(true, null, "adb")
        }
    }

    /**
     * `input -d N keyevent <code>` over loopback ADB. Standard Android
     * keycodes — KEYCODE_DEL (67), KEYCODE_ENTER (66), etc.
     */
    private fun adbInputKey(displayId: Int, keycode: Int): Map<String, Any?> {
        val probe = AdbShellBridge.shell("echo ok", 1_500).trim()
        if (probe.startsWith("Error:")) return envelope(false, "adb_unreachable", "adb")
        val cmd = "input -d $displayId keyevent $keycode"
        val out = AdbShellBridge.shell(cmd, 3_000).trim()
        return if (looksLikeAdbInputFailure(out)) {
            Log.w(TAG, "input keyevent failed: $out")
            envelope(false, "dispatch_rejected", "adb")
        } else {
            envelope(true, null, "adb")
        }
    }

    private fun adbInputSwipe(
        displayId: Int,
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        durationMs: Int,
    ): Map<String, Any?> {
        val probe = AdbShellBridge.shell("echo ok", 1_500).trim()
        if (probe.startsWith("Error:")) return envelope(false, "adb_unreachable", "adb")
        val cmd = MiniAppShellCommands.inputSwipe(
            displayId = displayId,
            fromX = fromX.toInt(), fromY = fromY.toInt(),
            toX = toX.toInt(), toY = toY.toInt(),
            durationMs = durationMs,
        )
        val out = AdbShellBridge.shell(cmd, durationMs.toLong() + 3_000).trim()
        return if (looksLikeAdbInputFailure(out)) {
            Log.w(TAG, "input swipe failed: $out")
            envelope(false, "dispatch_rejected", "adb")
        } else {
            envelope(true, null, "adb")
        }
    }

    private fun looksLikeAdbInputFailure(out: String): Boolean {
        if (out.isEmpty()) return false // input prints nothing on success
        val lower = out.lowercase()
        return lower.startsWith("error:") ||
            lower.contains("exception") ||
            lower.contains("usage:") ||
            lower.contains("invalid")
    }

    // ── helpers ──────────────────────────────────────────────────

    private fun envelope(
        dispatched: Boolean,
        reason: String?,
        path: String? = null,
    ): Map<String, Any?> {
        val m = mutableMapOf<String, Any?>("dispatched" to dispatched)
        if (reason != null) m["reason"] = reason
        if (path != null) m["path"] = path
        return m
    }

    private fun MethodCall.argInt(name: String): Int? =
        (argument<Number>(name))?.toInt()
    private fun MethodCall.argDouble(name: String): Double? =
        (argument<Number>(name))?.toDouble()

    private fun MethodChannel.Result.bad(slot: String) {
        error("bad_request", "$slot required", null)
    }

    companion object {
        private const val TAG = "InputPlatformPlugin"
        // Standard Android `KeyEvent.KEYCODE_DEL` — backspace. Carved
        // out so handleKey can route it through accessibility's
        // dispatchDeleteLastChar instead of ADB, matching the text
        // path's reach into windows that aren't reflected in
        // WindowManager's per-display focus.
        private const val KEYCODE_DEL = 67
    }
}
