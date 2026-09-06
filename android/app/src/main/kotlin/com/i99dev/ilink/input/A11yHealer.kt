package com.i99dev.ilink.input

import android.content.Context
import android.content.pm.PackageManager
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.util.Log

/**
 * Self-heals a "crashed" accessibility service without ADB.
 *
 * When our process dies (OOM / kill / force-stop after a sideload) the
 * framework's AccessibilityManagerService marks our a11y services "crashed" and
 * then REFUSES to rebind them until `enabled_accessibility_services` is toggled.
 * The services stay listed in that CSV — so they still LOOK enabled — but are
 * never bound, so no window events reach [NavA11yDispatcher] and the whole
 * nav-HUD a11y pipeline (Maps / Yandex / Waze) is starved: the panel shows
 * "Waiting for a navigation app…" for every nav app at once.
 *
 * The append-only enable (AdbBootstrap.ENABLE_A11Y_CMD) can't fix this: the
 * component is already in the CSV, so re-adding it is a no-op. Only a real
 * remove-then-re-add toggle clears the crashed flag and forces a rebind — which
 * is exactly what a manual `settings put` toggle does on-car.
 *
 * Detection is in-process and does not depend on the framework's CSV-derived
 * "enabled list" (which keeps reporting a crashed service as enabled): each
 * service stores a live [RemoteControlAccessibilityService.instance] /
 * [WatchdogAccessibilityService.instance] on `onServiceConnected` and clears it
 * on unbind/destroy. A service that is listed in the CSV but whose `instance`
 * is null (past a startup grace window) is crashed.
 *
 * We hold WRITE_SECURE_SETTINGS on the car, so the toggle needs no ADB. The
 * heal only ever touches OUR two services and preserves every other a11y
 * service the user enabled (TalkBack, BYD voice, etc.). Idempotent + rate
 * limited, so it is safe to call from `onResume` and the HUD arm path.
 */
object A11yHealer {
    private const val TAG = "A11yHealer"
    private const val PKG = "com.i99dev.ilink"
    private const val REMOTE = "$PKG/$PKG.input.RemoteControlAccessibilityService"
    private const val WATCHDOG = "$PKG/$PKG.input.WatchdogAccessibilityService"

    // A freshly spawned process has instance == null transiently while the
    // framework is still binding our services — don't mistake that for a crash.
    private const val STARTUP_GRACE_MS = 6_000L

    // A toggle takes a moment to rebind; never thrash the setting.
    private const val MIN_INTERVAL_MS = 15_000L

    // Gap between the remove and re-add writes so the framework's ContentObserver
    // actually observes the intermediate (removed) state — two back-to-back writes
    // can be coalesced to the final value (== original), which would rebind nothing.
    private const val TOGGLE_GAP_MS = 800L

    private val processStartMs = SystemClock.elapsedRealtime()

    @Volatile private var lastHealMs = 0L

    /**
     * Re-toggle the enabled-services CSV iff one of our enabled a11y services is
     * crashed (listed but unbound). No-op when healthy, when the user never
     * enabled the service, or without WRITE_SECURE_SETTINGS. Gated by a startup
     * grace window and rate limited. The toggle runs on a short worker thread so
     * the caller's thread (typically the main thread) is never blocked.
     */
    /**
     * Ensure our two a11y services are ENABLED — no Settings/diagnostics trip. If
     * either is missing from the enabled-services CSV, append it (+ flip
     * `accessibility_enabled` on) so the framework binds it; if it's listed but
     * crashed, re-toggle via [healIfCrashed]. Safe to call on every app open
     * (`onResume`) and on HUD arm — idempotent (writes only when something is
     * missing), off the caller's thread. No-op without WRITE_SECURE_SETTINGS (held
     * on the car / self-granted once via wireless debugging) and preserves every
     * foreign a11y service. This is what removes the need to manually enable the
     * services from the diagnostics page each launch.
     */
    @Synchronized
    fun ensureEnabled(context: Context) {
        val ctx = context.applicationContext
        if (!hasWriteSecure(ctx)) return
        val cr = ctx.contentResolver
        val csv = Settings.Secure.getString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
        val listed = csv.split(':').filter { it.isNotBlank() }.distinct()
        val merged = planEnable(listed)
        if (merged == null) {
            // Both already enabled — only a crashed binding needs fixing.
            healIfCrashed(ctx)
            return
        }
        Thread {
            runCatching {
                Settings.Secure.putString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, merged)
                Settings.Secure.putInt(cr, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
                Log.e(TAG, "auto-enabled a11y services (was missing)")
            }.onFailure { Log.w(TAG, "ensureEnabled failed: ${it.message}") }
        }.start()
    }

    /** Pure (host-testable): the CSV with our services appended (foreign services
     *  preserved in order), or null when both are already listed. */
    internal fun planEnable(listed: List<String>): String? {
        val missing = listOf(REMOTE, WATCHDOG).filter { it !in listed }
        return if (missing.isEmpty()) null else (listed + missing).joinToString(":")
    }

    private fun hasWriteSecure(ctx: Context): Boolean =
        ctx.checkPermission(
            android.Manifest.permission.WRITE_SECURE_SETTINGS,
            Process.myPid(),
            Process.myUid(),
        ) == PackageManager.PERMISSION_GRANTED

    @Synchronized
    fun healIfCrashed(context: Context) {
        val ctx = context.applicationContext
        if (!hasWriteSecure(ctx)) return

        val now = SystemClock.elapsedRealtime()
        if (now - processStartMs < STARTUP_GRACE_MS) return
        if (lastHealMs != 0L && now - lastHealMs < MIN_INTERVAL_MS) return

        val csv = Settings.Secure.getString(
            ctx.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return
        val listed = csv.split(':').filter { it.isNotBlank() }.distinct()

        // Only a service the user actually enabled can be "crashed"; an absent
        // service just means the user hasn't turned it on — nothing to heal.
        val crashed = buildList {
            if (REMOTE in listed && RemoteControlAccessibilityService.instance == null) add(REMOTE)
            if (WATCHDOG in listed && WatchdogAccessibilityService.instance == null) add(WATCHDOG)
        }
        val plan = planToggle(listed, crashed) ?: return

        lastHealMs = now
        val cr = ctx.contentResolver
        Thread {
            runCatching {
                Settings.Secure.putString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, plan.first)
                Thread.sleep(TOGGLE_GAP_MS)
                Settings.Secure.putString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, plan.second)
                // Log.e survives release proguard (BYD keeps E-tags) — visible in triage.
                Log.e(TAG, "re-toggled crashed a11y services: $crashed")
            }.onFailure { Log.w(TAG, "heal failed: ${it.message}") }
        }.start()
    }

    /**
     * Pure CSV toggle planner (host-testable). Given the currently-listed
     * services and the subset of OURS that are crashed, returns
     * `(without, with)` — the CSV with our services removed, then the CSV with
     * our enabled services re-appended (every foreign service preserved in
     * order). Returns null when nothing is crashed.
     */
    internal fun planToggle(listed: List<String>, crashed: List<String>): Pair<String, String>? {
        if (crashed.isEmpty()) return null
        val ours = listOf(REMOTE, WATCHDOG).filter { it in listed }
        val others = listed.filter { it != REMOTE && it != WATCHDOG }
        return others.joinToString(":") to (others + ours).joinToString(":")
    }
}
