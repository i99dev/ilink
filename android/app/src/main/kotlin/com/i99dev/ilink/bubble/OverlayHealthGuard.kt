package com.i99dev.ilink.bubble

import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge

/**
 * Detects and clears stuck system tasks that carry the
 * `HIDE_NON_SYSTEM_OVERLAY_WINDOWS` private window flag. While any
 * such window is alive, Android force-hides every non-system overlay
 * (TYPE_APPLICATION_OVERLAY) — bubble, chat-heads, anything an app
 * draws over its own / other apps. Even with the SYSTEM_ALERT_WINDOW
 * appop granted, the surface is added with alpha=0.0 / shown=false
 * and the user sees nothing.
 *
 * The flag is set legitimately by transient system dialogs (PIN
 * entry, USB-debug confirm, sensitive content). Those normally finish
 * themselves and the flag clears. The bug we work around: BYD's
 * cluster-projection service launches `ResolverActivity` on the
 * cluster display as a "recovery placeholder" after a multi-display
 * activity dies (e.g. an `am force-stop` against an app with a
 * cluster surface), and that placeholder never auto-finishes. The
 * sticky flag silently kills our bubble overlay until reboot.
 *
 * Sweep policy:
 *   * Look only at system-owned windows (`package=android`). Never
 *     touch vendor packages (`com.byd.*`) or our own.
 *   * Require an explicit `rootTaskId` (skip windowless system
 *     layers like the wallpaper / nav bar).
 *   * `am stack remove` via the existing loopback ADB session — same
 *     channel we use everywhere else; no new permission surface.
 *
 * Idempotent: a sweep with nothing to do returns 0. Safe to call
 * from any background thread; must NOT run on the main thread —
 * `AdbShellBridge.shell` does net I/O.
 */
object OverlayHealthGuard {
    private const val TAG = "OverlayHealthGuard"

    /**
     * Scan the WindowManager for stuck overlay-blockers and remove
     * any that match the policy above. Returns the number of tasks
     * removed; 0 means clean (or that the loopback ADB session isn't
     * up yet — the sweep is best-effort).
     *
     * Never throws. All errors land as logged warnings; the caller
     * should treat the return value as advisory, not a hard signal.
     */
    fun sweep(): Int {
        if (!AdbShellBridge.isConnected()) {
            // Loopback ADB isn't up yet (early boot, daemon not
            // bootstrapped). Skip silently — the next legit caller
            // will sweep again once the channel is alive.
            return 0
        }
        val out = try {
            AdbShellBridge.shell("dumpsys window windows", 4_000)
        } catch (t: Throwable) {
            Log.w(TAG, "dumpsys threw: ${t.javaClass.simpleName}: ${t.message}")
            return 0
        }
        val ids = parseStuckTaskIds(out)
        if (ids.isEmpty()) return 0
        var cleared = 0
        for (id in ids) {
            try {
                // `am stack remove N` returns no output on success.
                // Errors land in stderr which AdbShellBridge folds
                // into the result string — we don't gate on content.
                AdbShellBridge.shell("am stack remove $id", 3_000)
                cleared++
                Log.i(TAG, "removed stuck overlay-blocker taskId=$id")
            } catch (t: Throwable) {
                Log.w(TAG, "remove taskId=$id threw: ${t.message}")
            }
        }
        return cleared
    }

    /**
     * Parse `dumpsys window windows` output into the set of taskIds
     * that should be removed: system-owned (`package=android`)
     * windows whose private-flags include
     * `HIDE_NON_SYSTEM_OVERLAY_WINDOWS`.
     *
     * Internal-but-public so `OverlayHealthGuardTest` can pin the
     * parser against captured fixtures — the shell invocation and
     * `am stack remove` are environmental and not unit-testable.
     */
    fun parseStuckTaskIds(dumpsys: String): Set<Int> {
        // dumpsys groups windows under "Window #N Window{...}" headers.
        // Split on that pattern (lookahead so we keep the header on
        // the next section), then per-window check the three criteria
        // (system-owned, has rootTaskId, has flag) inside the section.
        val sections = dumpsys.split(Regex("(?=Window #\\d+ Window\\{)"))
        val ids = mutableSetOf<Int>()
        val taskIdRegex = Regex("""rootTaskId=(\d+)""")
        for (section in sections) {
            if (!section.contains("HIDE_NON_SYSTEM_OVERLAY_WINDOWS")) continue
            // Match `package=android ` with the trailing space so a
            // package whose name *starts* with "android" (e.g.
            // `package=android.something`) doesn't false-positive.
            // The dumpsys format always has another field after.
            if (!section.contains("package=android ")) continue
            val taskId = taskIdRegex.find(section)?.groupValues?.get(1)?.toIntOrNull()
                ?: continue
            if (taskId <= 0) continue
            ids.add(taskId)
        }
        return ids
    }
}
