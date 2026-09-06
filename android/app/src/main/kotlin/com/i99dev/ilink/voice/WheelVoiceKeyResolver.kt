package com.i99dev.ilink.voice

import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge
import java.io.File

/**
 * Resolves the steering-wheel voice button [WheelVoiceKey] for **this** car
 * by reading what the ROM declares — no hardcoded scancode, so the same code
 * adapts to Di5.0, Di5.1, and any future trim.
 *
 * Two reads, parsed by the pure [WheelVoiceKeyParser]:
 *   1. the `.kl` files in `/system/usr/keylayout` → label + scancode. These
 *      are `system_file`-context, world-readable (same as `build.prop`), so
 *      we read them **directly** with no loopback-ADB dependency — the
 *      scancode is all the a11y / dispatch interception needs. Falls back to
 *      a bridge `grep` only if direct file I/O is denied.
 *   2. `getevent -lp` → the owning `/dev/input/eventN`. `/dev/input` is
 *      `root:input`, NOT app-readable, so this stays bridge-only and
 *      best-effort: a null node is fine (it's only for the deferred
 *      getevent-monitor fallback; key matching keys on the scancode).
 *
 * The result is cached for the process lifetime (the keylayouts don't change
 * under us); [resolve] is idempotent and cheap after the first call.
 *
 * Threading: call on a worker thread — file I/O plus [AdbShellBridge.shell]
 * (which does net I/O and crashes with `NetworkOnMainThreadException` on the
 * main thread). The [shell] seam mirrors [com.i99dev.ilink.pkg.AmShellRunner]
 * so tests inject a recorded shell; production uses `AdbShellBridge::shell`.
 */
object WheelVoiceKeyResolver {
    private const val TAG = "WheelVoiceKey"

    private val DEFAULT_SHELL: (String, Long) -> String = AdbShellBridge::shell

    private const val KEYLAYOUT_DIR = "/system/usr/keylayout"

    /** `grep -H` so each match is prefixed with its keylayout path. The
     *  alternation is the same priority set [WheelVoiceKeyParser] accepts. */
    private const val GREP_CMD =
        "grep -HE 'AUTO_MEDIA_VOICE|VOICE_ASSIST|ASSIST' /system/usr/keylayout/*.kl 2>/dev/null"
    private const val GETEVENT_CMD = "getevent -lp 2>/dev/null"

    private const val GREP_TIMEOUT_MS = 4_000L
    private const val GETEVENT_TIMEOUT_MS = 4_000L

    @Volatile
    private var cached: WheelVoiceKey? = null

    /** True once a [resolve] attempt has completed (even if it found nothing),
     *  so callers can distinguish "not resolved yet" from "no key on this car". */
    @Volatile
    var attempted: Boolean = false
        private set

    /** The last successfully resolved key, or null if never resolved / none. */
    fun cached(): WheelVoiceKey? = cached

    /**
     * Resolve (and cache) the wheel-voice key. Returns the cached value on
     * subsequent calls unless [force] is set. Returns null when the bridge is
     * unreachable or the ROM declares no accepted voice label.
     */
    fun resolve(force: Boolean = false, shell: (String, Long) -> String = DEFAULT_SHELL): WheelVoiceKey? {
        if (!force) cached?.let { return it }
        // Scancode: direct file read first (no bridge); bridge grep only if
        // the direct read is denied (returns null).
        val grepOut = readKeyLayoutsDirect() ?: safeShell(shell, GREP_CMD, GREP_TIMEOUT_MS)
        // Device node: bridge-only, best-effort (empty → null node, which the
        // a11y / dispatch path tolerates).
        val geteventOut = safeShell(shell, GETEVENT_CMD, GETEVENT_TIMEOUT_MS) ?: ""
        attempted = true
        if (grepOut == null) {
            Log.w(TAG, "keylayout unreadable directly and bridge unreachable")
            return cached
        }
        val key = WheelVoiceKeyParser.resolve(grepOut, geteventOut)
        if (key != null) {
            cached = key
            Log.i(TAG, "resolved wheel-voice key: $key")
        } else {
            Log.i(TAG, "no wheel-voice key declared on this car (grep had ${grepOut.lineSequence().count()} lines)")
        }
        return key
    }

    /**
     * Read the keylayout `.kl` files directly and emit grep-equivalent
     * `path:line` rows (so [WheelVoiceKeyParser.parseCandidates] consumes the
     * same shape as a bridge grep). Returns:
     *   - the matching rows when the dir is readable and has voice labels,
     *   - `""` when the dir is readable but declares no voice label (so the
     *     caller treats it as "no key" and does NOT fall back to the bridge),
     *   - `null` when the dir/files can't be read (SELinux/IO) so the caller
     *     falls back to the bridge grep.
     */
    private fun readKeyLayoutsDirect(): String? {
        return try {
            val files = File(KEYLAYOUT_DIR).listFiles { f -> f.isFile && f.name.endsWith(".kl") }
                ?: return null
            if (files.isEmpty()) return null
            val sb = StringBuilder()
            for (f in files) {
                val text = try { f.readText() } catch (_: Throwable) { continue }
                for (line in text.lineSequence()) {
                    // Cheap case-sensitive pre-filter mirroring the grep
                    // alternation; the parser does the real validation.
                    if (line.contains("AUTO_MEDIA_VOICE") ||
                        line.contains("VOICE_ASSIST") ||
                        line.contains("ASSIST")
                    ) {
                        sb.append(f.absolutePath).append(':').append(line).append('\n')
                    }
                }
            }
            sb.toString()
        } catch (t: Throwable) {
            Log.w(TAG, "direct keylayout read failed: ${t.message}")
            null
        }
    }

    /** Runs [cmd]; returns null if the bridge reported its own error so the
     *  caller treats it as "not resolved" rather than feeding an error banner
     *  into the parser. */
    private fun safeShell(shell: (String, Long) -> String, cmd: String, timeoutMs: Long): String? {
        val out = try {
            shell(cmd, timeoutMs)
        } catch (t: Throwable) {
            Log.w(TAG, "shell threw for '$cmd': ${t.message}")
            return null
        }
        // AdbShellBridge wraps its own failures as "Error: …" bodies.
        if (out.startsWith("Error:")) {
            Log.w(TAG, "bridge error for '$cmd': ${out.take(80)}")
            return null
        }
        return out
    }
}
